#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Install one persistent Actions runner directly on an Ubuntu host. This script
# deliberately does not install, restart, reconfigure, or prune host Docker.

load_local_env() {
  local env_path="${ENV_FILE:-$PWD/.env}" line key value
  [[ -e "$env_path" ]] || return 0
  [[ -f "$env_path" ]] || { printf 'ERROR: %s is not a regular file.\n' "$env_path" >&2; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] \
      || { printf 'ERROR: invalid .env line: %s\n' "$line" >&2; exit 1; }
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" == \"*\" && "$value" == *\" ]] || [[ "$value" == \'*\' && "$value" == *\' ]]; then
      value="${value:1:${#value}-2}"
    fi
    case "$key" in
      RUNNER_PROVIDER|RUNNER_NAME|RUNNER_USER|RUNNER_PASSWORDLESS_SUDO|HOST_SWAP_SIZE|APT_FORCE_IPV4|\
      GH_TOKEN|ORG|RUNNER_GROUP|GITHUB_LABELS|RUNNER_VERSION|REPLACE_OFFLINE_RUNNER|\
      FORGEJO_URL|FORGEJO_API_TOKEN|FORGEJO_TOKEN|FORGEJO_SCOPE|FORGEJO_LABELS|\
      FORGEJO_RUNNER_VERSION|ALLOW_INSECURE_FORGEJO)
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

RUNNER_PROVIDER="${RUNNER_PROVIDER:-github}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_USER="${RUNNER_USER:-runner}"
RUNNER_PASSWORDLESS_SUDO="${RUNNER_PASSWORDLESS_SUDO:-0}"
HOST_SWAP_SIZE="${HOST_SWAP_SIZE:-0}"
APT_FORCE_IPV4="${APT_FORCE_IPV4:-auto}"

ORG="${ORG:-}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
GITHUB_LABELS="${GITHUB_LABELS:-cakecat,potato,mikrus}"
RUNNER_VERSION="${RUNNER_VERSION:-latest}"
REPLACE_OFFLINE_RUNNER="${REPLACE_OFFLINE_RUNNER:-0}"

FORGEJO_URL="${FORGEJO_URL:-}"
FORGEJO_URL="${FORGEJO_URL%/}"
FORGEJO_API_TOKEN="${FORGEJO_API_TOKEN:-${FORGEJO_TOKEN:-}}"
FORGEJO_SCOPE="${FORGEJO_SCOPE:-global}"
FORGEJO_LABELS="${FORGEJO_LABELS:-docker:docker://node:20-bookworm}"
FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-latest}"
ALLOW_INSECURE_FORGEJO="${ALLOW_INSECURE_FORGEJO:-0}"

readonly STATE_DIR=/etc/runner-fleet-config
readonly STATE_FILE="$STATE_DIR/potato-runner.json"
readonly NAME_FILE="$STATE_DIR/potato-runner-name"
readonly GITHUB_DIR=/opt/actions-runner
readonly FORGEJO_CONFIG_DIR=/etc/forgejo-runner
readonly FORGEJO_CONFIG="$FORGEJO_CONFIG_DIR/runner-config.yml"
readonly MANAGED_MARKER=.runner-fleet-managed
readonly LOCK_FILE=/run/lock/runner-fleet-potato.lock
MODE=install
TEMP_DIR=""

log()  { printf '\n🥔 [%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die()  { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }

cleanup_temp() {
  [[ -z "${TEMP_DIR:-}" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}
trap cleanup_temp EXIT
trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<'EOF'
Usage:
  sudo ./provision-potato-runner.sh
  sudo ./provision-potato-runner.sh --status
  sudo ./provision-potato-runner.sh --restart
  sudo ./provision-potato-runner.sh --cleanup

The script reads a safe allowlist from .env in the current directory.

GitHub requires:
  RUNNER_PROVIDER=github
  GH_TOKEN=...
  ORG=...

Forgejo requires:
  RUNNER_PROVIDER=forgejo
  FORGEJO_URL=https://git.example.com
  FORGEJO_API_TOKEN=...
  FORGEJO_SCOPE=global|user|org:NAME|repo:OWNER/REPOSITORY

Common optional settings:
  RUNNER_NAME=cakecat-tiramisu  Omit to draw a cake name once and persist it.
  RUNNER_USER=runner
  RUNNER_PASSWORDLESS_SUDO=0
  HOST_SWAP_SIZE=0          Set e.g. 1G to create swap only if none is active.
  APT_FORCE_IPV4=auto
EOF
}

case "${1:-}" in
  "") : ;;
  --status) MODE=status ;;
  --restart) MODE=restart ;;
  --cleanup) MODE=cleanup ;;
  --help|-h) usage; exit 0 ;;
  *) die "Unknown option: $1 (use --help)." ;;
esac

resolve_runner_name() {
  [[ -z "$RUNNER_NAME" ]] || return 0
  if [[ -s "$STATE_FILE" ]]; then
    RUNNER_NAME="$(jq -er '.name' "$STATE_FILE")"
    return
  fi
  if [[ -s "$NAME_FILE" ]]; then
    RUNNER_NAME="$(<"$NAME_FILE")"
    return
  fi
  [[ "$MODE" == install ]] || return 0
  local -a cakes=(
    brownie cannoli cheesecake chiffon-cookie cupcake donut eclair flan
    macaron madeleine millefeuille mochi muffin opera-cake panettone
    pavlova red-velvet sacher shortcake strudel tiramisu tres-leches waffle
  )
  RUNNER_NAME="cakecat-${cakes[RANDOM % ${#cakes[@]}]}"
  install -d -o root -g root -m 0700 "$STATE_DIR"
  printf '%s\n' "$RUNNER_NAME" >"$NAME_FILE"
  chmod 0600 "$NAME_FILE"
  log "🎂 The potato adopted a random cakecat name: $RUNNER_NAME"
}

[[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."
[[ "$RUNNER_PROVIDER" =~ ^(github|forgejo)$ ]] || die "RUNNER_PROVIDER must be github or forgejo."
[[ -z "$RUNNER_NAME" || "$RUNNER_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "RUNNER_NAME may contain only letters, digits, dot, underscore and dash."
[[ "$RUNNER_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "RUNNER_USER is invalid."
[[ "$RUNNER_PASSWORDLESS_SUDO" =~ ^[01]$ ]] || die "RUNNER_PASSWORDLESS_SUDO must be 0 or 1."
[[ "$HOST_SWAP_SIZE" =~ ^(0|[1-9][0-9]*[MG])$ ]] || die "HOST_SWAP_SIZE must be 0 or look like 1G/1024M."
[[ "$APT_FORCE_IPV4" =~ ^(auto|0|1)$ ]] || die "APT_FORCE_IPV4 must be auto, 0, or 1."
[[ "$REPLACE_OFFLINE_RUNNER" =~ ^[01]$ ]] || die "REPLACE_OFFLINE_RUNNER must be 0 or 1."
[[ "$ALLOW_INSECURE_FORGEJO" =~ ^[01]$ ]] || die "ALLOW_INSECURE_FORGEJO must be 0 or 1."

exec 9>"$LOCK_FILE"
flock -n 9 || die "Another potato provisioner is already running."
resolve_runner_name
[[ -z "$RUNNER_NAME" || "$RUNNER_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Persisted RUNNER_NAME is invalid."

apt_retry() {
  local force4="$1"; shift
  local -a opts=(-o Acquire::Retries=4 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)
  [[ "$force4" != 1 ]] || opts+=(-o Acquire::ForceIPv4=true)
  DEBIAN_FRONTEND=noninteractive timeout 900 apt-get "${opts[@]}" "$@"
}

host_apt() {
  local force4=0
  [[ "$APT_FORCE_IPV4" == 1 ]] && force4=1
  if ! apt_retry "$force4" update; then
    [[ "$APT_FORCE_IPV4" != 0 ]] || die "apt update failed and APT_FORCE_IPV4=0."
    warn "apt update failed; retrying over IPv4."
    apt_retry 1 update
    force4=1
  fi
  if ! apt_retry "$force4" install -y --no-install-recommends "$@"; then
    [[ "$APT_FORCE_IPV4" != 0 ]] || die "apt install failed and APT_FORCE_IPV4=0."
    warn "apt install failed; retrying over IPv4."
    apt_retry 1 install -y --no-install-recommends "$@"
  fi
}

ensure_optional_swap() {
  [[ "$HOST_SWAP_SIZE" != 0 ]] || return 0
  if swapon --noheadings --show=NAME 2>/dev/null | grep -q .; then
    log "💾 Swap already active; leaving it unchanged."
    return
  fi
  local swapfile=/swapfile fs_type free_mib requested_mib
  case "$HOST_SWAP_SIZE" in
    *G) requested_mib="$(( ${HOST_SWAP_SIZE%G} * 1024 ))" ;;
    *M) requested_mib="${HOST_SWAP_SIZE%M}" ;;
  esac
  free_mib="$(df -Pm / | awk 'NR==2 {print $4}')"
  ((free_mib - requested_mib >= 2048)) \
    || die "Refusing $HOST_SWAP_SIZE swap: less than 2 GiB would remain on /."
  if [[ -e "$swapfile" ]]; then
    [[ "$(blkid -p -s TYPE -o value "$swapfile" 2>/dev/null || true)" == swap ]] \
      || die "$swapfile exists but is not swap; refusing to overwrite it."
  else
    fs_type="$(findmnt -no FSTYPE /)"
    log "💾 Creating $HOST_SWAP_SIZE swap on $fs_type"
    case "$fs_type" in
      btrfs) host_apt btrfs-progs; btrfs filesystem mkswapfile --size "$HOST_SWAP_SIZE" "$swapfile" ;;
      ext4|xfs) fallocate -l "$HOST_SWAP_SIZE" "$swapfile"; chmod 600 "$swapfile"; mkswap "$swapfile" >/dev/null ;;
      *) die "Automatic swap is unsupported on '$fs_type'; configure it manually or keep HOST_SWAP_SIZE=0." ;;
    esac
  fi
  chmod 600 "$swapfile"
  grep -Eq '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab \
    || printf '/swapfile none swap sw 0 0\n' >>/etc/fstab
  swapon "$swapfile"
}

preflight() {
  [[ -r /etc/os-release ]] || die "Cannot identify the host OS."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "This script supports Ubuntu; detected ${ID:-unknown}."
  command -v systemctl >/dev/null || die "systemd is required."
  command -v docker >/dev/null || die "Docker is not installed. Install/configure it first; this script will not alter it."
  systemctl is-active --quiet docker || die "Docker exists but is not active. Start it yourself before provisioning."
  docker info >/dev/null 2>&1 || die "The existing Docker daemon is not usable by root."
  case "$(dpkg --print-architecture)" in amd64|arm64) : ;; *) die "Only amd64 and arm64 are supported." ;; esac
  local connect_host
  if [[ "$RUNNER_PROVIDER" == github ]]; then
    connect_host=api.github.com
  else
    [[ -n "$FORGEJO_URL" ]] || die "FORGEJO_URL is required for Forgejo mode."
    connect_host="${FORGEJO_URL#*://}"; connect_host="${connect_host%%/*}"; connect_host="${connect_host%%:*}"
  fi
  getent ahosts "$connect_host" >/dev/null || die "DNS lookup failed for $connect_host."
  log "✅ Ubuntu and the existing Docker daemon are ready; Docker configuration remains untouched."
}

ensure_runner_user() {
  if ! id "$RUNNER_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$RUNNER_USER"
  fi
  getent group docker >/dev/null || die "Docker group is missing; refusing to reconfigure Docker."
  usermod -aG docker "$RUNNER_USER"
  if [[ "$RUNNER_PASSWORDLESS_SUDO" == 1 ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$RUNNER_USER" >"/etc/sudoers.d/90-${RUNNER_USER}-actions-runner"
    chmod 0440 "/etc/sudoers.d/90-${RUNNER_USER}-actions-runner"
    visudo -cf "/etc/sudoers.d/90-${RUNNER_USER}-actions-runner" >/dev/null
  else
    rm -f -- "/etc/sudoers.d/90-${RUNNER_USER}-actions-runner"
  fi
}

github_api() {
  local method="$1" path="$2"; shift 2
  curl -fsSL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    -X "$method" -H 'Accept: application/vnd.github+json' \
    -H "Authorization: Bearer $GH_TOKEN" -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com${path}" "$@"
}

github_runner_record() {
  local page=1 response record total
  while :; do
    response="$(github_api GET "/orgs/$ORG/actions/runners?per_page=100&page=$page")"
    record="$(jq -c --arg n "$RUNNER_NAME" '.runners[] | select(.name == $n)' <<<"$response" | head -n1)"
    [[ -z "$record" ]] || { printf '%s\n' "$record"; return; }
    total="$(jq -r '.total_count' <<<"$response")"
    ((page * 100 >= total)) && break
    ((page++))
  done
}

forgejo_runner_endpoint() {
  case "$FORGEJO_SCOPE" in
    global) printf '/api/v1/admin/actions/runners\n' ;;
    user) printf '/api/v1/user/actions/runners\n' ;;
    org:*) [[ "${FORGEJO_SCOPE#org:}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid Forgejo organization."; printf '/api/v1/orgs/%s/actions/runners\n' "${FORGEJO_SCOPE#org:}" ;;
    repo:*) [[ "${FORGEJO_SCOPE#repo:}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid Forgejo repository."; printf '/api/v1/repos/%s/actions/runners\n' "${FORGEJO_SCOPE#repo:}" ;;
    *) die "FORGEJO_SCOPE must be global, user, org:NAME, or repo:OWNER/REPOSITORY." ;;
  esac
}

forgejo_api() {
  local method="$1" path="$2"; shift 2
  curl -fsSL --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    -X "$method" -H 'Accept: application/json' -H "Authorization: Bearer $FORGEJO_API_TOKEN" \
    "$FORGEJO_URL$path" "$@"
}

forgejo_runner_record() {
  local endpoint response
  endpoint="$(forgejo_runner_endpoint)"
  response="$(forgejo_api GET "$endpoint")"
  jq -c --arg n "$RUNNER_NAME" '(.runners? // . // [])[] | select(.name == $n)' <<<"$response" | head -n1
}

write_state() {
  install -d -o root -g root -m 0700 "$STATE_DIR"
  jq -n --arg provider "$RUNNER_PROVIDER" --arg name "$RUNNER_NAME" --arg user "$RUNNER_USER" \
    --arg org "$ORG" --arg group "$RUNNER_GROUP" --arg url "$FORGEJO_URL" --arg scope "$FORGEJO_SCOPE" \
    '{provider:$provider,name:$name,user:$user,org:$org,group:$group,forgejo_url:$url,forgejo_scope:$scope}' \
    >"$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  printf '%s\n' "$RUNNER_NAME" >"$NAME_FILE"
  chmod 0600 "$NAME_FILE"
}

assert_state_matches() {
  [[ -s "$STATE_FILE" ]] || return 0
  local old_provider old_name
  old_provider="$(jq -er '.provider' "$STATE_FILE")"
  old_name="$(jq -er '.name' "$STATE_FILE")"
  [[ "$old_provider" == "$RUNNER_PROVIDER" && "$old_name" == "$RUNNER_NAME" ]] \
    || die "This host already manages '$old_name' ($old_provider). Use its matching .env with --cleanup first."
}

install_github_runner() {
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required."
  [[ "$ORG" =~ ^[A-Za-z0-9_.-]+$ ]] || die "ORG is required and invalid."
  github_api GET "/orgs/$ORG/actions/runners?per_page=1" >/dev/null \
    || die "GH_TOKEN cannot administer runners in $ORG."

  local record status replace=0 api_json latest version arch asset url digest archive token service
  record="$(github_runner_record)"
  if [[ -f "$GITHUB_DIR/.runner" ]]; then
    [[ -f "$GITHUB_DIR/$MANAGED_MARKER" ]] || die "$GITHUB_DIR contains an unmanaged runner; refusing to adopt it."
    [[ "$(jq -r '.agentName // empty' "$GITHUB_DIR/.runner")" == "$RUNNER_NAME" ]] \
      || die "Local GitHub runner name differs from RUNNER_NAME."
    [[ -n "$record" ]] || die "Local runner exists but its GitHub registration is missing. Run --cleanup with matching settings first."
    service="$(cat "$GITHUB_DIR/.service" 2>/dev/null || true)"
    if [[ -z "$service" ]]; then
      (cd "$GITHUB_DIR" && ./svc.sh install "$RUNNER_USER")
      service="$(cat "$GITHUB_DIR/.service")"
    fi
    systemctl enable --now "$service"
    write_state
    log "🐈 $RUNNER_NAME is already configured; no duplicate registration was created."
    return
  fi

  if [[ -n "$record" ]]; then
    status="$(jq -r '.status' <<<"$record")"
    [[ "$status" == offline && "$REPLACE_OFFLINE_RUNNER" == 1 ]] \
      || die "$RUNNER_NAME already exists on GitHub ($status). Reconcile it or explicitly set REPLACE_OFFLINE_RUNNER=1 for an offline entry."
    replace=1
  fi

  if [[ -d "$GITHUB_DIR" && ! -f "$GITHUB_DIR/$MANAGED_MARKER" ]]; then
    [[ -z "$(find "$GITHUB_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
      || die "$GITHUB_DIR is non-empty and unmanaged; refusing to overwrite it."
  fi
  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" -m 0755 "$GITHUB_DIR"
  install -o root -g root -m 0444 /dev/null "$GITHUB_DIR/$MANAGED_MARKER"

  api_json="$(curl -fsSL --retry 5 --retry-all-errors https://api.github.com/repos/actions/runner/releases/latest)"
  latest="$(jq -er '.tag_name | ltrimstr("v")' <<<"$api_json")"
  version="$RUNNER_VERSION"; [[ "$version" != latest ]] || version="$latest"
  case "$(dpkg --print-architecture)" in amd64) arch=x64 ;; arm64) arch=arm64 ;; esac
  asset="actions-runner-linux-${arch}-${version}.tar.gz"
  if [[ "$version" != "$latest" ]]; then
    api_json="$(curl -fsSL --retry 5 --retry-all-errors "https://api.github.com/repos/actions/runner/releases/tags/v${version}")"
  fi
  url="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .browser_download_url' <<<"$api_json")"
  digest="$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest // empty' <<<"$api_json")"
  [[ -n "$url" && "$digest" == sha256:* ]] || die "GitHub release metadata lacks a verified asset for $asset."
  archive="$TEMP_DIR/$asset"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 900 "$url" -o "$archive"
  printf '%s  %s\n' "${digest#sha256:}" "$archive" | sha256sum -c -
  tar -xzf "$archive" -C "$GITHUB_DIR" --no-same-owner
  chown -R "$RUNNER_USER:$RUNNER_USER" "$GITHUB_DIR"
  chown root:root "$GITHUB_DIR/$MANAGED_MARKER"
  (cd "$GITHUB_DIR" && ./bin/installdependencies.sh)

  token="$(github_api POST "/orgs/$ORG/actions/runners/registration-token" | jq -er '.token')"
  local -a args=(--unattended --url "https://github.com/$ORG" --token "$token" --name "$RUNNER_NAME" \
    --runnergroup "$RUNNER_GROUP" --work _work --labels "$GITHUB_LABELS")
  [[ "$replace" != 1 ]] || args+=(--replace)
  (cd "$GITHUB_DIR" && runuser -u "$RUNNER_USER" -- ./config.sh "${args[@]}")
  token=""
  (cd "$GITHUB_DIR" && ./svc.sh install "$RUNNER_USER" && ./svc.sh start)
  service="$(cat "$GITHUB_DIR/.service")"
  systemctl is-active --quiet "$service" || die "GitHub runner service failed to start."
  write_state
  log "🐈✨ $RUNNER_NAME joined GitHub organization $ORG / $RUNNER_GROUP."
}

forgejo_latest_version() {
  curl -fsSL --retry 5 --retry-all-errors \
    https://data.forgejo.org/api/v1/repos/forgejo/runner/releases/latest \
    | jq -er '.name | ltrimstr("v")'
}

install_forgejo_binary() {
  local version="$FORGEJO_RUNNER_VERSION" arch url binary signature signing_key gpg_home fingerprint
  [[ "$version" != latest ]] || version="$(forgejo_latest_version)"
  case "$(dpkg --print-architecture)" in amd64) arch=amd64 ;; arm64) arch=arm64 ;; esac
  url="https://code.forgejo.org/forgejo/runner/releases/download/v${version}/forgejo-runner-${version}-linux-${arch}"
  binary="$TEMP_DIR/forgejo-runner"; signature="$TEMP_DIR/forgejo-runner.asc"
  signing_key="$TEMP_DIR/forgejo-signing-key.asc"; gpg_home="$TEMP_DIR/gnupg"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 900 "$url" -o "$binary"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 120 "$url.asc" -o "$signature"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 10 --max-time 120 \
    'https://keys.openpgp.org/vks/v1/by-fingerprint/EB114F5E6C0DC2BCDD183550A4B61A2DC5923710' \
    -o "$signing_key"
  install -d -m 0700 "$gpg_home"
  GNUPGHOME="$gpg_home" gpg --batch --import "$signing_key" >/dev/null
  GNUPGHOME="$gpg_home" gpg --batch --status-fd 1 --verify "$signature" "$binary" \
    | grep -q 'VALIDSIG EB114F5E6C0DC2BCDD183550A4B61A2DC5923710'
  fingerprint="$(GNUPGHOME="$gpg_home" gpg --batch --with-colons --fingerprint EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 | awk -F: '$1=="fpr" {print $10; exit}')"
  [[ "$fingerprint" == EB114F5E6C0DC2BCDD183550A4B61A2DC5923710 ]] || die "Unexpected Forgejo release signing key."
  install -o root -g root -m 0755 "$binary" /usr/local/bin/forgejo-runner
}

install_forgejo_runner() {
  [[ -n "$FORGEJO_URL" && -n "$FORGEJO_API_TOKEN" ]] || die "FORGEJO_URL and FORGEJO_API_TOKEN are required."
  if [[ "$ALLOW_INSECURE_FORGEJO" != 1 ]]; then
    [[ "$FORGEJO_URL" == https://* ]] || die "FORGEJO_URL must use HTTPS (or explicitly set ALLOW_INSECURE_FORGEJO=1)."
  fi
  local endpoint record id identity uuid token docker_server runner_home runner_group
  endpoint="$(forgejo_runner_endpoint)"
  forgejo_api GET "$endpoint" >/dev/null || die "Token cannot administer $FORGEJO_SCOPE runners."
  docker_server="$(docker version --format '{{.Server.Version}}')"
  dpkg --compare-versions "${docker_server%%-*}" ge 25.0 \
    || die "Forgejo Runner v13 requires Docker >=25; existing Docker is $docker_server."
  record="$(forgejo_runner_record)"

  if [[ -s "$FORGEJO_CONFIG" ]]; then
    [[ -f "$FORGEJO_CONFIG_DIR/$MANAGED_MARKER" ]] || die "$FORGEJO_CONFIG is unmanaged; refusing to adopt it."
    [[ -n "$record" ]] || die "Local Forgejo credentials exist but the remote runner is missing. Run matching --cleanup first."
    systemctl enable --now forgejo-runner.service
    write_state
    log "🐈 $RUNNER_NAME is already configured in Forgejo; no duplicate identity was created."
    return
  fi
  if [[ -n "$record" ]]; then
    [[ "$REPLACE_OFFLINE_RUNNER" == 1 ]] || die "$RUNNER_NAME already exists in Forgejo. Remove it or set REPLACE_OFFLINE_RUNNER=1 after verifying it is stale."
    id="$(jq -er '.id' <<<"$record")"
    forgejo_api DELETE "$endpoint/$id" >/dev/null
  fi

  if [[ -e /usr/local/bin/forgejo-runner && ! -f "$FORGEJO_CONFIG_DIR/$MANAGED_MARKER" ]]; then
    die "/usr/local/bin/forgejo-runner already exists and is unmanaged; refusing to overwrite it."
  fi
  runner_home="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
  runner_group="$(id -gn "$RUNNER_USER")"
  [[ -n "$runner_home" && -d "$runner_home" ]] || die "Cannot determine the home directory for $RUNNER_USER."
  install -d -o root -g "$runner_group" -m 0750 "$FORGEJO_CONFIG_DIR"
  install -o root -g root -m 0444 /dev/null "$FORGEJO_CONFIG_DIR/$MANAGED_MARKER"
  install_forgejo_binary
  identity="$(forgejo_api POST "$endpoint" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg name "$RUNNER_NAME" '{name:$name,description:"Direct Ubuntu host managed by runner-fleet-config",ephemeral:false}')")"
  uuid="$(jq -er '.uuid' <<<"$identity")"; token="$(jq -er '.token' <<<"$identity")"
  jq -n --arg url "$FORGEJO_URL" --arg uuid "$uuid" --arg token "$token" --arg labels "$FORGEJO_LABELS" '{
    log:{level:"info"}, runner:{capacity:1,labels:($labels|split(","))},
    container:{docker_host:"unix:///var/run/docker.sock"},
    server:{connections:{forgejo:{url:$url,uuid:$uuid,token:$token}}}
  }' >"$FORGEJO_CONFIG"
  chmod 0640 "$FORGEJO_CONFIG"; chown root:"$runner_group" "$FORGEJO_CONFIG"
  uuid=""; token=""; identity=""

  cat >/etc/systemd/system/forgejo-runner.service <<EOF
[Unit]
Description=Forgejo Actions Runner ($RUNNER_NAME)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
User=$RUNNER_USER
Group=$runner_group
SupplementaryGroups=docker
WorkingDirectory=$runner_home
ExecStart=/usr/local/bin/forgejo-runner daemon -c $FORGEJO_CONFIG
Restart=always
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now forgejo-runner.service
  sleep 2
  systemctl is-active --quiet forgejo-runner.service || die "Forgejo runner service failed to start."
  write_state
  log "🐈✨ $RUNNER_NAME joined Forgejo at $FORGEJO_URL ($FORGEJO_SCOPE)."
}

managed_provider() {
  [[ -s "$STATE_FILE" ]] && jq -er '.provider' "$STATE_FILE" || printf '%s\n' "$RUNNER_PROVIDER"
}

show_status() {
  local provider service
  provider="$(managed_provider)"
  printf 'Managed state: %s\n' "$([[ -s "$STATE_FILE" ]] && printf present || printf absent)"
  printf 'Provider: %s\n' "$provider"
  if [[ "$provider" == github && -s "$GITHUB_DIR/.service" ]]; then
    service="$(cat "$GITHUB_DIR/.service")"
    systemctl --no-pager --full status "$service" || true
  elif [[ "$provider" == forgejo ]]; then
    systemctl --no-pager --full status forgejo-runner.service || true
  else
    warn "No managed runner service was found."
  fi
}

restart_runner() {
  [[ -s "$STATE_FILE" ]] || die "No managed potato runner state exists."
  local provider service
  provider="$(jq -er '.provider' "$STATE_FILE")"
  if [[ "$provider" == github ]]; then
    service="$(cat "$GITHUB_DIR/.service" 2>/dev/null || true)"
    [[ -n "$service" ]] || die "GitHub runner service metadata is missing."
  else
    service=forgejo-runner.service
  fi
  systemctl restart "$service"
  systemctl is-active --quiet "$service" || die "$service did not become active."
  log "♻️  $service restarted."
}

cleanup_runner() {
  [[ -s "$STATE_FILE" ]] || die "No managed potato runner state exists; refusing broad cleanup."
  local provider name org url scope record id endpoint service
  provider="$(jq -er '.provider' "$STATE_FILE")"; name="$(jq -er '.name' "$STATE_FILE")"
  [[ "$provider" == "$RUNNER_PROVIDER" && "$name" == "$RUNNER_NAME" ]] \
    || die "Use the same RUNNER_PROVIDER and RUNNER_NAME that created this runner."
  if [[ "$provider" == github ]]; then
    [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required to remove the remote GitHub registration."
    org="$(jq -er '.org' "$STATE_FILE")"; [[ "$ORG" == "$org" ]] || die "ORG differs from managed state ($org)."
    record="$(github_runner_record)"; id="$(jq -r '.id // empty' <<<"${record:-{}}")"
    service="$(cat "$GITHUB_DIR/.service" 2>/dev/null || true)"
    [[ -z "$service" ]] || systemctl stop "$service" || true
    [[ -z "$id" ]] || github_api DELETE "/orgs/$ORG/actions/runners/$id" >/dev/null
    if [[ -f "$GITHUB_DIR/$MANAGED_MARKER" ]]; then
      [[ -z "$service" ]] || (cd "$GITHUB_DIR" && ./svc.sh uninstall) || true
      rm -rf -- "$GITHUB_DIR"
    fi
  else
    [[ -n "$FORGEJO_API_TOKEN" ]] || die "FORGEJO_API_TOKEN is required to remove the remote Forgejo registration."
    url="$(jq -er '.forgejo_url' "$STATE_FILE")"; scope="$(jq -er '.forgejo_scope' "$STATE_FILE")"
    [[ "$FORGEJO_URL" == "$url" && "$FORGEJO_SCOPE" == "$scope" ]] \
      || die "Forgejo URL/scope differs from managed state."
    record="$(forgejo_runner_record)"; id="$(jq -r '.id // empty' <<<"${record:-{}}")"; endpoint="$(forgejo_runner_endpoint)"
    systemctl disable --now forgejo-runner.service 2>/dev/null || true
    [[ -z "$id" ]] || forgejo_api DELETE "$endpoint/$id" >/dev/null
    if [[ -f "$FORGEJO_CONFIG_DIR/$MANAGED_MARKER" ]]; then
      rm -rf -- "$FORGEJO_CONFIG_DIR"
      rm -f -- /etc/systemd/system/forgejo-runner.service /usr/local/bin/forgejo-runner
      systemctl daemon-reload
    fi
  fi
  rm -f -- "/etc/sudoers.d/90-${RUNNER_USER}-actions-runner" "$STATE_FILE" "$NAME_FILE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  log "🧹 Managed runner '$name' and its remote registration were removed. Docker and the runner user were retained."
}

main() {
  case "$MODE" in
    status) show_status; return ;;
    restart) restart_runner; return ;;
    cleanup) cleanup_runner; return ;;
  esac
  TEMP_DIR="$(mktemp -d -t potato-runner.XXXXXXXX)"; chmod 700 "$TEMP_DIR"
  preflight
  host_apt ca-certificates curl git gnupg jq sudo tar gzip
  ensure_optional_swap
  ensure_runner_user
  assert_state_matches
  if [[ "$RUNNER_PROVIDER" == github ]]; then
    install_github_runner
  else
    install_forgejo_runner
  fi
  show_status
}

main "$@"
