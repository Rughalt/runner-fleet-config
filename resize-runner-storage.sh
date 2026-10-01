#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=${0##*/}
PROFILE="${INCUS_PROFILE:-seele-runners}"
POOL="${INCUS_STORAGE_POOL:-}"
POOL_SIZE=""
VM_SIZE=""
MIN_HOST_FREE_GIB="${MIN_HOST_FREE_GIB:-12}"
DRY_RUN=0
declare -a REQUESTED_VMS=()

log() { printf '\n🐗 [%(%F %T)T] %s\n' -1 "$*"; }
warn() { printf '⚠️  WARNING: %s\n' "$*" >&2; }
die() { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Grow the Incus pool and/or root disks of provisioner-owned runner VMs.
Shrinking is never performed.

Usage:
  sudo ./$SCRIPT_NAME --pool-size 48GiB --vm-size 20GiB
  sudo ./$SCRIPT_NAME --vm selee-trotter-01 --vm-size 20GiB
  sudo ./$SCRIPT_NAME --pool-size 48GiB --dry-run

Options:
  --pool NAME       Incus pool (default: read from profile '$PROFILE')
  --pool-size SIZE  New size of an Incus-managed loop-backed pool
  --vm-size SIZE    New root-disk size for selected/all owned runner VMs
  --vm NAME         Resize only this VM; may be repeated
  --dry-run         Show validated changes without applying them
  -h, --help        Show this help

Sizes must be whole MiB/GiB/TiB values, for example 20480MiB or 20GiB.
The script refuses busy runners and leaves at least MIN_HOST_FREE_GIB
(${MIN_HOST_FREE_GIB} by default) on the host when growing a loop image.
EOF
}

while (($#)); do
  case "$1" in
    --pool) [[ $# -ge 2 ]] || die "--pool needs a value"; POOL=$2; shift 2 ;;
    --pool-size) [[ $# -ge 2 ]] || die "--pool-size needs a value"; POOL_SIZE=$2; shift 2 ;;
    --vm-size) [[ $# -ge 2 ]] || die "--vm-size needs a value"; VM_SIZE=$2; shift 2 ;;
    --vm) [[ $# -ge 2 ]] || die "--vm needs a value"; REQUESTED_VMS+=("$2"); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$POOL_SIZE" || -n "$VM_SIZE" ]] || { usage; die "Choose --pool-size and/or --vm-size."; }
[[ $EUID -eq 0 ]] || die "Run this script with sudo."

for command in incus jq findmnt lsblk; do
  command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
done
incus admin waitready --timeout=30 >/dev/null || die "Incus is not ready."
[[ "$MIN_HOST_FREE_GIB" =~ ^[1-9][0-9]*$ ]] \
  || die "MIN_HOST_FREE_GIB must be a positive whole number."

size_to_bytes() {
  local value=$1 number suffix multiplier
  [[ "$value" =~ ^([1-9][0-9]*)(MiB|GiB|TiB)$ ]] \
    || die "Invalid size '$value'; use a whole value such as 20GiB."
  number=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]}
  case "$suffix" in
    MiB) multiplier=$((1024**2)) ;;
    GiB) multiplier=$((1024**3)) ;;
    TiB) multiplier=$((1024**4)) ;;
  esac
  printf '%s\n' "$((number * multiplier))"
}

human_gib() { awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'; }

profile_value() {
  incus profile get "$PROFILE" "$1" 2>/dev/null || true
}

if [[ -z "$POOL" ]]; then
  POOL=$(profile_value user.seele.storage_pool)
  if [[ -z "$POOL" ]]; then
    POOL=$(incus profile device get "$PROFILE" root pool 2>/dev/null || true)
  fi
fi
[[ -n "$POOL" ]] || die "Could not determine the Incus pool; pass --pool NAME."
incus storage show "$POOL" >/dev/null 2>&1 || die "Incus pool '$POOL' does not exist."

pool_total_bytes() {
  incus query "/1.0/storage-pools/$POOL/resources" \
    | jq -er '.space.total // .metadata.space.total'
}

grow_pool() {
  local target_bytes current_bytes delta host_free remaining source expected_source owned
  target_bytes=$(size_to_bytes "$POOL_SIZE")
  current_bytes=$(pool_total_bytes) || die "Could not read capacity of '$POOL'."
  if ((target_bytes < current_bytes)); then
    die "Refusing to shrink '$POOL' from $(human_gib "$current_bytes") to $POOL_SIZE."
  fi
  if ((target_bytes == current_bytes)); then
    log "💽 Pool '$POOL' is already $POOL_SIZE; nothing to do."
    return
  fi

  source=$(incus storage get "$POOL" source 2>/dev/null || true)
  expected_source="/var/lib/incus/disks/${POOL}.img"
  owned=$(profile_value user.seele.storage_owned)
  [[ "$source" == "$expected_source" && "$owned" =~ ^(1|true)$ ]] || die \
    "Pool '$POOL' is not the provisioner's Incus-managed loop image. Refusing to resize backing storage automatically (source: ${source:-unknown})."

  delta=$((target_bytes - current_bytes))
  host_free=$(df -PB1 "$source" | awk 'NR==2 {print $4}')
  remaining=$((host_free - delta))
  ((remaining >= MIN_HOST_FREE_GIB * 1024**3)) || die \
    "Growing '$POOL' by $(human_gib "$delta") would leave only $(human_gib "$remaining") free on the host; required reserve is ${MIN_HOST_FREE_GIB} GiB."

  log "💽 Growing pool '$POOL': $(human_gib "$current_bytes") → $POOL_SIZE (host reserve afterwards: about $(human_gib "$remaining"))"
  if ((DRY_RUN)); then return; fi
  incus storage set "$POOL" size="$POOL_SIZE"
  current_bytes=$(pool_total_bytes) || die "Pool was changed, but its new capacity could not be verified."
  ((current_bytes >= target_bytes)) || die \
    "Pool resize returned successfully, but Incus reports only $(human_gib "$current_bytes")."
  log "✅ Pool '$POOL' now reports $(human_gib "$current_bytes")."
}

instance_json() {
  incus query "/1.0/instances/$1?recursion=1"
}

instance_role() {
  instance_json "$1" | jq -r '.config["user.seele.role"] // .metadata.config["user.seele.role"] // ""'
}

runner_service() {
  incus exec "$1" -- bash -lc \
    "systemctl list-unit-files --type=service --no-legend 'actions.runner.*.service' 'forgejo-runner.service' 2>/dev/null | awk 'NR==1 {print \$1}'" \
    2>/dev/null || true
}

runner_busy() {
  incus exec "$1" -- bash -lc \
    "pgrep -u runner -f 'Runner.Worker' >/dev/null || docker ps --format '{{.ID}}' 2>/dev/null | grep -q ." \
    >/dev/null 2>&1
}

wait_for_agent() {
  local vm=$1 attempt state
  for attempt in {1..120}; do
    if incus exec "$vm" -- true >/dev/null 2>&1; then return 0; fi
    state=$(incus list "$vm" --format csv -c s | head -n1)
    [[ "$state" == RUNNING ]] || return 1
    sleep 2
  done
  return 1
}

grow_guest_filesystem() {
  local vm=$1
  incus exec "$vm" -- bash -s <<'GUEST'
set -Eeuo pipefail
root_source=$(findmnt -n -o SOURCE /)
root_device=$(readlink -f "$root_source")
partition=$(lsblk -n -o PARTN "$root_device" | tr -d '[:space:]')
parent=$(lsblk -n -o PKNAME "$root_device" | tr -d '[:space:]')

if [[ -n "$partition" && -n "$parent" ]]; then
  command -v growpart >/dev/null 2>&1 || {
    echo "cloud-guest-utils/growpart is missing in the guest" >&2
    exit 1
  }
  [[ ! -w "/sys/class/block/$parent/device/rescan" ]] || echo 1 >"/sys/class/block/$parent/device/rescan"
  grow_output=$(growpart "/dev/$parent" "$partition" 2>&1) || {
    grep -q 'NOCHANGE' <<<"$grow_output" || { echo "$grow_output" >&2; exit 1; }
  }
fi

case $(findmnt -n -o FSTYPE /) in
  ext2|ext3|ext4) resize2fs "$root_device" ;;
  xfs) xfs_growfs / ;;
  btrfs) btrfs filesystem resize max / ;;
  *) echo "Unsupported guest root filesystem: $(findmnt -n -o FSTYPE /)" >&2; exit 1 ;;
esac
df -h /
GUEST
}

resize_vm() {
  local vm=$1 target_bytes current_size current_bytes state service was_active=0 was_enabled=0
  incus info "$vm" >/dev/null 2>&1 || die "VM '$vm' does not exist."
  case $(instance_role "$vm") in
    runner-v1|github-runner-v1|forgejo-runner-v1) ;;
    *) die "VM '$vm' is not an owned runner; refusing to change it." ;;
  esac
  target_bytes=$(size_to_bytes "$VM_SIZE")
  current_size=$(instance_json "$vm" | jq -r \
    '.expanded_devices.root.size // .metadata.expanded_devices.root.size // .devices.root.size // .metadata.devices.root.size // empty')
  [[ -n "$current_size" ]] || die "Could not determine root size of '$vm'."
  current_bytes=$(size_to_bytes "$current_size")
  ((target_bytes >= current_bytes)) || die \
    "Refusing to shrink '$vm' from $current_size to $VM_SIZE."
  if ((target_bytes == current_bytes)); then
    log "📦 '$vm' already has a $VM_SIZE root disk; nothing to do."
    return
  fi

  state=$(incus list "$vm" --format csv -c s | head -n1)
  [[ "$state" == RUNNING ]] || die "'$vm' is $state. Start/recover it before resizing so the guest filesystem can be verified."
  runner_busy "$vm" && die "'$vm' is executing a runner/Docker job. Retry after it becomes idle."
  service=$(runner_service "$vm")
  [[ -n "$service" ]] || die "No runner systemd service found in '$vm'."
  incus exec "$vm" -- systemctl is-active --quiet "$service" && was_active=1 || true
  incus exec "$vm" -- systemctl is-enabled --quiet "$service" && was_enabled=1 || true

  log "📦 Growing '$vm': $current_size → $VM_SIZE (runner '$service' will pause briefly)"
  if ((DRY_RUN)); then return; fi

  incus exec "$vm" -- systemctl stop "$service"
  ((was_enabled == 0)) || incus exec "$vm" -- systemctl disable "$service" >/dev/null
  incus stop "$vm" --timeout 120 || incus stop "$vm" --force
  if incus config device show "$vm" | grep -q '^root:'; then
    incus config device set "$vm" root size="$VM_SIZE"
  else
    incus config device override "$vm" root size="$VM_SIZE"
  fi
  incus start "$vm"
  if ! wait_for_agent "$vm"; then
    die "'$vm' was resized but its agent did not return. Runner service remains disabled for safety."
  fi
  if ! grow_guest_filesystem "$vm"; then
    die "'$vm' block device was enlarged, but the guest filesystem could not be grown. Runner service remains disabled for safety."
  fi
  ((was_enabled == 0)) || incus exec "$vm" -- systemctl enable "$service" >/dev/null
  ((was_active == 0)) || incus exec "$vm" -- systemctl start "$service"
  log "✅ '$vm' filesystem is larger and its previous runner-service state was restored."
}

if [[ -n "$POOL_SIZE" ]]; then grow_pool; fi

if [[ -n "$VM_SIZE" ]]; then
  if ((${#REQUESTED_VMS[@]} == 0)); then
    mapfile -t REQUESTED_VMS < <(
      incus list --format json | jq -r '.[]
        | select(.type == "virtual-machine")
        | select(.config["user.seele.role"] == "runner-v1"
              or .config["user.seele.role"] == "github-runner-v1"
              or .config["user.seele.role"] == "forgejo-runner-v1")
        | .name' | sort
    )
  fi
  ((${#REQUESTED_VMS[@]} > 0)) || die "No provisioner-owned runner VMs were found."
  for vm in "${REQUESTED_VMS[@]}"; do resize_vm "$vm"; done
fi

log "🌟 Storage expansion complete. Nothing was shrunk."
