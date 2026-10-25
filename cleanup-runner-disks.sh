#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Reclaim disposable data from provisioner-managed runner VMs and/or the direct
# potato runner. Docker volumes require a separate explicit opt-in.

MODE=all
TARGET_VM=""
AGGRESSIVE=0
DRY_RUN=0
ANALYZE=0
FORCE=0
INCLUDE_HOST_DOCKER=0
INCLUDE_VOLUMES=0
readonly EMERGENCY_DISK_PERCENT=98
readonly WORKSPACE_MAX_AGE_DAYS=1
readonly CACHE_MAX_AGE_DAYS=30
readonly DIAG_MAX_AGE_DAYS=7
readonly LOCK_FILE=/run/lock/runner-fleet-disk-cleanup.lock
readonly POTATO_STATE=/etc/runner-fleet-config/potato-runner.json
readonly POTATO_GITHUB_DIR=/opt/actions-runner
readonly POTATO_FORGEJO_CONFIG=/etc/forgejo-runner/runner-config.yml
readonly GITHUB_WORK_DIR=/opt/actions-runner/_work
readonly GITHUB_DIAG_DIR=/opt/actions-runner/_diag
readonly FORGEJO_WORK_DIR=/home/runner/work
readonly FORGEJO_SERVICE=forgejo-runner.service

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
  --analyze              Report what fills the disk and how much each cleanup
                         mode would reclaim. Read-only: nothing is deleted, no
                         service is stopped and no job is interrupted.
  --dry-run              Show targets and disk usage without deleting anything.
  --aggressive           Also drop reusable Actions/tool caches and all unused
                         Docker images/build cache. Volumes still require the
                         separate --include-volumes switch.
  --force                Terminate a running job instead of skipping the
                         target, and restart its runner afterwards even when
                         the runner was stopped before. A runner whose disk is
                         still at least 98% full stays offline.
  --include-host-docker  Permit Docker pruning on a direct potato host. Without
                         this flag, local cleanup never touches host Docker.
  --include-volumes      Also prune unused Docker volumes. This is never implied
                         by --aggressive and must be requested separately.
  --help                 Show this help.

Cleanup is skipped when an active GitHub worker or Forgejo job container is
detected. Stopped or errored Incus VMs are reported but not started.
--force overrides that skip and forces a runner restart afterwards.
EOF
}

parse_args() {
  MODE=all
  TARGET_VM=""
  AGGRESSIVE=0
  DRY_RUN=0
  ANALYZE=0
  FORCE=0
  INCLUDE_HOST_DOCKER=0
  INCLUDE_VOLUMES=0
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
      --analyze) ANALYZE=1; shift ;;
      --aggressive) AGGRESSIVE=1; shift ;;
      --force) FORCE=1; shift ;;
      --include-host-docker) INCLUDE_HOST_DOCKER=1; shift ;;
      --include-volumes) INCLUDE_VOLUMES=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown option: $1 (use --help)." ;;
    esac
  done
}

require_privileges() {
  [[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."
  [[ -z "$TARGET_VM" || "$TARGET_VM" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid VM name."
  mkdir -p /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another runner disk cleanup is already running."
}

# ---------------------------------------------------------------------------
# Shared cleanup helpers.
#
# The text below is emitted verbatim into the guest cleaner and is also
# sourced on the host, so a workspace is judged stale in exactly the same way
# everywhere. Keep it free of host-specific assumptions.
# ---------------------------------------------------------------------------
write_shared_constants() {
  cat <<'CONSTANTS'
readonly WORKSPACE_MAX_AGE_DAYS=1
readonly CACHE_MAX_AGE_DAYS=30
readonly DIAG_MAX_AGE_DAYS=7
CONSTANTS
}

write_cleanup_helpers() {
  cat <<'HELPERS'
# Docker reports human sizes; the estimates need bytes.
to_bytes() {
  awk -v value="$1" 'BEGIN {
    number = value + 0
    unit = ""
    if (match(value, /[kKmMgGtTpP]?[Bb]$/)) {
      unit = tolower(substr(value, RSTART, 1))
    }
    if (unit == "k") number *= 1024
    else if (unit == "m") number *= 1024 * 1024
    else if (unit == "g") number *= 1024 * 1024 * 1024
    else if (unit == "t") number *= 1024 * 1024 * 1024 * 1024
    else if (unit == "p") number *= 1024 * 1024 * 1024 * 1024 * 1024
    printf "%d", number
  }'
}

human_bytes() {
  local bytes="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%sB' "$bytes"
  else
    printf '%sB' "$bytes"
  fi
}

# Bytes Docker reports as reclaimable for one object type.
docker_reclaimable_bytes() {
  local wanted="$1" line type reclaim
  while IFS= read -r line; do
    type="${line%%|*}"
    if [[ "$type" == "$wanted" ]]; then
      reclaim="${line##*|}"
      to_bytes "$reclaim"
      return 0
    fi
  done < <(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null || true)
  printf '0\n'
}

# A workspace is stale when none of its files were touched recently.
# The directory mtime is deliberately ignored: a repository that ran a job
# today keeps a fresh mtime while its stale checkouts underneath survive.
workspace_is_stale() {
  local dir="$1" age_days="$2"
  [[ -d "$dir" ]] || return 1
  find "$dir" -xdev -type f -newermt "-${age_days} days" -print -quit 2>/dev/null \
    | grep -q . && return 1
  return 0
}

# Remove runner workspaces. Aggressive mode removes everything, otherwise only
# workspaces whose newest file is older than age_days.
clean_workspaces() {
  local root="$1" age_days="$2" aggressive="$3" dir name
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' dir; do
    name="$(basename -- "$dir")"
    case "$name" in
      _actions|_tool|_temp) continue ;;
    esac
    if [[ "$aggressive" == 1 ]] || workspace_is_stale "$dir" "$age_days"; then
      rm -rf -- "$dir"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0)
}

# Remove the runner's temporary job directories. The old-directory list is
# captured before the files are deleted, because deleting a file refreshes the
# mtime of its parent. Directories are removed with rmdir, which tolerates a
# directory that still holds recent files instead of aborting the cleanup.
clean_temp() {
  local root="$1" age_days="$2" aggressive="$3" dir old_dirs
  [[ -d "$root" ]] || return 0
  if [[ "$aggressive" == 1 ]]; then
    find "$root" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    return 0
  fi
  old_dirs="$(mktemp)"
  find "$root" -depth -mindepth 1 -type d -mtime "+${age_days}" -print >"$old_dirs" 2>/dev/null || true
  find "$root" -mindepth 1 -mtime "+${age_days}" \( -type f -o -type l \) -delete 2>/dev/null || true
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    rmdir -- "$dir" 2>/dev/null || true
  done <"$old_dirs"
  rm -f -- "$old_dirs"
}

# Drop downloaded action and runner-tool versions that have not been used for
# a while. The newest version of each package is always kept so a job can
# still find its tool without a re-download.
clean_cache_versions() {
  local base="$1" age_days="$2" aggressive="$3" pkg dir newest
  [[ -d "$base" ]] || return 0
  if [[ "$aggressive" == 1 ]]; then
    find "$base" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    return 0
  fi
  while IFS= read -r -d '' pkg; do
    local -a versions=()
    while IFS= read -r -d '' dir; do
      versions+=("$dir")
    done < <(find "$pkg" -mindepth 1 -maxdepth 1 -type d -print0)
    ((${#versions[@]} > 0)) || continue
    newest="${versions[0]}"
    for dir in "${versions[@]}"; do
      if [[ "$dir" -nt "$newest" ]]; then
        newest="$dir"
      fi
    done
    for dir in "${versions[@]}"; do
      if [[ "$dir" != "$newest" ]] && workspace_is_stale "$dir" "$age_days"; then
        rm -rf -- "$dir"
      fi
    done
  done < <(find "$base" -depth -mindepth 1 -type d -print0)
}

# Remove runner diagnostic logs. The runner never prunes them by itself.
clean_diag_logs() {
  local diag_dir="$1" age_days="$2" aggressive="$3"
  [[ -d "$diag_dir" ]] || return 0
  if [[ "$aggressive" == 1 ]]; then
    find "$diag_dir" -mindepth 1 -maxdepth 1 -type f -delete
  else
    find "$diag_dir" -mindepth 1 -maxdepth 1 -type f -mtime "+${age_days}" -delete
  fi
  find "$diag_dir" -mindepth 1 -maxdepth 1 -type d -empty -delete
}
HELPERS
}

# The host uses the very same helpers that are embedded in the guest scripts,
# so a workspace is judged stale in exactly the same way everywhere.
# shellcheck source=/dev/null
source <(write_cleanup_helpers)

# ---------------------------------------------------------------------------
# Guest cleaner
# ---------------------------------------------------------------------------
write_guest_cleaner() {
  local destination="$1"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    write_shared_constants
    write_cleanup_helpers
    cat <<'GUEST'
aggressive="$1"
include_volumes="$2"
work_dir="$3"
diag_dir="$4"
age_days="$5"

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
else
  # Unused volumes are the one thing the cleaner never touches on its own,
  # and they are a common reason a runner keeps running out of space.
  reclaimable_volumes="$(docker_reclaimable_bytes 'Local Volumes')"
  if [[ "$reclaimable_volumes" =~ ^[0-9]+$ ]] && ((reclaimable_volumes > 0)); then
    printf '⚠️  %s of unused Docker volumes were NOT pruned (they need --include-volumes).\n' \
      "$(human_bytes "$reclaimable_volumes")"
  fi
fi

clean_workspaces "$work_dir" "$age_days" "$aggressive"
clean_temp "${work_dir}/_temp" "$age_days" "$aggressive"
clean_cache_versions "${work_dir}/_actions" "$CACHE_MAX_AGE_DAYS" "$aggressive"
clean_cache_versions "${work_dir}/_tool" "$CACHE_MAX_AGE_DAYS" "$aggressive"
clean_diag_logs "$diag_dir" "$DIAG_MAX_AGE_DAYS" "$aggressive"

if command -v go >/dev/null 2>&1; then
  runuser -u runner -- go clean -cache -testcache || true
fi
apt-get clean
journalctl --vacuum-time=7d >/dev/null
fstrim -av || true
GUEST
  } >"$destination"
  chmod 0700 "$destination"
}

# ---------------------------------------------------------------------------
# Guest analyzer
#
# Prints a stable, machine-readable stream that the host formats. The analyzer
# never deletes anything, never stops a service and never interrupts a job.
# ---------------------------------------------------------------------------
write_guest_analyzer() {
  local destination="$1"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    write_shared_constants
    write_cleanup_helpers
    cat <<'ANALYZE'
work_dir="$1"
diag_dir="$2"
age_days="$3"

emit() { printf '%s\n' "$*"; }

dir_bytes() {
  du -x -B1 -s "$1" 2>/dev/null | awk 'NR==1 {print $1; exit}'
}

# Bytes of unused images that were created more than age_days ago. Normal
# cleanup only prunes images unused for a week, so this is the part it can
# actually reclaim.
unused_old_image_bytes() {
  local age_days="$1" id created size created_epoch cutoff total=0
  local -A in_use=()
  cutoff=$(( $(date +%s) - age_days * 86400 ))
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    in_use["$id"]=1
  done < <(docker ps -aq 2>/dev/null \
    | xargs -r docker inspect --format '{{.Image}}' 2>/dev/null || true)
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ -z "${in_use[$id]:-}" ]] || continue
    created="$(docker image inspect --format '{{.Created}}' "$id" 2>/dev/null || true)"
    size="$(docker image inspect --format '{{.Size}}' "$id" 2>/dev/null || true)"
    [[ -n "$created" && -n "$size" ]] || continue
    created_epoch="$(date -d "$created" +%s 2>/dev/null || echo 0)"
    if ((created_epoch > 0 && created_epoch < cutoff)); then
      total=$(( total + size ))
    fi
  done < <(docker image ls -q --no-trunc 2>/dev/null | sort -u)
  printf '%s\n' "$total"
}

dangling_volume_bytes() {
  local volume mountpoint total=0 size
  while IFS= read -r volume; do
    [[ -n "$volume" ]] || continue
    mountpoint="$(docker volume inspect --format '{{.Mountpoint}}' "$volume" 2>/dev/null || true)"
    [[ -n "$mountpoint" && -d "$mountpoint" ]] || continue
    size="$(dir_bytes "$mountpoint")"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    total=$(( total + size ))
  done < <(docker volume ls -q --filter dangling=true 2>/dev/null || true)
  printf '%s\n' "$total"
}

# Space that was deleted but is still held open by a running process. The
# directory entry is gone, so du cannot see it, yet the filesystem keeps the
# blocks until the holder closes the file. No amount of cleanup reclaims it.
deleted_open_files() {
  local fd target key size pid comm total=0 count=0 top_bytes=0 top_holder=""
  local -A seen=()
  for fd in /proc/[0-9]*/fd/*; do
    target="$(readlink "$fd" 2>/dev/null || true)"
    case "$target" in
      *"(deleted)") ;;
      *) continue ;;
    esac
    # Anonymous memory files live in RAM, not on the filesystem.
    case "$target" in
      /memfd:*) continue ;;
    esac
    key="$(stat -L -c '%d:%i' "$fd" 2>/dev/null || true)"
    [[ -n "$key" ]] || continue
    [[ -z "${seen[$key]:-}" ]] || continue
    seen["$key"]=1
    size="$(stat -L -c %s "$fd" 2>/dev/null || echo 0)"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    count=$(( count + 1 ))
    total=$(( total + size ))
    if ((size > top_bytes)); then
      top_bytes="$size"
      pid="$(basename -- "$(dirname -- "$(dirname -- "$fd")")")"
      comm="$(cat "/proc/$pid/comm" 2>/dev/null || echo 'unknown')"
      top_holder="${comm}:${pid}"
    fi
  done
  printf 'count=%s|bytes=%s|top_bytes=%s|holder=%s\n' "$count" "$total" "$top_bytes" "$top_holder"
}

read -r total used free pct < <(df -PB1 / | awk 'NR==2 {gsub(/%/, "", $5); print $2, $3, $4, $5}')
emit "ROOT|total=${total}|used=${used}|free=${free}|pct=${pct}"

while IFS=$'\t' read -r bytes path; do
  [[ -n "$path" ]] || continue
  if [[ "$path" == "/" ]]; then
    continue
  fi
  # Tiny system directories are noise; only report what actually fills the disk.
  if ((bytes < 1048576)); then
    continue
  fi
  emit "TOP|path=${path}|bytes=${bytes}"
done < <(du -x -B1 --max-depth=1 / 2>/dev/null | sort -rn)

if [[ -n "$work_dir" && -d "$work_dir" ]]; then
  emit "WSROOT|path=${work_dir}"
  while IFS=$'\t' read -r bytes path; do
    [[ -n "$path" ]] || continue
    if [[ "$path" == "$work_dir" ]]; then
      continue
    fi
    name="$(basename -- "$path")"
    case "$name" in
      _actions|_tool|_temp)
        emit "WSSUB|name=${name}|bytes=${bytes}"
        continue
        ;;
    esac
    stale=no
    if workspace_is_stale "$path" "$age_days"; then
      stale=yes
    fi
    newest="$(find "$path" -xdev -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -r | head -n1)"
    emit "WS|name=${name}|bytes=${bytes}|stale=${stale}|newest=${newest:-unknown}"
  done < <(du -x -B1 --max-depth=1 "$work_dir" 2>/dev/null | sort -rn)
fi

# Only report Docker when its daemon actually answers, otherwise the command
# prints an error where the report expects data.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    type="${line%%|*}"
    size="${line#*|}"
    size="${size%%|*}"
    reclaim="${line##*|}"
    total_bytes="$(to_bytes "$size")"
    reclaim_bytes="$(to_bytes "$reclaim")"
    old_bytes=0
    if [[ "$type" == "Images" ]]; then
      old_bytes="$(unused_old_image_bytes 7)"
    fi
    emit "DOCKER|type=${type}|total=${size}|reclaimable=${reclaim}|total_bytes=${total_bytes}|reclaim_bytes=${reclaim_bytes}|old_bytes=${old_bytes}"
  done < <(docker system df --format '{{.Type}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null || true)
  emit "VOLUME|count=$(docker volume ls -q --filter dangling=true 2>/dev/null | grep -cE '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || true)|bytes=$(dangling_volume_bytes)"
fi

emit "CACHE|kind=apt|bytes=$(dir_bytes /var/cache/apt/archives)"
emit "CACHE|kind=journal|bytes=$(dir_bytes /var/log/journal)"
if [[ -n "$diag_dir" && -d "$diag_dir" ]]; then
  emit "CACHE|kind=diag|bytes=$(dir_bytes "$diag_dir")|old_bytes=$(find "$diag_dir" -mindepth 1 -maxdepth 1 -type f -mtime "+${DIAG_MAX_AGE_DAYS}" -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print s + 0}')"
else
  emit "CACHE|kind=diag|bytes=0|old_bytes=0"
fi
emit "CACHE|kind=go|bytes=$(dir_bytes /home/runner/.cache/go-build)"

emit "DELETED|$(deleted_open_files)"

if [[ -e /swapfile ]]; then
  emit "SWAP|bytes=$(stat -c %s /swapfile 2>/dev/null || echo 0)"
fi
ANALYZE
  } >"$destination"
  chmod 0700 "$destination"
}

# ---------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------
human_root_usage_local() {
  df -hP / | awk 'NR==1 || NR==2'
}

human_root_usage_vm() {
  local vm="$1"
  incus exec "$vm" -- df -hP / | awk 'NR==1 || NR==2'
}

to_number() {
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$1"
  else
    printf '0\n'
  fi
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
    forgejo-runner-v1) service=$FORGEJO_SERVICE ;;
  esac
  printf '%s\n' "${service:-}"
}

# Work and diagnostics directories of a runner, per provider.
vm_runner_paths() {
  local vm="$1" role
  role="$(owned_vm_role "$vm")"
  case "$role" in
    forgejo-runner-v1) printf '%s\n%s\n' "$FORGEJO_WORK_DIR" "" ;;
    *) printf '%s\n%s\n' "$GITHUB_WORK_DIR" "$GITHUB_DIAG_DIR" ;;
  esac
}

# Stop the runner and terminate whatever job it is running. This is only ever
# used for Incus VMs, which are owned by this repository.
kill_vm_work() {
  local vm="$1" service="$2" reason="$3"
  warn "🚨 $reason in '$vm': stopping the runner and terminating its current job."
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

# Terminate only the runner worker of the host. The potato shares Docker with
# other host services, so host containers are never killed here.
force_kill_local_work() {
  warn "🔨 --force: terminating the active runner worker on this host."
  pkill -TERM -u runner -f 'Runner.Worker' >/dev/null 2>&1 || true
  sleep 2
  pkill -KILL -u runner -f 'Runner.Worker' >/dev/null 2>&1 || true
}

local_job_is_active() {
  pgrep -u runner -f 'Runner.Worker' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------
analysis_field() {
  local haystack="$1" name="$2" part
  local -a parts
  local IFS='|'
  read -ra parts <<<"$haystack"
  for part in "${parts[@]}"; do
    if [[ "$part" == "$name="* ]]; then
      printf '%s\n' "${part#*=}"
      return 0
    fi
  done
  return 1
}

# Print a parsed analyzer stream as a human report.
print_analysis() {
  local target="$1" provider="$2" stream="$3"
  local line key value kind bytes old
  local -a top_rows=() ws_rows=() ws_sub_rows=() docker_rows=() cache_rows=()
  local root_total=0 root_used=0 root_free=0 root_pct="" work_root=""
  local pct_display="?" shown=0
  local volume_count=0 volume_bytes=0 swap_bytes=0 volumes_reclaim_bytes=0
  local deleted_count=0 deleted_bytes=0 deleted_top_bytes=0 deleted_holder=""
  local est_normal=0 est_aggressive=0
  local -A cache_bytes=() cache_old=()
  local actions_bytes=0 tool_bytes=0
  local images_old_bytes=0 images_reclaim_bytes=0

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%|*}"
    case "$key" in
      ROOT)
        root_total="$(to_number "$(analysis_field "$line" total || echo 0)")"
        root_used="$(to_number "$(analysis_field "$line" used || echo 0)")"
        root_free="$(to_number "$(analysis_field "$line" free || echo 0)")"
        root_pct="$(analysis_field "$line" pct || echo '')"
        if [[ -n "$root_pct" ]]; then
          pct_display="${root_pct}%"
        fi
        ;;
      TOP)
        value="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        top_rows+=("${value}|$(analysis_field "$line" path || echo '')")
        ;;
      WSROOT)
        work_root="$(analysis_field "$line" path || echo '')"
        ;;
      WS)
        value="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        ws_rows+=("${value}|$(analysis_field "$line" name || echo '')|$(analysis_field "$line" stale || echo no)|$(analysis_field "$line" newest || echo unknown)")
        ;;
      WSSUB)
        value="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        case "$(analysis_field "$line" name || echo '')" in
          _actions) actions_bytes="$value" ;;
          _tool) tool_bytes="$value" ;;
        esac
        ws_sub_rows+=("${value}|$(analysis_field "$line" name || echo '')")
        ;;
      DOCKER)
        docker_rows+=("$(analysis_field "$line" type || echo '?')|$(analysis_field "$line" total || echo '?')|$(analysis_field "$line" reclaimable || echo '?')")
        case "$(analysis_field "$line" type || echo '')" in
          Images)
            images_old_bytes="$(to_number "$(analysis_field "$line" old_bytes || echo 0)")"
            images_reclaim_bytes="$(to_number "$(analysis_field "$line" reclaim_bytes || echo 0)")"
            ;;
          Local\ Volumes)
            # Volumes are never pruned without --include-volumes, so they
            # must not inflate the normal or aggressive estimate.
            volumes_reclaim_bytes="$(to_number "$(analysis_field "$line" reclaim_bytes || echo 0)")"
            ;;
          *)
            value="$(to_number "$(analysis_field "$line" reclaim_bytes || echo 0)")"
            est_normal=$(( est_normal + value ))
            est_aggressive=$(( est_aggressive + value ))
            ;;
        esac
        ;;
      CACHE)
        kind="$(analysis_field "$line" kind || echo unknown)"
        bytes="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        old="$(to_number "$(analysis_field "$line" old_bytes || echo "$bytes")")"
        cache_bytes["$kind"]="$bytes"
        cache_old["$kind"]="$old"
        cache_rows+=("${kind}|${bytes}|${old}")
        ;;
      VOLUME)
        volume_count="$(to_number "$(analysis_field "$line" count || echo 0)")"
        volume_bytes="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        ;;
      DELETED)
        deleted_count="$(to_number "$(analysis_field "$line" count || echo 0)")"
        deleted_bytes="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        deleted_top_bytes="$(to_number "$(analysis_field "$line" top_bytes || echo 0)")"
        deleted_holder="$(analysis_field "$line" holder || echo '')"
        ;;
      SWAP)
        swap_bytes="$(to_number "$(analysis_field "$line" bytes || echo 0)")"
        ;;
    esac
  done <<<"$stream"

  for row in "${ws_rows[@]}"; do
    IFS='|' read -r bytes name stale newest <<<"$row"
    bytes="$(to_number "$bytes")"
    if [[ "$stale" == "yes" ]]; then
      est_normal=$(( est_normal + bytes ))
    fi
    est_aggressive=$(( est_aggressive + bytes ))
  done
  est_normal=$(( est_normal + images_old_bytes ))
  est_aggressive=$(( est_aggressive + images_reclaim_bytes ))
  est_aggressive=$(( est_aggressive + actions_bytes + tool_bytes ))
  for kind in apt journal diag; do
    est_normal=$(( est_normal + ${cache_old[$kind]:-0} ))
    est_aggressive=$(( est_aggressive + ${cache_bytes[$kind]:-0} ))
  done

  printf '\n🔍 Disk analysis — %s (%s)\n' "$target" "$provider"
  printf '   Root: %s/%s used (%s), %s free\n' \
    "$(human_bytes "$root_used")" "$(human_bytes "$root_total")" "$pct_display" "$(human_bytes "$root_free")"

  if ((${#top_rows[@]} > 0)); then
    printf '\nTop-level consumers of /\n'
    shown=0
    for row in "${top_rows[@]}"; do
      ((shown < 12)) || break
      IFS='|' read -r bytes path <<<"$row"
      printf '   %8s  %s\n' "$(human_bytes "$bytes")" "$path"
      shown=$(( shown + 1 ))
    done
  fi

  if ((${#ws_rows[@]} > 0 || ${#ws_sub_rows[@]} > 0)); then
    printf '\nRunner workspaces — %s\n' "${work_root:-unknown}"
    for row in "${ws_rows[@]}"; do
      IFS='|' read -r bytes name stale newest <<<"$row"
      if [[ "$stale" == "yes" ]]; then
        printf '   %8s  %-14s stale (newest file %s)  ← lingering checkout\n' \
          "$(human_bytes "$bytes")" "$name" "$newest"
      else
        printf '   %8s  %-14s in use (newest file %s)\n' \
          "$(human_bytes "$bytes")" "$name" "$newest"
      fi
    done
    for row in "${ws_sub_rows[@]}"; do
      IFS='|' read -r bytes name <<<"$row"
      printf '   %8s  %-14s kept by normal cleanup, dropped by --aggressive\n' \
        "$(human_bytes "$bytes")" "$name"
    done
  fi

  if ((${#docker_rows[@]} > 0)); then
    printf '\nDocker\n'
    for row in "${docker_rows[@]}"; do
      IFS='|' read -r type total reclaim <<<"$row"
      printf '   %-14s %s total, %s reclaimable\n' "$type" "$total" "$reclaim"
    done
  fi

  if ((${#cache_rows[@]} > 0)); then
    printf '\nLogs and caches\n'
    for row in "${cache_rows[@]}"; do
      IFS='|' read -r kind bytes old <<<"$row"
      case "$kind" in
        diag)
          printf '   %8s  runner _diag logs (older than %s days: %s)\n' \
            "$(human_bytes "$bytes")" "$DIAG_MAX_AGE_DAYS" "$(human_bytes "$old")"
          ;;
        journal)
          printf '   %8s  systemd journal\n' "$(human_bytes "$bytes")"
          ;;
        apt)
          printf '   %8s  apt cache\n' "$(human_bytes "$bytes")"
          ;;
        go)
          printf '   %8s  Go build cache\n' "$(human_bytes "$bytes")"
          ;;
        *)
          printf '   %8s  %s\n' "$(human_bytes "$bytes")" "$kind"
          ;;
      esac
    done
  fi

  if ((swap_bytes > 0)); then
    printf '   %8s  /swapfile (never removed automatically)\n' "$(human_bytes "$swap_bytes")"
  fi

  if ((deleted_count > 0)); then
    printf '\n⚠️  Deleted files still held open — no cleanup can reclaim these\n'
    printf '   %8s  in %s deleted file(s), largest %s held by %s\n' \
      "$(human_bytes "$deleted_bytes")" "$deleted_count" \
      "$(human_bytes "$deleted_top_bytes")" "${deleted_holder:-unknown}"
    printf '   The blocks stay on the filesystem until that process closes the file.\n'
    printf '   Restart the holder (usually the runner service) to release the space.\n'
  fi

  printf '\nReclaim estimate\n'
  printf '   normal cleanup           ~%s\n' "$(human_bytes "$est_normal")"
  printf '   aggressive cleanup       ~%s\n' "$(human_bytes "$est_aggressive")"
  if ((volume_bytes < volumes_reclaim_bytes)); then
    volume_bytes="$volumes_reclaim_bytes"
  fi
  if ((volume_count > 0)); then
    printf '   with --include-volumes   ~%s  (%s unused volumes)\n' \
      "$(human_bytes "$(( est_aggressive + volume_bytes ))")" "$volume_count"
  else
    printf '   with --include-volumes   ~%s  (no unused volumes)\n' "$(human_bytes "$est_aggressive")"
  fi
}

analyze_vm() {
  local vm="$1" provider state analyzer stream work_dir diag_dir
  local -a paths=()
  assert_owned_runner_vm "$vm"
  state="$(vm_state "$vm")"
  if [[ "$state" != RUNNING ]]; then
    warn "Cannot analyse '$vm': state is ${state:-unknown}. Start it with: sudo ./restart-runners.sh --vm $vm"
    return
  fi
  provider="$(owned_vm_role "$vm")"
  mapfile -t paths < <(vm_runner_paths "$vm")
  work_dir="${paths[0]:-}"
  diag_dir="${paths[1]:-}"
  log "🔍 Analysing VM: $vm ($provider)"
  analyzer="$(mktemp -t runner-guest-analyze.XXXXXXXX)"
  write_guest_analyzer "$analyzer"
  if ! incus file push "$analyzer" "$vm/run/runner-disk-analyze"; then
    rm -f -- "$analyzer"
    warn "Could not upload the analyzer to '$vm'."
    return
  fi
  rm -f -- "$analyzer"
  printf '   scanning %s, this can take a moment on a large filesystem...\n' "$vm"
  stream="$(incus exec "$vm" -- bash /run/runner-disk-analyze "$work_dir" "$diag_dir" "$WORKSPACE_MAX_AGE_DAYS" 2>/dev/null || true)"
  incus exec "$vm" -- rm -f /run/runner-disk-analyze >/dev/null 2>&1 || true
  if [[ -z "$stream" ]]; then
    warn "The analyzer returned no data for '$vm'."
    return
  fi
  print_analysis "$vm" "$provider" "$stream"
}

analyze_local() {
  local provider name analyzer stream work_dir diag_dir user home
  if [[ ! -s "$POTATO_STATE" ]]; then
    warn "No direct potato runner state found at $POTATO_STATE; local analysis skipped."
    return
  fi
  command -v jq >/dev/null || die "jq is required to inspect the managed potato state."
  provider="$(jq -er '.provider' "$POTATO_STATE")"
  name="$(jq -er '.name' "$POTATO_STATE")"
  user="$(jq -er '.user' "$POTATO_STATE")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  work_dir="$GITHUB_WORK_DIR"
  diag_dir="$GITHUB_DIAG_DIR"
  if [[ "$provider" == forgejo ]]; then
    work_dir="${home:-$FORGEJO_WORK_DIR}/work"
    diag_dir=""
  fi
  log "🔍 Analysing local runner: $name ($provider)"
  analyzer="$(mktemp -t runner-host-analyze.XXXXXXXX)"
  write_guest_analyzer "$analyzer"
  printf '   scanning the host filesystem, this can take a moment...\n'
  stream="$(bash "$analyzer" "$work_dir" "$diag_dir" "$WORKSPACE_MAX_AGE_DAYS" 2>/dev/null || true)"
  rm -f -- "$analyzer"
  if [[ -z "$stream" ]]; then
    warn "The analyzer returned no data for the local runner."
    return
  fi
  print_analysis "$name (local)" "$provider" "$stream"
}

analyze_all_incus() {
  command -v incus >/dev/null 2>&1 || { warn "Incus is not installed; no runner VMs to analyse."; return; }
  incus admin waitready --timeout=60
  local vm
  local -a instances=()
  mapfile -t instances < <(discover_owned_runner_vms)
  if ((${#instances[@]} == 0)); then
    warn "No provisioner-owned runner VMs were found in the current Incus project."
    return
  fi
  log "🔍 Analysing ${#instances[@]} runner VM(s)"
  for vm in "${instances[@]}"; do
    [[ -n "$vm" ]] || continue
    analyze_vm "$vm"
  done
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
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

cleanup_vm() {
  local vm="$1" state before after temp_cleaner service service_was_active=0
  local before_pct after_pct emergency=0 cleanup_log cleanup_ok=0 cleanup_aggressive="$AGGRESSIVE"
  local forced=0 work_dir diag_dir
  local -a paths=()
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
    if [[ "$FORCE" != 1 ]]; then
      warn "Skipping '$vm': an active runner worker or Docker job was detected."
      return
    fi
    forced=1
  fi

  mapfile -t paths < <(vm_runner_paths "$vm")
  work_dir="${paths[0]:-}"
  diag_dir="${paths[1]:-}"

  log "🐗 Target VM: $vm"
  before="$(human_root_usage_vm "$vm")"
  printf 'Before:\n%s\n' "$before"
  if [[ "$DRY_RUN" == 1 ]]; then
    [[ "$emergency" != 1 ]] \
      || printf 'Dry run: critical disk usage would trigger emergency runner/job termination.\n'
    [[ "$forced" != 1 ]] \
      || printf 'Dry run: --force would terminate the active job and restart the runner.\n'
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
    kill_vm_work "$vm" "$service" "Emergency cleanup"
  elif [[ "$forced" == 1 ]]; then
    kill_vm_work "$vm" "$service" "--force cleanup"
  elif [[ "$service_was_active" == 1 ]]; then
    if ! incus exec "$vm" -- timeout 60 systemctl stop "$service"; then
      if [[ "$FORCE" != 1 ]]; then
        rm -f -- "$temp_cleaner"
        incus exec "$vm" -- systemctl start "$service" >/dev/null 2>&1 || true
        warn "Skipping '$vm': its runner service did not stop cleanly."
        return
      fi
      warn "🔨 --force: '$service' did not stop cleanly; force-killing it."
      incus exec "$vm" -- systemctl kill --kill-who=all --signal=SIGKILL "$service" >/dev/null 2>&1 || true
    fi
  fi
  if vm_job_is_active "$vm"; then
    if [[ "$emergency" == 1 || "$forced" == 1 ]]; then
      kill_vm_work "$vm" "$service" "Cleanup before a forced restart"
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
      "$work_dir" "$diag_dir" "$WORKSPACE_MAX_AGE_DAYS" \
      2>&1 | tee "$cleanup_log"; then
    cleanup_ok=1
  elif grep -Eqi 'no space left on device|ENOSPC' "$cleanup_log"; then
    warn "'$vm' reported ENOSPC; killing the runner job and retrying cleanup once."
    emergency=1
    cleanup_aggressive=1
    kill_vm_work "$vm" "$service" "Emergency cleanup"
    : >"$cleanup_log"
    if incus exec "$vm" -- bash /run/runner-disk-cleanup "$cleanup_aggressive" "$INCLUDE_VOLUMES" \
        "$work_dir" "$diag_dir" "$WORKSPACE_MAX_AGE_DAYS" \
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
  elif [[ -z "$service" ]]; then
    warn "'$vm' has no runner service metadata; cannot restart its runner."
  elif [[ "$service_was_active" == 1 || "$forced" == 1 || "$FORCE" == 1 ]]; then
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
  local user home diag_root forced=0
  provider="$(jq -er '.provider' "$POTATO_STATE")"
  name="$(jq -er '.name' "$POTATO_STATE")"
  user="$(jq -er '.user' "$POTATO_STATE")"
  home="$(getent passwd "$user" | cut -d: -f6)"
  case "$provider" in
    github)
      [[ -f "$POTATO_GITHUB_DIR/.runner-fleet-managed" ]] \
        || die "Local GitHub runner state exists, but its ownership marker is missing."
      work_root="$GITHUB_WORK_DIR"
      diag_root="$GITHUB_DIAG_DIR"
      service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
      ;;
    forgejo)
      [[ -f "${POTATO_FORGEJO_CONFIG%/*}/.runner-fleet-managed" ]] \
        || die "Local Forgejo runner state exists, but its ownership marker is missing."
      work_root="${home:-$FORGEJO_WORK_DIR}/work"
      diag_root=""
      service="$FORGEJO_SERVICE"
      ;;
    *) die "Unsupported provider in $POTATO_STATE: $provider" ;;
  esac
  if local_job_is_active; then
    if [[ "$FORCE" != 1 ]]; then
      warn "Skipping local runner '$name': an active GitHub worker was detected."
      return
    fi
    forced=1
  fi

  log "🥔 Target local runner: $name ($provider)"
  before="$(human_root_usage_local)"
  printf 'Before:\n%s\n' "$before"
  if [[ "$DRY_RUN" == 1 ]]; then
    [[ "$INCLUDE_HOST_DOCKER" != 1 ]] \
      || printf 'Dry run: host Docker pruning was requested but not executed.\n'
    [[ "$forced" != 1 ]] \
      || printf 'Dry run: --force would terminate the active runner worker and restart the runner.\n'
    printf 'Dry run: no files were removed.\n'
    return
  fi

  if [[ "$forced" == 1 ]]; then
    force_kill_local_work
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
    clean_workspaces "$work_root" "$WORKSPACE_MAX_AGE_DAYS" "$AGGRESSIVE"
    clean_temp "${work_root}/_temp" "$WORKSPACE_MAX_AGE_DAYS" "$AGGRESSIVE"
    clean_cache_versions "${work_root}/_actions" "$CACHE_MAX_AGE_DAYS" "$AGGRESSIVE"
    clean_cache_versions "${work_root}/_tool" "$CACHE_MAX_AGE_DAYS" "$AGGRESSIVE"
    clean_diag_logs "$diag_root" "$DIAG_MAX_AGE_DAYS" "$AGGRESSIVE"
    if command -v go >/dev/null 2>&1; then
      runuser -u "$user" -- go clean -cache -testcache || true
    fi
    if [[ "$INCLUDE_HOST_DOCKER" == 1 ]]; then
      warn "Explicitly pruning unused HOST Docker objects."
      clean_docker "$AGGRESSIVE" "$INCLUDE_VOLUMES"
      if [[ "$INCLUDE_VOLUMES" != 1 ]]; then
        reclaimable_volumes="$(docker_reclaimable_bytes 'Local Volumes')"
        if [[ "$reclaimable_volumes" =~ ^[0-9]+$ ]] && ((reclaimable_volumes > 0)); then
          warn "$(human_bytes "$reclaimable_volumes") of unused HOST Docker volumes were NOT pruned (they need --include-volumes)."
        fi
      fi
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
  if [[ "$service_was_active" == 1 || "$forced" == 1 || "$FORCE" == 1 ]]; then
    if [[ -n "$service" ]]; then
      systemctl start "$service"
      log "✅ Local runner '$name' has space again; runner service restarted."
    else
      warn "Local runner '$name' has no service metadata; cannot restart it."
    fi
  fi
  after="$(human_root_usage_local)"
  printf 'After:\n%s\n' "$after"
}

main() {
  parse_args "$@"
  require_privileges

  if [[ "$ANALYZE" == 1 ]]; then
    case "$MODE" in
      all) analyze_all_incus; analyze_local ;;
      incus) analyze_all_incus ;;
      vm)
        command -v incus >/dev/null 2>&1 || die "Incus is not installed."
        incus admin waitready --timeout=60
        analyze_vm "$TARGET_VM"
        ;;
      local) analyze_local ;;
    esac
    log "✅ Disk analysis finished. Nothing was deleted and no service was restarted."
    return
  fi

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

# Only run when executed directly; sourcing exposes the helpers for the tests.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
