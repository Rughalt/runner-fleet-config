#!/usr/bin/env bash
set -Eeuo pipefail

SWAP_SIZE="${SWAP_SIZE:-2G}"
MIN_HOST_FREE_AFTER_SWAP_GIB="${MIN_HOST_FREE_AFTER_SWAP_GIB:-8}"
ENSURE_SWAP=0
ONLY_VM=""

log()  { printf '\n🐗 [%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die()  { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./restart-runners.sh
  sudo ./restart-runners.sh --ensure-swap
  sudo ./restart-runners.sh --vm selee-trotter-02
  sudo SWAP_SIZE=2G ./restart-runners.sh --ensure-swap

Options:
  --ensure-swap   Safely create/enable /swapfile inside each VM when it has no swap.
  --vm NAME       Operate on one provisioner-owned runner VM only.
  --help          Show this help.

The script discovers GitHub and Forgejo runner VMs through their user.seele.role
ownership marker. It does not register, remove, clone, or reconfigure runners.
EOF
}

while (($#)); do
  case "$1" in
    --ensure-swap) ENSURE_SWAP=1; shift ;;
    --vm)
      (($# >= 2)) || die "--vm requires an instance name."
      ONLY_VM="$2"
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)." ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."
[[ "$SWAP_SIZE" =~ ^[1-9][0-9]*[MG]$ ]] || die "SWAP_SIZE must look like 2048M or 2G."
[[ "$MIN_HOST_FREE_AFTER_SWAP_GIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_HOST_FREE_AFTER_SWAP_GIB must be a positive integer."
command -v incus >/dev/null 2>&1 || die "Incus is not installed."
mkdir -p /run/lock
exec 9>/run/lock/seele-runners.lock
flock -n 9 || die "The runner provisioner or another maintenance run is active. Stop it or wait for it to finish."
incus admin waitready --timeout=60

is_runner_role() {
  case "$1" in
    runner-v1|github-runner-v1|forgejo-runner-v1) return 0 ;;
    *) return 1 ;;
  esac
}

swap_size_mib() {
  case "$SWAP_SIZE" in
    *G) printf '%s\n' "$(( ${SWAP_SIZE%G} * 1024 ))" ;;
    *M) printf '%s\n' "${SWAP_SIZE%M}" ;;
  esac
}

preflight_swap_disk_space() {
  local runner_count="$1" free_mib requested_mib reserve_mib
  [[ "$ENSURE_SWAP" == 1 ]] || return 0
  free_mib="$(df -Pm /var | awk 'NR==2 {print $4}')"
  requested_mib="$(( runner_count * $(swap_size_mib) ))"
  reserve_mib="$(( MIN_HOST_FREE_AFTER_SWAP_GIB * 1024 ))"
  if ((free_mib - requested_mib < reserve_mib)); then
    die "Refusing worst-case ${runner_count} x $SWAP_SIZE VM swap allocation: /var has $((free_mib / 1024)) GiB free and must retain at least ${MIN_HOST_FREE_AFTER_SWAP_GIB} GiB. Add space, select one VM with --vm, or use a smaller SWAP_SIZE."
  fi
  log "💾 Swap preflight: worst case ${runner_count} x $SWAP_SIZE leaves at least $(((free_mib - requested_mib) / 1024)) GiB free on the host."
}

wait_for_agent() {
  local vm="$1" tries=90 state
  until incus exec "$vm" -- true >/dev/null 2>&1; do
    state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
    if [[ "$state" != RUNNING ]]; then
      warn "$vm stopped while waiting for its Incus agent (state: ${state:-unknown})."
      incus info "$vm" --show-log >&2 || true
      return 1
    fi
    ((tries-=1))
    if ((tries <= 0)); then
      warn "$vm agent did not become available within 180 seconds."
      incus info "$vm" --show-log >&2 || true
      return 1
    fi
    sleep 2
  done
}

start_or_recover_vm() {
  local vm="$1" state tries
  state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"

  if [[ "$state" == ERROR ]]; then
    warn "$vm is in Incus ERROR state; force-stopping the owned runner VM to clear stale QEMU state."
    incus stop "$vm" --force >/dev/null 2>&1 || true
    tries=15
    while ((tries > 0)); do
      state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
      [[ "$state" != ERROR ]] && break
      ((tries-=1))
      sleep 1
    done
    if [[ "$state" == ERROR ]]; then
      warn "$vm remains in ERROR after a forced stop."
      incus info "$vm" --show-log >&2 || true
      return 1
    fi
    log "🩹 Cleared stale ERROR state for '$vm' (now: ${state:-unknown})."
  fi

  if [[ "$state" != RUNNING ]]; then
    log "✨ Starting sleeping runner VM '$vm'"
    if ! incus start "$vm"; then
      warn "Incus could not start $vm."
      incus info "$vm" --show-log >&2 || true
      return 1
    fi
  fi
  return 0
}

ensure_swap() {
  local vm="$1"
  if incus exec "$vm" -- swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    log "💾 $vm already has active swap; leaving it unchanged."
    return
  fi

  log "💾 Giving $vm a $SWAP_SIZE emergency snack for hungry compilers"
  incus exec "$vm" --env REQUESTED_SWAP_SIZE="$SWAP_SIZE" -- bash -c '
set -Eeuo pipefail
swapfile=/swapfile
if [[ -e "$swapfile" ]] && [[ "$(blkid -p -s TYPE -o value "$swapfile" 2>/dev/null || true)" != swap ]]; then
  echo "$swapfile exists but is not a swap file; refusing to overwrite it" >&2
  exit 1
fi
if [[ ! -e "$swapfile" ]]; then
  if ! fallocate -l "$REQUESTED_SWAP_SIZE" "$swapfile"; then
    case "$REQUESTED_SWAP_SIZE" in
      *G) swap_mib="$(( ${REQUESTED_SWAP_SIZE%G} * 1024 ))" ;;
      *M) swap_mib="${REQUESTED_SWAP_SIZE%M}" ;;
    esac
    dd if=/dev/zero of="$swapfile" bs=1M count="$swap_mib" status=progress
  fi
  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
fi
grep -Eq "^[[:space:]]*/swapfile[[:space:]]" /etc/fstab \
  || printf "/swapfile none swap sw 0 0\n" >>/etc/fstab
swapon "$swapfile"
'
  incus exec "$vm" -- swapon --show
}

github_service_name() {
  local vm="$1" service
  service="$(incus exec "$vm" -- sh -c 'cat /opt/actions-runner/.service 2>/dev/null' || true)"
  [[ -n "$service" ]] || return 1
  printf '%s\n' "$service"
}

restart_one() {
  local vm="$1" role state service
  role="$(incus config get "$vm" user.seele.role 2>/dev/null || true)"
  if ! is_runner_role "$role"; then
    warn "$vm is not marked as an owned runner VM (role: ${role:-none})."
    return 1
  fi

  start_or_recover_vm "$vm" || return 1
  wait_for_agent "$vm" || return 1

  [[ "$ENSURE_SWAP" == 1 ]] && ensure_swap "$vm"

  case "$role" in
    runner-v1|github-runner-v1)
      if ! service="$(github_service_name "$vm")"; then
        warn "$vm has no GitHub Actions service metadata."
        return 1
      fi
      ;;
    forgejo-runner-v1) service=forgejo-runner.service ;;
  esac

  log "🔄 Restarting $service in '$vm'"
  incus exec "$vm" -- systemctl reset-failed "$service" || true
  incus exec "$vm" -- systemctl restart "$service"
  sleep 2
  incus exec "$vm" -- systemctl is-active --quiet "$service" \
    || { incus exec "$vm" -- systemctl status "$service" --no-pager >&2 || true; return 1; }

  local ipv4 swap
  ipv4="$(incus exec "$vm" -- ip -4 -o address show scope global 2>/dev/null \
    | awk '$2 !~ /^docker/ {split($4,a,"/"); print a[1]; exit}')"
  swap="$(incus exec "$vm" -- free -h | awk '/^Swap:/ {print $2}')"
  log "✅ $vm is online locally — service active, IPv4 ${ipv4:-unknown}, swap ${swap:-unknown}."
}

main() {
  local vm role found=0 failures=0
  local -a runners=()

  if [[ -n "$ONLY_VM" ]]; then
    incus info "$ONLY_VM" >/dev/null 2>&1 || die "Instance '$ONLY_VM' does not exist."
    runners+=("$ONLY_VM")
  else
    while IFS= read -r vm; do
      [[ -n "$vm" ]] || continue
      role="$(incus config get "$vm" user.seele.role 2>/dev/null || true)"
      is_runner_role "$role" && runners+=("$vm")
    done < <(incus list --format csv -c n)
  fi

  ((${#runners[@]} > 0)) || die "No provisioner-owned runner VMs were found."
  preflight_swap_disk_space "${#runners[@]}"
  for vm in "${runners[@]}"; do
    found=1
    if ! restart_one "$vm"; then
      warn "Failed to recover $vm; continuing with the remaining runners."
      ((failures+=1))
    fi
  done

  [[ "$found" == 1 ]] || die "No runner VMs selected."
  if ((failures > 0)); then
    die "$failures runner(s) failed to recover."
  fi
  log "🐗✅ Runner restart complete. GitHub/Forgejo may need a few seconds to refresh online status."
}

main
