#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

# Reconcile provisioner-owned runners whose remote registration was lost.
#
# GitHub deletes self-hosted runner registrations that have not connected for
# more than 14 days. The VM then keeps a stale /opt/actions-runner/.runner
# while the provisioner refuses to touch it ("configured locally but missing
# from GitHub"). This script removes the stale credentials and registers the
# runner again under its original name, group and labels. Forgejo runners get
# a fresh remote identity written into their existing runner-config.yml.
# Healthy runners are only restarted, never re-registered.

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
      GH_TOKEN|ORG|RUNNER_GROUP|RUNNER_PREFIX|RUNNER_VERSION|RUNNER_LABELS|\
      RUNNER_PROVIDER|RUNNER_NAME|RUNNER_USER|GITHUB_LABELS|REPLACE_OFFLINE_RUNNER|\
      FORGEJO_URL|FORGEJO_TOKEN|FORGEJO_API_TOKEN|FORGEJO_SCOPE|FORGEJO_LABELS)
        if [[ ! -v "$key" ]]; then
          printf -v "$key" '%s' "$value"
          export "${key?}"
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
RUNNER_LABELS="${RUNNER_LABELS:-seele,selee-trotter,docker}"
GITHUB_LABELS="${GITHUB_LABELS:-cakecat,potato,mikrus}"
RUNNER_NAME="${RUNNER_NAME:-}"
RUNNER_USER="${RUNNER_USER:-runner}"
FORGEJO_URL="${FORGEJO_URL:-}"
FORGEJO_API_TOKEN="${FORGEJO_API_TOKEN:-${FORGEJO_TOKEN:-}}"
FORGEJO_SCOPE="${FORGEJO_SCOPE:-global}"
FORGEJO_LABELS="${FORGEJO_LABELS:-docker:docker://node:20-bookworm}"
REPLACE_OFFLINE_RUNNER="${REPLACE_OFFLINE_RUNNER:-0}"

readonly POTATO_STATE=/etc/runner-fleet-config/potato-runner.json
readonly POTATO_GITHUB_DIR=/opt/actions-runner
readonly POTATO_FORGEJO_CONFIG=/etc/forgejo-runner/runner-config.yml
readonly MANAGED_MARKER=.runner-fleet-managed

DRY_RUN=0
REPLACE_REMOTE=0
ONLY_VM=""
DO_INCUS=1
DO_LOCAL=1
INCUS_REQUESTED=0
declare -a FAILURES=()
GH_CHECKED=0
FJ_CHECKED=0
TEMP_DIR=""

log()  { printf '\n🩹 [%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n⚠️  WARNING: %s\n' "$*" >&2; }
die()  { printf '\n❌ ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '    %s\n' "$*"; }

cleanup() {
  [[ -z "${TEMP_DIR:-}" || ! -d "$TEMP_DIR" ]] || rm -rf -- "$TEMP_DIR"
}
trap cleanup EXIT
trap 'die "Command failed at line $LINENO: $BASH_COMMAND"' ERR

usage() {
  cat <<'EOF'
Usage:
  sudo ./reregister-runners.sh --dry-run
  sudo ./reregister-runners.sh
  sudo ./reregister-runners.sh --vm selee-trotter-01
  sudo ./reregister-runners.sh --local
  sudo ./reregister-runners.sh --replace-remote

Options:
  --dry-run         Report local/remote registration state; change nothing.
  --vm NAME         Repair only this provisioner-owned runner VM.
  --incus           Repair Incus runner VMs only.
  --local|--potato  Repair the managed direct (potato) runner only.
  --replace-remote  Also replace a remote registration that still exists while
                    local credentials are gone. Without it such a runner is
                    reported and skipped instead of deleted remotely.
  --help            Show this help.

Reconciliation per runner:
  local credentials + remote present   -> ensure the service runs; nothing else.
  local credentials + remote absent    -> wipe stale credentials, re-register.
  no credentials + remote offline      -> re-register with --replace.
  no credentials + remote absent       -> fresh registration.
  no credentials + remote exists       -> skipped unless --replace-remote.

The script reads the same .env as the provisioners. GitHub repairs need
GH_TOKEN and ORG (RUNNER_GROUP/RUNNER_LABELS are reused when no remote record
is left to copy them from). Forgejo repairs need FORGEJO_URL,
FORGEJO_API_TOKEN and FORGEJO_SCOPE. REPLACE_OFFLINE_RUNNER=1 in .env is
equivalent to --replace-remote.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --replace-remote) REPLACE_REMOTE=1; shift ;;
    --incus) DO_LOCAL=0; INCUS_REQUESTED=1; shift ;;
    --local|--potato) DO_INCUS=0; shift ;;
    --vm)
      (($# >= 2)) || die "--vm requires an instance name."
      ONLY_VM="$2"; DO_LOCAL=0; INCUS_REQUESTED=1; shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1 (use --help)." ;;
  esac
done

[[ "$REPLACE_OFFLINE_RUNNER" == 1 ]] && REPLACE_REMOTE=1
[[ -z "$ONLY_VM" || $DO_INCUS == 1 ]] || die "--vm cannot be combined with --local/--potato."
[[ $EUID -eq 0 ]] || die "Run this script as root (sudo)."

plan() { # describe an action without doing it
  if [[ "$DRY_RUN" == 1 ]]; then note "[dry-run] $*"; return 0; fi
  return 1
}

# ---------------------------------------------------------------- GitHub API

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

need_github() {
  ((GH_CHECKED == 0)) || return 0
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required to repair GitHub runners."
  github_api GET "/orgs/$ORG/actions/runners?per_page=1" >/dev/null \
    || die "GH_TOKEN cannot administer self-hosted runners in $ORG."
  GH_CHECKED=1
}

github_runner_record() { # $1=name -> full runner JSON or empty
  local name="$1" page=1 response record total
  while :; do
    response="$(github_api GET "/orgs/$ORG/actions/runners?per_page=100&page=$page")"
    record="$(jq -c --arg n "$name" '.runners[] | select(.name == $n)' <<<"$response" | head -n1)"
    [[ -z "$record" ]] || { printf '%s\n' "$record"; return 0; }
    total="$(jq -r '.total_count' <<<"$response")"
    ((page * 100 >= total)) && break
    ((page++))
  done
}

github_registration_token() {
  github_api POST "/orgs/$ORG/actions/runners/registration-token" | jq -er '.token'
}

github_delete_runner() {
  github_api DELETE "/orgs/$ORG/actions/runners/$1" >/dev/null
}

# Custom labels only: GitHub auto-adds self-hosted, the OS and the arch.
github_custom_labels() {
  jq -r '[.labels[]?.name
    | select(ascii_downcase as $l
      | (["self-hosted","linux","windows","macos","x64","x86","arm","arm64"] | index($l)) == null)]
    | join(",")' <<<"$1"
}

# ---------------------------------------------------------------- Forgejo API

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

need_forgejo() {
  ((FJ_CHECKED == 0)) || return 0
  [[ -n "$FORGEJO_URL" && -n "$FORGEJO_API_TOKEN" ]] \
    || die "FORGEJO_URL and FORGEJO_API_TOKEN are required to repair Forgejo runners."
  forgejo_api GET "$(forgejo_runner_endpoint)" >/dev/null \
    || die "Forgejo token cannot administer $FORGEJO_SCOPE runners at $FORGEJO_URL."
  FJ_CHECKED=1
}

forgejo_runner_record() { # $1=name -> full runner JSON or empty
  forgejo_api GET "$(forgejo_runner_endpoint)" \
    | jq -c --arg n "$1" '(.runners? // . // [])[] | select(.name == $n)' | head -n1
}

forgejo_new_identity() { # $1=name, $2=description -> {uuid, token, id}
  forgejo_api POST "$(forgejo_runner_endpoint)" -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg name "$1" --arg d "$2" '{name:$name, description:$d, ephemeral:false}')"
}

forgejo_runner_config() { # $1=uuid $2=token $3=labels -> runner-config.yml (JSON)
  jq -n --arg url "$FORGEJO_URL" --arg uuid "$1" --arg token "$2" --arg labels "$3" '{
    log: {level: "info"},
    runner: {capacity: 1, labels: ($labels | split(","))},
    container: {docker_host: "unix:///var/run/docker.sock"},
    server: {connections: {forgejo: {url: $url, uuid: $uuid, token: $token}}}
  }'
}

# ------------------------------------------------------- Incus VM management

runner_role() {
  incus config get "$1" user.seele.role 2>/dev/null || true
}

discover_runner_vms() { # prints "name<TAB>role" for owned runner VMs
  local inst role
  while IFS= read -r inst; do
    [[ -n "$inst" ]] || continue
    role="$(runner_role "$inst")"
    case "$role" in
      runner-v1|github-runner-v1|forgejo-runner-v1) printf '%s\t%s\n' "$inst" "$role" ;;
    esac
  done < <(incus list --format csv -c n 2>/dev/null || true)
}

wait_for_agent() {
  local vm="$1" tries=90 state
  until incus exec "$vm" -- true >/dev/null 2>&1; do
    state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
    if [[ "$state" != RUNNING ]]; then
      warn "$vm stopped while waiting for its Incus agent (state: ${state:-unknown})."
      return 1
    fi
    ((tries-=1))
    if ((tries <= 0)); then
      warn "$vm agent did not become available within 180 seconds."
      return 1
    fi
    sleep 2
  done
}

ensure_vm_running() {
  local vm="$1" state
  state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
  if [[ "$state" != RUNNING ]]; then
    if plan "would start/recover VM '$vm' (state: ${state:-unknown})."; then return 2; fi
    if [[ "$state" == ERROR ]]; then
      warn "$vm is in Incus ERROR state; force-stopping to clear stale QEMU state."
      incus stop "$vm" --force >/dev/null 2>&1 || true
    fi
    incus start "$vm" >/dev/null 2>&1 || true
  fi
  wait_for_agent "$vm"
}

vm_has_github_config() {
  incus exec "$1" -- test -e /opt/actions-runner/.runner 2>/dev/null
}

vm_github_runner_field() { # $1=vm $2=jq filter on .runner
  incus exec "$1" -- sh -c "jq -r '$2' /opt/actions-runner/.runner" 2>/dev/null || true
}

vm_ensure_github_service() { # $1=vm; repair + start svc.sh service; returns 0 ok
  local vm="$1" service
  if ! incus exec "$vm" -- test -s /opt/actions-runner/.service; then
    incus exec "$vm" -- bash -c 'cd /opt/actions-runner && ./svc.sh install runner' >/dev/null \
      || return 1
  fi
  service="$(incus exec "$vm" -- sh -c 'cat /opt/actions-runner/.service 2>/dev/null' || true)"
  [[ -n "$service" ]] || return 1
  incus exec "$vm" -- systemctl enable --now "$service" >/dev/null 2>&1 || true
  incus exec "$vm" -- systemctl is-active --quiet "$service"
}

vm_github_reregister() { # $1=vm $2=org $3=group $4=labels $5=replace(0|1)
  local vm="$1" org="$2" group="$3" labels="$4" replace="$5" token
  token="$(github_registration_token)"
  printf '%s' "$token" >"$TEMP_DIR/registration-token"
  chmod 600 "$TEMP_DIR/registration-token"
  incus file push "$TEMP_DIR/registration-token" "$vm/run/github-runner-registration-token"
  incus exec "$vm" -- chmod 600 /run/github-runner-registration-token
  : >"$TEMP_DIR/registration-token"
  cat >"$TEMP_DIR/reregister.sh" <<'GUEST'
#!/usr/bin/env bash
set -Eeuo pipefail
ORG="$1" GROUP="$2" NAME="$3" LABELS="$4" REPLACE="$5"
cd /opt/actions-runner
if [[ -s .service ]]; then
  systemctl disable --now "$(cat .service)" 2>/dev/null || true
fi
./svc.sh uninstall >/dev/null 2>&1 || true
rm -f .runner .credentials .credentials_rsaparams .credentials_migrated \
      .service .svcsh .env .path runsvc.sh
token="$(</run/github-runner-registration-token)"
rm -f /run/github-runner-registration-token
args=(--unattended --url "https://github.com/$ORG" --token "$token" --name "$NAME" \
      --runnergroup "$GROUP" --work _work --labels "$LABELS")
[[ "$REPLACE" != 1 ]] || args+=(--replace)
runuser -u runner -- ./config.sh "${args[@]}"
./svc.sh install runner
./svc.sh start
systemctl is-active --quiet "$(cat .service)"
GUEST
  incus file push "$TEMP_DIR/reregister.sh" "$vm/root/reregister.sh"
  if ! incus exec "$vm" -- bash /root/reregister.sh "$org" "$group" "$vm" "$labels" "$replace"; then
    incus exec "$vm" -- rm -f /root/reregister.sh /run/github-runner-registration-token || true
    return 1
  fi
  incus exec "$vm" -- rm -f /root/reregister.sh
}

# Repair one GitHub Incus runner VM. Appends to FAILURES on unrecoverable error.
repair_github_vm() {
  local vm="$1" record status local_cfg org group labels replace rc
  log "🐗 Checking GitHub runner VM '$vm'"
  ensure_vm_running "$vm" && rc=0 || rc=$?
  case "$rc" in
    0) : ;;
    2) note "VM start planned; re-run without --dry-run to evaluate registration."; return ;;
    *) FAILURES+=("$vm: VM cannot be reached"); return ;;
  esac

  local_cfg=0; vm_has_github_config "$vm" && local_cfg=1
  if ! incus exec "$vm" -- test -x /opt/actions-runner/config.sh; then
    if ((local_cfg == 1)); then
      warn "$vm has credentials but no runner software; wipe it with the provisioner --cleanup or reinstall."
      FAILURES+=("$vm: runner software missing")
    else
      note "$vm has no runner software; run provision-seele-runners.sh for a full install."
    fi
    return
  fi

  record="$(github_runner_record "$vm")"
  status="$(jq -r '.status // empty' <<<"${record:-{}}")"

  if ((local_cfg == 1)) && [[ -n "$record" ]]; then
    if plan "would ensure the runner service in '$vm' is enabled and running."; then return; fi
    if vm_ensure_github_service "$vm"; then
      note "$vm is registered ($status) and its service is active."
    else
      warn "$vm is registered but its service could not be started."
      FAILURES+=("$vm: service start failed")
    fi
    return
  fi

  org="$ORG"; group="$RUNNER_GROUP"
  if ((local_cfg == 1)); then
    local stale_url stale_group
    stale_url="$(vm_github_runner_field "$vm" '.gitHubUrl // empty')"
    stale_group="$(vm_github_runner_field "$vm" '.poolName // empty')"
    [[ -z "$stale_url" ]] || org="${stale_url##*/}"
    [[ -z "$stale_group" ]] || group="$stale_group"
    [[ "$org" == "$ORG" ]] || warn "$vm was registered under org '$org', which differs from ORG=$ORG."
  fi

  labels="$(github_custom_labels "${record:-}")"
  if [[ -z "$labels" ]]; then
    labels="$RUNNER_LABELS"
    note "No remote labels to reuse; applying RUNNER_LABELS=$labels."
  else
    note "Reusing labels from the existing remote record: $labels"
  fi

  replace=0
  if ((local_cfg == 1)); then
    note "$vm is configured locally but absent from GitHub (stale credentials — likely the 14-day auto-removal)."
    if plan "would wipe stale credentials and re-register '$vm' in org $org / group $group."; then return; fi
  else
    case "$status" in
      "" )
        note "$vm has no local credentials and no remote registration."
        if plan "would register '$vm' as a fresh runner in org $org / group $group."; then return; fi
        ;;
      offline )
        note "$vm exists on GitHub as offline but has no local credentials."
        if plan "would re-register '$vm' over the offline remote entry."; then return; fi
        replace=1
        ;;
      * )
        if ((REPLACE_REMOTE == 1)); then
          if plan "would delete the $status remote '$vm' and re-register."; then return; fi
          if ! github_delete_runner "$(jq -er '.id' <<<"$record")"; then
            warn "Could not delete the $status remote registration for '$vm'."
            FAILURES+=("$vm: remote delete failed")
            return
          fi
          note "Deleted $status remote registration for '$vm'."
        else
          warn "$vm exists on GitHub ($status) but has no local credentials. Investigate or rerun with --replace-remote."
          FAILURES+=("$vm: remote registration exists without local credentials")
          return
        fi
        ;;
    esac
  fi

  if vm_github_reregister "$vm" "$org" "$group" "$labels" "$replace"; then
    log "✅ $vm re-registered in $org / $group and its service is active."
  else
    warn "$vm re-registration failed; the VM was kept for inspection."
    FAILURES+=("$vm: re-registration failed")
  fi
}

# Repair one Forgejo Incus runner VM.
repair_forgejo_vm() {
  local vm="$1" record local_cfg identity uuid token labels id rc
  log "🐧 Checking Forgejo runner VM '$vm'"
  ensure_vm_running "$vm" && rc=0 || rc=$?
  case "$rc" in
    0) : ;;
    2) note "VM start planned; re-run without --dry-run to evaluate registration."; return ;;
    *) FAILURES+=("$vm: VM cannot be reached"); return ;;
  esac

  local_cfg=0; incus exec "$vm" -- test -s /home/runner/runner-config.yml 2>/dev/null && local_cfg=1
  if ! incus exec "$vm" -- test -x /usr/local/bin/forgejo-runner; then
    if ((local_cfg == 1)); then
      warn "$vm has Forgejo credentials but no runner binary; reinstall it with provision-seele-runners.sh."
      FAILURES+=("$vm: forgejo-runner binary missing")
    else
      note "$vm has no Forgejo runner installed; run provision-seele-runners.sh for a full install."
    fi
    return
  fi

  # Forgejo markers pin the URL/scope this identity was created under.
  local vm_url vm_scope
  vm_url="$(incus config get "$vm" user.seele.forgejo_url 2>/dev/null || true)"
  vm_scope="$(incus config get "$vm" user.seele.forgejo_scope 2>/dev/null || true)"
  if [[ -n "$vm_url" && "$vm_url" != "$FORGEJO_URL" ]] || [[ -n "$vm_scope" && "$vm_scope" != "$FORGEJO_SCOPE" ]]; then
    warn "$vm belongs to $vm_url ($vm_scope); current FORGEJO_URL/FORGEJO_SCOPE differ. Skipping."
    return
  fi

  record="$(forgejo_runner_record "$vm")"

  if ((local_cfg == 1)) && [[ -n "$record" ]]; then
    if plan "would ensure forgejo-runner.service in '$vm' is enabled and running."; then return; fi
    if incus exec "$vm" -- systemctl enable --now forgejo-runner.service >/dev/null 2>&1 \
      && incus exec "$vm" -- systemctl is-active --quiet forgejo-runner.service; then
      note "$vm is registered and forgejo-runner.service is active."
    else
      warn "$vm is registered but forgejo-runner.service could not be started."
      FAILURES+=("$vm: forgejo-runner.service start failed")
    fi
    return
  fi

  if ((local_cfg == 0)) && [[ -n "$record" ]]; then
    if ((REPLACE_REMOTE == 1)); then
      id="$(jq -er '.id' <<<"$record")"
      if plan "would delete remote Forgejo runner '$vm' (id $id) and re-register."; then return; fi
      if ! forgejo_api DELETE "$(forgejo_runner_endpoint)/$id" >/dev/null; then
        warn "Could not delete the stale remote Forgejo runner '$vm' (id $id)."
        FAILURES+=("$vm: remote delete failed")
        return
      fi
      note "Deleted stale remote Forgejo runner '$vm' (id $id)."
      record=""
    else
      warn "$vm exists in Forgejo but has no local credentials. Investigate or rerun with --replace-remote."
      FAILURES+=("$vm: remote Forgejo registration exists without local credentials")
      return
    fi
  fi

  # Keep the labels the runner already used; fall back to FORGEJO_LABELS.
  labels="$(incus exec "$vm" -- jq -r '.runner.labels | join(",")' /home/runner/runner-config.yml 2>/dev/null || true)"
  [[ -n "$labels" ]] || labels="$FORGEJO_LABELS"

  if plan "would create a fresh Forgejo identity for '$vm' (labels: $labels) and rewrite runner-config.yml."; then return; fi
  if ! identity="$(forgejo_new_identity "$vm" "Incus VM re-registered by reregister-runners.sh")"; then
    warn "Forgejo refused a new identity for '$vm'."
    FAILURES+=("$vm: Forgejo identity creation failed")
    return
  fi
  uuid="$(jq -er '.uuid' <<<"$identity")"; token="$(jq -er '.token' <<<"$identity")"
  forgejo_runner_config "$uuid" "$token" "$labels" >"$TEMP_DIR/forgejo-runner-config.json"
  chmod 600 "$TEMP_DIR/forgejo-runner-config.json"
  incus file push "$TEMP_DIR/forgejo-runner-config.json" "$vm/run/forgejo-runner-config.json"
  incus exec "$vm" -- install -o runner -g runner -m 0600 /run/forgejo-runner-config.json /home/runner/runner-config.yml
  incus exec "$vm" -- rm -f /run/forgejo-runner-config.json
  : >"$TEMP_DIR/forgejo-runner-config.json"
  identity=""; uuid=""; token=""
  # restart, not enable --now: a daemon already running with dead credentials
  # must pick up the rewritten runner-config.yml.
  incus exec "$vm" -- systemctl enable forgejo-runner.service >/dev/null 2>&1 || true
  if incus exec "$vm" -- systemctl restart forgejo-runner.service >/dev/null 2>&1 \
    && sleep 2 && incus exec "$vm" -- systemctl is-active --quiet forgejo-runner.service; then
    log "✅ $vm re-registered at $FORGEJO_URL ($FORGEJO_SCOPE)."
  else
    warn "$vm got a new identity but forgejo-runner.service did not become active."
    FAILURES+=("$vm: forgejo-runner.service failed after re-registration")
  fi
}

# --------------------------------------------------------------- Local potato

repair_potato() {
  local provider name user org group url scope record status service labels replace
  if [[ ! -s "$POTATO_STATE" ]]; then
    if [[ -f "$POTATO_GITHUB_DIR/$MANAGED_MARKER" || -f /etc/forgejo-runner/$MANAGED_MARKER ]]; then
      warn "Managed runner files exist but $POTATO_STATE is missing; refusing to guess."
      FAILURES+=("local: state file missing")
    else
      note "No managed potato runner on this host."
    fi
    return
  fi
  provider="$(jq -er '.provider' "$POTATO_STATE")"
  name="$(jq -er '.name' "$POTATO_STATE")"
  user="$(jq -r '.user // "runner"' "$POTATO_STATE")"

  if [[ "$provider" == github ]]; then
    need_github
    org="$(jq -r '.org // empty' "$POTATO_STATE")"; [[ -n "$org" ]] || org="$ORG"
    group="$(jq -r '.group // empty' "$POTATO_STATE")"; [[ -n "$group" ]] || group="$RUNNER_GROUP"
    [[ "$org" == "$ORG" ]] || die "Potato runner '$name' belongs to org '$org'; use the matching ORG."
    log "🥔 Checking potato GitHub runner '$name'"

    local local_cfg=0
    [[ -f "$POTATO_GITHUB_DIR/.runner" ]] && local_cfg=1
    if ((local_cfg == 1)) && [[ ! -f "$POTATO_GITHUB_DIR/$MANAGED_MARKER" ]]; then
      warn "$POTATO_GITHUB_DIR contains an unmanaged runner; refusing to adopt it."
      FAILURES+=("$name: unmanaged runner directory")
      return
    fi
    if [[ ! -x "$POTATO_GITHUB_DIR/config.sh" ]]; then
      warn "$POTATO_GITHUB_DIR/config.sh is missing; run provision-potato-runner.sh for a full install."
      FAILURES+=("$name: runner software missing")
      return
    fi

    record="$(github_runner_record "$name")"
    status="$(jq -r '.status // empty' <<<"${record:-{}}")"

    if ((local_cfg == 1)) && [[ -n "$record" ]]; then
      if plan "would ensure the runner service for '$name' is enabled and running."; then return; fi
      service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
      if [[ -z "$service" ]]; then
        (cd "$POTATO_GITHUB_DIR" && ./svc.sh install "$user") >/dev/null || true
        service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
      fi
      if [[ -z "$service" ]]; then
        warn "$name has no service metadata and svc.sh could not install one."
        FAILURES+=("$name: service install failed")
        return
      fi
      systemctl enable --now "$service" >/dev/null 2>&1 || true
      if systemctl is-active --quiet "$service"; then
        note "$name is registered ($status) and $service is active."
      else
        warn "$name is registered but $service could not be started."
        FAILURES+=("$name: service start failed")
      fi
      return
    fi

    labels="$(github_custom_labels "${record:-}")"
    [[ -n "$labels" ]] || labels="$GITHUB_LABELS"

    replace=0
    if ((local_cfg == 1)); then
      note "$name is configured locally but absent from GitHub (stale credentials — likely the 14-day auto-removal)."
      if plan "would wipe stale credentials and re-register '$name' in org $org / group $group (labels: $labels)."; then return; fi
    else
      case "$status" in
        "" )
          note "$name has no local credentials and no remote registration."
          if plan "would register '$name' as a fresh runner (labels: $labels)."; then return; fi
          ;;
        offline )
          note "$name exists on GitHub as offline but has no local credentials."
          if plan "would re-register '$name' over the offline remote entry (labels: $labels)."; then return; fi
          replace=1
          ;;
        * )
          if ((REPLACE_REMOTE == 1)); then
            if plan "would delete the $status remote '$name' and re-register."; then return; fi
            if ! github_delete_runner "$(jq -er '.id' <<<"$record")"; then
              warn "Could not delete the $status remote registration for '$name'."
              FAILURES+=("$name: remote delete failed")
              return
            fi
            note "Deleted $status remote registration for '$name'."
          else
            warn "$name exists on GitHub ($status) but has no local credentials. Investigate or rerun with --replace-remote."
            FAILURES+=("$name: remote registration exists without local credentials")
            return
          fi
          ;;
      esac
    fi

    service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
    [[ -z "$service" ]] || { systemctl disable --now "$service" 2>/dev/null || true; }
    (cd "$POTATO_GITHUB_DIR" && ./svc.sh uninstall) >/dev/null 2>&1 || true
    rm -f -- "$POTATO_GITHUB_DIR"/{.runner,.credentials,.credentials_rsaparams,.credentials_migrated,.service,.svcsh,.env,.path,runsvc.sh}

    local token
    token="$(github_registration_token)"
    local -a args=(--unattended --url "https://github.com/$org" --token "$token" --name "$name" \
      --runnergroup "$group" --work _work --labels "$labels")
    ((replace == 0)) || args+=(--replace)
    if ! (cd "$POTATO_GITHUB_DIR" && runuser -u "$user" -- ./config.sh "${args[@]}"); then
      warn "$name re-registration failed."
      FAILURES+=("$name: re-registration failed")
      return
    fi
    token=""
    if ! (cd "$POTATO_GITHUB_DIR" && ./svc.sh install "$user" && ./svc.sh start) >/dev/null; then
      warn "$name re-registered but its service could not be installed or started."
      FAILURES+=("$name: service failed after re-registration")
      return
    fi
    service="$(cat "$POTATO_GITHUB_DIR/.service")"
    if systemctl is-active --quiet "$service"; then
      log "✅ $name re-registered in $org / $group and $service is active."
    else
      warn "$name re-registered but $service did not become active."
      FAILURES+=("$name: service failed after re-registration")
    fi
    return
  fi

  # Forgejo potato
  need_forgejo
  url="$(jq -r '.forgejo_url // empty' "$POTATO_STATE")"; scope="$(jq -r '.forgejo_scope // empty' "$POTATO_STATE")"
  [[ -z "$url" || "$url" == "$FORGEJO_URL" ]] || die "Potato runner '$name' belongs to $url; use the matching FORGEJO_URL."
  [[ -z "$scope" || "$scope" == "$FORGEJO_SCOPE" ]] || die "Potato runner '$name' uses scope '$scope'; use the matching FORGEJO_SCOPE."
  log "🥔 Checking potato Forgejo runner '$name'"

  if [[ ! -x /usr/local/bin/forgejo-runner ]]; then
    warn "forgejo-runner binary is missing; run provision-potato-runner.sh for a full install."
    FAILURES+=("$name: forgejo-runner binary missing")
    return
  fi
  if [[ -s "$POTATO_FORGEJO_CONFIG" && ! -f /etc/forgejo-runner/$MANAGED_MARKER ]]; then
    warn "$POTATO_FORGEJO_CONFIG is unmanaged; refusing to adopt it."
    FAILURES+=("$name: unmanaged Forgejo config")
    return
  fi

  record="$(forgejo_runner_record "$name")"
  local local_cfg=0
  [[ -s "$POTATO_FORGEJO_CONFIG" ]] && local_cfg=1

  if ((local_cfg == 1)) && [[ -n "$record" ]]; then
    if plan "would ensure forgejo-runner.service is enabled and running."; then return; fi
    systemctl enable --now forgejo-runner.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet forgejo-runner.service; then
      note "$name is registered and forgejo-runner.service is active."
    else
      warn "$name is registered but forgejo-runner.service could not be started."
      FAILURES+=("$name: forgejo-runner.service start failed")
    fi
    return
  fi

  if ((local_cfg == 0)) && [[ -n "$record" ]]; then
    if ((REPLACE_REMOTE == 1)); then
      local id
      id="$(jq -er '.id' <<<"$record")"
      if plan "would delete remote Forgejo runner '$name' (id $id) and re-register."; then return; fi
      if ! forgejo_api DELETE "$(forgejo_runner_endpoint)/$id" >/dev/null; then
        warn "Could not delete the stale remote Forgejo runner '$name' (id $id)."
        FAILURES+=("$name: remote delete failed")
        return
      fi
      note "Deleted stale remote Forgejo runner '$name' (id $id)."
      record=""
    else
      warn "$name exists in Forgejo but has no local credentials. Investigate or rerun with --replace-remote."
      FAILURES+=("$name: remote Forgejo registration exists without local credentials")
      return
    fi
  fi

  labels="$(jq -r '.runner.labels | join(",")' "$POTATO_FORGEJO_CONFIG" 2>/dev/null || true)"
  [[ -n "$labels" ]] || labels="$FORGEJO_LABELS"
  if plan "would create a fresh Forgejo identity for '$name' (labels: $labels) and rewrite $POTATO_FORGEJO_CONFIG."; then return; fi

  local identity uuid token runner_group
  if ! identity="$(forgejo_new_identity "$name" "Direct Ubuntu host re-registered by reregister-runners.sh")"; then
    warn "Forgejo refused a new identity for '$name'."
    FAILURES+=("$name: Forgejo identity creation failed")
    return
  fi
  uuid="$(jq -er '.uuid' <<<"$identity")"; token="$(jq -er '.token' <<<"$identity")"
  runner_group="$(id -gn "$user")"
  forgejo_runner_config "$uuid" "$token" "$labels" >"$POTATO_FORGEJO_CONFIG"
  chmod 0640 "$POTATO_FORGEJO_CONFIG"; chown root:"$runner_group" "$POTATO_FORGEJO_CONFIG"
  identity=""; uuid=""; token=""

  if [[ ! -f /etc/systemd/system/forgejo-runner.service ]]; then
    local runner_home
    runner_home="$(getent passwd "$user" | cut -d: -f6)"
    cat >/etc/systemd/system/forgejo-runner.service <<EOF
[Unit]
Description=Forgejo Actions Runner ($name)
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=simple
User=$user
Group=$runner_group
SupplementaryGroups=docker
WorkingDirectory=$runner_home
ExecStart=/usr/local/bin/forgejo-runner daemon -c $POTATO_FORGEJO_CONFIG
Restart=always
RestartSec=5s
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  # restart, not enable --now: a daemon already running with dead credentials
  # must pick up the rewritten runner-config.yml.
  systemctl enable forgejo-runner.service >/dev/null 2>&1 || true
  systemctl restart forgejo-runner.service >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet forgejo-runner.service; then
    log "✅ $name re-registered at $FORGEJO_URL ($FORGEJO_SCOPE)."
  else
    warn "$name got a new identity but forgejo-runner.service did not become active."
    FAILURES+=("$name: forgejo-runner.service failed after re-registration")
  fi
}

# ------------------------------------------------------------------------ main

main() {
  TEMP_DIR="$(mktemp -d -t runner-reregister.XXXXXXXX)"
  chmod 700 "$TEMP_DIR"

  if ((DO_INCUS == 1)) && ! command -v incus >/dev/null 2>&1; then
    if ((INCUS_REQUESTED == 1)); then
      die "Incus is not installed on this host."
    fi
    note "Incus is not installed; skipping VM repair."
    DO_INCUS=0
  fi
  if ((DO_INCUS == 1)); then
    incus admin waitready --timeout=60
    mkdir -p /run/lock
    exec 9>/run/lock/seele-runners.lock
    flock -n 9 || die "The runner provisioner or another maintenance run is active. Stop it or wait for it to finish."

    local found=0 name role
    while IFS=$'\t' read -r name role; do
      [[ -n "$name" ]] || continue
      [[ -z "$ONLY_VM" || "$name" == "$ONLY_VM" ]] || continue
      found=1
      case "$role" in
        runner-v1|github-runner-v1) need_github; repair_github_vm "$name" ;;
        forgejo-runner-v1) need_forgejo; repair_forgejo_vm "$name" ;;
      esac
    done < <(discover_runner_vms)

    if [[ -n "$ONLY_VM" && $found == 0 ]]; then
      die "No provisioner-owned runner VM named '$ONLY_VM'."
    elif ((found == 0)); then
      note "No provisioner-owned runner VMs found."
    fi
  fi

  if ((DO_LOCAL == 1)); then
    mkdir -p /run/lock
    exec 8>/run/lock/runner-fleet-potato.lock
    flock -n 8 || die "The potato provisioner or another maintenance run is active."
    repair_potato
  fi

  if ((${#FAILURES[@]} > 0)); then
    warn "Some runners could not be repaired:"
    printf '    - %s\n' "${FAILURES[@]}" >&2
    exit 1
  fi
  ((DRY_RUN == 0)) || { log "Dry run finished; no changes were made."; return; }
  log "🦋✅ All reachable runners are registered and their services are running."
}

main "$@"
