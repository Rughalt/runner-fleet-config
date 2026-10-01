#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Seele: an idempotent Incus VM factory for GitHub Actions organization runners.
# Run as root on an Ubuntu 24.04+ VPS with nested virtualization (/dev/kvm).

# Read a deliberately small allowlist from the .env in the directory where the
# operator invoked the script. Existing exported variables win. Values are
# treated as data, never evaluated as shell code, because this script runs as
# root and a convenient dotenv file must not become a root-code loader.
load_local_env() {
  local env_path="${ENV_FILE:-$PWD/.env}" line key value
  [[ -e "$env_path" ]] || return 0
  [[ -f "$env_path" ]] || { printf 'ERROR: %s is not a regular file.\n' "$env_path" >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] \
      || { printf 'ERROR: invalid .env line (expected KEY=VALUE): %s\n' "$line" >&2; exit 1; }
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      GH_TOKEN|ORG|RUNNER_GROUP|RUNNER_COUNT|RUNNER_PREFIX|BASE_VM|GOLDEN_SNAPSHOT|UBUNTU_IMAGE|\
      INCUS_NETWORK|INCUS_PROFILE|INCUS_STORAGE_POOL|INCUS_STORAGE_DRIVER|INCUS_STORAGE_SOURCE|\
      CONFIRM_STORAGE_SOURCE|POOL_SIZE_GIB|VM_CPUS|VM_MEMORY|VM_DISK|RUNNER_VERSION|\
      APT_FORCE_IPV4|REPLACE_OFFLINE_RUNNER|SKIP_RESOURCE_CHECKS|MIN_HOST_CPUS|\
      MIN_HOST_RAM_MIB|MIN_HOST_DISK_GIB|FORGEJO_URL|FORGEJO_TOKEN|FORGEJO_API_TOKEN|\
      FORGEJO_RUNNER_VERSION|FORGEJO_RUNNER_COUNT|FORGEJO_RUNNER_PREFIX|FORGEJO_SCOPE|\
      FORGEJO_LABELS|RUNNER_PROVIDER|HOST_SWAP_SIZE|GUEST_SWAP_SIZE|DAILY_CLEANUP)
        if [[ ! -v "$key" ]]; then
          printf -v "$key" '%s' "$value"
          export "$key"
        fi
        ;;
      *) printf 'WARNING: ignoring unsupported .env key: %s\n' "$key" >&2 ;;
    esac
  done <"$env_path"
  printf 'Loaded settings from %s (exported variables take precedence).\n' "$env_path"
}

load_local_env

ORG="${ORG:-Dragonshorn-Studios}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
RUNNER_PROVIDER="${RUNNER_PROVIDER:-github}"
if [[ "$RUNNER_PROVIDER" == forgejo ]]; then
  RUNNER_COUNT="${FORGEJO_RUNNER_COUNT:-${RUNNER_COUNT:-2}}"
  RUNNER_PREFIX="${FORGEJO_RUNNER_PREFIX:-${RUNNER_PREFIX:-lux-poro}}"
else
  RUNNER_COUNT="${RUNNER_COUNT:-2}"
  RUNNER_PREFIX="${RUNNER_PREFIX:-selee-trotter}"
fi
BASE_VM="${BASE_VM:-seele-base}"
GOLDEN_SNAPSHOT="${GOLDEN_SNAPSHOT:-golden-v1}"
UBUNTU_IMAGE="${UBUNTU_IMAGE:-images:ubuntu/24.04/cloud}"
INCUS_NETWORK="${INCUS_NETWORK:-incusbr0}"
INCUS_PROFILE="${INCUS_PROFILE:-seele-runners}"
INCUS_STORAGE_POOL="${INCUS_STORAGE_POOL:-}"
INCUS_STORAGE_DRIVER="${INCUS_STORAGE_DRIVER:-auto}"
INCUS_STORAGE_SOURCE="${INCUS_STORAGE_SOURCE:-}"
POOL_SIZE_GIB="${POOL_SIZE_GIB:-}"
VM_CPUS="${VM_CPUS:-2}"
VM_MEMORY="${VM_MEMORY:-1536MiB}"
VM_DISK="${VM_DISK:-15GiB}"
HOST_SWAP_SIZE="${HOST_SWAP_SIZE:-2G}"
GUEST_SWAP_SIZE="${GUEST_SWAP_SIZE:-1G}"
DAILY_CLEANUP="${DAILY_CLEANUP:-1}"
RUNNER_VERSION="${RUNNER_VERSION:-latest}"
FORGEJO_URL="${FORGEJO_URL:-}"
FORGEJO_API_TOKEN="${FORGEJO_API_TOKEN:-${FORGEJO_TOKEN:-}}"
FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-13.1.0}"
FORGEJO_SCOPE="${FORGEJO_SCOPE:-global}"
FORGEJO_LABELS="${FORGEJO_LABELS:-docker:docker://node:20-bookworm}"
APT_FORCE_IPV4="${APT_FORCE_IPV4:-auto}"
REPLACE_OFFLINE_RUNNER="${REPLACE_OFFLINE_RUNNER:-0}"
SKIP_RESOURCE_CHECKS="${SKIP_RESOURCE_CHECKS:-0}"
MIN_HOST_CPUS="${MIN_HOST_CPUS:-4}"
MIN_HOST_RAM_MIB="${MIN_HOST_RAM_MIB:-7168}"
MIN_HOST_DISK_GIB="${MIN_HOST_DISK_GIB:-30}"

readonly SCRIPT_NAME="${0##*/}"
TEMP_DIR=""
POOL_CREATED_BY_SCRIPT=0
NETWORK_CREATED_BY_SCRIPT=0
CLEANUP_MODE=0
STOP_RUNNING_MODE=0
LOCK_FILE="/run/lock/seele-runners.lock"
PID_FILE="/run/seele-runners.pid"
LOCK_HELD=0

log()  { printf '\n🐗 [%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die()  { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ "$LOCK_HELD" == 1 && -s "$PID_FILE" && "$(<"$PID_FILE")" == "$$" ]]; then
    rm -f -- "$PID_FILE"
  fi
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<'EOF'
Usage:
  sudo --preserve-env=GH_TOKEN,RUNNER_COUNT ./provision-seele-runners.sh
  RUNNER_PROVIDER=forgejo sudo --preserve-env=RUNNER_PROVIDER,FORGEJO_URL,FORGEJO_API_TOKEN ./provision-seele-runners.sh
  sudo --preserve-env=GH_TOKEN ./provision-seele-runners.sh --cleanup
  sudo ./provision-seele-runners.sh --stop-running

Required environment:
  RUNNER_PROVIDER=github   Requires GH_TOKEN with organization runners:write.
  RUNNER_PROVIDER=forgejo  Requires FORGEJO_URL and FORGEJO_API_TOKEN.

Common settings:
  RUNNER_COUNT=2           Number of VMs (selee-trotter-01, -02, ...).
  VM_CPUS=2 VM_MEMORY=1536MiB VM_DISK=15GiB
  HOST_SWAP_SIZE=2G        Persistent swap on the VPS host (keeps existing swap).
  GUEST_SWAP_SIZE=1G       Persistent swap baked into the golden VM.
  DAILY_CLEANUP=1          Daily Docker/cache cleanup timer inside runner VMs.
  INCUS_STORAGE_POOL=name  Reuse an existing Incus btrfs/lvm/zfs pool.
  POOL_SIZE_GIB=40         Size for a new safe loop-backed pool.
  RUNNER_VERSION=latest    Or pin, for example 2.328.0 (without "v").
  FORGEJO_SCOPE=global     Or user, org:NAME, repo:OWNER/REPO.
  FORGEJO_LABELS=...       Default: docker:docker://node:20-bookworm.

Explicit existing storage (never autodetected or claimed):
  INCUS_STORAGE_DRIVER=lvm|zfs|btrfs
  INCUS_STORAGE_SOURCE=<VG/thinpool, zpool/dataset, block device or btrfs path>
  CONFIRM_STORAGE_SOURCE=<exact same value>

Recovery switch:
  REPLACE_OFFLINE_RUNNER=1 Replace a same-named GitHub runner only when it is offline.

Maintenance:
  --cleanup                Remove only resources owned by this provisioner, then exit.
  --stop-running           Stop an earlier provisioning process, then exit.
EOF
}

case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --cleanup) CLEANUP_MODE=1 ;;
  --stop-running) STOP_RUNNING_MODE=1 ;;
  "") : ;;
  *) die "Unknown option: $1 (use --help)." ;;
esac
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."
[[ "$RUNNER_PROVIDER" =~ ^(github|forgejo)$ ]] || die "RUNNER_PROVIDER must be github or forgejo."
[[ "$RUNNER_COUNT" =~ ^[1-9][0-9]*$ ]] || die "RUNNER_COUNT must be a positive integer."
[[ "$VM_CPUS" =~ ^[1-9][0-9]*$ ]] || die "VM_CPUS must be a positive integer."
[[ "$MIN_HOST_RAM_MIB" =~ ^[1-9][0-9]*$ ]] || die "MIN_HOST_RAM_MIB must be a positive integer."
[[ "$INCUS_STORAGE_DRIVER" =~ ^(auto|btrfs|lvm|zfs)$ ]] || die "Unsupported INCUS_STORAGE_DRIVER."
[[ "$HOST_SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "HOST_SWAP_SIZE must be 0 or look like 2G/2048M."
[[ "$GUEST_SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "GUEST_SWAP_SIZE must be 0 or look like 1G/1024M."
[[ "$DAILY_CLEANUP" =~ ^[01]$ ]] || die "DAILY_CLEANUP must be 0 or 1."
if [[ "$RUNNER_PROVIDER" == forgejo ]]; then
  FORGEJO_URL="${FORGEJO_URL%/}"
  [[ "$FORGEJO_URL" =~ ^https://([^/:]+)(:([0-9]+))?$ ]] \
    || die "FORGEJO_URL must be an HTTPS origin such as https://git.example.com (no path)."
  RUNNER_CONNECT_HOST="${BASH_REMATCH[1]}"
  RUNNER_CONNECT_PORT="${BASH_REMATCH[3]:-443}"
else
  RUNNER_CONNECT_HOST=api.github.com
  RUNNER_CONNECT_PORT=443
fi

apt_retry() {
  local force4="$1"
  shift
  local -a opts=(-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
  [[ "$force4" == 1 ]] && opts+=(-o Acquire::ForceIPv4=true)
  DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" "$@"
}

process_cmdline() {
  local pid="$1"
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  tr '\0' ' ' <"/proc/$pid/cmdline"
}

signal_process_tree() {
  local pid="$1" signal="$2" child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    signal_process_tree "$child" "$signal"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -s "$signal" "$pid" 2>/dev/null || true
}

wait_for_process_exit() {
  local pid="$1" seconds="$2" i
  for ((i=0; i<seconds*5; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

stop_one_process_tree() {
  local pid="$1" cmd
  kill -0 "$pid" 2>/dev/null || return 0
  cmd="$(process_cmdline "$pid" || true)"
  log "Stopping provisioning process PID $pid: ${cmd:-unknown command}"
  signal_process_tree "$pid" INT
  wait_for_process_exit "$pid" 5 && return 0
  warn "PID $pid ignored SIGINT; sending SIGTERM."
  signal_process_tree "$pid" TERM
  wait_for_process_exit "$pid" 10 && return 0
  warn "PID $pid ignored SIGTERM; sending SIGKILL."
  signal_process_tree "$pid" KILL
  wait_for_process_exit "$pid" 3 || die "Could not stop PID $pid."
}

stop_running_provisioner() {
  local pid cmd found=0
  local -a candidates=()

  if [[ -s "$PID_FILE" ]]; then
    pid="$(<"$PID_FILE")"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      cmd="$(process_cmdline "$pid" || true)"
      if [[ "$cmd" == *"$SCRIPT_NAME"* && "$cmd" != *"--stop-running"* ]]; then
        candidates+=("$pid")
      else
        warn "Ignoring stale PID file (PID ${pid} is not this provisioner)."
      fi
    fi
  fi

  # Compatibility with a provisioning process started by an older script that
  # predates the PID file. Match this script's exact basename and exclude this
  # --stop-running invocation and its sudo wrapper.
  for proc in /proc/[0-9]*; do
    pid="${proc##*/}"
    [[ "$pid" != "$$" && "$pid" != "$PPID" ]] || continue
    cmd="$(process_cmdline "$pid" || true)"
    [[ "$cmd" == *"$SCRIPT_NAME"* && "$cmd" != *"--stop-running"* ]] || continue
    candidates+=("$pid")
  done

  local seen=" " candidate
  for candidate in "${candidates[@]}"; do
    [[ "$seen" != *" $candidate "* ]] || continue
    seen+="$candidate "
    kill -0 "$candidate" 2>/dev/null || continue
    stop_one_process_tree "$candidate"
    found=1
  done

  rm -f -- "$PID_FILE"
  if [[ "$found" == 1 ]]; then
    log "Previous provisioning process stopped. You can now run --cleanup."
  else
    log "No earlier provisioning process is running."
  fi
}

acquire_provisioning_lock() {
  mkdir -p /run/lock
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another provisioning process is running. Use '$SCRIPT_NAME --stop-running' first."
  LOCK_HELD=1
  printf '%s\n' "$$" >"$PID_FILE"
}

host_apt() {
  local force4=0
  [[ "$APT_FORCE_IPV4" == 1 ]] && force4=1
  if ! apt_retry "$force4" update; then
    [[ "$APT_FORCE_IPV4" == 0 ]] && die "apt update failed and APT_FORCE_IPV4=0."
    warn "apt update failed; retrying over IPv4."
    apt_retry 1 update
    force4=1
  fi
  if ! apt_retry "$force4" install -y --no-install-recommends "$@"; then
    [[ "$APT_FORCE_IPV4" == 0 ]] && die "apt install failed and APT_FORCE_IPV4=0."
    warn "apt install failed; retrying over IPv4."
    apt_retry 1 install -y --no-install-recommends "$@"
  fi
}

ensure_host_swap() {
  [[ "$HOST_SWAP_SIZE" != 0 ]] || { log "💤 Host swap creation disabled."; return; }
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    log "💾 Host swap already active; leaving it unchanged."
    return
  fi

  local swapfile=/swapfile fs_type free_mib requested_mib
  case "$HOST_SWAP_SIZE" in
    *G) requested_mib="$(( ${HOST_SWAP_SIZE%G} * 1024 ))" ;;
    *M) requested_mib="${HOST_SWAP_SIZE%M}" ;;
  esac
  free_mib="$(df -Pm / | awk 'NR==2 {print $4}')"
  ((free_mib - requested_mib >= 8192)) \
    || die "Refusing $HOST_SWAP_SIZE host swap: less than 8 GiB would remain on /."

  if [[ -e "$swapfile" ]]; then
    [[ "$(blkid -p -s TYPE -o value "$swapfile" 2>/dev/null || true)" == swap ]] \
      || die "$swapfile exists but is not a swap file; refusing to overwrite it."
  else
    fs_type="$(findmnt -no FSTYPE /)"
    log "💾 Creating $HOST_SWAP_SIZE host swap on $fs_type"
    case "$fs_type" in
      btrfs) btrfs filesystem mkswapfile --size "$HOST_SWAP_SIZE" "$swapfile" ;;
      ext4|xfs)
        fallocate -l "$HOST_SWAP_SIZE" "$swapfile"
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        ;;
      *) die "Automatic host swap is unsupported on root filesystem '$fs_type'. Configure swap manually or set HOST_SWAP_SIZE=0." ;;
    esac
  fi
  chmod 600 "$swapfile"
  grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab \
    || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  swapon "$swapfile"
  printf 'vm.swappiness=20\n' >/etc/sysctl.d/90-runner-swap.conf
  sysctl --system >/dev/null
  log "✅ Host swap is active; QEMU has an emergency buffer."
}

preflight_host() {
  log "🦋 Seele scans the host — CPU, RAM, disk, KVM and networking preflight"
  [[ -r /etc/os-release ]] || die "Cannot identify the host OS."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "This script supports Ubuntu hosts; detected ${ID:-unknown}."
  dpkg --print-architecture | grep -Eq '^(amd64|arm64)$' || die "Only amd64 and arm64 hosts are supported."
  [[ -e /dev/kvm ]] || die "/dev/kvm is missing. Enable nested virtualization in the VPS panel/provider."
  [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm exists but is not accessible to root."

  local cpus ram_mib free_gib
  cpus="$(nproc)"
  ram_mib="$(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))"
  free_gib="$(( $(df -Pk /var | awk 'NR==2 {print $4}') / 1024 / 1024 ))"
  printf 'CPU: %s, RAM: %s MiB, free /var: %s GiB\n' "$cpus" "$ram_mib" "$free_gib"
  if [[ "$SKIP_RESOURCE_CHECKS" != 1 ]]; then
    (( cpus >= MIN_HOST_CPUS )) || die "Need at least ${MIN_HOST_CPUS} vCPUs (override MIN_HOST_CPUS or set SKIP_RESOURCE_CHECKS=1)."
    (( ram_mib >= MIN_HOST_RAM_MIB )) || die "Need at least ${MIN_HOST_RAM_MIB} MiB RAM."
    (( free_gib >= MIN_HOST_DISK_GIB )) || die "Need at least ${MIN_HOST_DISK_GIB} GiB free under /var."
  fi

  local -a required_hosts=(archive.ubuntu.com images.linuxcontainers.org "$RUNNER_CONNECT_HOST")
  if [[ "$RUNNER_PROVIDER" == github ]]; then
    required_hosts+=(api.github.com github.com)
  else
    required_hosts+=(code.forgejo.org)
  fi
  local host
  for host in "${required_hosts[@]}"; do
    getent ahosts "$host" >/dev/null || die "DNS lookup failed for $host."
  done
  if command -v curl >/dev/null 2>&1; then
    curl -4fsSI --connect-timeout 10 --max-time 20 "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/" >/dev/null \
      || curl -fsSI --connect-timeout 10 --max-time 20 "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/" >/dev/null \
      || die "Cannot reach $RUNNER_CONNECT_HOST over HTTPS."
  fi
}

install_incus() {
  if command -v incus >/dev/null 2>&1; then
    log "⚙️  Incus engine already online: $(incus version 2>/dev/null | head -n1)"
  else
    log "⚙️  Assembling the Incus engine; host Docker stays outside the Fragmentum"
  fi
  host_apt ca-certificates curl genisoimage jq qemu-system btrfs-progs lvm2 thin-provisioning-tools incus
  curl -4fsSI --connect-timeout 10 --max-time 20 "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/" >/dev/null \
    || curl -fsSI --connect-timeout 10 --max-time 20 "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/" >/dev/null \
    || die "Cannot reach $RUNNER_CONNECT_HOST over HTTPS."
  systemctl enable --now incus.service
  incus admin waitready --timeout=60
}

storage_driver() {
  incus storage show "$1" 2>/dev/null | awk '$1 == "driver:" {print $2; exit}'
}

storage_status() {
  incus storage list --format csv -c ns 2>/dev/null | awk -F, -v pool="$1" '$1 == pool {print $2; exit}'
}

pool_is_cow() {
  local pool="$1" driver
  driver="$(storage_driver "$pool")"
  case "$driver" in
    btrfs|zfs) return 0 ;;
    lvm) [[ "$(incus storage get "$pool" lvm.use_thinpool 2>/dev/null || true)" != false ]] ;;
    *) return 1 ;;
  esac
}

choose_existing_pool() {
  local preferred name driver status
  for preferred in zfs btrfs lvm; do
    while IFS=, read -r name driver status; do
      [[ "$driver" == "$preferred" && "$status" == CREATED ]] || continue
      pool_is_cow "$name" || continue
      printf '%s\n' "$name"
      return 0
    done < <(incus storage list --format csv -c nDs 2>/dev/null || true)
  done
  return 1
}

create_storage_pool() {
  local pool="$1" driver="$2" size_gib="$3"
  if [[ -n "$INCUS_STORAGE_SOURCE" ]]; then
    [[ "${CONFIRM_STORAGE_SOURCE:-}" == "$INCUS_STORAGE_SOURCE" ]] \
      || die "Refusing to claim INCUS_STORAGE_SOURCE without CONFIRM_STORAGE_SOURCE set to the identical value."
    [[ "$driver" != auto ]] || die "Set INCUS_STORAGE_DRIVER when using INCUS_STORAGE_SOURCE."
    log "Creating explicitly authorized $driver pool '$pool' from '$INCUS_STORAGE_SOURCE'"
    incus storage create "$pool" "$driver" source="$INCUS_STORAGE_SOURCE"
    return
  fi

  if [[ "$driver" == auto || "$driver" == btrfs ]]; then
    if modprobe btrfs 2>/dev/null && command -v mkfs.btrfs >/dev/null; then
      log "Creating safe loop-backed Btrfs pool '$pool' (${size_gib} GiB)"
      if incus storage create "$pool" btrfs size="${size_gib}GiB"; then
        incus storage set "$pool" user.seele.managed=true
        POOL_CREATED_BY_SCRIPT=1
        return
      fi
      [[ "$driver" == auto ]] || die "Could not create the requested Btrfs pool."
      warn "Btrfs pool creation failed; trying loop-backed LVM-thin."
      if incus storage show "$pool" >/dev/null 2>&1; then
        incus storage delete "$pool" \
          || die "Failed Btrfs pool '$pool' needs manual inspection; refusing to reuse its name."
      fi
    elif [[ "$driver" == btrfs ]]; then
      die "Btrfs is not supported by this host kernel."
    fi
  fi

  log "Creating safe loop-backed LVM-thin pool '$pool' (${size_gib} GiB)"
  incus storage create "$pool" lvm size="${size_gib}GiB" lvm.use_thinpool=true
  incus storage set "$pool" user.seele.managed=true
  POOL_CREATED_BY_SCRIPT=1
}

pool_looks_like_legacy_seele_loop() {
  local pool="$1" source
  [[ "$pool" =~ ^seele-cow(-[0-9]+)?$ ]] || return 1
  source="$(incus storage get "$pool" source 2>/dev/null || true)"
  [[ "$source" == "/var/lib/incus/disks/${pool}.img" ]]
}

ensure_incus_foundation() {
  log "🌌 Mapping the Fragmentum — selecting Incus storage and networking"
  local pool free_gib driver status
  pool="$INCUS_STORAGE_POOL"
  if [[ -n "$pool" ]]; then
    driver="$(storage_driver "$pool")"
    [[ "$driver" =~ ^(btrfs|lvm|zfs)$ ]] || die "Pool '$pool' is missing or uses '$driver'; dir is intentionally unsupported."
    pool_is_cow "$pool" || die "Pool '$pool' does not provide the required CoW/thin-clone behavior."
    status="$(storage_status "$pool")"
    [[ "$status" == CREATED ]] || die "Pool '$pool' is not ready (status: ${status:-unknown})."
  elif pool="$(choose_existing_pool)"; then
    driver="$(storage_driver "$pool")"
    log "Reusing existing CoW pool '$pool' ($driver)."
  else
    pool="seele-cow"
    if incus storage show "$pool" >/dev/null 2>&1; then
      local suffix=2
      while incus storage show "seele-cow-$suffix" >/dev/null 2>&1; do
        ((suffix++))
      done
      pool="seele-cow-$suffix"
      warn "Storage pool name 'seele-cow' is already occupied by an incompatible legacy pool; using '$pool'."
    fi
    free_gib="$(( $(df -Pk /var | awk 'NR==2 {print $4}') / 1024 / 1024 ))"
    if [[ -z "$POOL_SIZE_GIB" ]]; then
      # Keep roughly 40% of the host filesystem outside the loop pool for
      # host swap, package updates, logs and emergency headroom. The previous
      # free-minus-10 policy was too aggressive on small VPS disks.
      POOL_SIZE_GIB=$(( free_gib * 60 / 100 ))
      (( POOL_SIZE_GIB > 40 )) && POOL_SIZE_GIB=40
      (( POOL_SIZE_GIB >= 20 )) || die "Not enough free space for a 20 GiB Incus pool."
    fi
    [[ "$POOL_SIZE_GIB" =~ ^[1-9][0-9]*$ ]] || die "POOL_SIZE_GIB must be an integer."
    create_storage_pool "$pool" "$INCUS_STORAGE_DRIVER" "$POOL_SIZE_GIB"
    driver="$(storage_driver "$pool")"
  fi
  INCUS_STORAGE_POOL="$pool"
  export INCUS_STORAGE_POOL
  log "💾 Fragmentum anchor ready: storage pool '$pool' ($driver), no dir backend"

  if ! incus network show "$INCUS_NETWORK" >/dev/null 2>&1; then
    incus network create "$INCUS_NETWORK" ipv4.address=auto ipv4.nat=true ipv6.address=none
    incus network set "$INCUS_NETWORK" user.seele.managed=true
    NETWORK_CREATED_BY_SCRIPT=1
  else
    [[ "$(incus network show "$INCUS_NETWORK" | awk '$1 == "type:" {print $2; exit}')" == bridge ]] \
      || die "Existing network '$INCUS_NETWORK' is not an Incus bridge. Choose another INCUS_NETWORK."
    [[ "$(incus network get "$INCUS_NETWORK" ipv4.address)" != none && -n "$(incus network get "$INCUS_NETWORK" ipv4.address)" ]] \
      || die "Existing network '$INCUS_NETWORK' has no managed IPv4 subnet. Choose another INCUS_NETWORK."
    [[ "$(incus network get "$INCUS_NETWORK" ipv4.nat)" == true ]] \
      || die "Existing network '$INCUS_NETWORK' has no IPv4 NAT. Choose another INCUS_NETWORK."
  fi

  if ! incus profile show "$INCUS_PROFILE" >/dev/null 2>&1; then
    incus profile create "$INCUS_PROFILE"
    incus profile set "$INCUS_PROFILE" user.seele.managed=true \
      user.seele.storage_pool="$pool" user.seele.storage_owned="$POOL_CREATED_BY_SCRIPT" \
      user.seele.network="$INCUS_NETWORK" user.seele.network_owned="$NETWORK_CREATED_BY_SCRIPT"
    incus profile device add "$INCUS_PROFILE" root disk path=/ pool="$pool"
    incus profile device add "$INCUS_PROFILE" eth0 nic network="$INCUS_NETWORK" name=eth0
    incus profile device add "$INCUS_PROFILE" agent disk source=agent:config
  else
    [[ "$(incus profile get "$INCUS_PROFILE" user.seele.managed)" == true ]] \
      || die "Profile '$INCUS_PROFILE' already exists but is not owned by this provisioner. Choose another INCUS_PROFILE."
    [[ "$(incus profile device get "$INCUS_PROFILE" root pool)" == "$pool" ]] \
      || die "Managed profile '$INCUS_PROFILE' points at a different storage pool."
    [[ "$(incus profile device get "$INCUS_PROFILE" eth0 network)" == "$INCUS_NETWORK" ]] \
      || die "Managed profile '$INCUS_PROFILE' points at a different network."
    if ! incus profile device show "$INCUS_PROFILE" | grep -q '^agent:'; then
      warn "Adding the Incus agent CD-ROM fallback to the existing managed profile."
      incus profile device add "$INCUS_PROFILE" agent disk source=agent:config
    fi
    if [[ -z "$(incus profile get "$INCUS_PROFILE" user.seele.storage_pool)" ]]; then
      local legacy_storage_owned=0
      pool_looks_like_legacy_seele_loop "$pool" && legacy_storage_owned=1
      incus profile set "$INCUS_PROFILE" user.seele.storage_pool="$pool" \
        user.seele.storage_owned="$legacy_storage_owned" user.seele.network="$INCUS_NETWORK" \
        user.seele.network_owned="$(incus network get "$INCUS_NETWORK" user.seele.managed 2>/dev/null || printf 0)"
    fi
  fi
}

ensure_incus_firewall_access() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0

  local subnet4 subnet6
  subnet4="$(ip -4 route show dev "$INCUS_NETWORK" proto kernel scope link 2>/dev/null | awk 'NR==1 {print $1}')"
  [[ -n "$subnet4" ]] || die "UFW is active but the IPv4 subnet for '$INCUS_NETWORK' could not be determined."

  log "🛡️ Teaching hardened UFW to admit Incus DHCP/DNS and VM egress"
  ufw allow in on "$INCUS_NETWORK" to any port 67 proto udp comment 'Incus DHCPv4'
  ufw allow in on "$INCUS_NETWORK" to any port 53 comment 'Incus DNS'
  ufw route allow in on "$INCUS_NETWORK" from "$subnet4" comment 'Incus IPv4 egress'

  subnet6="$(ip -6 route show dev "$INCUS_NETWORK" proto kernel 2>/dev/null | awk '$1 != "fe80::/64" {print $1; exit}')"
  if [[ -n "$subnet6" ]]; then
    ufw route allow in on "$INCUS_NETWORK" from "$subnet6" comment 'Incus IPv6 egress'
  fi
  log "✅ UFW keeps the host hardened while '$INCUS_NETWORK' can serve its guests."
}

ensure_unique_clone_dhcp_identity() {
  local vm="$1"
  [[ "$vm" != "$BASE_VM" ]] || return 0
  if incus exec "$vm" -- test -e /var/lib/seele-dhcp-mac-v1; then
    return 0
  fi

  log "🪪 Giving '$vm' a MAC-based DHCP identity"
  incus exec "$vm" -- bash -c 'set -Eeuo pipefail
iface="$(ip -o link show | awk -F": " '\''$2 != "lo" && $2 !~ /^docker/ {print $2; exit}'\'')"
[[ -n "$iface" ]] || { echo "No guest Ethernet interface found" >&2; exit 1; }
cat > /etc/netplan/99-incus-dhcp-identity.yaml <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp-identifier: mac
EOF
chmod 600 /etc/netplan/99-incus-dhcp-identity.yaml
netplan generate
netplan apply
networkctl reconfigure "$iface" || true
networkctl renew "$iface" || true
touch /var/lib/seele-dhcp-mac-v1'
  sleep 3
}

wait_for_vm() {
  local vm="$1"
  local agent_tries=120 state restart_attempts=0 start_try restarted
  log "🛰️ Waiting for the Incus agent in '$vm' (up to 4 minutes)"
  until incus exec "$vm" -- true >/dev/null 2>&1; do
    state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
    if [[ "$state" != RUNNING ]]; then
      if [[ "$state" == STOPPED && "$restart_attempts" -lt 2 ]]; then
        ((restart_attempts+=1))
        warn "✨ $vm stopped during first-boot agent/cloud-init handoff; restarting it ($restart_attempts/2)."
        # Incus can report STOPPED a moment before it has released the
        # agent:config ISO mount. Starting during that small window fails with
        # EBUSY. Let Incus finish its own cleanup and retry without touching or
        # lazily unmounting daemon-owned paths behind its back.
        restarted=0
        for start_try in 1 2 3 4 5 6; do
          sleep $((start_try * 2))
          state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
          if [[ "$state" == RUNNING ]]; then
            log "✨ $vm completed its handoff and resumed by itself."
            restarted=1
            break
          fi
          if incus start "$vm" 2>"$TEMP_DIR/incus-start.err"; then
            restarted=1
            break
          fi
          # Close the small race between the state check and `incus start`:
          # an automatic guest/Incus restart makes start return "already
          # running", which is the desired outcome rather than a failure.
          state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
          if [[ "$state" == RUNNING ]]; then
            log "✨ $vm resumed while Incus was processing the start request."
            restarted=1
            break
          fi
          sed 's/^/Incus: /' "$TEMP_DIR/incus-start.err" >&2 || true
          warn "Incus is still releasing '$vm' config media; retrying start ($start_try/6)."
        done
        if [[ "$restarted" != 1 ]]; then
          incus info "$vm" --show-log >&2 || true
          findmnt "/var/lib/incus/devices/$vm/config.mount" >&2 || true
          die "$vm is still stopped because Incus could not release its config-drive mount. Stop other Incus commands and retry."
        fi
        sleep 3
        continue
      fi
      incus info "$vm" --show-log >&2 || true
      incus console "$vm" --show-log >&2 || true
      die "$vm repeatedly stopped before its Incus VM agent became available (state: ${state:-unknown})."
    fi
    if (( --agent_tries <= 0 )); then
      incus info "$vm" --show-log >&2 || true
      incus console "$vm" --show-log >&2 || true
      die "$vm is running, but its Incus VM agent did not become available within 240 seconds."
    fi
    sleep 2
  done
  log "✅ Incus agent is online in '$vm'."
  ensure_unique_clone_dhcp_identity "$vm"
  local cloud_init_rc
  log "☁️ Waiting for cloud-init in '$vm' to finish"
  set +e
  incus exec "$vm" -- cloud-init status --wait >/dev/null
  cloud_init_rc=$?
  set -e
  case "$cloud_init_rc" in
    0) : ;;
    2)
      warn "$vm cloud-init completed with recoverable warnings (exit 2); continuing."
      incus exec "$vm" -- cloud-init status --long >&2 || true
      ;;
    *)
      incus exec "$vm" -- cloud-init status --long >&2 || true
      incus exec "$vm" -- journalctl -u cloud-final.service --no-pager -n 100 >&2 || true
      die "$vm cloud-init failed with exit code $cloud_init_rc."
      ;;
  esac
  log "✅ cloud-init finished in '$vm'."

  local tries=45
  log "🌐 Waiting for DHCPv4 in '$vm' (up to 90 seconds)"
  until incus exec "$vm" -- sh -c "ip -4 -o address show scope global | grep -q ' inet '"; do
    if (( --tries <= 0 )); then
      incus exec "$vm" -- ip -br address >&2 || true
      incus exec "$vm" -- ip -4 route >&2 || true
      incus network show "$INCUS_NETWORK" >&2 || true
      die "$vm is running but received no IPv4 address from '$INCUS_NETWORK'. Check the Incus bridge/DHCP service and host firewall."
    fi
    ((tries-=1))
    sleep 2
  done
  log "✅ '$vm' received IPv4; checking DNS and GitHub connectivity."

  tries=30
  until incus exec "$vm" -- getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1; do
    (( --tries > 0 )) || die "$vm has no working IPv4 DNS/networking."
    sleep 2
  done
  local https_ok=0 attempt
  for attempt in 1 2 3 4 5; do
    if incus exec "$vm" -- curl -4fsS -o /dev/null --connect-timeout 10 --max-time 30 \
      "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/"; then
      https_ok=1
      break
    fi
    warn "$vm HTTPS check failed over IPv4; retrying ($attempt/5)."
    sleep $((attempt * 2))
  done
  if [[ "$https_ok" != 1 ]]; then
    incus exec "$vm" -- ip -4 route >&2 || true
    incus exec "$vm" -- getent ahostsv4 "$RUNNER_CONNECT_HOST" >&2 || true
    incus exec "$vm" -- curl -4v -o /dev/null --connect-timeout 10 --max-time 30 \
      "https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/" >&2 || true
    die "$vm cannot reach https://${RUNNER_CONNECT_HOST}:${RUNNER_CONNECT_PORT}/ over IPv4 after 5 attempts."
  fi
  log "✅ Network path from '$vm' is ready."
}

write_base_bootstrap() {
  cat >"$TEMP_DIR/base-bootstrap.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
MARKER=/var/lib/seele-base-ready
[[ ! -e "$MARKER" ]] || exit 0

apt_run() {
  local force4="$1"; shift
  local -a opts=(-o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
  [[ "$force4" == 1 ]] && opts+=(-o Acquire::ForceIPv4=true)
  DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" "$@"
}

force4=0
case "${APT_FORCE_IPV4:-auto}" in 1) force4=1;; 0|auto) :;; *) exit 2;; esac
if ! apt_run "$force4" update; then
  [[ "${APT_FORCE_IPV4:-auto}" != 0 ]] || exit 1
  echo "apt update failed; retrying with Acquire::ForceIPv4=true" >&2
  apt_run 1 update
  force4=1
fi

packages=(build-essential ca-certificates cloud-guest-utils curl docker.io docker-compose-v2 git jq libicu-dev libkrb5-3 libssl-dev
          pkg-config rsync sudo tar unzip xz-utils zip zlib1g)
if ! apt_run "$force4" install -y --no-install-recommends "${packages[@]}"; then
  [[ "${APT_FORCE_IPV4:-auto}" != 0 ]] || exit 1
  echo "apt install failed; retrying with Acquire::ForceIPv4=true" >&2
  apt_run 1 update
  apt_run 1 install -y --no-install-recommends "${packages[@]}"
fi

if ! id runner >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash runner
fi
usermod -aG docker runner
install -o root -g root -m 0440 /dev/null /etc/sudoers.d/90-runner
printf 'runner ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-runner
visudo -cf /etc/sudoers.d/90-runner
systemctl enable --now docker
install -d -o runner -g runner -m 0755 /opt/actions-runner

if [[ "${GUEST_SWAP_SIZE:-1G}" != 0 ]]; then
  swapfile=/swapfile
  if [[ -e "$swapfile" ]] && [[ "$(blkid -p -s TYPE -o value "$swapfile" 2>/dev/null || true)" != swap ]]; then
    echo "$swapfile exists but is not a swap file; refusing to overwrite it" >&2
    exit 1
  fi
  if [[ ! -e "$swapfile" ]]; then
    fallocate -l "$GUEST_SWAP_SIZE" "$swapfile"
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
  fi
  grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab \
    || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  swapon "$swapfile"
fi

if [[ "${DAILY_CLEANUP:-1}" == 1 ]]; then
  cat >/usr/local/sbin/runner-daily-cleanup <<'CLEANUP'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/runner-daily-cleanup.lock
flock -n 9 || exit 0

# Never compete with a GitHub worker or a running Forgejo/Docker job. A
# persistent timer will try again after the next daily trigger.
if pgrep -u runner -f 'Runner.Worker' >/dev/null 2>&1 \
   || docker ps -q | grep -q .; then
  exit 0
fi

# Docker never prunes running containers or resources currently referenced by
# them. Volumes are intentionally excluded.
docker container prune -f --filter 'until=24h'
docker network prune -f --filter 'until=24h'
docker image prune -af --filter 'until=168h'
docker builder prune -af --filter 'until=24h' --keep-storage 2GB \
  || docker builder prune -af --filter 'until=24h'

# Remove stale GitHub job workspaces but preserve downloaded actions and tools.
if [[ -d /opt/actions-runner/_work ]]; then
  find /opt/actions-runner/_work -mindepth 1 -maxdepth 1 -type d -mtime +1 \
    ! -name _actions ! -name _tool ! -name _temp -exec rm -rf -- {} +
  [[ ! -d /opt/actions-runner/_work/_temp ]] \
    || find /opt/actions-runner/_work/_temp -mindepth 1 -mtime +1 -delete
fi
if command -v go >/dev/null 2>&1; then
  runuser -u runner -- go clean -cache -testcache || true
fi

apt-get clean
journalctl --vacuum-time=7d >/dev/null
CLEANUP
  chmod 0755 /usr/local/sbin/runner-daily-cleanup

  cat >/etc/systemd/system/runner-daily-cleanup.service <<'UNIT'
[Unit]
Description=Daily cleanup for disposable Actions runner data
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/runner-daily-cleanup
Nice=10
IOSchedulingClass=idle
UNIT

  cat >/etc/systemd/system/runner-daily-cleanup.timer <<'TIMER'
[Unit]
Description=Daily cleanup timer for Actions runner data

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER
  systemctl daemon-reload
  systemctl enable runner-daily-cleanup.timer
fi

touch "$MARKER"
sync
GUEST
  chmod 700 "$TEMP_DIR/base-bootstrap.sh"
}

golden_snapshot_exists() {
  # `incus snapshot show` queries the snapshot API directly. `incus info
  # instance/snapshot` is not reliable across all Incus client versions and can
  # report absent even though the database already contains the snapshot.
  incus snapshot show "$BASE_VM" "$GOLDEN_SNAPSHOT" >/dev/null 2>&1
}

ensure_base_vm() {
  log "✨ Forging the golden Trotter: Ubuntu VM '$BASE_VM'"
  if golden_snapshot_exists; then
    [[ "$(incus config get "$BASE_VM" user.seele.role)" == base-v1 ]] \
      || die "'$BASE_VM' has the expected snapshot name but is not owned by this provisioner."
    log "✨ Golden Trotter snapshot already exists; package installation is skipped."
    return
  fi

  if ! incus info "$BASE_VM" >/dev/null 2>&1; then
    incus init "$UBUNTU_IMAGE" "$BASE_VM" --vm -p "$INCUS_PROFILE" --storage "$INCUS_STORAGE_POOL" \
      -c limits.cpu="$VM_CPUS" -c limits.memory="$VM_MEMORY" -c user.seele.role=base-v1
  else
    [[ "$(incus config get "$BASE_VM" user.seele.role)" == base-v1 ]] \
      || die "Instance '$BASE_VM' already exists and is not owned by this provisioner. Rename it or choose another BASE_VM."
  fi
  if incus config device show "$BASE_VM" | grep -q '^root:'; then
    incus config device set "$BASE_VM" root size="$VM_DISK"
  else
    incus config device override "$BASE_VM" root size="$VM_DISK"
  fi
  if [[ "$(incus list "$BASE_VM" --format csv -c s | head -n1)" == RUNNING ]]; then
    log "Restarting the incomplete base VM so its Incus agent device is loaded"
    incus restart "$BASE_VM" --timeout 120 || incus restart "$BASE_VM" --force
  else
    incus start "$BASE_VM"
  fi
  wait_for_vm "$BASE_VM"

  if ! incus exec "$BASE_VM" -- test -e /var/lib/seele-base-ready; then
    log "📦 Installing the base toolchain and Docker once (apt progress follows)"
    write_base_bootstrap
    incus file push "$TEMP_DIR/base-bootstrap.sh" "$BASE_VM/root/base-bootstrap.sh"
    incus exec "$BASE_VM" --env APT_FORCE_IPV4="$APT_FORCE_IPV4" \
      --env GUEST_SWAP_SIZE="$GUEST_SWAP_SIZE" --env DAILY_CLEANUP="$DAILY_CLEANUP" \
      -- bash /root/base-bootstrap.sh
    incus exec "$BASE_VM" -- rm -f /root/base-bootstrap.sh
  fi
  incus exec "$BASE_VM" -- test -x /usr/bin/docker
  incus exec "$BASE_VM" -- id runner >/dev/null
  incus stop "$BASE_VM" --timeout 120 || incus stop "$BASE_VM" --force
  if ! incus snapshot create "$BASE_VM" "$GOLDEN_SNAPSHOT"; then
    if golden_snapshot_exists; then
      warn "Snapshot '$BASE_VM/$GOLDEN_SNAPSHOT' appeared during creation; treating it as complete."
    else
      incus snapshot list "$BASE_VM" >&2 || true
      die "Incus rejected snapshot '$BASE_VM/$GOLDEN_SNAPSHOT', but it is not visible through the snapshot API. Inspect Incus state before retrying."
    fi
  fi
  log "✨ Golden Trotter sealed as '$BASE_VM/$GOLDEN_SNAPSHOT'."
}

github_api() {
  local method="$1" path="$2"
  shift 2
  curl -fsSL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    -X "$method" \
    -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com${path}" "$@"
}

check_github_access() {
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required; see README for the minimal permission."
  log "🔑 Seele checks the path to GitHub organization runners"
  github_api GET "/orgs/$ORG/actions/runners?per_page=1" >/dev/null \
    || die "GH_TOKEN cannot administer self-hosted runners in $ORG."
}

forgejo_runner_endpoint() {
  case "$FORGEJO_SCOPE" in
    global) printf '/api/v1/admin/actions/runners\n' ;;
    user) printf '/api/v1/user/actions/runners\n' ;;
    org:*)
      [[ "${FORGEJO_SCOPE#org:}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid FORGEJO_SCOPE organization."
      printf '/api/v1/orgs/%s/actions/runners\n' "${FORGEJO_SCOPE#org:}"
      ;;
    repo:*)
      [[ "${FORGEJO_SCOPE#repo:}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid FORGEJO_SCOPE repository."
      printf '/api/v1/repos/%s/actions/runners\n' "${FORGEJO_SCOPE#repo:}"
      ;;
    *) die "FORGEJO_SCOPE must be global, user, org:NAME, or repo:OWNER/REPO." ;;
  esac
}

forgejo_api() {
  local method="$1" path="$2"
  shift 2
  curl -fsSL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    -X "$method" -H 'Accept: application/json' \
    -H "Authorization: Bearer $FORGEJO_API_TOKEN" \
    "$FORGEJO_URL$path" "$@"
}

check_forgejo_access() {
  [[ -n "$FORGEJO_API_TOKEN" ]] || die "FORGEJO_API_TOKEN is required for automatic Forgejo runner creation."
  local endpoint
  endpoint="$(forgejo_runner_endpoint)"
  log "🪄 Lux checks the path to Forgejo runners at $FORGEJO_URL ($FORGEJO_SCOPE)"
  forgejo_api GET "$endpoint" >/dev/null \
    || die "FORGEJO_API_TOKEN cannot administer $FORGEJO_SCOPE runners at $FORGEJO_URL."
}

forgejo_runner_record() {
  local name="$1" endpoint response
  endpoint="$(forgejo_runner_endpoint)"
  response="$(forgejo_api GET "$endpoint")"
  jq -c --arg n "$name" '(.runners? // . // [])[] | select(.name == $n)' <<<"$response" | head -n1
}

delete_forgejo_runner() {
  local id="$1" endpoint
  endpoint="$(forgejo_runner_endpoint)"
  forgejo_api DELETE "$endpoint/$id" >/dev/null
}

runner_remote_state() {
  local name="$1" page=1 response match
  while :; do
    response="$(github_api GET "/orgs/$ORG/actions/runners?per_page=100&page=$page")"
    match="$(jq -r --arg n "$name" '.runners[] | select(.name == $n) | .status' <<<"$response" | head -n1)"
    [[ -z "$match" ]] || { printf '%s\n' "$match"; return 0; }
    (( page * 100 >= $(jq -r '.total_count' <<<"$response") )) && break
    ((page++))
  done
  printf 'absent\n'
}

runner_remote_id() {
  local name="$1" page=1 response match
  while :; do
    response="$(github_api GET "/orgs/$ORG/actions/runners?per_page=100&page=$page")"
    match="$(jq -r --arg n "$name" '.runners[] | select(.name == $n) | .id' <<<"$response" | head -n1)"
    [[ -z "$match" ]] || { printf '%s\n' "$match"; return 0; }
    (( page * 100 >= $(jq -r '.total_count' <<<"$response") )) && break
    ((page++))
  done
  return 1
}

cleanup_owned_resources() {
  command -v incus >/dev/null 2>&1 || die "Incus is not installed; there is nothing for this script to clean."
  incus admin waitready --timeout=60
  log "🦋 Cleanup in the Sea of Quanta — discovering provisioner-owned resources"

  local name role runner_id record profile_pool profile_network storage_owned network_owned
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    role="$(incus config get "$name" user.seele.role 2>/dev/null || true)"
    case "$role" in
      runner-v1|github-runner-v1)
        [[ -n "${GH_TOKEN:-}" ]] \
          || die "Runner VM '$name' exists. GH_TOKEN is required so --cleanup can remove its GitHub registration safely."
        runner_id="$(runner_remote_id "$name" || true)"
        if [[ -n "$runner_id" ]]; then
          log "Removing GitHub runner registration '$name' (id $runner_id)"
          github_api DELETE "/orgs/$ORG/actions/runners/$runner_id" >/dev/null
        fi
        ;;
      forgejo-runner-v1)
        [[ -n "$FORGEJO_URL" && -n "$FORGEJO_API_TOKEN" ]] \
          || die "Forgejo runner VM '$name' exists. FORGEJO_URL and FORGEJO_API_TOKEN are required for safe cleanup."
        [[ "$(incus config get "$name" user.seele.forgejo_url)" == "$FORGEJO_URL" ]] \
          || die "Forgejo URL for '$name' differs from FORGEJO_URL; refusing remote deletion."
        [[ "$(incus config get "$name" user.seele.forgejo_scope)" == "$FORGEJO_SCOPE" ]] \
          || die "Forgejo scope for '$name' differs from FORGEJO_SCOPE; refusing remote deletion."
        record="$(forgejo_runner_record "$name")"
        runner_id="$(jq -r '.id // empty' <<<"${record:-{}}")"
        if [[ -n "$runner_id" ]]; then
          log "Removing Forgejo runner registration '$name' (id $runner_id)"
          delete_forgejo_runner "$runner_id"
        fi
        ;;
      *) continue ;;
    esac
    log "Deleting owned runner VM '$name'"
    incus delete "$name" --force
  done < <(incus list --format csv -c n)

  if incus info "$BASE_VM" >/dev/null 2>&1; then
    role="$(incus config get "$BASE_VM" user.seele.role 2>/dev/null || true)"
    [[ "$role" == base-v1 ]] \
      || die "Instance '$BASE_VM' exists without the expected ownership marker; refusing to delete it."
    log "Deleting owned base VM '$BASE_VM' and its snapshots"
    incus delete "$BASE_VM" --force
  fi

  if ! incus profile show "$INCUS_PROFILE" >/dev/null 2>&1; then
    log "Owned profile '$INCUS_PROFILE' is already absent; cleanup complete."
    return
  fi
  [[ "$(incus profile get "$INCUS_PROFILE" user.seele.managed)" == true ]] \
    || die "Profile '$INCUS_PROFILE' is not marked as owned; refusing to delete it."

  profile_pool="$(incus profile get "$INCUS_PROFILE" user.seele.storage_pool)"
  [[ -n "$profile_pool" ]] || profile_pool="$(incus profile device get "$INCUS_PROFILE" root pool)"
  profile_network="$(incus profile get "$INCUS_PROFILE" user.seele.network)"
  [[ -n "$profile_network" ]] || profile_network="$(incus profile device get "$INCUS_PROFILE" eth0 network)"
  storage_owned="$(incus profile get "$INCUS_PROFILE" user.seele.storage_owned)"
  network_owned="$(incus profile get "$INCUS_PROFILE" user.seele.network_owned)"
  if [[ -z "$storage_owned" ]] && pool_looks_like_legacy_seele_loop "$profile_pool"; then
    storage_owned=1
  fi

  log "Deleting owned profile '$INCUS_PROFILE'"
  incus profile delete "$INCUS_PROFILE"

  if [[ "$storage_owned" == 1 || "$storage_owned" == true ]]; then
    if incus storage show "$profile_pool" >/dev/null 2>&1; then
      log "Deleting owned storage pool '$profile_pool'"
      incus storage delete "$profile_pool"
    fi
  else
    log "Leaving reused storage pool '$profile_pool' untouched."
  fi

  if [[ "$network_owned" == 1 || "$network_owned" == true ]]; then
    if incus network show "$profile_network" >/dev/null 2>&1; then
      log "Deleting owned network '$profile_network'"
      incus network delete "$profile_network"
    fi
  else
    log "Leaving pre-existing network '$profile_network' untouched."
  fi
  log "🦋✅ Sea of Quanta cleared. Run again without --cleanup to summon a fresh herd."
}

write_runner_install() {
  local vm="$1" replace="$2"
  cat >"$TEMP_DIR/runner-install.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
VM_NAME="$1" ORG="$2" RUNNER_GROUP="$3" REQUESTED_VERSION="$4" REPLACE="$5"
cd /opt/actions-runner
[[ ! -e .runner ]] || exit 0

api_json="$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 60 \
  https://api.github.com/repos/actions/runner/releases/latest)"
latest="$(jq -r '.tag_name | ltrimstr("v")' <<<"$api_json")"
version="$REQUESTED_VERSION"
[[ "$version" != latest ]] || version="$latest"

case "$(dpkg --print-architecture)" in
  amd64) runner_arch=x64 ;;
  arm64) runner_arch=arm64 ;;
  *) echo "Unsupported guest architecture" >&2; exit 1 ;;
esac
asset="actions-runner-linux-${runner_arch}-${version}.tar.gz"
if [[ "$version" != "$latest" ]]; then
  api_json="$(curl -fsSL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 60 \
    "https://api.github.com/repos/actions/runner/releases/tags/v${version}")"
fi
url="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .browser_download_url' <<<"$api_json")"
digest="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest // empty' <<<"$api_json")"
[[ -n "$url" ]] || { echo "Runner asset not found: $asset" >&2; exit 1; }
[[ "$digest" == sha256:* ]] || { echo "GitHub API did not provide a SHA-256 digest for $asset" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f -- "$tmp" /run/github-runner-registration-token' EXIT
curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 900 "$url" -o "$tmp"
printf '%s  %s\n' "${digest#sha256:}" "$tmp" | sha256sum -c -
tar -xzf "$tmp" --no-same-owner
chown -R runner:runner /opt/actions-runner
token="$(</run/github-runner-registration-token)"
args=(--unattended --url "https://github.com/$ORG" --token "$token" --name "$VM_NAME" \
      --runnergroup "$RUNNER_GROUP" --work _work --labels seele,selee-trotter,docker)
[[ "$REPLACE" != 1 ]] || args+=(--replace)
runuser -u runner -- ./config.sh "${args[@]}"
./svc.sh install runner
./svc.sh start
systemctl is-active --quiet "$(cat .service)"
GUEST
  chmod 700 "$TEMP_DIR/runner-install.sh"
}

ensure_runner_vm() {
  local index="$1" name remote replace=0 token service_name
  printf -v name '%s-%02d' "$RUNNER_PREFIX" "$index"
  log "🐗 Summoning Warp Trotter runner VM '$name'"
  if ! incus info "$name" >/dev/null 2>&1; then
    incus copy "$BASE_VM/$GOLDEN_SNAPSHOT" "$name"
    incus config set "$name" user.seele.role=runner-v1 user.seele.runner_name="$name"
  else
    [[ "$(incus config get "$name" user.seele.role)" == runner-v1 ]] \
      || die "Instance '$name' already exists and is not owned by this provisioner. Rename it before continuing."
  fi
  incus start "$name" 2>/dev/null || true
  wait_for_vm "$name"

  if incus exec "$name" -- test -e /opt/actions-runner/.runner; then
    remote="$(runner_remote_state "$name")"
    [[ "$remote" != absent ]] \
      || die "$name is configured locally but missing from GitHub. Reconcile its stale local config before rerunning."
    if ! incus exec "$name" -- test -s /opt/actions-runner/.service; then
      warn "$name is configured but has no systemd service; repairing the service installation."
      incus exec "$name" -- bash -c 'cd /opt/actions-runner && ./svc.sh install runner && ./svc.sh start'
    fi
    service_name="$(incus exec "$name" -- sh -c 'cat /opt/actions-runner/.service 2>/dev/null' || true)"
    [[ -n "$service_name" ]] || die "$name is configured but its service metadata is missing."
    incus exec "$name" -- systemctl enable --now "$service_name"
    log "$name is already configured; no duplicate registration performed."
    return
  fi

  remote="$(runner_remote_state "$name")"
  case "$remote" in
    absent) : ;;
    offline)
      [[ "$REPLACE_OFFLINE_RUNNER" == 1 ]] \
        || die "$name exists on GitHub and is offline. Reconcile/delete it, or rerun with REPLACE_OFFLINE_RUNNER=1."
      replace=1
      ;;
    online) die "$name already exists and is online on GitHub; refusing to replace it." ;;
    *) die "Unexpected GitHub runner state for $name: $remote" ;;
  esac

  token="$(github_api POST "/orgs/$ORG/actions/runners/registration-token" | jq -er '.token')"
  printf '%s' "$token" >"$TEMP_DIR/registration-token"
  chmod 600 "$TEMP_DIR/registration-token"
  incus file push "$TEMP_DIR/registration-token" "$name/run/github-runner-registration-token"
  incus exec "$name" -- chmod 600 /run/github-runner-registration-token
  write_runner_install "$name" "$replace"
  incus file push "$TEMP_DIR/runner-install.sh" "$name/root/runner-install.sh"
  if ! incus exec "$name" -- bash /root/runner-install.sh "$name" "$ORG" "$RUNNER_GROUP" "$RUNNER_VERSION" "$replace"; then
    incus exec "$name" -- rm -f /run/github-runner-registration-token /root/runner-install.sh || true
    die "Runner installation failed in $name. The VM was kept for inspection and will not be duplicated on rerun."
  fi
  incus exec "$name" -- rm -f /root/runner-install.sh /run/github-runner-registration-token
  : >"$TEMP_DIR/registration-token"
  log "🐗 $name escaped into $ORG / $RUNNER_GROUP and is running as a systemd service."
}

write_forgejo_runner_install() {
  cat >"$TEMP_DIR/forgejo-runner-install.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="$1"
docker_server="$(docker version --format '{{.Server.Version}}')"
dpkg --compare-versions "${docker_server%%-*}" ge 25.0 \
  || { echo "Forgejo Runner v13 requires Docker >=25; found $docker_server" >&2; exit 1; }
case "$(dpkg --print-architecture)" in
  amd64) runner_arch=amd64 ;;
  arm64) runner_arch=arm64 ;;
  *) echo "Unsupported guest architecture" >&2; exit 1 ;;
esac

url="https://code.forgejo.org/forgejo/runner/releases/download/v${VERSION}/forgejo-runner-${VERSION}-linux-${runner_arch}"
tmp="$(mktemp)"
trap 'rm -f -- "$tmp" /run/forgejo-runner-config.json' EXIT
curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 900 "$url" -o "$tmp"
install -o root -g root -m 0755 "$tmp" /usr/local/bin/forgejo-runner
install -o runner -g runner -m 0600 /run/forgejo-runner-config.json /home/runner/runner-config.yml
install -d -o runner -g runner -m 0755 /home/runner/.cache/act

cat >/etc/systemd/system/forgejo-runner.service <<'UNIT'
[Unit]
Description=Forgejo Actions Runner
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
User=runner
Group=runner
SupplementaryGroups=docker
WorkingDirectory=/home/runner
ExecStart=/usr/local/bin/forgejo-runner daemon -c /home/runner/runner-config.yml
Restart=always
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now forgejo-runner.service
sleep 2
systemctl is-active --quiet forgejo-runner.service
GUEST
  chmod 700 "$TEMP_DIR/forgejo-runner-install.sh"
}

ensure_forgejo_runner_vm() {
  local index="$1" name record id identity uuid token
  printf -v name '%s-%02d' "$RUNNER_PREFIX" "$index"
  log "🐧 Summoning Poro Forgejo runner VM '$name' under Lux's light"
  if ! incus info "$name" >/dev/null 2>&1; then
    incus copy "$BASE_VM/$GOLDEN_SNAPSHOT" "$name"
    incus config set "$name" user.seele.role=forgejo-runner-v1 user.seele.runner_name="$name" \
      user.seele.forgejo_url="$FORGEJO_URL" user.seele.forgejo_scope="$FORGEJO_SCOPE"
  else
    [[ "$(incus config get "$name" user.seele.role)" == forgejo-runner-v1 ]] \
      || die "Instance '$name' already exists and is not an owned Forgejo runner."
  fi
  incus start "$name" 2>/dev/null || true
  wait_for_vm "$name"

  record="$(forgejo_runner_record "$name")"
  if incus exec "$name" -- test -s /home/runner/runner-config.yml; then
    [[ -n "$record" ]] || die "$name has local Forgejo credentials but is absent remotely. Delete/recreate its local VM or restore the remote runner."
    incus exec "$name" -- systemctl enable --now forgejo-runner.service
    log "🐧 $name is already configured; no duplicate Forgejo identity was created."
    return
  fi

  if [[ -n "$record" ]]; then
    [[ "$REPLACE_OFFLINE_RUNNER" == 1 ]] \
      || die "$name already exists in Forgejo but this VM has no credentials. Delete it remotely or use REPLACE_OFFLINE_RUNNER=1."
    id="$(jq -er '.id' <<<"$record")"
    warn "Replacing stale Forgejo runner '$name' (id $id)."
    delete_forgejo_runner "$id"
  fi

  identity="$(forgejo_api POST "$(forgejo_runner_endpoint)" \
    -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg name "$name" '{name:$name, description:"Incus VM managed by provision-seele-runners", ephemeral:false}')")"
  uuid="$(jq -er '.uuid' <<<"$identity")"
  token="$(jq -er '.token' <<<"$identity")"

  jq -n --arg url "$FORGEJO_URL" --arg uuid "$uuid" --arg token "$token" \
    --arg labels "$FORGEJO_LABELS" '{
      log: {level: "info"},
      runner: {capacity: 1, labels: ($labels | split(","))},
      container: {docker_host: "unix:///var/run/docker.sock"},
      server: {connections: {forgejo: {url: $url, uuid: $uuid, token: $token}}}
    }' >"$TEMP_DIR/forgejo-runner-config.json"
  chmod 600 "$TEMP_DIR/forgejo-runner-config.json"
  incus file push "$TEMP_DIR/forgejo-runner-config.json" "$name/run/forgejo-runner-config.json"
  incus exec "$name" -- chmod 600 /run/forgejo-runner-config.json
  write_forgejo_runner_install
  incus file push "$TEMP_DIR/forgejo-runner-install.sh" "$name/root/forgejo-runner-install.sh"
  if ! incus exec "$name" -- bash /root/forgejo-runner-install.sh "$FORGEJO_RUNNER_VERSION"; then
    incus exec "$name" -- rm -f /run/forgejo-runner-config.json /root/forgejo-runner-install.sh || true
    die "Forgejo Runner installation failed in $name. Its remote identity was kept for safe inspection."
  fi
  incus exec "$name" -- rm -f /root/forgejo-runner-install.sh /run/forgejo-runner-config.json
  : >"$TEMP_DIR/forgejo-runner-config.json"
  identity= uuid= token=
  log "🐧✨ $name joined $FORGEJO_URL and is running as forgejo-runner.service."
}

verify_unique_runner_ipv4() {
  local i name ip
  declare -A seen_ipv4=()
  for ((i=1; i<=RUNNER_COUNT; i++)); do
    printf -v name '%s-%02d' "$RUNNER_PREFIX" "$i"
    ip="$(incus exec "$name" -- ip -4 -o address show scope global 2>/dev/null \
      | awk '$2 !~ /^docker/ {split($4,a,"/"); print a[1]; exit}' || true)"
    [[ -n "$ip" ]] || die "$name has no non-Docker IPv4 address after provisioning."
    if [[ -n "${seen_ipv4[$ip]:-}" ]]; then
      die "$name and ${seen_ipv4[$ip]} still share IPv4 $ip; DHCP identity repair did not take effect."
    fi
    seen_ipv4[$ip]="$name"
  done
  log "🪪 Every runner has a unique IPv4 lease."
}

main() {
  if [[ "$STOP_RUNNING_MODE" == 1 ]]; then
    stop_running_provisioner
    return
  fi
  acquire_provisioning_lock
  TEMP_DIR="$(mktemp -d -t seele-provision.XXXXXXXX)"
  chmod 700 "$TEMP_DIR"
  if [[ "$CLEANUP_MODE" == 1 ]]; then
    cleanup_owned_resources
    return
  fi
  preflight_host
  install_incus
  ensure_host_swap
  if [[ "$RUNNER_PROVIDER" == github ]]; then
    [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required; see README for the minimal permission."
    check_github_access
  else
    check_forgejo_access
  fi
  ensure_incus_foundation
  ensure_incus_firewall_access
  ensure_base_vm
  local i
  for ((i=1; i<=RUNNER_COUNT; i++)); do
    if [[ "$RUNNER_PROVIDER" == github ]]; then
      ensure_runner_vm "$i"
    else
      ensure_forgejo_runner_vm "$i"
    fi
  done
  verify_unique_runner_ipv4
  if [[ "$RUNNER_PROVIDER" == github ]]; then
    log "🦋✅ Provisioning complete — Seele's Trotter herd is ready"
    printf '\nGitHub: https://github.com/organizations/%s/settings/actions/runners\n' "$ORG"
  else
    log "🪄✅ Provisioning complete — Lux's Poro parade is ready"
    printf '\nForgejo: %s (scope: %s)\n' "$FORGEJO_URL" "$FORGEJO_SCOPE"
  fi
  incus list "^${RUNNER_PREFIX}-" -c ns4t
}

main "$@"
