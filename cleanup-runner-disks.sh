#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Reclaim disposable data from provisioner-managed runner VMs and/or the direct
# potato runner. Docker volumes require a separate explicit opt-in.

MODE=all
TARGET_VM=""
AGGRESSIVE=0
DRY_RUN=0
INCLUDE_HOST_DOCKER=0
INCLUDE_VOLUMES=0
readonly EMERGENCY_DISK_PERCENT=98
readonly LOCK_FILE=/run/lock/runner-fleet-disk-cleanup.lock
readonly POTATO_STATE=/etc/runner-fleet-config/potato-runner.json
readonly POTATO_GITHUB_DIR=/opt/actions-runner
readonly POTATO_FORGEJO_CONFIG=/etc/forgejo-runner/runner-config.yml

log()  { printf '\n🧹 [%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die()  { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./cleanup-runner-disks.sh                 # all managed Incus VMs + local potato
  sudo ./cleanup-runner-disks.sh --incus         # all managed running runner VMs
  sudo ./cleanup-runner-disks.sh --vm NAME       # one owned runner VM
  sudo ./cleanup-runner-disks.sh --local         # direct potato runner only

Options:
  --dry-run              Show targets and disk usage without deleting anything.
  --aggressive           Also drop reusable Actions/tool caches and all unused
                         Docker images/build cache. Volumes still require the
                         separate --include-volumes switch.
  --include-host-docker  Permit Docker pruning on a direct potato host. Without
                         this flag, local cleanup never touches host Docker.
  --include-volumes      Also prune unused Docker volumes. This is never implied
                         by --aggressive and must be requested separately.
  --help                 Show this help.

Cleanup is skipped when an active GitHub worker or Forgejo job container is
detected. Stopped or errored Incus VMs are reported but not started.
EOF
}

while (($#)); do
  case "$1" in
    --all) MODE=all; shift ;;
    --incus) MODE=incus; shift ;;
    --local) MODE=local; shift ;;
    --vm)
      (($# >= 2)) || die "--vm requires an instance name."
      MODE=vm; TARGET_VM="$2"; shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --include-host-docker) INCLUDE_HOST_DOCKER=1; shift ;;
    --include-volumes) INCLUDE_VOLUMES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)." ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."
[[ -z "$TARGET_VM" || "$TARGET_VM" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid VM name."
exec 9>"$LOCK_FILE"
flock -n 9 || die "Another runner disk cleanup is already running."

human_root_usage_local() {
  df -hP / | awk 'NR==1 || NR==2'
}

human_root_usage_vm() {
  local vm="$1"
  incus exec "$vm" -- df -hP / | awk 'NR==1 || NR==2'
}

owned_vm_role() {
  incus config get "$1" user.seele.role 2>/dev/null || true
}

assert_owned_runner_vm() {
  local vm="$1" role
  incus info "$vm" >/dev/null 2>&1 || die "Incus instance '$vm' does not exist."
  role="$(owned_vm_role "$vm")"
  case "$role" in
    runner-v1|github-runner-v1|forgejo-runner-v1) : ;;
    *) die "'$vm' is not marked as a runner owned by this repository (role: ${role:-none})." ;;
  esac
}

vm_state() {
  incus list "$1" --format csv -c s 2>/dev/null | head -n1
}

vm_job_is_active() {
  local vm="$1"
  incus exec "$vm" -- bash -c '
    pgrep -u runner -f "Runner.Worker" >/dev/null 2>&1 && exit 0
    command -v docker >/dev/null 2>&1 && docker ps -q | grep -q . && exit 0
    exit 1
  '
}

vm_root_percent() {
  local vm="$1"
  incus exec "$vm" -- df -P / 2>/dev/null \
    | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

vm_runner_service() {
  local vm="$1" role service
  role="$(owned_vm_role "$vm")"
  case "$role" in
    runner-v1|github-runner-v1)
      service="$(incus exec "$vm" -- sh -c 'cat /opt/actions-runner/.service 2>/dev/null' || true)"
      ;;
    forgejo-runner-v1) service=forgejo-runner.service ;;
  esac
  printf '%s\n' "${service:-}"
}

emergency_kill_vm_work() {
  local vm="$1" service="$2"
  warn "🚨 Emergency cleanup in '$vm': stopping the runner and terminating its current job."
  if [[ -n "$service" ]]; then
    incus exec "$vm" -- timeout 30 systemctl stop "$service" >/dev/null 2>&1 || true
    incus exec "$vm" -- systemctl kill --kill-who=all --signal=SIGKILL "$service" >/dev/null 2>&1 || true
  fi
  incus exec "$vm" -- bash -c '
    pkill -TERM -u runner -f "Runner.Worker" >/dev/null 2>&1 || true
    sleep 2
    pkill -KILL -u runner -f "Runner.Worker" >/dev/null 2>&1 || true
    if command -v docker >/dev/null 2>&1; then
      while IFS= read -r id; do
        [[ -z "$id" ]] || docker kill "$id" >/dev/null 2>&1 || true
      done < <(docker ps -q)
    fi
  '
}

local_job_is_active() {
  pgrep -u runner -f 'Runner.Worker' >/dev/null 2>&1
}

clean_workspaces() {
  local root="$1" aggressive="$2"
  [[ -d "$root" ]] || return 0

  if [[ "$aggressive" == 1 ]]; then
    find "$root" -mindepth 1 -maxdepth 1 -type d -exec rm -rf -- {} +
  else
    find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +1 \
      ! -name _actions ! -name _tool ! -name _temp -exec rm -rf -- {} +
    [[ ! -d "$root/_temp" ]] \
      || find "$root/_temp" -mindepth 1 -mtime +1 -delete
  fi
}

clean_docker() {
  local aggressive="$1" include_volumes="$2"
  if [[ "$aggressive" == 1 ]]; then
    docker container prune -f
    docker network prune -f
    docker image prune -af
    docker builder prune -af
  else
    docker container prune -f --filter 'until=24h'
    docker network prune -f --filter 'until=24h'
    docker image prune -af --filter 'until=168h'
    docker builder prune -af --filter 'until=24h' --keep-storage 2GB \
      || docker builder prune -af --filter 'until=24h'
  fi
  if [[ "$include_volumes" == 1 ]]; then
    docker volume prune -af || docker volume prune -f
  fi
}

write_guest_cleaner() {
  local destination="$1"
  cat >"$destination" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
aggressive="$1"
include_volumes="$2"

clean_workspaces() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  if [[ "$aggressive" == 1 ]]; then
    find "$root" -mindepth 1 -maxdepth 1 -type d -exec rm -rf -- {} +
  else
    find "$root" -mindepth 1 -maxdepth 1 -type d -mtime +1 \
      ! -name _actions ! -name _tool ! -name _temp -exec rm -rf -- {} +
    [[ ! -d "$root/_temp" ]] \
      || find "$root/_temp" -mindepth 1 -mtime +1 -delete
  fi
}

if [[ "$aggressive" == 1 ]]; then
  docker container prune -f
  docker network prune -f
  docker image prune -af
  docker builder prune -af
else
  docker container prune -f --filter 'until=24h'
  docker network prune -f --filter 'until=24h'
  docker image prune -af --filter 'until=168h'
  docker builder prune -af --filter 'until=24h' --keep-storage 2GB \
    || docker builder prune -af --filter 'until=24h'
fi
if [[ "$include_volumes" == 1 ]]; then
  docker volume prune -af || docker volume prune -f
fi

clean_workspaces /opt/actions-runner/_work
if command -v go >/dev/null 2>&1; then
  runuser -u runner -- go clean -cache -testcache || true
fi
apt-get clean
journalctl --vacuum-time=7d >/dev/null
fstrim -av || true
GUEST
  chmod 0700 "$destination"
}

cleanup_vm() {
  local vm="$1" state before after temp_cleaner service service_was_active=0
  local before_pct after_pct emergency=0 cleanup_log cleanup_ok=0 cleanup_aggressive="$AGGRESSIVE"
  assert_owned_runner_vm "$vm"
  state="$(vm_state "$vm")"
  if [[ "$state" != RUNNING ]]; then
    warn "Skipping '$vm': state is ${state:-unknown}; cleanup never starts stopped/error VMs."
    return
  fi
  before_pct="$(vm_root_percent "$vm" || true)"
  if [[ "$before_pct" =~ ^[0-9]+$ ]] && ((before_pct >= EMERGENCY_DISK_PERCENT)); then
    emergency=1
    cleanup_aggressive=1
  fi
  if vm_job_is_active "$vm" && [[ "$emergency" != 1 ]]; then
    warn "Skipping '$vm': an active runner worker or Docker job was detected."
    return
  fi

  log "🐗 Target VM: $vm"
  before="$(human_root_usage_vm "$vm")"
  printf 'Before:\n%s\n' "$before"
  if [[ "$DRY_RUN" == 1 ]]; then
    [[ "$emergency" != 1 ]] \
      || printf 'Dry run: critical disk usage would trigger emergency runner/job termination.\n'
    printf 'Dry run: no files were removed.\n'
    return
  fi

  temp_cleaner="$(mktemp -t runner-guest-clean.XXXXXXXX)"
  write_guest_cleaner "$temp_cleaner"

  service="$(vm_runner_service "$vm")"
  if [[ -n "$service" ]] && incus exec "$vm" -- systemctl is-active --quiet "$service"; then
    service_was_active=1
  fi
  if [[ "$emergency" == 1 ]]; then
    emergency_kill_vm_work "$vm" "$service"
  elif [[ "$service_was_active" == 1 ]]; then
    if ! incus exec "$vm" -- timeout 60 systemctl stop "$service"; then
      rm -f -- "$temp_cleaner"
      incus exec "$vm" -- systemctl start "$service" >/dev/null 2>&1 || true
      warn "Skipping '$vm': its runner service did not stop cleanly."
      return
    fi
  fi
  if vm_job_is_active "$vm"; then
    if [[ "$emergency" == 1 ]]; then
      emergency_kill_vm_work "$vm" "$service"
    else
      [[ "$service_was_active" != 1 ]] || incus exec "$vm" -- systemctl start "$service"
      rm -f -- "$temp_cleaner"
      warn "Skipping '$vm': work appeared while its runner service was being quiesced."
      return
    fi
  fi

  if ! incus file push "$temp_cleaner" "$vm/run/runner-disk-cleanup"; then
    rm -f -- "$temp_cleaner"
    if [[ "$service_was_active" == 1 && "$emergency" != 1 ]]; then
      incus exec "$vm" -- systemctl start "$service" || true
    fi
    die "Could not upload the cleaner to '$vm'."
  fi
  rm -f -- "$temp_cleaner"
  cleanup_log="$(mktemp -t runner-cleanup-log.XXXXXXXX)"
  if incus exec "$vm" -- bash /run/runner-disk-cleanup "$cleanup_aggressive" "$INCLUDE_VOLUMES" \
      2>&1 | tee "$cleanup_log"; then
    cleanup_ok=1
  elif grep -Eqi 'no space left on device|ENOSPC' "$cleanup_log"; then
    warn "'$vm' reported ENOSPC; killing the runner job and retrying cleanup once."
    emergency=1
    cleanup_aggressive=1
    emergency_kill_vm_work "$vm" "$service"
    : >"$cleanup_log"
    if incus exec "$vm" -- bash /run/runner-disk-cleanup "$cleanup_aggressive" "$INCLUDE_VOLUMES" \
        2>&1 | tee "$cleanup_log"; then
      cleanup_ok=1
    fi
  fi
  rm -f -- "$cleanup_log"
  incus exec "$vm" -- rm -f /run/runner-disk-cleanup || true
  if [[ "$cleanup_ok" != 1 ]]; then
    after_pct="$(vm_root_percent "$vm" || true)"
    if { [[ "$after_pct" =~ ^[0-9]+$ ]] && ((after_pct >= EMERGENCY_DISK_PERCENT)); } \
       || { [[ "$emergency" == 1 ]] && [[ ! "$after_pct" =~ ^[0-9]+$ ]]; }; then
      die "Cleanup failed inside '$vm'; its runner stays stopped while disk usage is critical."
    fi
    if [[ "$service_was_active" == 1 ]]; then
      incus exec "$vm" -- systemctl start "$service" || true
    fi
    die "Cleanup failed inside '$vm'; its previous runner service state was restored."
  fi
  after="$(human_root_usage_vm "$vm")"
  printf 'After:\n%s\n' "$after"
  after_pct="$(vm_root_percent "$vm" || true)"
  if [[ "$after_pct" =~ ^[0-9]+$ ]] && ((after_pct >= EMERGENCY_DISK_PERCENT)); then
    warn "'$vm' is still ${after_pct}% full; leaving its runner service stopped so it cannot accept more jobs."
  elif [[ "$emergency" == 1 && ! "$after_pct" =~ ^[0-9]+$ ]]; then
    warn "Could not verify free space after emergency cleanup; leaving '$vm' runner service stopped."
  elif [[ "$service_was_active" == 1 ]]; then
    incus exec "$vm" -- systemctl start "$service"
    log "✅ '$vm' has space again; runner service restarted."
  fi
}

discover_owned_runner_vms() {
  local vm role
  local -a instances=()
  command -v incus >/dev/null 2>&1 || return 0
  mapfile -t instances < <(incus list --format csv -c n)
  for vm in "${instances[@]}"; do
    [[ -n "$vm" ]] || continue
    role="$(owned_vm_role "$vm")"
    case "$role" in
      runner-v1|github-runner-v1|forgejo-runner-v1) printf '%s\n' "$vm" ;;
    esac
  done
}

cleanup_all_incus() {
  command -v incus >/dev/null 2>&1 || { warn "Incus is not installed; no runner VMs to clean."; return; }
  incus admin waitready --timeout=60
  local found=0 vm
  local -a instances=()
  mapfile -t instances < <(discover_owned_runner_vms)
  for vm in "${instances[@]}"; do
    [[ -n "$vm" ]] || continue
    found=1
    cleanup_vm "$vm"
  done
  [[ "$found" == 1 ]] || warn "No provisioner-owned runner VMs were found in the current Incus project."
}

cleanup_local() {
  if [[ ! -s "$POTATO_STATE" ]]; then
    warn "No direct potato runner state found at $POTATO_STATE; local cleanup skipped."
    return
  fi
  command -v jq >/dev/null || die "jq is required to inspect the managed potato state."
  local provider name work_root before after service="" service_was_active=0
  provider="$(jq -er '.provider' "$POTATO_STATE")"
  name="$(jq -er '.name' "$POTATO_STATE")"
  case "$provider" in
    github)
      [[ -f "$POTATO_GITHUB_DIR/.runner-fleet-managed" ]] \
        || die "Local GitHub runner state exists, but its ownership marker is missing."
      work_root="$POTATO_GITHUB_DIR/_work"
      service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
      ;;
    forgejo)
      [[ -f "${POTATO_FORGEJO_CONFIG%/*}/.runner-fleet-managed" ]] \
        || die "Local Forgejo runner state exists, but its ownership marker is missing."
      work_root=""
      ;;
    *) die "Unsupported provider in $POTATO_STATE: $provider" ;;
  esac
  if local_job_is_active; then
    warn "Skipping local runner '$name': an active GitHub worker was detected."
    return
  fi

  log "🥔 Target local runner: $name ($provider)"
  before="$(human_root_usage_local)"
  printf 'Before:\n%s\n' "$before"
  if [[ "$DRY_RUN" == 1 ]]; then
    [[ "$INCLUDE_HOST_DOCKER" != 1 ]] \
      || printf 'Dry run: host Docker pruning was requested but not executed.\n'
    printf 'Dry run: no files were removed.\n'
    return
  fi

  if [[ -n "$service" ]] && systemctl is-active --quiet "$service"; then
    service_was_active=1
    systemctl stop "$service"
  fi
  if local_job_is_active; then
    [[ "$service_was_active" != 1 ]] || systemctl start "$service"
    warn "Skipping local runner '$name': work appeared while its service was being quiesced."
    return
  fi

  if ! (
    [[ -z "$work_root" ]] || clean_workspaces "$work_root" "$AGGRESSIVE"
    if command -v go >/dev/null 2>&1; then
      runuser -u "$(jq -er '.user' "$POTATO_STATE")" -- go clean -cache -testcache || true
    fi
    if [[ "$INCLUDE_HOST_DOCKER" == 1 ]]; then
      warn "Explicitly pruning unused HOST Docker objects."
      clean_docker "$AGGRESSIVE" "$INCLUDE_VOLUMES"
    else
      log "Host Docker cleanup not authorized; leaving all host Docker objects untouched."
      [[ "$INCLUDE_VOLUMES" != 1 ]] \
        || warn "--include-volumes does not apply to host Docker without --include-host-docker."
    fi
    apt-get clean
    journalctl --vacuum-time=7d >/dev/null
  ); then
    [[ "$service_was_active" != 1 ]] || systemctl start "$service" || true
    die "Local cleanup failed; the runner service restart was attempted."
  fi
  [[ "$service_was_active" != 1 ]] || systemctl start "$service"
  after="$(human_root_usage_local)"
  printf 'After:\n%s\n' "$after"
}

main() {
  case "$MODE" in
    all) cleanup_all_incus; cleanup_local ;;
    incus) cleanup_all_incus ;;
    vm)
      command -v incus >/dev/null 2>&1 || die "Incus is not installed."
      incus admin waitready --timeout=60
      cleanup_vm "$TARGET_VM"
      ;;
    local) cleanup_local ;;
  esac
  log "✅ On-demand runner disk cleanup finished."
}

main
