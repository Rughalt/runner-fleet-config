#!/usr/bin/env bash
set -Eeuo pipefail

# Unit tests for the runner disk cleanup helpers.
#
# These tests never touch Incus, Docker or a real runner: they build a
# synthetic workspace tree and assert that the cleanup helpers behave the way
# cleanup-runner-disks.sh and the in-guest daily timer rely on.
#
#   ./tests/cleanup-helpers.test.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/cleanup-runner-disks.sh"

PASSED=0
FAILED=0

pass() { printf '  ok   %s\n' "$1"; PASSED=$(( PASSED + 1 )); }
fail() { printf '  FAIL %s\n' "$1"; FAILED=$(( FAILED + 1 )); }

check() {
  local description="$1"
  shift
  if "$@"; then
    pass "$description"
  else
    fail "$description"
  fi
}

check_not() {
  local description="$1"
  shift
  if "$@"; then
    fail "$description"
  else
    pass "$description"
  fi
}

check_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$description"
  else
    fail "$description (expected '$expected', got '$actual')"
  fi
}

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# Build a workspace tree and backdate the given paths.
age_days() {
  local days="$1"
  shift
  local path
  for path in "$@"; do
    touch -d "${days} days ago" "$path"
  done
}

echo "== workspace staleness =="

STALE_ROOT="$WORK/stale/_work"
mkdir -p "$STALE_ROOT/old-repo/old-repo"
touch "$STALE_ROOT/old-repo/old-repo/file.txt"
age_days 5 "$STALE_ROOT/old-repo/old-repo/file.txt" "$STALE_ROOT/old-repo/old-repo" "$STALE_ROOT/old-repo"

FRESH_ROOT="$WORK/fresh/_work"
mkdir -p "$FRESH_ROOT/new-repo/new-repo"
touch "$FRESH_ROOT/new-repo/new-repo/file.txt"

check "an untouched workspace is stale" \
  workspace_is_stale "$STALE_ROOT/old-repo" 1
check_not "a workspace touched today is not stale" \
  workspace_is_stale "$FRESH_ROOT/new-repo" 1

# The regression that made old checkouts linger: the outer directory was
# refreshed by a recent job, but the checkout underneath is months old.
LINGERING_ROOT="$WORK/lingering/_work"
mkdir -p "$LINGERING_ROOT/busy-repo/busy-repo"
touch "$LINGERING_ROOT/busy-repo/busy-repo/file.txt"
age_days 30 "$LINGERING_ROOT/busy-repo/busy-repo/file.txt" "$LINGERING_ROOT/busy-repo/busy-repo"
touch "$LINGERING_ROOT/busy-repo"
check "a lingering checkout under a fresh parent is stale" \
  workspace_is_stale "$LINGERING_ROOT/busy-repo" 1

echo
echo "== workspace cleanup =="

CLEAN_ROOT="$WORK/clean/_work"
mkdir -p "$CLEAN_ROOT/old-repo/old-repo" "$CLEAN_ROOT/new-repo/new-repo" "$CLEAN_ROOT/_actions/owner/repo/v1"
touch "$CLEAN_ROOT/old-repo/old-repo/file.txt" "$CLEAN_ROOT/new-repo/new-repo/file.txt"
age_days 5 "$CLEAN_ROOT/old-repo/old-repo/file.txt" "$CLEAN_ROOT/old-repo/old-repo" "$CLEAN_ROOT/old-repo"

clean_workspaces "$CLEAN_ROOT" 1 0

check "a stale workspace is removed" test ! -d "$CLEAN_ROOT/old-repo"
check "a fresh workspace survives" test -d "$CLEAN_ROOT/new-repo"
check "_actions is left to the cache pruner" test -d "$CLEAN_ROOT/_actions"

echo
echo "== temporary job directories =="

TEMP_ROOT="$WORK/temp/_work/_temp"
mkdir -p "$TEMP_ROOT/old-with-old-file" "$TEMP_ROOT/old-with-recent-file" "$TEMP_ROOT/fresh-empty"
touch "$TEMP_ROOT/old-with-old-file/file.txt" "$TEMP_ROOT/old-with-recent-file/recent.txt"
age_days 3 "$TEMP_ROOT/old-with-old-file/file.txt" "$TEMP_ROOT/old-with-old-file" "$TEMP_ROOT/old-with-recent-file"

# The old implementation aborted the whole cleanup here.
set +e
( set -Eeuo pipefail; find "$TEMP_ROOT" -mindepth 1 -mtime +1 -delete ) >/dev/null 2>&1
OLD_STATUS=$?
set -e
check_eq "the old find -delete aborts on a non-empty directory" "1" "$OLD_STATUS"

clean_temp "$TEMP_ROOT" 1 0
check "the cleanup continues past a non-empty old directory" true
check "an old directory with an old file is removed" test ! -d "$TEMP_ROOT/old-with-old-file"
check "a recent file is never deleted" test -f "$TEMP_ROOT/old-with-recent-file/recent.txt"
check "a fresh empty directory is preserved" test -d "$TEMP_ROOT/fresh-empty"

echo
echo "== downloaded action and tool versions =="

CACHE_ROOT="$WORK/cache/_work"
mkdir -p "$CACHE_ROOT/_tool/runner-1/v1" "$CACHE_ROOT/_tool/runner-1/v2" "$CACHE_ROOT/_actions/owner/repo/v1"
touch "$CACHE_ROOT/_tool/runner-1/v1/tool" "$CACHE_ROOT/_tool/runner-1/v2/tool" "$CACHE_ROOT/_actions/owner/repo/v1/action"
age_days 60 "$CACHE_ROOT/_tool/runner-1/v1/tool" "$CACHE_ROOT/_tool/runner-1/v1"
touch "$CACHE_ROOT/_tool/runner-1/v2/tool" "$CACHE_ROOT/_actions/owner/repo/v1/action"

clean_cache_versions "$CACHE_ROOT/_tool" 30 0

check "an unused tool version is pruned" test ! -d "$CACHE_ROOT/_tool/runner-1/v1"
check "the newest tool version is kept" test -d "$CACHE_ROOT/_tool/runner-1/v2"

echo
echo "== runner diagnostic logs =="

DIAG_ROOT="$WORK/diag"
mkdir -p "$DIAG_ROOT"
touch "$DIAG_ROOT/worker-old.log" "$DIAG_ROOT/worker-new.log"
age_days 9 "$DIAG_ROOT/worker-old.log"

clean_diag_logs "$DIAG_ROOT" 7 0

check "an old diagnostic log is removed" test ! -f "$DIAG_ROOT/worker-old.log"
check "a recent diagnostic log survives" test -f "$DIAG_ROOT/worker-new.log"

echo
echo "== generated guest scripts =="

CLEANER="$WORK/runner-disk-cleanup"
ANALYZER="$WORK/runner-disk-analyze"
write_guest_cleaner "$CLEANER"
write_guest_analyzer "$ANALYZER"

check "the guest cleaner is valid bash" bash -n "$CLEANER"
check "the guest analyzer is valid bash" bash -n "$ANALYZER"
# shellcheck disable=SC2016
check "the guest cleaner takes the work and diagnostics directories" \
  grep -q 'work_dir="\$3"' "$CLEANER"
check "the guest cleaner never deletes a directory through find -delete" \
  bash -c "! grep -E 'find .*-delete' '$CLEANER' | grep -qv -- '-type'"

echo
echo "== analyzer output =="

ANALYZE_WORK="$WORK/analyze/_work"
mkdir -p "$ANALYZE_WORK/my-repo/my-repo"
touch "$ANALYZE_WORK/my-repo/my-repo/file.txt"
age_days 9 "$ANALYZE_WORK/my-repo/my-repo/file.txt" "$ANALYZE_WORK/my-repo/my-repo"

STREAM="$(bash "$ANALYZER" "$ANALYZE_WORK" "" 1 2>/dev/null || true)"
check "the analyzer reports the root filesystem" grep -q '^ROOT|' <<<"$STREAM"
check "the analyzer reports the workspace root" grep -q '^WSROOT|' <<<"$STREAM"
check "the analyzer flags the stale workspace" grep -q '^WS|.*|stale=yes|' <<<"$STREAM"
check "the analyzer reports top-level consumers" grep -q '^TOP|' <<<"$STREAM"

echo
echo "== reclaim estimate =="

ESTIMATE_STREAM='ROOT|total=20000000000|used=18000000000|free=2000000000|pct=90
TOP|path=/var|bytes=8000000000
WSROOT|path=/opt/actions-runner/_work
WS|name=my-repo|bytes=1000000000|stale=yes|newest=2026-10-19
WSSUB|name=_actions|bytes=2000000000
DOCKER|type=Images|total=4200000000|reclaimable=3100000000|total_bytes=4200000000|reclaim_bytes=3100000000|old_bytes=1000000000
DOCKER|type=Local Volumes|total=11410000000|reclaimable=11410000000|total_bytes=11410000000|reclaim_bytes=11410000000|old_bytes=0
DOCKER|type=Build Cache|total=1400000000|reclaimable=1400000000|total_bytes=1400000000|reclaim_bytes=1400000000|old_bytes=0
CACHE|kind=apt|bytes=120000000|old_bytes=120000000
CACHE|kind=journal|bytes=800000000|old_bytes=800000000
CACHE|kind=diag|bytes=15000000|old_bytes=10000000
VOLUME|count=3|bytes=11410000000'

REPORT="$(print_analysis "test-target" "github-runner-v1" "$ESTIMATE_STREAM")"

# normal  = stale workspace 1000000000 + old images 1000000000
#         + build cache 1400000000 + apt 120000000 + journal 800000000
#         = 4320000000
# aggressive = all workspace 1000000000 + images 3100000000 + _actions 2000000000
#             + build cache 1400000000 + apt 120000000 + journal 800000000
#             + diag 15000000 = 8435000000
# volumes are excluded from both: they need --include-volumes
NORMAL_EXPECTED="$(numfmt --to=iec-i --suffix=B 4320000000)"
AGGRESSIVE_EXPECTED="$(numfmt --to=iec-i --suffix=B 8435000000)"
VOLUMES_EXPECTED="$(numfmt --to=iec-i --suffix=B $((8435000000 + 11410000000)))"

check "the normal estimate counts stale data only" grep -qF "normal cleanup           ~$NORMAL_EXPECTED" <<<"$REPORT"
check "the aggressive estimate counts every reclaimable byte" grep -qF "aggressive cleanup       ~$AGGRESSIVE_EXPECTED" <<<"$REPORT"
check "unused volumes are only counted with --include-volumes" grep -qF "with --include-volumes   ~$VOLUMES_EXPECTED" <<<"$REPORT"
check "the report marks a stale checkout" grep -q 'lingering checkout' <<<"$REPORT"
check "the report mentions the action cache" grep -q '_actions' <<<"$REPORT"

echo
echo "== deleted files held open =="

# A file that is unlinked while a process still holds it open keeps its blocks
# on the filesystem. Cleanup cannot reclaim it; only closing the fd can.
DELETED_FILE="$WORK/held-open.log"
head -c 4096 /dev/urandom >"$DELETED_FILE"
exec 9<"$DELETED_FILE"
# unlink, not rm: the file must really disappear from the directory while the
# descriptor stays open.
unlink "$DELETED_FILE"

DELETED_LINE="$(bash -c '
  source "'"$SCRIPT_DIR"'/cleanup-runner-disks.sh"
  analyzer="$(mktemp)"
  write_guest_analyzer "$analyzer"
  bash "$analyzer" "" "" 1 2>/dev/null | grep "^DELETED|"
  rm -f "$analyzer"
')"

DELETED_BYTES="$(sed -n 's/.*bytes=\([0-9]*\).*/\1/p' <<<"$DELETED_LINE")"
check "the analyzer reports deleted files held open" test -n "$DELETED_BYTES"
check "the analyzer counts the held-open bytes" test "$DELETED_BYTES" -ge 4096
exec 9<&-

echo
echo "== command line =="

parse_args --analyze --force --aggressive --vm selee-trotter-01
# shellcheck disable=SC2153
check_eq "--analyze is parsed" "1" "$ANALYZE"
check_eq "--force is parsed" "1" "$FORCE"
check_eq "--aggressive is parsed" "1" "$AGGRESSIVE"
check_eq "--vm is parsed" "selee-trotter-01" "$TARGET_VM"
check_eq "--vm selects the single VM mode" "vm" "$MODE"

parse_args --local
check_eq "--local selects the local mode" "local" "$MODE"
check_eq "a fresh parse clears the previous flags" "0" "$ANALYZE"

if ( parse_args --not-a-flag ) >/dev/null 2>&1; then
  fail "an unknown option is rejected"
else
  pass "an unknown option is rejected"
fi

echo
echo "== guest cleaner, end to end =="

STUB_DIR="$WORK/stubs"
mkdir -p "$STUB_DIR"
for stub in docker apt-get journalctl fstrim runuser go; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/$stub"
  chmod +x "$STUB_DIR/$stub"
done

GUEST_WORK="$WORK/guest/_work"
mkdir -p "$GUEST_WORK/old-repo/old-repo" "$GUEST_WORK/new-repo/new-repo" "$GUEST_WORK/_temp/old" "$GUEST_WORK/_diag"
touch "$GUEST_WORK/old-repo/old-repo/file" "$GUEST_WORK/new-repo/new-repo/file"
touch "$GUEST_WORK/_temp/old/recent" "$GUEST_WORK/_diag/worker.log"
age_days 5 "$GUEST_WORK/old-repo/old-repo/file" "$GUEST_WORK/old-repo/old-repo" "$GUEST_WORK/old-repo" "$GUEST_WORK/_temp/old"
age_days 9 "$GUEST_WORK/_diag/worker.log"

if PATH="$STUB_DIR:$PATH" bash "$CLEANER" 0 0 "$GUEST_WORK" "$GUEST_WORK/_diag" 1 >/dev/null 2>&1; then
  pass "the guest cleaner completes without aborting"
else
  fail "the guest cleaner completes without aborting"
fi
check "the guest cleaner removes a stale workspace" test ! -d "$GUEST_WORK/old-repo"
check "the guest cleaner keeps a fresh workspace" test -d "$GUEST_WORK/new-repo"
check "the guest cleaner keeps a recent file in an old temp directory" \
  test -f "$GUEST_WORK/_temp/old/recent"
check "the guest cleaner removes an old diagnostic log" test ! -f "$GUEST_WORK/_diag/worker.log"

echo
printf 'passed: %s   failed: %s\n' "$PASSED" "$FAILED"
((FAILED == 0))
