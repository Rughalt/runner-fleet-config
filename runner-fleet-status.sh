#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only health and capacity dashboard for the runner fleet.

WATCH_SECONDS=0
SHOW_DOCKER=1
readonly POTATO_STATE=/etc/runner-fleet-config/potato-runner.json
readonly POTATO_GITHUB_DIR=/opt/actions-runner

usage() {
  cat <<'EOF'
Usage:
  sudo ./runner-fleet-status.sh
  sudo ./runner-fleet-status.sh --watch 10
  sudo ./runner-fleet-status.sh --no-docker

Options:
  --watch SECONDS  Refresh continuously (minimum 2 seconds).
  --no-docker      Skip the slower Docker disk-usage queries.
  --help           Show this help.

The script is read-only. It inspects the host, Incus runner VMs in the current
project, Incus storage pools, and a managed direct potato runner when present.
EOF
}

while (($#)); do
  case "$1" in
    --watch)
      (($# >= 2)) || { printf 'ERROR: --watch requires seconds.\n' >&2; exit 1; }
      WATCH_SECONDS="$2"; shift 2
      ;;
    --no-docker) SHOW_DOCKER=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'ERROR: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

[[ "$WATCH_SECONDS" =~ ^[0-9]+$ ]] || { printf 'ERROR: --watch must be an integer.\n' >&2; exit 1; }
((WATCH_SECONDS == 0 || WATCH_SECONDS >= 2)) || { printf 'ERROR: --watch minimum is 2 seconds.\n' >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  printf 'WARNING: not running as root; Incus or local-runner details may be unavailable.\n' >&2
fi

declare -a WARNINGS=()

human_bytes() {
  local bytes="${1:-0}"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || printf '%sB' "$bytes"
  else
    printf '%sB' "$bytes"
  fi
}

percent_warning() {
  local label="$1" percent="${2%%%}"
  [[ "$percent" =~ ^[0-9]+$ ]] || return 0
  if ((percent >= 90)); then
    WARNINGS+=("🔴 $label is ${percent}% full")
  elif ((percent >= 80)); then
    WARNINGS+=("🟠 $label is ${percent}% full")
  fi
}

print_table() {
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

docker_summary_local() {
  [[ "$SHOW_DOCKER" == 1 ]] || { printf 'skipped'; return; }
  command -v docker >/dev/null 2>&1 || { printf 'n/a'; return; }
  docker info >/dev/null 2>&1 || { printf 'unavailable'; return; }
  docker system df --format '{{.Type}}={{.Size}}/{{.Reclaimable}}' 2>/dev/null \
    | paste -sd ',' - | sed 's/,/, /g'
}

docker_summary_vm() {
  local vm="$1"
  [[ "$SHOW_DOCKER" == 1 ]] || { printf 'skipped'; return; }
  incus exec "$vm" -- sh -c '
    command -v docker >/dev/null 2>&1 || { printf n/a; exit; }
    docker system df --format "{{.Type}}={{.Size}}/{{.Reclaimable}}" 2>/dev/null \
      | paste -sd "," - | sed "s/,/, /g"
  ' 2>/dev/null || printf 'unavailable'
}

service_state_vm() {
  local vm="$1" role="$2" service=""
  case "$role" in
    runner-v1|github-runner-v1)
      service="$(incus exec "$vm" -- sh -c 'cat /opt/actions-runner/.service 2>/dev/null' 2>/dev/null || true)"
      ;;
    forgejo-runner-v1) service=forgejo-runner.service ;;
  esac
  [[ -n "$service" ]] || { printf 'missing'; return; }
  incus exec "$vm" -- systemctl is-active "$service" 2>/dev/null || true
}

expanded_limit() {
  local vm="$1" key="$2"
  incus config show "$vm" --expanded 2>/dev/null \
    | awk -v key="$key:" '$1 == key {gsub(/"/, "", $2); print $2; exit}'
}

print_host() {
  local hostname kernel cpus load uptime mem_used mem_total swap_used swap_total
  local root_size root_used root_free root_pct docker
  hostname="$(hostname -s)"; kernel="$(uname -r)"; cpus="$(nproc)"; load="$(awk '{print $1}' /proc/loadavg)"
  uptime="$(uptime -p 2>/dev/null | sed 's/^up //' || true)"
  read -r mem_total mem_used < <(free -b | awk '/^Mem:/ {print $2, $3}')
  read -r swap_total swap_used < <(free -b | awk '/^Swap:/ {print $2, $3}')
  read -r root_size root_used root_free root_pct < <(df -hP / | awk 'NR==2 {print $2,$3,$4,$5}')
  docker="$(docker_summary_local)"

  printf '🪐 HOST  %s  | kernel %s | uptime %s\n' "$hostname" "$kernel" "${uptime:-unknown}"
  printf 'CPU: %s vCPU, load(1m): %s\n' "$cpus" "$load"
  printf 'RAM: %s / %s    Swap: %s / %s\n' \
    "$(human_bytes "$mem_used")" "$(human_bytes "$mem_total")" \
    "$(human_bytes "$swap_used")" "$(human_bytes "$swap_total")"
  printf 'Root disk: %s / %s used, %s free (%s)\n' "$root_used" "$root_size" "$root_free" "$root_pct"
  printf 'Host Docker: %s\n' "${docker:-empty}"
  percent_warning "host root disk" "$root_pct"
  if ((swap_total > 0 && swap_used * 100 / swap_total >= 70)); then
    WARNINGS+=("🟠 host swap usage is $((swap_used * 100 / swap_total))%")
  fi
}

print_storage_pools() {
  command -v incus >/dev/null 2>&1 || return 0
  incus admin waitready --timeout=10 >/dev/null 2>&1 || { WARNINGS+=("🔴 Incus daemon is unavailable"); return; }
  local pool driver used total pct raw_used raw_total resources info
  local -a rows=('POOL\tDRIVER\tUSED\tTOTAL\tUSE%')
  printf '\n💽 INCUS STORAGE\n'
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue
    driver="$(incus storage show "$pool" 2>/dev/null | awk '$1=="driver:" {print $2; exit}')"
    resources="$(incus query "/1.0/storage-pools/$pool/resources" 2>/dev/null || true)"
    raw_used="$(jq -r '.space.used // .metadata.space.used // empty' <<<"$resources" 2>/dev/null || true)"
    raw_total="$(jq -r '.space.total // .metadata.space.total // empty' <<<"$resources" 2>/dev/null || true)"

    # Older Incus clients can expose the endpoint differently. `--bytes` keeps
    # this fallback independent of localized human-readable units.
    if [[ ! "$raw_used" =~ ^[0-9]+$ || ! "$raw_total" =~ ^[1-9][0-9]*$ ]]; then
      info="$(incus storage info "$pool" --bytes 2>/dev/null || true)"
      raw_used="$(awk -F: 'tolower($1) ~ /space used/ {gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$info")"
      raw_total="$(awk -F: 'tolower($1) ~ /total space/ {gsub(/[^0-9]/, "", $2); print $2; exit}' <<<"$info")"
    fi

    used=unknown; total=unknown; pct='-'
    if [[ "$raw_used" =~ ^[0-9]+$ && "$raw_total" =~ ^[1-9][0-9]*$ ]]; then
      used="$(human_bytes "$raw_used")"; total="$(human_bytes "$raw_total")"
      pct="$((raw_used * 100 / raw_total))%"
      percent_warning "Incus pool $pool" "$pct"
    fi
    rows+=("$pool\t${driver:-?}\t$used\t$total\t$pct")
  done < <(
    if command -v jq >/dev/null 2>&1; then
      incus storage list --format json 2>/dev/null | jq -r '.[].name'
    else
      incus storage list --format csv -c n 2>/dev/null
    fi
  )
  printf '%b\n' "${rows[@]}" | print_table
}

owned_runner_vms() {
  local vm role
  command -v incus >/dev/null 2>&1 || return 0
  while IFS= read -r vm; do
    [[ -n "$vm" ]] || continue
    role="$(incus config get "$vm" user.seele.role 2>/dev/null || true)"
    case "$role" in
      runner-v1|github-runner-v1|forgejo-runner-v1) printf '%s\t%s\n' "$vm" "$role" ;;
    esac
  done < <(incus list --format csv -c n 2>/dev/null)
}

print_runner_vms() {
  command -v incus >/dev/null 2>&1 || { printf '\n🐗 INCUS RUNNERS: Incus not installed\n'; return; }
  local found=0 vm role provider state service cpu_limit mem_limit uptime load
  local mem_used mem_total swap_used swap_total disk_used disk_total disk_free disk_pct docker
  local mem_line swap_line disk_line
  local -a rows=('NAME\tPROVIDER\tSTATE\tSERVICE\tLIMIT\tLOAD\tRAM\tSWAP\tROOT\tFREE\tDOCKER')
  printf '\n🐗 INCUS RUNNERS\n'
  while IFS=$'\t' read -r vm role; do
      [[ -n "$vm" ]] || continue
      found=1
      [[ "$role" == forgejo-runner-v1 ]] && provider=forgejo || provider=github
      state="$(incus list "$vm" --format csv -c s 2>/dev/null | head -n1)"
      cpu_limit="$(expanded_limit "$vm" limits.cpu)"; mem_limit="$(expanded_limit "$vm" limits.memory)"
      if [[ "$state" != RUNNING ]]; then
        rows+=("$vm\t$provider\t${state:-?}\t-\t${cpu_limit:-?}CPU/${mem_limit:-?}\t-\t-\t-\t-\t-\t-")
        WARNINGS+=("🔴 $vm is ${state:-unknown}")
        continue
      fi
      service="$(service_state_vm "$vm")"
      load="$(incus exec "$vm" -- awk '{print $1}' /proc/loadavg 2>/dev/null || printf '?')"
      uptime="$(incus exec "$vm" -- awk '{printf "%dd%02dh", $1/86400, ($1%86400)/3600}' /proc/uptime 2>/dev/null || true)"
      mem_line="$(incus exec "$vm" -- free -b 2>/dev/null | awk '/^Mem:/ {print $2,$3}' || true)"
      swap_line="$(incus exec "$vm" -- free -b 2>/dev/null | awk '/^Swap:/ {print $2,$3}' || true)"
      disk_line="$(incus exec "$vm" -- df -hP / 2>/dev/null | awk 'NR==2 {print $2,$3,$4,$5}' || true)"
      read -r mem_total mem_used <<<"${mem_line:-0 0}"
      read -r swap_total swap_used <<<"${swap_line:-0 0}"
      read -r disk_total disk_used disk_free disk_pct <<<"${disk_line:-? ? ? ?}"
      docker="$(docker_summary_vm "$vm")"
      rows+=("$vm\t$provider\t$state/${uptime:-?}\t${service:-?}\t${cpu_limit:-?}CPU/${mem_limit:-?}\t$load\t$(human_bytes "${mem_used:-0}")/$(human_bytes "${mem_total:-0}")\t$(human_bytes "${swap_used:-0}")/$(human_bytes "${swap_total:-0}")\t${disk_used:-?}/${disk_total:-?}\t${disk_free:-?}\t${docker:-empty}")
      [[ "$service" == active ]] || WARNINGS+=("🔴 $vm runner service is ${service:-unknown}")
      percent_warning "$vm root disk" "${disk_pct:-}"
      if [[ "${swap_total:-0}" =~ ^[0-9]+$ && "${swap_used:-0}" =~ ^[0-9]+$ ]] \
         && ((swap_total > 0 && swap_used * 100 / swap_total >= 70)); then
        WARNINGS+=("🟠 $vm swap usage is $((swap_used * 100 / swap_total))%")
      fi
  done < <(owned_runner_vms)
  printf '%b\n' "${rows[@]}" | print_table
  [[ "$found" == 1 ]] || printf 'No managed runner VMs found in the current Incus project.\n'
}

print_local_runner() {
  [[ -s "$POTATO_STATE" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    WARNINGS+=("🟠 local potato state exists but jq is unavailable")
    return
  fi
  local provider name user service state
  provider="$(jq -r '.provider // "?"' "$POTATO_STATE")"
  name="$(jq -r '.name // "?"' "$POTATO_STATE")"
  user="$(jq -r '.user // "runner"' "$POTATO_STATE")"
  if [[ "$provider" == github ]]; then
    service="$(cat "$POTATO_GITHUB_DIR/.service" 2>/dev/null || true)"
  else
    service=forgejo-runner.service
  fi
  if [[ -n "$service" ]]; then
    state="$(systemctl is-active "$service" 2>/dev/null || true)"
  else
    state=missing
  fi
  printf '\n🥔 LOCAL POTATO RUNNER\n'
  printf 'Name: %s | provider: %s | user: %s | service: %s\n' "$name" "$provider" "$user" "${state:-unknown}"
  [[ "$state" == active ]] || WARNINGS+=("🔴 local runner $name service is ${state:-unknown}")
}

render() {
  WARNINGS=()
  printf 'Runner Fleet Status — %s\n' "$(date '+%F %T %Z')"
  print_host
  print_storage_pools
  print_runner_vms
  print_local_runner
  printf '\n🩺 HEALTH\n'
  if ((${#WARNINGS[@]} == 0)); then
    printf '✅ No capacity or service warnings detected.\n'
  else
    printf '%s\n' "${WARNINGS[@]}"
  fi
}

if ((WATCH_SECONDS == 0)); then
  render
else
  while :; do
    command -v clear >/dev/null 2>&1 && clear || printf '\033[2J\033[H'
    render
    printf '\nRefreshing every %ss; Ctrl+C to stop.\n' "$WATCH_SECONDS"
    sleep "$WATCH_SECONDS"
  done
fi
