#!/usr/bin/env bash
#
# ccwatch test suite.
#
# Every assertion here has been mutation-checked: the implementation was broken
# in the specific way the assertion describes, and the assertion was confirmed
# to fail. An assertion that passes against a broken implementation is a test
# defect, not coverage.
#
# Everything runs against a FABRICATED ~/.claude. A suite that reads the
# developer's live sessions asserts on whatever happened to be open, which is
# not a test — it is a screenshot.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CCWATCH="$ROOT/bin/ccwatch"

# --fast skips the sections that start HTTP servers and wait on real time.
#
# ⚠️ It is for the edit-test loop, not for deciding a change is good. Measured
# on this host: the whole suite is 4m06s at 24% CPU, and the `serve` section
# alone starts 11 of the 14 servers and owns 49s of the 59s the suite spends
# waiting. What is left runs in seconds and catches most of what a change to
# the renderer, the classification or a web module breaks. The full run is
# still what has to be green before anything is committed, which is why the
# summary says loudly which one this was.
FAST=0
for _arg in "$@"; do
  case "$_arg" in
    --fast) FAST=1;;
    -h|--help)
      printf 'usage: tests/run.sh [--fast]\n\n'
      printf '  --fast   skip the server and timing sections (see the note in this file)\n'
      exit 0;;
    *) printf 'unknown option: %s\n' "$_arg" >&2; exit 2;;
  esac
done

pass=0; fail=0; skipped=0

# ⚠️ `return 0` is load-bearing in t_fail. Without it its status is that of the
# last command — the `[ -n "${2:-}" ]` test — so a one-argument t_fail returns 1,
# and the `cond && t_fail || t_pass` form then runs BOTH branches: one assertion
# prints a ✗ AND a ✓ and is counted twice.
t_note() { printf '  %s\n' "$1"; }
t_pass() { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
t_fail() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; return 0; }
t_skip() { skipped=$((skipped+1)); printf '  \033[33m-\033[0m %s (skipped: %s)\n' "$1" "$2"; }

# A floor on the tally, because "assertions ran but were never counted" is
# invisible by construction: nothing else in a passing run distinguishes it from
# a full run.
#
# ⚠️ There are TWO floors, because a skipped assertion is not a counted one —
# the check below compares `pass + fail` and ignores `skipped`. Three sections
# (markdown, roster-module, modal-module) need `node`, and measured
# 2026-09-15 they are 187 of the 491 assertions. A single floor set from a
# machine that has node therefore fails on a machine that does not: at 455
# against the 302 that ran without it, the suite once reported "assertions are
# running but not registering" on a host whose only fault was missing an
# optional tool. That is one machine's configuration written into the suite,
# which is the thing a floor must not do.
#
# So TALLY_FLOOR is what always runs, and TALLY_FLOOR_NODE is added only when
# node is actually present. Both dropped when the pan-and-zoom camera was
# replaced by the scrolling board: web/plots.js and web/camera.js were pure
# arithmetic modules with 73 node checks between them, and retiring the
# arithmetic retired the assertions on it.
# Raised by the alert control: 11 static page assertions that always run, and
# 40 node checks on web/alerts.js - less the 10 on roster.js's statements(),
# which the alert control replaced and which went with it.
# Raised again by the usage meter: 14 static, and 28 that need node - 25 on
# web/usage.js, plus the three that compare the terminal's own rendering of a
# reset instant against the page's.
# Raised by `ccwatch bar`: 39 assertions, of which 31 always run. The other
# eight are the four needing a free port to bind and the four behind the jq
# shim, and a floor counting those would fail on a host that can do neither -
# which is one machine's configuration written into the suite.
TALLY_FLOOR=373
TALLY_FLOOR_NODE=243

# wait_until <seconds> <command...> — poll until the command succeeds, or the
# deadline passes. Returns 0 if it succeeded.
#
# ⚠️ Polling at 100ms, not sleeping for the worst case. Every wait in this
# suite used to be either a fixed `sleep` sized for a slow machine or a loop
# with 1-second granularity, and both are paid in full on every run: measured
# 59s of deliberate waiting, 49s of it in the `serve` section alone, against a
# 4m06s suite. The deadlines here are unchanged — what changed is that a
# condition met in 200ms costs 200ms.
wait_until() { # wait_until <seconds> <command...>
  local _ticks=$(( $1 * 10 )); shift
  while [ "$_ticks" -gt 0 ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1
    _ticks=$((_ticks - 1))
  done
  return 1
}
# The conditions the waits above are usually waiting for, named once each so a
# typo in one is not a wait that silently never succeeds.
srv_up() { curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$1/"; }
srv_dead() { ! curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$1/"; }
srv_warm() { # the first snapshot has landed
  [ "$(curl -s --max-time 3 "http://127.0.0.1:$1/api/state" 2>/dev/null \
       | jq -r '.warming' 2>/dev/null)" = "false" ]
}
srv_field() { # srv_field <port> <jq-filter> <expected>
  [ "$(curl -s --max-time 3 "http://127.0.0.1:$1/api/state" 2>/dev/null \
       | jq -r "$2" 2>/dev/null)" = "$3" ]
}

assert_contains() { case "$1" in *"$2"*) t_pass "$3";; *) t_fail "$3" "expected to contain: $2";; esac; }
assert_not_contains() { case "$1" in *"$2"*) t_fail "$3" "should NOT contain: $2";; *) t_pass "$3";; esac; }
assert_eq() { [ "$1" = "$2" ] && t_pass "$3" || t_fail "$3" "expected '$2', got '$1'"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccwatch-tests.XXXXXX")
# The serve tests start real servers. Reaping them on exit is not optional:
# a leaked one holds a port that a later run may pick, and then that run tests
# the leaked binary instead of its own.
# ⚠️ Ports are recorded as they are handed out, never enumerated by hand.
#
# This function used to reap $SPORT through $SPORT6, one line each. The suite
# then grew SPORT7, SPORT8 and SPORT9, and nobody added the lines — so three
# servers leaked on every single run, including runs that passed. Measured
# 2026-09-09: 1686 orphaned `ccwatch serve` processes on the development
# machine, the oldest more than a day old, holding roughly 5GB between them.
# Swap fell from 95% to 76% when they were reaped, which had been read as the
# host simply being short of memory.
#
# The fix is not a seventh line. Any list a new test has to remember to extend
# will eventually not be extended, so `free_port` records every port it issues
# and cleanup reaps exactly what was recorded.
SERVE_PORTS="$WORK/serve-ports"
SUITE_PID_FILE="$WORK/suite-pid"
: > "$SERVE_PORTS"
printf '%s\n' "$$" > "$SUITE_PID_FILE"

cleanup_suite() {
  if [ -f "$SERVE_PORTS" ]; then
    while IFS= read -r _p; do
      [ -n "$_p" ] && pkill -f "ccwatch serve --port $_p" 2>/dev/null
    done < "$SERVE_PORTS"
  fi
  rm -rf "$WORK"
  return 0
}
# ⚠️ EXIT alone is not enough: a suite stopped with Ctrl-C or SIGTERM never ran
# it, and left every server it had started behind.
trap cleanup_suite EXIT INT TERM HUP

# ⚠️ SIGKILL runs no trap at all, and the OOM killer sends SIGKILL — which is
# how most of those 1686 accumulated, each aborted run making the next OOM more
# likely. Nothing inside the suite can catch that, so instead each run cleans
# up after previous runs that were killed: the work directory survives a
# SIGKILL, and it records both the ports and the pid of the suite that owned
# them. A directory whose owning pid is gone is finished, whatever happened to
# it, and its ports are safe to reap. A concurrently running suite keeps a live
# pid and is left alone.
for _stale in "${TMPDIR:-/tmp}"/ccwatch-tests.*; do
  [ -d "$_stale" ] || continue
  [ "$_stale" = "$WORK" ] && continue
  _owner=$(cat "$_stale/suite-pid" 2>/dev/null)
  # No pid recorded means it predates this mechanism; treat as finished.
  if [ -n "$_owner" ] && kill -0 "$_owner" 2>/dev/null; then continue; fi
  if [ -f "$_stale/serve-ports" ]; then
    while IFS= read -r _p; do
      [ -n "$_p" ] && pkill -f "ccwatch serve --port $_p" 2>/dev/null
    done < "$_stale/serve-ports"
  fi
  rm -rf "$_stale"
done
unset _stale _owner _p

for t in jq awk; do
  command -v "$t" >/dev/null 2>&1 || { printf 'ccwatch needs %s\n' "$t" >&2; exit 2; }
done

# =============================================================== shellcheck ===
printf '\nshellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  # Pinned expectations: an unpinned linter means "lint" does not mean the same
  # thing on a laptop as in CI.
  t_note "shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
  # The menu bar plugin is linted with the rest of it. It is a shell script
  # that ships, and the plugin host runs it with no terminal to print a
  # complaint to — a quoting bug there is a menu bar item that silently says
  # the wrong thing, which is the failure this whole tool is against.
  if sc=$(shellcheck -x -S warning "$CCWATCH" "$ROOT/tests/run.sh" \
            "$ROOT/extra/swiftbar/ccwatch.10s.sh" 2>&1); then
    t_pass "clean at -S warning"
  else
    t_fail "shellcheck findings" "$(printf '%s' "$sc" | head -30)"
  fi
else
  t_skip "shellcheck" "not installed — brew install shellcheck"
fi

# bash 3.2 is what macOS ships, so it is the floor. Grep for the constructs that
# silently do nothing there rather than trusting whoever edits this next.
# The plugin is included: its shebang is /bin/bash, which on macOS IS 3.2 —
# so it is the one file here that cannot even fall back to a newer bash on
# PATH the way `#!/usr/bin/env bash` would.
b4=$(grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' \
       "$CCWATCH" "$ROOT/extra/swiftbar/ccwatch.10s.sh" 2>/dev/null | grep -v '^\s*#' || true)
assert_eq "$b4" "" "no bash-4-only construct (macOS ships 3.2)"
t_note "running under bash ${BASH_VERSION}"

# ⚠️ This suite starts real servers, so how it reaps them is itself worth
# asserting. `cleanup_suite` used to reap $SPORT..$SPORT6 by name, one line
# each; the suite grew SPORT7, SPORT8 and SPORT9, the lines were not added, and
# three servers leaked on every run that passed. Measured 2026-09-09: 1686
# orphaned `ccwatch serve` processes, the oldest over a day old, ~5GB between
# them — reaping them moved swap from 95% to 76%, which had been read as the
# host merely being short of memory.
#
# So the guard is against the SHAPE of the old bug, not the symptom: cleanup
# must not name port variables, because any list a new test has to remember to
# extend will eventually not be extended.
_cln=$(sed -n '/^cleanup_suite()/,/^}/p' "$ROOT/tests/run.sh" | grep -cE 'SPORT[0-9]*' || true)
assert_eq "$_cln" "0" \
  "cleanup reaps recorded ports, not a hand-maintained list of SPORT variables"
_fp=$(sed -n '/free_port() {/,/^  }/p' "$ROOT/tests/run.sh" | grep -c 'SERVE_PORTS' || true)
[ "$_fp" -ge 1 ] \
  && t_pass "taking a port registers it, so a new server cannot forget to" \
  || t_fail "taking a port registers it, so a new server cannot forget to" \
            "free_port does not append to SERVE_PORTS"
# A run stopped with Ctrl-C or SIGTERM must reap too; only EXIT was trapped.
_tr=$(grep -cE "^trap cleanup_suite .*INT.*TERM" "$ROOT/tests/run.sh" || true)
assert_eq "$_tr" "1" "the cleanup trap covers interruption, not just a clean exit"

# ================================================================== ccwatch ===
printf '\nclassification\n'

# Every ccwatch assertion runs against a FABRICATED ~/.claude, because the real one
# changes between runs — a suite that reads the developer's live sessions asserts
# on whatever happened to be open, which is not a test. CLAUDE_CONFIG_DIR moves
# the registry and the transcripts; CCWATCH_FAKE_PS substitutes the liveness probe,
# without which no fabricated pid is ever live and every row is filtered out
# before it reaches the classification.
FH="$WORK/ccwatch-home"
mkdir -p "$FH/sessions" "$FH/projects/-fake-repo"

# A session file, and a transcript whose mtime is the progress signal.
mksess() { # mksess <pid> <sid> <name> <cwd> <status|-> <entrypoint> [waitingFor]
  local extra=""
  [ "$5" != "-" ] && extra=",\"status\":\"$5\",\"statusUpdatedAt\":$(( ($(date '+%s') - 60) * 1000 ))"
  [ -n "${7:-}" ] && extra="$extra,\"waitingFor\":\"$7\""
  cat > "$FH/sessions/$1.json" <<EOF
{"pid":$1,"sessionId":"$2","cwd":"$4","startedAt":$(( ($(date '+%s') - 3600) * 1000 )),
 "kind":"interactive","entrypoint":"$6","name":"$3","version":"9.9.9"$extra}
EOF
}
# <sid> <seconds-ago>: a transcript last written that long ago. The mtime IS the
# assertion input, so it is set explicitly rather than left to write order.
mktrans() { touch -t "$(date -r "$(( $(date '+%s') - $2 ))" '+%Y%m%d%H%M.%S')" "$FH/projects/-fake-repo/$1.jsonl"; }
# <pid> <cpu-seconds>: what ps would have reported.
mkps() { printf '%s %s %s\n' "$1" "$(date -r "$(( $(date '+%s') - 3600 ))" '+%a %b %e %T %Y')" "$2"; }

# ⚠️ CCWATCH_CPU_MIN_GAP is lowered from its 1.5s default to 0.2s. The CPU
# delta is only believed when two samples are far enough apart to mean
# something, so the assertions on it have to wait out that gap — five times,
# at 2s each, for 10s of the suite's runtime. The gap is a parameter, so the
# fixture sets it small and waits 0.3s instead. What is under test is the
# comparison against the gap, not the gap's default value.
CPU_GAP=0.2
ccwatch_json() { # ccwatch_json <fake-ps-file>
  CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$1" CCWATCH_HOME="$WORK/ccwatch-events" \
    CCWATCH_CPU_MIN_GAP="$CPU_GAP" NO_COLOR=1 "$CCWATCH" --json 2>/dev/null
}
tok() { printf '%s' "$1" | jq -r --arg n "$2" '.sessions[] | select(.name == $n) | .token'; }
sev() { printf '%s' "$1" | jq -r --arg n "$2" '.sessions[] | select(.name == $n) | .sev'; }

# --- the case the whole tool exists for: busy, and gone quiet -----------------
# 1200s of silence against a 600s threshold, and CPU that has not moved between
# the two frames. Two independent signals agreeing is what licenses the verdict.
mksess 9001 aaaaaaaa-0000-0000-0000-000000000001 hung-one /fake/repo busy cli
mktrans aaaaaaaa-0000-0000-0000-000000000001 1200
mkps 9001 "1:00.00" > "$WORK/ps-a"
cpu_cache_reset() { rm -f "${TMPDIR:-/tmp}"/ccwatch-cpu-*.json; }
cpu_cache_reset
_f1=$(ccwatch_json "$WORK/ps-a")   # first frame: no previous CPU sample yet
# The gap has to exceed CCWATCH_CPU_MIN_GAP or the delta is reported as
# unmeasured rather than as zero — deliberately, because "measured no progress"
# is the claim that escalates a quiet session to HUNG. Comfortably past the
# 0.2s the fixture sets, not past the 1.5s default.
sleep 0.3
_f2=$(ccwatch_json "$WORK/ps-a")   # second frame: CPU identical, so it has not moved
assert_eq "$(tok "$_f2" hung-one)" "HUNG?" \
  "a busy session whose transcript stopped growing, with no CPU movement, is HUNG?"
assert_eq "$(sev "$_f2" hung-one)" "3" "and it carries the severity that sorts it to the top"

# Mutation check for the pair above: if the threshold comparison were dropped,
# this would ALSO read HUNG?, and the two assertions together would pass against
# an implementation that flags every busy session.
mktrans aaaaaaaa-0000-0000-0000-000000000001 5
_f3=$(ccwatch_json "$WORK/ps-a")
assert_eq "$(tok "$_f3" hung-one)" "busy" \
  "the same session, transcript freshly written, is just busy"

# --- and the false alarm that would make the column unreadable ---------------
# Quiet, but burning CPU: a long Bash call looks exactly like this, and calling
# it a hang is the cry-wolf that stops the column being read at all.
mktrans aaaaaaaa-0000-0000-0000-000000000001 1200
mkps 9001 "1:00.00" > "$WORK/ps-b"
mkps 9001 "1:30.00" > "$WORK/ps-c"
cpu_cache_reset
ccwatch_json "$WORK/ps-b" >/dev/null
sleep 0.3
_f4=$(ccwatch_json "$WORK/ps-c")
assert_eq "$(tok "$_f4" hung-one)" "busy" \
  "a quiet transcript is NOT a hang while CPU is still moving"
assert_contains "$(printf '%s' "$_f4" | jq -r '.sessions[] | select(.name=="hung-one") | .note')" \
  "cpu" "and the row says which measurement spared it"

# Escalation past 3x, so the verdict grows with the evidence rather than
# arriving all at once.
mktrans aaaaaaaa-0000-0000-0000-000000000001 2400
cpu_cache_reset
ccwatch_json "$WORK/ps-a" >/dev/null
sleep 0.3
assert_eq "$(tok "$(ccwatch_json "$WORK/ps-a")" hung-one)" "HUNG!!" \
  "past 3x the threshold the verdict escalates"
rm -f "$FH/sessions/9001.json"

# The CPU cache must be scoped to the registry being watched. A single global
# file meant a `ccwatch serve` polling the real registry every two seconds
# overwrote the samples of a run against a different CLAUDE_CONFIG_DIR, and both
# then reported no CPU movement — inventing hangs in healthy sessions.
cpu_cache_reset
ccwatch_json "$WORK/ps-a" >/dev/null
_cache_a=$(ls -t "${TMPDIR:-/tmp}"/ccwatch-cpu-*.json 2>/dev/null | head -1)
mkdir -p "$WORK/other-home/sessions"
CLAUDE_CONFIG_DIR="$WORK/other-home" CCWATCH_FAKE_PS="$WORK/ps-a" \
  CCWATCH_HOME="$WORK/other-cch" NO_COLOR=1 "$CCWATCH" --json >/dev/null 2>&1
_cache_b=$(ls -t "${TMPDIR:-/tmp}"/ccwatch-cpu-*.json 2>/dev/null | head -1)
[ -n "$_cache_a" ] && [ "$_cache_a" != "$_cache_b" ] \
  && t_pass "a run against a different config directory uses its own CPU cache" \
  || t_fail "a run against a different config directory uses its own CPU cache" \
            "both used $_cache_a"

# --- blocked on you, which outranks everything -------------------------------
mksess 9002 aaaaaaaa-0000-0000-0000-000000000002 asking /fake/repo waiting cli "permission to run rm"
mktrans aaaaaaaa-0000-0000-0000-000000000002 30
mkps 9002 "0:10.00" > "$WORK/ps-w"
_w=$(ccwatch_json "$WORK/ps-w")
assert_eq "$(tok "$_w" asking)" "waiting" "a session with a dialog open reports waiting"
assert_eq "$(sev "$_w" asking)" "4" "and outranks a suspected hang"
assert_contains "$(printf '%s' "$_w" | jq -r '.sessions[] | select(.name=="asking") | .note')" \
  "permission to run rm" "the reason it is blocked is carried through, not just the fact"
# waitingFor absent must not become an empty reason: the row would say a session
# needs you and decline to say what for.
mksess 9003 aaaaaaaa-0000-0000-0000-000000000003 asking-bare /fake/repo waiting cli
mktrans aaaaaaaa-0000-0000-0000-000000000003 30
mkps 9003 "0:10.00" >> "$WORK/ps-w"
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-w")" | jq -r '.sessions[] | select(.name=="asking-bare") | .note')" \
  "input needed" "a waiting session with no recorded reason still states one"
rm -f "$FH/sessions/9002.json" "$FH/sessions/9003.json"

# --- the two kinds of statusless session, which must NOT be conflated --------
# sdk-cli writes a transcript, so silence there means something. sdk-ts never
# writes one, so silence there measures nothing — and reporting it as a hang
# would have fired on 4 of 19 real sessions.
mksess 9004 aaaaaaaa-0000-0000-0000-000000000004 headless /fake/repo - sdk-cli
mktrans aaaaaaaa-0000-0000-0000-000000000004 1800
mkps 9004 "1:00.00" > "$WORK/ps-s"
mksess 9005 aaaaaaaa-0000-0000-0000-000000000005 embedded /fake/repo - sdk-ts
mkps 9005 "1:00.00" >> "$WORK/ps-s"
cpu_cache_reset
ccwatch_json "$WORK/ps-s" >/dev/null
sleep 0.3
_s=$(ccwatch_json "$WORK/ps-s")
assert_eq "$(tok "$_s" headless)" "SDK STALE?" \
  "a headless claude -p run that stopped writing its transcript is flagged"
assert_eq "$(tok "$_s" embedded)" "sdk-ts" \
  "an embedded-SDK session, which never writes a transcript, is NOT called a hang"
assert_eq "$(sev "$_s" embedded)" "1" "and does not sort with the suspects"
rm -f "$FH/sessions/9004.json" "$FH/sessions/9005.json"

# --- a claim with nothing behind it ------------------------------------------
# Busy, and no transcript at all. The honest report is that the claim cannot be
# checked, which is different from checking it and finding it fine.
mksess 9006 aaaaaaaa-0000-0000-0000-000000000006 unverifiable /fake/repo busy cli
mkps 9006 "1:00.00" > "$WORK/ps-n"
cpu_cache_reset
ccwatch_json "$WORK/ps-n" >/dev/null
sleep 0.3
assert_eq "$(tok "$(ccwatch_json "$WORK/ps-n")" unverifiable)" "NO TRANSCRIPT" \
  "busy with no transcript to corroborate it is reported as unverifiable, not as fine"
rm -f "$FH/sessions/9006.json"

# --- PID reuse, the way a stale registry file lies ---------------------------
# The file says pid 9007 started an hour ago; ps says that pid has been up for
# two days. The number was recycled, so the session is gone however live the
# pid looks. Without this guard an unrelated process resurrects a dead row.
mksess 9007 aaaaaaaa-0000-0000-0000-000000000007 impostor /fake/repo busy cli
mktrans aaaaaaaa-0000-0000-0000-000000000007 30
printf '%s %s %s\n' 9007 "$(date -r "$(( $(date '+%s') - 172800 ))" '+%a %b %e %T %Y')" "5:00.00" > "$WORK/ps-r"
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-r")" | jq '.sessions | length')" "0" \
  "a registry file whose pid was recycled is not reported as a live session"
# Mutation check: the same fixture with a start time that MATCHES does appear, so
# the assertion above is about the guard rather than about an empty fixture.
mkps 9007 "5:00.00" > "$WORK/ps-r2"
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-r2")" | jq '.sessions | length')" "1" \
  "and the same session with a matching start time IS reported"
rm -f "$FH/sessions/9007.json"

# --- an unreadable registry file costs one row, not the table ----------------
mksess 9008 aaaaaaaa-0000-0000-0000-000000000008 healthy /fake/repo idle cli
mktrans aaaaaaaa-0000-0000-0000-000000000008 30
mkps 9008 "0:10.00" > "$WORK/ps-p"
printf '{"pid":9009,"cwd":' > "$FH/sessions/9009.json"   # truncated mid-write
mkps 9009 "0:10.00" >> "$WORK/ps-p"
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-p")" | jq -r '.sessions[0].name')" "healthy" \
  "a half-written registry file does not take the rest of the table down with it"

# --- parse_failed reaches all four consumers identically (research.md D6) ---
# Mutation check: reverting any of collect_sessions/snapshot/cmd_doctor/the
# footer to read a stale/global $PARSE_FAILED instead of the object this
# fixture drives makes every one of these read 0 again.
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-p")" | jq -r '.parse_failed')" "1" \
  "--json reports the one unreadable file as parse_failed"
_footout=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-p" CCWATCH_HOME="$WORK/ccwatch-events" \
           NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_footout" "1 unreadable registry file(s) — run: ccwatch doctor" \
  "the terminal footer states the unreadable file and where to look"
_doc9=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-p" CCWATCH_HOME="$WORK/ccwatch-events" \
        NO_COLOR=1 "$CCWATCH" doctor 2>&1)
assert_contains "$_doc9" "1 registry file(s) would not parse" \
  "ccwatch doctor reports the same count"
rm -f "$FH/sessions/9009.json"
# Constitution XII: with the bad file gone, all four consumers drop to 0 and
# print nothing — not a "0 unreadable" line, an absent one.
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-p")" | jq -r '.parse_failed')" "0" \
  "deleting the bad file drops parse_failed to 0"
_footout2=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-p" CCWATCH_HOME="$WORK/ccwatch-events" \
            NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_not_contains "$_footout2" "unreadable registry file" \
  "and the footer prints no note at all below the threshold, not a zero"

# --- the pipeline overlay attaches by session id, not by directory -----------
# Attaching by cwd was the first thing tried and it lied: four sessions in one
# repo all claimed the same run.
FSPEC="$WORK/ccwatch-repo/specs/001-thing/.pipeline"
mkdir -p "$FSPEC"
cat > "$FSPEC/state.json" <<EOF
{"version":1,"feature_dir":"$WORK/ccwatch-repo/specs/001-thing","branch":"001-thing",
 "phases":{"specify":{"status":"ok","session_id":"bbbbbbbb-0000-0000-0000-000000000001","model":"opus","cost_usd":2.5},
           "plan":{"status":"running","session_id":"bbbbbbbb-0000-0000-0000-000000000002","model":"opus","cost_usd":0,"runner_pid":9101,"started_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}}}
EOF
mksess 9010 bbbbbbbb-0000-0000-0000-000000000002 owner "$WORK/ccwatch-repo" - sdk-cli
mktrans bbbbbbbb-0000-0000-0000-000000000002 30
mksess 9011 cccccccc-0000-0000-0000-000000000001 bystander "$WORK/ccwatch-repo" idle cli
mktrans cccccccc-0000-0000-0000-000000000001 30
mkps 9010 "0:30.00" >  "$WORK/ps-pl"
mkps 9011 "0:30.00" >> "$WORK/ps-pl"
mkps 9101 "0:30.00" >> "$WORK/ps-pl"   # the runner is alive, so the phase has not crashed
_pl=$(ccwatch_json "$WORK/ps-pl")
assert_eq "$(printf '%s' "$_pl" | jq -r '.sessions[] | select(.name=="owner") | .pipeline.phase')" "plan" \
  "a phase attaches to the session whose id spec-run recorded for it"
assert_eq "$(printf '%s' "$_pl" | jq -r '.sessions[] | select(.name=="bystander") | .pipeline')" "null" \
  "and NOT to another session that merely shares the directory"
assert_eq "$(printf '%s' "$_pl" | jq -r '.sessions[] | select(.name=="owner") | .pipeline.cost')" "2.5" \
  "the overlay shows the run total, since a phase still running has spent nothing yet"

# --- a running phase whose runner is dead is a crash, and says so ------------
# spec-run reconciles this to `interrupted` on its next invocation, which could
# be days away. Until then this is the only place it shows.
mkps 9010 "0:30.00" >  "$WORK/ps-cr"
mkps 9011 "0:30.00" >> "$WORK/ps-cr"   # 9101 omitted: the runner is gone
_cr=$(ccwatch_json "$WORK/ps-cr")
assert_eq "$(printf '%s' "$_cr" | jq -r '.sessions[] | select(.name=="owner") | .pipeline.crashed')" "true" \
  "a running phase with no live runner is reported as crashed"
assert_eq "$(printf '%s' "$_cr" | jq -r '.sessions[] | select(.name=="owner") | .psev')" "3" \
  "and the pipeline severity rises even though the session itself is healthy"
assert_eq "$(printf '%s' "$_cr" | jq -r '.sessions[] | select(.name=="owner") | .sev')" "2" \
  "the session severity is left alone, so 'idle' and 'crashed' stay two separate claims"

# --- needs_input: the pipeline's own record of being blocked on you ----------
sed -i '' 's/"status":"running"/"status":"needs_input"/' "$FSPEC/state.json"
assert_eq "$(printf '%s' "$(ccwatch_json "$WORK/ps-cr")" | jq -r '.sessions[] | select(.name=="owner") | .psev')" "4" \
  "a phase that stopped to ask you something ranks with a session that is waiting"
rm -f "$FH/sessions/9010.json" "$FH/sessions/9011.json"

# --- unfinished runs: stopped, with no live session left holding them --------
# The class of failure the user actually hits: a phase died, its session is gone,
# and nothing reports it. Windowed, because the first version listed a fortnight
# of wreckage and buried the two entries from the last hour.
mksess 9012 dddddddd-0000-0000-0000-000000000001 watcher "$WORK/ccwatch-repo" idle cli
mktrans dddddddd-0000-0000-0000-000000000001 30
mkps 9012 "0:30.00" > "$WORK/ps-un"
_un=$(ccwatch_json "$WORK/ps-un")
assert_eq "$(printf '%s' "$_un" | jq '[.unfinished[] | select(.phase=="plan")] | length')" "1" \
  "a stopped phase whose session is gone is reported under unfinished runs"
assert_eq "$(printf '%s' "$_un" | jq -r '.unfinished[] | select(.phase=="plan") | .sid')" \
  "bbbbbbbb-0000-0000-0000-000000000002" \
  "with the session id needed to resume it"
# Which project it belongs to. The record carried the cwd from the start and
# neither renderer showed it, so two unfinished runs from different repos were
# indistinguishable — the feature name alone does not say where it lives.
assert_eq "$(printf '%s' "$_un" | jq -r '.unfinished[] | select(.phase=="plan") | .project')" \
  "ccwatch-repo" "and the project it belongs to"
assert_contains "$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-un" CCWATCH_HOME="$WORK/ccwatch-events" \
  NO_COLOR=1 "$CCWATCH" once 2>&1)" "ccwatch-repo" \
  "and the table prints it next to the feature"
# The window, and the fact that what it withholds is counted rather than dropped
# in silence.
_old=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-un" CCWATCH_HOME="$WORK/ccwatch-events" \
       CCWATCH_UNFINISHED_HOURS=0 NO_COLOR=1 "$CCWATCH" --json 2>/dev/null)
assert_eq "$(printf '%s' "$_old" | jq '.unfinished | length')" "0" \
  "the window excludes a run older than the cutoff"
assert_eq "$(printf '%s' "$_old" | jq '.unfinished_old')" "1" \
  "and counts what it withheld, so the omission is stated rather than silent"

# --- rendering, since a table nobody can read is not an answer --------------
_out=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-un" CCWATCH_HOME="$WORK/ccwatch-events" \
       NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_out" "watcher" "the table names the session"
assert_contains "$_out" "UNFINISHED RUNS" "and shows the unfinished-run block when there is one"
assert_contains "$_out" "1 live" "and a footer that can be read from across the room"
# Colour must never be the only thing carrying a severity, or `ccwatch | grep` and
# a screen reader both lose the meaning.
assert_not_contains "$_out" "$(printf '\033')" "no escape codes when NO_COLOR is set"

# --- doctor: the assertion that ccwatch's own view is trustworthy --------------
# ccwatch reads an internal file layout, so an upgrade could move it. The failure
# that must never happen is an empty, confident table.
_doc=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-un" CCWATCH_HOME="$WORK/ccwatch-events" \
       NO_COLOR=1 "$CCWATCH" doctor 2>&1)
assert_contains "$_doc" "registry schema looks right" "doctor confirms the registry schema it depends on"
# A status value ccwatch does not understand would otherwise be classified by the
# final else branch and reported as though it had been read.
mksess 9013 dddddddd-0000-0000-0000-000000000002 futurestatus /fake/repo teleporting cli
_doc2=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-un" CCWATCH_HOME="$WORK/ccwatch-events" \
        NO_COLOR=1 "$CCWATCH" doctor 2>&1)
assert_contains "$_doc2" "unrecognised status value" \
  "doctor complains about a status value it does not know, instead of guessing"
rm -f "$FH/sessions/9013.json"

# --- the hook receiver must never break the session that called it ----------
_hookout=$(printf '{"session_id":"e1","cwd":"/fake/repo","message":"needs your permission"}' \
  | CCWATCH_HOME="$WORK/ccwatch-events" CLAUDE_CONFIG_DIR="$FH" "$CCWATCH" hook Notification 2>&1; echo "rc=$?")
assert_contains "$_hookout" "rc=0" "the hook receiver exits 0"
assert_contains "$(cat "$WORK/ccwatch-events/events.jsonl" 2>/dev/null)" "needs your permission" \
  "and records the reason a session wanted you"
# Garbage on stdin is the case that would otherwise abort a hook mid-session.
_bad=$(printf 'not json at all' \
  | CCWATCH_HOME="$WORK/ccwatch-events" CLAUDE_CONFIG_DIR="$FH" "$CCWATCH" hook Stop 2>&1; echo "rc=$?")
assert_contains "$_bad" "rc=0" "an unparseable hook payload still exits 0"
assert_contains "$(cat "$WORK/ccwatch-events/events.jsonl" 2>/dev/null)" "unparseable" \
  "and leaves a record saying so rather than nothing"

# --- install-hooks: the only thing ccwatch writes that is not its own ---------
# It edits the user's settings.json, which makes it the riskiest command here.
# An existing hook that gets clobbered is silent damage to something ccwatch does
# not own.
mkdir -p "$WORK/hookhome"
printf '{"model":"opus","hooks":{"Notification":[{"matcher":"","hooks":[{"type":"command","command":"say hello"}]}]}}\n' \
  > "$WORK/hookhome/settings.json"
_decline=$(printf 'n\n' | CLAUDE_CONFIG_DIR="$WORK/hookhome" CCWATCH_HOME="$WORK/ccwatch-events" \
           NO_COLOR=1 "$CCWATCH" install-hooks 2>&1)
assert_contains "$_decline" "Nothing changed" "declining install-hooks changes nothing"
assert_eq "$(jq -r '.hooks | keys | join(",")' "$WORK/hookhome/settings.json")" "Notification" \
  "and the settings file is untouched after a decline"

printf 'y\n' | CLAUDE_CONFIG_DIR="$WORK/hookhome" CCWATCH_HOME="$WORK/ccwatch-events" \
  NO_COLOR=1 "$CCWATCH" install-hooks >/dev/null 2>&1
assert_eq "$(jq -r '.hooks | keys | sort | join(",")' "$WORK/hookhome/settings.json")" \
  "Notification,SessionEnd,SessionStart,Stop" "applying it installs all four hooks"
assert_eq "$(jq -r '[.hooks.Notification[].hooks[].command] | map(select(contains("say hello"))) | length' \
  "$WORK/hookhome/settings.json")" "1" "and leaves a hook the user already had in place"
assert_eq "$(jq -r '.model' "$WORK/hookhome/settings.json")" "opus" \
  "and does not disturb the rest of the settings file"
# Asserted HERE, after exactly one apply. Checking it after the second apply
# counted two backups whenever the two writes landed in different seconds and
# one when they did not — a flake that failed roughly half the time and would
# have been blamed on install-hooks rather than on the assertion.
set -- "$WORK/hookhome"/settings.json.ccwatch-backup.*
assert_eq "$#" "1" "and the original was backed up before the write"
# Idempotence matters because the natural thing to do after upgrading ccwatch is
# to run it again, and a second copy of every hook would double every event.
printf 'y\n' | CLAUDE_CONFIG_DIR="$WORK/hookhome" CCWATCH_HOME="$WORK/ccwatch-events" \
  NO_COLOR=1 "$CCWATCH" install-hooks >/dev/null 2>&1
assert_eq "$(jq -r '[.hooks[][].hooks[].command] | map(select(contains("ccwatch hook"))) | length' \
  "$WORK/hookhome/settings.json")" "4" "running it twice does not install a second copy"

# --- resume: the reboot case, where the registry is no help at all ----------
# Every pid is gone, so the list has to come from transcripts. An empty ps is
# exactly what a fresh boot looks like.
: > "$WORK/ps-empty"
# A transcript has to contain its own identity, because that — not the filename
# — is what resume prints.
mkdir -p "$FH/projects/-fake-repo"
printf '{"type":"user","sessionId":"eeeeeeee-0000-0000-0000-000000000001","cwd":"%s","gitBranch":"main","isSidechain":false}\n' \
  "$WORK" > "$FH/projects/-fake-repo/eeeeeeee-0000-0000-0000-000000000001.jsonl"
_res=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-empty" CCWATCH_HOME="$WORK/ccwatch-events" \
       NO_COLOR=1 "$CCWATCH" resume 2>&1)
assert_contains "$_res" "RESUMABLE" "resume reports even with an empty registry"
assert_contains "$_res" "claude --resume eeeeeeee-0000-0000-0000-000000000001" \
  "and hands back a resume command built from the transcript, not the registry"
# stderr is checked too: the first version errored here on every invocation
# (`.[]` where `.sessions[]` was needed), and because the heading still printed
# the output looked fine while the live-exclusion list came out EMPTY.
assert_not_contains "$_res" "jq: error" "resume does not print a jq error under a heading that looks fine"

# A session that is still running must never be offered — resuming it is how you
# get two processes on one conversation. This is the assertion that would have
# caught the bug above.
mksess 9014 eeeeeeee-0000-0000-0000-000000000001 stillrunning "$WORK" busy cli
mktrans eeeeeeee-0000-0000-0000-000000000001 10
mkps 9014 "0:10.00" > "$WORK/ps-alive"
_res2=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-alive" CCWATCH_HOME="$WORK/ccwatch-events" \
        NO_COLOR=1 "$CCWATCH" resume 2>&1)
assert_not_contains "$_res2" "claude --resume eeeeeeee-0000-0000-0000-000000000001" \
  "a session that is still running is NOT offered for resume"
rm -f "$FH/sessions/9014.json"

# A subagent transcript is not a conversation you can reopen. These live one
# level deeper and are named for the TASK, so recursing into them produced
# `claude --resume agent-a9cec8c7fe67e1238` — a command that cannot work. There
# were 131 of them on the machine this was found on, crowding out real sessions.
mkdir -p "$FH/projects/-fake-repo/eeeeeeee-0000-0000-0000-000000000001/subagents"
printf '{"type":"assistant","sessionId":"eeeeeeee-0000-0000-0000-000000000001","cwd":"%s","isSidechain":true}\n' \
  "$WORK" > "$FH/projects/-fake-repo/eeeeeeee-0000-0000-0000-000000000001/subagents/agent-deadbeef.jsonl"
_res3=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-empty" CCWATCH_HOME="$WORK/ccwatch-events" \
        NO_COLOR=1 "$CCWATCH" resume 2>&1)
assert_not_contains "$_res3" "agent-deadbeef" "a subagent transcript is not offered as a resumable session"
# Mutation check for the pair: a sidechain file placed at the depth resume DOES
# scan is still rejected, so the assertion above is about the content check and
# not only about the depth limit.
printf '{"type":"assistant","sessionId":"ffffffff-0000-0000-0000-000000000001","cwd":"%s","isSidechain":true}\n' \
  "$WORK" > "$FH/projects/-fake-repo/ffffffff-0000-0000-0000-000000000001.jsonl"
_res4=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-empty" CCWATCH_HOME="$WORK/ccwatch-events" \
        NO_COLOR=1 "$CCWATCH" resume 2>&1)
assert_not_contains "$_res4" "ffffffff-0000-0000-0000-000000000001" \
  "a sidechain at the scanned depth is rejected on its content too"
# --- FR-008–FR-010: the roster's order is the payload's own order -----------
# The roster (web/roster.js) contains no comparator (data-model.md §3, D2) —
# these assertions are on the ONE place the order is actually decided, so a
# regression there is caught before it ever reaches the panel.
printf '\nordering\n'
ORD="$WORK/ordering-repo"
mkdir -p "$ORD"

# (1) five sessions, one per severity, sort strictly descending by
# max(sev, psev).
mksess 9020 90000001-0000-0000-0000-000000000001 sev-waiting "$ORD" waiting cli needsinput
mksess 9021 90000002-0000-0000-0000-000000000001 sev-notranscript "$ORD" busy cli
mksess 9022 90000003-0000-0000-0000-000000000001 sev-busy "$ORD" busy cli
mktrans 90000003-0000-0000-0000-000000000001 30
mksess 9023 90000004-0000-0000-0000-000000000001 sev-shell "$ORD" shell cli
mktrans 90000004-0000-0000-0000-000000000001 30
mksess 9024 90000005-0000-0000-0000-000000000001 sev-idle "$ORD" idle cli
mktrans 90000005-0000-0000-0000-000000000001 30
mkps 9020 "0:30.00" >  "$WORK/ps-ord"
mkps 9021 "0:30.00" >> "$WORK/ps-ord"
mkps 9022 "0:30.00" >> "$WORK/ps-ord"
mkps 9023 "0:30.00" >> "$WORK/ps-ord"
mkps 9024 "0:30.00" >> "$WORK/ps-ord"
_ord=$(ccwatch_json "$WORK/ps-ord")
assert_eq "$(printf '%s' "$_ord" \
  | jq -r '[.sessions[] | select(.name | startswith("sev-")) | .name] | join(",")')" \
  "sev-waiting,sev-notranscript,sev-busy,sev-shell,sev-idle" \
  "sessions at severities 4, 3, 2, 1, 0 sort descending by max(sev, psev)"
rm -f "$FH/sessions/9020.json" "$FH/sessions/9021.json" "$FH/sessions/9022.json" \
      "$FH/sessions/9023.json" "$FH/sessions/9024.json"

# (2)+(3) two rows tied on max(sev, psev) — one a genuinely waiting session
# with a modest `waited`, the other an idle session whose pipeline stopped to
# ask a question and has been quiet far longer. The tie-break is the raw
# number (data-model.md §3 O1: `-(waited // quiet // 0)`), so the bigger
# number wins whichever field it came from — and a needs_input pipeline never
# rewrites the session's own token.
mksess 9025 90000006-0000-0000-0000-000000000001 tie-waited "$ORD" waiting cli needsinput
mksess 9026 90000007-0000-0000-0000-000000000001 tie-needsinput "$ORD" idle cli
mktrans 90000007-0000-0000-0000-000000000001 800
FSPEC2="$ORD/specs/002-tie/.pipeline"
mkdir -p "$FSPEC2"
cat > "$FSPEC2/state.json" <<EOF
{"version":1,"feature_dir":"$ORD/specs/002-tie","branch":"002-tie",
 "phases":{"plan":{"status":"needs_input","session_id":"90000007-0000-0000-0000-000000000001","model":"opus","cost_usd":0}}}
EOF
mkps 9025 "0:30.00" >  "$WORK/ps-tie"
mkps 9026 "0:30.00" >> "$WORK/ps-tie"
_tie=$(ccwatch_json "$WORK/ps-tie")
assert_eq "$(printf '%s' "$_tie" \
  | jq -r '[.sessions[] | select(.name | startswith("tie-")) | .name] | join(",")')" \
  "tie-needsinput,tie-waited" \
  "tied on max(sev, psev), the row with the larger waited/quiet number sorts first regardless of which field carried it"
assert_eq "$(printf '%s' "$_tie" | jq -r '.sessions[] | select(.name=="tie-needsinput") | .token')" \
  "idle" "a needs_input pipeline on an idle session sorts with the waiting rows via psev while its own token stays idle"
assert_eq "$(printf '%s' "$_tie" | jq -r '.sessions[] | select(.name=="tie-needsinput") | .psev')" \
  "4" "psev, not sev, is what pulled the idle session up to the waiting tier"
rm -f "$FH/sessions/9025.json" "$FH/sessions/9026.json"

# (4) two rows tied on every ordering field: the same order on two
# consecutive runs, not merely a plausible-looking one.
mksess 9027 90000008-0000-0000-0000-000000000001 stable-a "$ORD" idle cli
mktrans 90000008-0000-0000-0000-000000000001 30
mksess 9028 90000009-0000-0000-0000-000000000001 stable-b "$ORD" idle cli
mktrans 90000009-0000-0000-0000-000000000001 30
mkps 9027 "0:30.00" >  "$WORK/ps-stable"
mkps 9028 "0:30.00" >> "$WORK/ps-stable"
_stab_names() { printf '%s' "$(ccwatch_json "$WORK/ps-stable")" \
  | jq -r '[.sessions[] | select(.name | startswith("stable-")) | .name] | join(",")'; }
_stab1=$(_stab_names)
_stab2=$(_stab_names)
assert_eq "$_stab1" "$_stab2" \
  "two rows tied on every ordering field produce the same order across two consecutive ccwatch --json runs"
rm -f "$FH/sessions/9027.json" "$FH/sessions/9028.json"

# ============================================================== statusline ===
printf '\nusage feed\n'

# Where the usage numbers come from: Claude Code hands its statusline command a
# JSON payload that already contains rate_limits and context_window, so the
# figures are available without touching a credential. These assertions are
# about that contract.
SL_PAYLOAD='{"session_id":"aaaaaaaa-0000-0000-0000-000000000001","cwd":"/fake/repo",
  "model":{"id":"claude-opus-5","display_name":"Opus 5"},"effort":{"level":"high"},
  "cost":{"total_cost_usd":4.21},
  "context_window":{"context_window_size":1000000,"used_percentage":18.4},
  "rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":9999999999},
                 "seven_day":{"used_percentage":18.2,"resets_at":9999999999}}}'

SLH="$WORK/usage-home"
printf '%s' "$SL_PAYLOAD" | CCWATCH_HOME="$SLH" "$CCWATCH" statusline >"$WORK/sl.out" 2>&1
assert_eq "$(jq -r '.five_hour.used_percentage' "$SLH/usage.json" 2>/dev/null)" "42.7" \
  "the statusline feed records the account-wide rate limit"
assert_eq "$(jq -r '.used_percentage' "$SLH/context/aaaaaaaa-0000-0000-0000-000000000001.json" 2>/dev/null)" "18.4" \
  "and the per-session context fill, keyed by session id"
assert_contains "$(cat "$WORK/sl.out")" "5h 42%" "standalone use still prints a status line"

# Composing matters: replacing an existing statusline would make adopting
# ccwatch cost you the one you already tuned.
_sl2=$(printf '%s' "$SL_PAYLOAD" | CCWATCH_HOME="$SLH" "$CCWATCH" statusline \
       --exec "jq -r '\"MINE: \" + .model.display_name'" 2>&1)
assert_eq "$_sl2" "MINE: Opus 5" "--exec passes the payload through to an existing statusline"

# This runs on every repaint, in the critical path of the prompt. It must never
# fail, whatever it is handed.
_slrc=$(printf 'not json' | CCWATCH_HOME="$SLH" "$CCWATCH" statusline >/dev/null 2>&1; echo "rc=$?")
assert_eq "$_slrc" "rc=0" "a garbage payload does not fail the statusline"

# --- the usage header, and the ageing that keeps it honest -------------------
mksess 9101 aaaaaaaa-0000-0000-0000-000000000001 usagerow /fake/repo idle cli
mktrans aaaaaaaa-0000-0000-0000-000000000001 20
mkps 9101 "0:10.00" > "$WORK/ps-u"
_hdr=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
       NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_hdr" "5h 42%" "the table shows the account-wide usage above it"
assert_contains "$_hdr" "18%" "and the per-session context fill in its own column"

# A reading with no age is the failure this whole tool exists to avoid: a
# number presented as current when nobody knows whether it is.
jq -c '.at = 1' "$SLH/usage.json" > "$SLH/usage.tmp" && mv "$SLH/usage.tmp" "$SLH/usage.json"
_old=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
       NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_old" "not shown" \
  "a usage reading past the staleness limit has its numbers WITHHELD, not annotated"
# ⚠️ This is the assertion that matters, and it exists because of a real
# incident: a fixture left in place from an earlier session displayed 52% on
# the dashboard while the true figure was 7%. It carried an "[1h old]" note and
# was still read as current, because a percentage on screen always is. A
# monitoring tool showing a confidently wrong number is worse than one showing
# none.
assert_not_contains "$_old" "42%" "and the stale percentage itself is not rendered anywhere"
# A fresh reading is still shown, so the rule above cannot be satisfied by
# simply never displaying anything.
python3 -c "import json,time; print(json.dumps({'at':int(time.time()),'five_hour':{'used_percentage':7.0,'resets_at':int(time.time())+16200},'seven_day':{'used_percentage':3.0}}))" \
  > "$SLH/usage.json"
_fresh=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
         NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_fresh" "5h 7%" "a fresh reading is shown"
assert_not_contains "$_fresh" "not shown" "and is not withheld"
# And a context reading that has stopped being refreshed is DROPPED, not shown:
# a gauge frozen at the value it had an hour ago looks live, which is worse
# than no gauge.
jq -c '.at = 1' "$SLH/context/aaaaaaaa-0000-0000-0000-000000000001.json" > "$SLH/c.tmp" \
  && mv "$SLH/c.tmp" "$SLH/context/aaaaaaaa-0000-0000-0000-000000000001.json"
_nc=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
      NO_COLOR=1 "$CCWATCH" --json 2>/dev/null | jq -r '.sessions[0].context')
assert_eq "$_nc" "null" "a context reading that stopped being refreshed is dropped, not frozen"

# With no feed at all the header says so rather than showing nothing.
_none=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$WORK/empty-home" \
        NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_none" "install-statusline" "with no feed wired, the header says how to wire it"
rm -f "$FH/sessions/9101.json"

# ==================================================================== bar ====
printf '\nbar\n'

# `ccwatch bar` is the menu bar rendering of the same snapshot. It gets its own
# fabricated home rather than reusing $FH: by this point in the suite $FH has
# been added to and deleted from by a dozen sections, and an assertion about
# "the title with nothing wrong" cannot be written against a home whose
# contents depend on what ran before it.
BH="$WORK/bar-home"
BCH="$WORK/bar-ccwatch"
mkdir -p "$BH/sessions" "$BH/projects/-fake-repo" "$BCH"

bar_sess() { # bar_sess <pid> <sid> <name> <cwd> <status|-> <entrypoint> [waitingFor]
  local extra=""
  [ "$5" != "-" ] && extra=",\"status\":\"$5\",\"statusUpdatedAt\":$(( ($(date '+%s') - 240) * 1000 ))"
  [ -n "${7:-}" ] && extra="$extra,\"waitingFor\":$(printf '%s' "$7" | jq -Rs .)"
  cat > "$BH/sessions/$1.json" <<EOF
{"pid":$1,"sessionId":"$2","cwd":"$4","startedAt":$(( ($(date '+%s') - 3600) * 1000 )),
 "kind":"interactive","entrypoint":"$6","name":$(printf '%s' "$3" | jq -Rs .),"version":"9.9.9"$extra}
EOF
}
bar_trans() { touch -t "$(date -r "$(( $(date '+%s') - $2 ))" '+%Y%m%d%H%M.%S')" "$BH/projects/-fake-repo/$1.jsonl"; }
# A port nothing is listening on, so the dashboard item has a known state to
# assert against rather than whatever this machine happens to be running.
#
# ⚠️ Found by probing, and deliberately OUTSIDE free_port's 18000-19499 range.
# A hardcoded number is two bugs waiting: a leaked `serve` from an earlier run
# holding it turns "with no server listening" into a silent lie, and a port
# inside free_port's range can be handed to the serve section of a suite
# running alongside this one.
BAR_DEAD_PORT=""
for _bp in 17901 17902 17903 17904 17905 17906 17907 17908; do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/$_bp") 2>/dev/null; then BAR_DEAD_PORT=$_bp; break; fi
done
bar_run() { # bar_run [args...]
  CLAUDE_CONFIG_DIR="$BH" CCWATCH_FAKE_PS="$WORK/ps-bar" CCWATCH_HOME="$BCH" \
    CCWATCH_PORT="$BAR_DEAD_PORT" CCWATCH_CPU_MIN_GAP="${CPU_GAP:-0.2}" NO_COLOR=1 \
    "$CCWATCH" bar "$@" 2>/dev/null
}

bar_sess 9301 f0000001-0000-0000-0000-000000000001 hung-one   /fake/repo busy    cli
bar_sess 9302 f0000002-0000-0000-0000-000000000001 asking     /fake/repo waiting cli "permission to run rm"
bar_sess 9303 f0000003-0000-0000-0000-000000000001 quiet-idle /fake/repo idle    cli
bar_trans f0000001-0000-0000-0000-000000000001 1200
bar_trans f0000002-0000-0000-0000-000000000001 30
bar_trans f0000003-0000-0000-0000-000000000001 30
mkps 9301 "1:00.00" >  "$WORK/ps-bar"
mkps 9302 "1:00.00" >> "$WORK/ps-bar"
mkps 9303 "1:00.00" >> "$WORK/ps-bar"

_bar=$(bar_run)
_bartitle=$(bar_run --title)

# ⚠️ Every condition found reaches the title, not just the loudest one. The
# title is the only surface visible without a click, so a condition left out
# of it is absent — and an absence reads as "nothing wrong", which is the
# failure constitution IV is about. Mutation check: making the title carry
# only the highest severity drops "1 suspect" and this fails.
assert_contains "$_bartitle" "1 waiting" "the title states the sessions blocked on you"
assert_contains "$_bartitle" "1 suspect" "and states the suspect one in the same breath"
assert_contains "$_bartitle" "cc 3" "alongside the live count"

# A menu bar title is one line by construction. A second line would be
# swallowed by the plugin host and become the first dropdown item.
#
# ⚠️ Counted with awk on the unterminated string, not `printf '%s\n' | wc -l`.
# That form appends the newline it is about to count, so it reports 1 for an
# empty title and the assertion passes against a `bar` that printed nothing at
# all — which is how it was first written, and it stayed green through a whole
# run where every other assertion in this section was failing on empty output.
assert_eq "$(printf '%s' "$_bartitle" | awk 'END{print NR}')" "1" \
  "the title is a single line, and there is one"

# Rule 2, in the place it matters most: the menu is read at a glance, so a
# verdict with no measurement beside it is asking to be taken on trust.
assert_contains "$_bar" "HUNG?" "a suspect session is named with its own word in the dropdown"
assert_contains "$_bar" "quiet 20m" "and the silence that produced that verdict is printed with it"

# ⚠️ The glyph is the one thing the menu renders from `sev` itself rather than
# taking verbatim, so it is the one place two renderers of one payload can
# drift apart — the table maps sev to a glyph in awk and the menu does it in
# jq, and nothing but this connects the two copies. The claim under test is
# not "the menu has a glyph", it is "it is the SAME glyph the table printed for
# that same session". With NO_COLOR the table's fields are name, project,
# glyph, token; the menu's are glyph first.
bar_glyph_table() { # bar_glyph_table <name>
  CLAUDE_CONFIG_DIR="$BH" CCWATCH_FAKE_PS="$WORK/ps-bar" CCWATCH_HOME="$BCH" \
    CCWATCH_CPU_MIN_GAP="${CPU_GAP:-0.2}" NO_COLOR=1 "$CCWATCH" once 2>/dev/null \
    | awk -v n="$1" '$1 == n { print $3 }'
}
for _bn in asking hung-one quiet-idle; do
  _bgt=$(bar_glyph_table "$_bn")
  _bgm=$(printf '%s\n' "$_bar" | awk -v n="$_bn" '$2 == n { print $1 }')
  # Both empty would be two renderers agreeing about nothing, so the glyph has
  # to have been found before it can be compared.
  if [ -z "$_bgt" ]; then
    t_fail "the menu and the table print the same glyph for $_bn" \
           "the table printed no row for $_bn"
  else
    assert_eq "$_bgm" "$_bgt" "the menu and the table print the same glyph for $_bn"
  fi
done

# ⚠️ Nothing may be put behind a submenu. The format offers them and they would
# tidy the list, but a submenu is a collapsed badge: it turns a crashed phase
# into something you have to hover to find, which is the same failure-as-absence
# the pages' alert control exists to avoid. `--` is the submenu prefix; `---` is
# a separator and is fine.
assert_eq "$(printf '%s\n' "$_bar" | grep -c '^--[^-]' || true)" "0" \
  "no dropdown line is hidden behind a submenu"

# ⚠️ Security control, not tidying. A bare pipe opens the plugin format's
# parameter list, and `bash=` is one of the parameters it accepts — so a
# session name carrying one would put a CLICKABLE COMMAND in the menu. The
# fixture name is the attack, not a lookalike: it is exactly what a menu line
# would need to gain a shell.
bar_sess 9304 f0000004-0000-0000-0000-000000000001 "evil | bash=/bin/sh param1=-c" /fake/repo idle cli
bar_trans f0000004-0000-0000-0000-000000000001 30
mkps 9304 "1:00.00" >> "$WORK/ps-bar"
_barinj=$(bar_run)
assert_not_contains "$_barinj" "| bash=/bin/sh" \
  "a pipe in a session name cannot open the parameter list"
assert_contains "$_barinj" "evil ¦ bash=/bin/sh" \
  "and the name is still shown, as the name it actually is"
# The structural form of the same claim: the line carries exactly one
# parameter separator, the one ccwatch put there itself.
assert_eq "$(printf '%s\n' "$_barinj" | grep 'evil' | grep -o ' | ' | wc -l | tr -d ' ')" "1" \
  "the row has exactly one parameter separator, ccwatch's own"

# The note travels the same path and is just as attacker-shaped: `waitingFor`
# is whatever the session put there.
bar_sess 9305 f0000005-0000-0000-0000-000000000001 notey /fake/repo waiting cli \
  'ok | bash="/usr/bin/open" param1=http://example.invalid terminal=false'
bar_trans f0000005-0000-0000-0000-000000000001 30
mkps 9305 "1:00.00" >> "$WORK/ps-bar"
_barnote=$(bar_run)
assert_not_contains "$_barnote" '| bash="/usr/bin/open"' \
  "a pipe in a waitingFor note cannot open the parameter list either"
rm -f "$BH/sessions/9304.json" "$BH/sessions/9305.json"

# --- normal conditions are silent -------------------------------------------
# ⚠️ The title with nothing wrong is the live count and nothing else. A menu
# bar item that always has something to say is one you stop reading, and then
# it is not saying anything when it matters. Mutation check: appending an "ok"
# clause, or an sfimage on the quiet path, fails both of these.
rm -f "$BH/sessions/9301.json" "$BH/sessions/9302.json"
_barquiet=$(bar_run --title)
assert_eq "$_barquiet" "cc 1" "with nothing wrong the title is the count alone"
assert_not_contains "$(bar_run | head -1)" "sfimage" \
  "and carries no icon either — absent below the threshold, not a green one"

# --- the dashboard item tells the truth about the dashboard ------------------
# A link to a server nobody is running is a failure dressed as a working
# feature, and it stays dressed as one until somebody clicks it.
# ⚠️ `${FAST:-0}`, not `$FAST`. This is the only part of the section that binds
# a port and waits on real time, so it is the only part a --fast mode would
# want to drop — but the flag is not in this file yet, and under `set -u` a
# bare `$FAST` would make this section explode for everyone until it is. The
# default reads as "not fast" and the gate starts working the day the flag
# lands, with nothing to remember.
if [ "${FAST:-0}" -eq 1 ]; then
  t_skip "the dashboard item tells the truth about the dashboard" \
         "--fast: binds a port and waits for it"
elif [ -z "$BAR_DEAD_PORT" ]; then
  t_skip "the dashboard item tells the truth about the dashboard" \
         "no free port in 17901-17908 to probe with"
else
  assert_contains "$(bar_run)" "Start dashboard" \
    "with no server listening the menu offers to start one"
  assert_not_contains "$(bar_run)" "Open dashboard" \
    "and does not offer a link that would fail"
  # ⚠️ The other branch, because a check that has only ever seen one answer has
  # not been tested. Without this, "always print Start dashboard" satisfies the
  # assertion above and is counted as coverage it is not.
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $BAR_DEAD_PORT))
s.listen(5)
time.sleep(20)
" &
  _barlistener=$!
  # Polled inline rather than through a helper, so this section depends on
  # nothing outside itself. 50 ticks of 100ms: a local bind that has not
  # answered in five seconds is not going to.
  _barticks=50
  while [ "$_barticks" -gt 0 ]; do
    (exec 3<>"/dev/tcp/127.0.0.1/$BAR_DEAD_PORT") 2>/dev/null && break
    sleep 0.1
    _barticks=$((_barticks - 1))
  done
  if [ "$_barticks" -gt 0 ]; then
    _barup=$(bar_run)
    assert_contains "$_barup" "Open dashboard" \
      "with a server listening the menu links to it instead"
    assert_not_contains "$_barup" "Start dashboard" \
      "and does not offer to start a second one"
  else
    t_skip "the menu links to a running dashboard" "could not bind $BAR_DEAD_PORT"
  fi
  # Reaped here rather than left to the 20s sleep: a listener outliving its
  # assertion holds a port the next section may probe.
  kill "$_barlistener" 2>/dev/null
  wait "$_barlistener" 2>/dev/null
fi

# --- usage, under the same rule as everywhere else --------------------------
# A percentage in a menu bar is read as current even harder than one on a page:
# it sits there between glances with nothing around it to date it.
python3 -c "import json,time; print(json.dumps({'at':int(time.time()),'five_hour':{'used_percentage':42.0},'seven_day':{'used_percentage':3.0}}))" \
  > "$BCH/usage.json"
assert_contains "$(bar_run)" "5h 42%" "a fresh usage reading is shown in the dropdown"
jq -c '.at = 1' "$BCH/usage.json" > "$BCH/u.tmp" && mv "$BCH/u.tmp" "$BCH/usage.json"
_barstale=$(bar_run)
assert_contains "$_barstale" "not shown" \
  "a stale one has its numbers withheld, not annotated"
assert_not_contains "$_barstale" "42%" "and the stale percentage reaches the menu nowhere"
rm -f "$BCH/usage.json"

# --- a failure must not look like an absence --------------------------------
# ⚠️ The menu bar is where this is hardest to see: a quiet machine and a blind
# tool both look equally calm up there, with no surrounding page to carry the
# reason. The failure is injected the way the send section does it — a jq shim
# that fails only for the final join, which is what an OOM-killed collector
# does.
_barjq=$(command -v jq)
if [ -n "$_barjq" ]; then
  mkdir -p "$WORK/bar-shim"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do [ "$a" = "swap_warn" ] && exit 1; done\n'
    printf 'exec %s "$@"\n' "$_barjq"
  } > "$WORK/bar-shim/jq"
  chmod +x "$WORK/bar-shim/jq"
  _barfail=$(CLAUDE_CONFIG_DIR="$BH" CCWATCH_FAKE_PS="$WORK/ps-bar" CCWATCH_HOME="$BCH" \
             CCWATCH_PORT="$BAR_DEAD_PORT" PATH="$WORK/bar-shim:$PATH" NO_COLOR=1 \
             "$CCWATCH" bar 2>/dev/null)
  assert_contains "$_barfail" "cc ?" "a snapshot that failed renders a reading nobody counts"
  assert_not_contains "$_barfail" "cc 0" \
    "and never the number zero, which would read as a calm machine"
  assert_contains "$_barfail" "snapshot itself failed" \
    "the dropdown says which of the two it is"
  _barfailtitle=$(CLAUDE_CONFIG_DIR="$BH" CCWATCH_FAKE_PS="$WORK/ps-bar" CCWATCH_HOME="$BCH" \
                  CCWATCH_PORT="$BAR_DEAD_PORT" PATH="$WORK/bar-shim:$PATH" NO_COLOR=1 \
                  "$CCWATCH" bar --title 2>/dev/null)
  assert_eq "$_barfailtitle" "cc ?" "and --title says the same thing, with no parameters on it"
  rm -rf "$WORK/bar-shim"
else
  t_skip "a failed snapshot does not render as a calm menu bar" "no jq on PATH to shim"
fi

# An unreadable registry file is one row lost, and it is counted — so the menu
# is the fifth consumer of parse_failed and must not be the one that drops it.
#
# ⚠️ The title claim is asserted against `--title`, not against the whole
# document. Written the obvious way it read "1 unreadable" out of the summary
# LINE and passed with the title clause deleted — the mutation went through
# green, which is a test defect counted as coverage. The two surfaces make two
# separate claims and need two separate assertions.
printf '{"pid":9306,"cwd":' > "$BH/sessions/9306.json"   # truncated mid-write
mkps 9306 "1:00.00" >> "$WORK/ps-bar"
_barbad=$(bar_run)
assert_contains "$(bar_run --title)" "1 unreadable" \
  "an unreadable registry file reaches the menu bar title itself"
assert_contains "$_barbad" "unreadable registry file" \
  "and the dropdown states it as a sentence"
assert_contains "$_barbad" "ccwatch doctor" "with where to look"
rm -f "$BH/sessions/9306.json"

# --- a crashed run, which no live session reports for itself ----------------
# The session is honestly idle while the run it drove has crashed. Both claims
# have to be legible, and the crashed one may not be the one behind a hover.
BSPEC="$WORK/bar-repo/specs/002-thing/.pipeline"
mkdir -p "$BSPEC"
cat > "$BSPEC/state.json" <<EOF
{"version":1,"feature_dir":"$WORK/bar-repo/specs/002-thing","branch":"002-thing",
 "phases":{"plan":{"status":"running","session_id":"f0000006-0000-0000-0000-000000000001",
                   "model":"opus","cost_usd":1.25,"runner_pid":9399,
                   "started_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}}}
EOF
bar_sess 9307 f0000006-0000-0000-0000-000000000001 runner "$WORK/bar-repo" idle cli
bar_trans f0000006-0000-0000-0000-000000000001 30
mkps 9307 "1:00.00" >> "$WORK/ps-bar"   # 9399, the runner, is deliberately absent
_barcrash=$(bar_run)
assert_contains "$_barcrash" "plan/CRASHED" "a run whose runner is gone is reported as crashed"
assert_contains "$_barcrash" "needs a rerun" "with what to do about it"
assert_eq "$(printf '%s\n' "$_barcrash" | grep -c '^--[^-]' || true)" "0" \
  "and it is a visible line, not a submenu item somebody has to hover to find"
rm -f "$BH/sessions/9307.json"

# --- an empty machine says so ----------------------------------------------
# Distinct from the failure above, and the dropdown has to read differently.
rm -f "$BH/sessions"/*.json
_barempty=$(bar_run)
assert_contains "$_barempty" "No live Claude Code sessions" \
  "an empty machine says so rather than showing an empty menu"
assert_contains "$_barempty" "ccwatch resume" "and points at what rebuilds the list"

# --- the plugin, on the path where ccwatch never gets to speak ---------------
# ⚠️ The plugin deliberately does not `exec` into ccwatch. `need jq` exits
# before printing anything, and the plugin host renders stdout — so an exec
# would leave a blank menu bar item with nothing under it, which reads exactly
# like a machine with nothing running. The stub here is the failure: it writes
# a diagnosis to stderr and exits non-zero, the way `die` does.
BPLUG="$ROOT/extra/swiftbar/ccwatch.10s.sh"
printf '#!/bin/sh\nprintf "ccwatch needs jq on PATH\\n" >&2\nexit 1\n' > "$WORK/bar-dead"
chmod +x "$WORK/bar-dead"
_bplug=$(CCWATCH_BIN="$WORK/bar-dead" bash "$BPLUG" 2>&1)
assert_contains "$_bplug" "produced no output" \
  "a ccwatch that died before printing is reported, not passed through as a blank item"
assert_contains "$_bplug" "ccwatch needs jq on PATH" \
  "and its own diagnosis is carried into the menu"
# The stderr text is not ccwatch's to trust either — it ends up on a menu line
# like any other field, so it goes through the same pipe strip.
printf '#!/bin/sh\nprintf "boom | bash=/bin/sh param1=-c\\n" >&2\nexit 1\n' > "$WORK/bar-inj"
chmod +x "$WORK/bar-inj"
assert_not_contains "$(CCWATCH_BIN="$WORK/bar-inj" bash "$BPLUG" 2>&1)" "| bash=/bin/sh" \
  "a pipe in that diagnosis cannot open the parameter list either"
# And the pass-through, so none of the above is satisfied by a plugin that
# always reports a failure.
printf '#!/bin/sh\nprintf "cc 2\\n---\\nfine\\n"\n' > "$WORK/bar-ok"
chmod +x "$WORK/bar-ok"
_bplugok=$(CCWATCH_BIN="$WORK/bar-ok" bash "$BPLUG" 2>&1)
assert_eq "$_bplugok" "cc 2
---
fine" "and a ccwatch that printed is passed through verbatim, with nothing added"

# =================================================================== send ====
printf '\nsend\n'

# Injecting into a session that is already running, rather than resuming a copy
# of its conversation. Claude Code exports CLAUDE_CODE_MESSAGING_SOCKET and
# _TOKEN into every tool call, and documents the wire format in its own debug
# log, so this is an interface it offers rather than one prised open.
mksess 9102 aaaaaaaa-0000-0000-0000-000000000002 target-a /fake/repo idle cli
mktrans aaaaaaaa-0000-0000-0000-000000000002 20
mkps 9102 "0:10.00" > "$WORK/ps-s2"
# The messaging token lives beside the registry entry as <pid>.<hash>.key.
printf '{"peerToken":"SECRETTOKENVALUE","pidDomain":"darwin","procStart":"x"}\n' \
  > "$FH/sessions/9102.deadbeef.key"
_dry=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-s2" CCWATCH_HOME="$SLH" \
       NO_COLOR=1 "$CCWATCH" send --dry-run target-a "hello there" 2>&1)
assert_contains "$_dry" '"content":"hello there"' "dry-run shows the exact frame that would be sent"
assert_contains "$_dry" '"from":"ccwatch"' \
  "the frame declares its sender, so an injected message is attributable in the receiver"
# The token is a live credential. Printing it would put it in whatever
# scrollback or CI log this ran in.
assert_contains "$_dry" "<redacted>" "and the auth token is redacted, not printed"
assert_not_contains "$_dry" "SECRETTOKENVALUE" "no token material reaches the output"

# Sending to the wrong agent cannot be undone by the tool: it has already been
# said. So an ambiguous target is refused rather than resolved by picking one.
mksess 9103 aaaaaaaa-0000-0000-0000-000000000003 target-a /fake/other idle cli
mktrans aaaaaaaa-0000-0000-0000-000000000003 20
mkps 9103 "0:10.00" >> "$WORK/ps-s2"
_amb=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-s2" CCWATCH_HOME="$SLH" \
       NO_COLOR=1 "$CCWATCH" send --dry-run target-a "hi" 2>&1; echo "rc=$?")
assert_contains "$_amb" "matches 2 live sessions" "an ambiguous target is refused, not guessed at"
assert_contains "$_amb" "rc=1" "and refusing is a failure, not a silent no-op"
rm -f "$FH/sessions/9103.json"

_gone=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-s2" CCWATCH_HOME="$SLH" \
        NO_COLOR=1 "$CCWATCH" send nonexistent-name "hi" 2>&1; echo "rc=$?")
assert_contains "$_gone" "no live session matches" "an unknown target is named, not ignored"
assert_contains "$_gone" "rc=1" "and is a failure"

# ⚠️ A snapshot that FAILED must not be reported as an ambiguous name match.
# Before this, an empty snapshot gave an empty match list, `jq length` printed
# nothing, `$n` was the empty string, and the `case` fell through to its
# ambiguity arm — so the tool said "'<pid>' matches  live sessions — be
# specific:" with a blank where the count belongs and nothing listed after it.
# Seen for real on a host that had run out of memory: of eight kills, five were
# refused with a message describing a completely different problem.
#
# The failure is injected with a `jq` shim that fails only for the final join
# (identified by an argument name unique to it), because that is what an
# OOM-killed collector does — returns nothing, mid-pipeline.
_realjq=$(command -v jq)
if [ -n "$_realjq" ]; then
  mkdir -p "$WORK/shim"
  {
    printf '#!/bin/sh\n'
    printf 'for a in "$@"; do [ "$a" = "swap_warn" ] && exit 1; done\n'
    printf 'exec %s "$@"\n' "$_realjq"
  } > "$WORK/shim/jq"
  chmod +x "$WORK/shim/jq"
  _snapfail=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-s2" CCWATCH_HOME="$SLH" \
              PATH="$WORK/shim:$PATH" NO_COLOR=1 \
              "$CCWATCH" send target-b "hi" 2>&1; echo "rc=$?")
  assert_contains "$_snapfail" "produced no usable JSON" \
    "a snapshot that failed says so, naming the stage that produced nothing"
  assert_not_contains "$_snapfail" "matches  live sessions" \
    "and never reports a failed snapshot as an ambiguous match with a blank count"
  assert_contains "$_snapfail" "rc=1" "and refusing is a failure, not a silent no-op"
  rm -rf "$WORK/shim"
else
  t_skip "a snapshot that failed says so" "no jq on PATH to shim"
fi

# ⚠️ The other direction of the same mistake. A collector may legitimately
# return `null` — `collect_usage` does whenever no statusline has ever
# reported, which is most machines. The guard must accept that. Checking with
# `jq -e .` instead of `jq empty` looks equivalent and is not: `-e` exits 1 for
# `null` and `false`, so the first version of the guard reported
# "collect_usage produced no usable JSON" on any host without a usage feed,
# turning a normal condition into a failure (constitution XII).
mkdir -p "$WORK/nofeed-cfg"
_nofeed=$(CLAUDE_CONFIG_DIR="$WORK/nofeed-cfg" CCWATCH_HOME="$WORK/nofeed-home" \
          CCWATCH_FAKE_PS="$WORK/ps-s2" NO_COLOR=1 "$CCWATCH" --json 2>&1)
assert_not_contains "$_nofeed" "produced no usable JSON" \
  "a collector that legitimately returns null is not reported as having failed"

rm -f "$FH/sessions/9102.json"

# ================================================================ deploys ====
printf '\ndeploys\n'

# gh is a network call, so the cache is the seam: these assertions are about the
# filtering, which is the part with judgement in it.
DH="$WORK/deploy-home"; mkdir -p "$DH"
_now=$(date '+%s')
python3 - "$_now" > "$DH/deploys.json" <<'PYEOF'
import json, sys, time
now = int(sys.argv[1])
def ts(off): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - off))
print(json.dumps({"at": now, "age": 0, "runs": [
 {"databaseId":1,"workflowName":"Deploy to staging","status":"in_progress","conclusion":None,
  "headBranch":"main","createdAt":ts(300),"updatedAt":ts(300),"url":"u1","event":"push",
  "repo":"acme/web"},
 {"databaseId":2,"workflowName":"deploy-production","status":"completed","conclusion":"failure",
  "headBranch":"main","createdAt":ts(4000),"updatedAt":ts(3600),"url":"u2","event":"push",
  "repo":"acme/api"},
 {"databaseId":3,"workflowName":"deploy-production","status":"completed","conclusion":"success",
  "headBranch":"main","createdAt":ts(200000),"updatedAt":ts(199000),"url":"u3","event":"push",
  "repo":"acme/api"},
 {"databaseId":4,"workflowName":"CI","status":"completed","conclusion":"failure",
  "headBranch":"main","createdAt":ts(200),"updatedAt":ts(100),"url":"u4","event":"push",
  "repo":"acme/api"},
]}))
PYEOF
mksess 9104 aaaaaaaa-0000-0000-0000-000000000004 deployrow /fake/repo idle cli
mktrans aaaaaaaa-0000-0000-0000-000000000004 20
mkps 9104 "0:10.00" > "$WORK/ps-d"
dep() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-d" CCWATCH_HOME="$DH" \
        CCWATCH_DEPLOY_TTL=999999 NO_COLOR=1 "$CCWATCH" deploys "$@" 2>/dev/null; }
_dj=$(dep --json)
assert_eq "$(printf '%s' "$_dj" | jq -r '[.runs[].databaseId] | sort | map(tostring) | join(",")')" "1,2" \
  "an in-flight deploy and a recently-failed one are reported"
assert_not_contains "$(printf '%s' "$_dj" | jq -c '[.runs[].databaseId]')" "3" \
  "a deploy that succeeded two days ago is not something you are waiting on"
assert_not_contains "$(printf '%s' "$_dj" | jq -c '[.runs[].workflowName]')" "CI" \
  "a CI run on every push is not a deploy"
assert_eq "$(printf '%s' "$_dj" | jq -r '.runs[0].live')" "true" \
  "the in-flight one sorts first, because it is the one still to land"
assert_contains "$(dep)" "RUNNING" "the table names the state in words, not only in colour"

# A failed lookup and an empty deploy list must not look the same.
printf '{"at":%s,"age":0,"runs":[],"error":"gh failed: HTTP 401: Bad credentials"}' "$_now" >"$DH/deploys.json"
assert_contains "$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-d" CCWATCH_HOME="$DH" \
  CCWATCH_DEPLOY_TTL=999999 NO_COLOR=1 "$CCWATCH" deploys 2>&1)" "401" \
  "a gh failure is surfaced with its actual reason, not reported as 'no deploys'"

# --------------------------------------------------- subscriptions -----------
printf '\nsubscriptions\n'

# The answer to "can the agents subscribe": they can, and they do it
# themselves. Claude Code puts the session id in the environment of every tool
# call, so an agent needs no arguments beyond the pattern.
_sub=$(cd "$WORK" && CLAUDE_CONFIG_DIR="$FH" CCWATCH_HOME="$DH" NO_COLOR=1 \
       CLAUDE_CODE_SESSION_ID=aaaaaaaa-0000-0000-0000-000000000004 \
       "$CCWATCH" subscribe deploy-production 2>&1)
assert_contains "$_sub" "subscribed aaaaaaaa" \
  "an agent subscribes itself using the session id Claude Code exports to it"
assert_eq "$(jq -r '.session_id' "$DH/subscriptions.jsonl" | head -1)" \
  "aaaaaaaa-0000-0000-0000-000000000004" "and the subscription is recorded against that session"
assert_contains "$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-d" CCWATCH_HOME="$DH" \
  NO_COLOR=1 "$CCWATCH" subs 2>&1)" "deployrow" \
  "subs resolves a subscription to the session name you know it by"

# The de-duplication is what makes the feature usable rather than a machine for
# telling an agent the same thing every 60 seconds.
python3 - "$_now" > "$DH/deploys.json" <<'PYEOF'
import json, sys, time
now = int(sys.argv[1])
def ts(off): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - off))
print(json.dumps({"at": now, "age": 0, "runs": [
 {"databaseId":77,"workflowName":"deploy-production","status":"completed","conclusion":"failure",
  "headBranch":"main","createdAt":ts(400),"updatedAt":ts(300),"url":"u77","event":"push",
  "repo":"acme/api"}]}))
PYEOF
rm -f "$DH/deploys-seen.json"
tick() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-d" CCWATCH_HOME="$DH" \
         CCWATCH_DEPLOY_TTL=999999 CCWATCH_SEND_VERIFY=1 NO_COLOR=1 "$CCWATCH" tick 2>&1; }
_t1=$(tick)
assert_eq "$(jq -r 'keys | length' "$DH/deploys-seen.json" 2>/dev/null)" "1" \
  "a concluded deploy matching a subscription is marked as notified"
assert_contains "$(jq -r 'keys[0]' "$DH/deploys-seen.json")" "77" \
  "keyed by subscriber AND run, so two subscribers each get told once"
_t2=$(tick)
assert_not_contains "$_t2" "notify" \
  "a second tick does not even attempt to tell the same session again"
# And the seen file is what gates it, not luck: clear the entry and the next
# tick tries again. Without this pair, the assertion above would also pass
# against an implementation that had simply stopped working.
printf '{}' > "$DH/deploys-seen.json"
_t3=$(tick; echo "rc=$?")
assert_contains "$_t3" "notify" "clearing the seen record makes it try again"
# The property that matters for a watcher meant to run unattended: a subscriber
# it cannot reach must not take the daemon down with it. cmd_send uses `die`,
# and `die` in an `if` condition exits the whole process — so this ran the
# daemon into the ground on its first unreachable session.
assert_contains "$_t3" "rc=0" "a subscriber that cannot be reached does not kill the daemon"

# A subscription whose session has exited must be dropped, not retried forever.
_unsub=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_HOME="$DH" NO_COLOR=1 \
         "$CCWATCH" unsubscribe aaaaaaaa-0000-0000-0000-000000000004 2>&1)
assert_contains "$_unsub" "unsubscribed" "a subscription can be removed"
assert_eq "$(wc -l <"$DH/subscriptions.jsonl" | tr -d ' ')" "0" "and is actually gone from the file"
rm -f "$FH/sessions/9104.json"

# ================================================================== peers ====
printf '\npeers\n'

# A message from another session is recorded in the RECEIVER's transcript as a
# user entry with origin.kind == "peer". That is the only place it is written,
# which is why the graph is built by scanning transcripts: it works
# retrospectively and it survives a reboot.
PH="$FH/projects/-peer-repo"; mkdir -p "$PH"
mkpeer() { # mkpeer <to-sid> <from-name> <from-pid> <text>
  printf '{"type":"user","sessionId":"%s","cwd":"/fake/repo","timestamp":"2026-09-07T12:00:00Z",' "$1" >>"$PH/$1.jsonl"
  printf '"origin":{"kind":"peer","from":"%s","verifiedPeerPid":%s},' "$2" "$3" >>"$PH/$1.jsonl"
  printf '"message":{"role":"user","content":"%s"}}\n' "$4" >>"$PH/$1.jsonl"
}
mksess 9105 pppppppp-0000-0000-0000-000000000001 talker-a /fake/repo idle cli
mksess 9106 pppppppp-0000-0000-0000-000000000002 talker-b /fake/repo idle cli
mkps 9105 "0:10.00" >  "$WORK/ps-p2"
mkps 9106 "0:10.00" >> "$WORK/ps-p2"
mkpeer pppppppp-0000-0000-0000-000000000002 unknown 9105 "first"
mkpeer pppppppp-0000-0000-0000-000000000002 unknown 9105 "second"
mkpeer pppppppp-0000-0000-0000-000000000001 unknown 9106 "reply"
peers() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-p2" CCWATCH_HOME="$DH" \
          NO_COLOR=1 "$CCWATCH" peers "$@" 2>/dev/null; }
_pj=$(peers --days 1 --json)
assert_eq "$(printf '%s' "$_pj" | jq '.messages')" "3" "every peer message is counted"
assert_eq "$(printf '%s' "$_pj" | jq -r '[.edges[] | select(.from=="talker-a" and .to=="talker-b")] | .[0].count')" "2" \
  "messages are grouped into a directed edge with a count"
assert_eq "$(printf '%s' "$_pj" | jq '.edges | length')" "2" \
  "and the reverse direction is a separate edge, not folded into the first"
# The pid the server verified from the socket credentials is preferred over the
# name the sender merely asserted.
mkpeer pppppppp-0000-0000-0000-000000000001 "i-am-someone-else" 9106 "spoofed"
assert_eq "$(peers --days 1 --json | jq -r '[.edges[] | select(.to=="talker-a")] | length')" "1" \
  "a declared sender name does not create a second edge when the verified pid says otherwise"
assert_not_contains "$(peers --days 1 --json)" "i-am-someone-else" \
  "the verified pid wins over the name the frame asserted"
# The terminal and --json must not derive the graph separately.
assert_contains "$(peers --days 1)" "talker-a" "the table renders the same graph"
rm -f "$FH/sessions/9105.json" "$FH/sessions/9106.json"

# A subagent transcript is not a session, and its messages are not peer traffic
# between sessions.
mkdir -p "$PH/pppppppp-0000-0000-0000-000000000001/subagents"
cp "$PH/pppppppp-0000-0000-0000-000000000001.jsonl" \
   "$PH/pppppppp-0000-0000-0000-000000000001/subagents/agent-xyz.jsonl"
assert_eq "$(peers --days 1 --json | jq '.messages')" "4" \
  "a subagent transcript one level deeper is not counted as peer traffic"

# ================================================================== serve ====
printf '\nserve\n'

# FR-020-FR-022: no animation loop, and every periodic thing on a page routes
# through exactly one setInterval — the shared visibility-aware scheduler.
# This is a static, no-browser-needed guard for a property no other assertion
# here can check.
for _pf in "$ROOT/web/index.html" "$ROOT/web/map.html"; do
  assert_eq "$(grep -c requestAnimationFrame "$_pf")" "0" \
    "$_pf has no animation-frame loop"
  assert_eq "$(grep -c 'setInterval(' "$_pf")" "1" \
    "$_pf has exactly one setInterval — the shared scheduler"
  _pfvc=$(grep -c visibilitychange "$_pf")
  assert_eq "$(awk -v n="$_pfvc" 'BEGIN{print (n >= 1) ? "yes" : "no"}')" "yes" \
    "$_pf listens for visibilitychange"
done

_maphtml=$(cat "$ROOT/web/map.html")

# FR-018: the board must be reachable by keyboard, and it is reachable the way
# every other scroll container in the browser is — a focusable overflow box
# scrolls on the arrow keys, PageUp/PageDown and Home/End with no script at
# all. So what is asserted is the tabindex that makes it focusable, and a
# non-empty aria-label. The old label had to recite a hand-written keymap
# ("Arrow keys pan, plus and minus zoom, zero fits"); there is no keymap to
# recite now, and a label that explains scrolling to a screen-reader user is
# explaining their own scroll container to them.
_board_tag=$(awk '/<div id="board"/{f=1} f{print; if(/>/){exit}}' "$ROOT/web/map.html")
assert_contains "$_board_tag" 'tabindex="0"' "#board carries tabindex=\"0\""
assert_contains "$_board_tag" 'aria-label="' "#board carries a non-empty aria-label"

# ⚠️ The scroll container must be the BOARD, not the page. `body` is
# overflow:hidden and the page is a flex column, so a #board that forgets
# `overflow-y:auto` does not grow a scrollbar of its own — it clips, and every
# territory below the fold becomes unreachable with no indication that it is
# there. That is the failure this whole view was built to end, so the rule is
# pinned rather than left to be noticed.
_board_rule=$(printf '%s' "$_maphtml" | awk '/^  #board \{/{f=1} f{print; if (/\}/) exit}')
assert_contains "$_board_rule" 'overflow:auto' "#board scrolls"
# min-height:0 on the scroll container itself is belt-and-braces, and is
# recorded as such rather than credited with more than it does: removing it
# alone did NOT reproduce a page scroll in verify-ui. The one that is
# load-bearing is #stage's, asserted below — removing THAT reddens
# "the page itself does not scroll". Stating which of two similar declarations
# was actually measured is the difference between a comment and a guess.
assert_contains "$_board_rule" 'min-height:0' \
  "and #board carries min-height:0 so a flex child that scrolls can shrink"
# ⚠️ Not overflow-x:hidden. Clipped content is unreachable at every scroll
# position, which is a failure presenting as an absence; a scrollbar is the
# same bug made visible. And the hidden form cannot even be tested for: an
# overflow:hidden box still reports scrollHeight past clientHeight and still
# moves under scrollTop, so a "does it overflow / does it scroll" check passes
# against it either way. Both of those checks were written, were green, and
# could not fail — see the mutation table.
assert_not_contains "$_board_rule" 'overflow-x:hidden' \
  "and does not clip sideways, which would hide content at every scroll position"

# The overlay is positioned against #boardinner, so #boardinner must establish
# the containing block. Without position:relative the wires are positioned
# against the nearest positioned ancestor instead and every one of them is
# offset by however far the board has been scrolled.
_inner_rule=$(printf '%s' "$_maphtml" | grep -E '^\s*#boardinner \{' | head -1)
assert_contains "$_inner_rule" 'position:relative' \
  "#boardinner is the positioned ancestor the wire overlay is measured against"

# FR-016, FR-047: the map key is a real, focusable, named button — not a div
# with a click handler, which a screen reader and Tab both skip. One now: the
# zoom-out/zoom-in/fit trio went with the camera, since the browser's own
# scrollbar is the position indicator and there is no zoom to be at.
_keybtn_js=$(awk '/^const keyBtn = document.createElement/,/appendChild\(keyBtn\)/' "$ROOT/web/map.html")
assert_eq "$(printf '%s' "$_keybtn_js" | grep -c 'createElement("button")')" "1" \
  "the map key is built from one real <button> element"
# A control whose only label is a glyph ("?") is a control nobody can identify.
assert_contains "$_keybtn_js" 'setAttribute("aria-label"' \
  "and the glyph-only control is named by aria-label"
# ⚠️ And it is in the HEADER, not floating over the board. It inherited the
# retired camera cluster's `position:absolute; bottom:1.6rem`, and once the
# board scrolled under it, it covered whatever sat at the bottom-left — two
# `implement/CRASHED` badges, measured. A control that floats over a scroll
# container has to earn it, and a help button in a fixed place does not.
assert_contains "$_keybtn_js" 'querySelector("header nav").appendChild' \
  "and it is docked in the header, where it cannot overlap the board"
assert_eq "$(grep -c 'boardctl' "$ROOT/web/map.html")" "0" \
  "and no floating control layer is left over the board"

# ⚠️ No level-of-detail rule may come back. The camera hid buildings, zones,
# agents and labels below a zoom threshold, and that is how it shipped a
# default view with display:none on every figure on the page. Nothing in this
# stylesheet may hide a session at any window size.
assert_eq "$(printf '%s' "$_maphtml" | grep -cE '^\s*#[a-z]+\[data-lod')" "0" \
  "no level-of-detail rule hides anything on the board"
# And no counter-scaling: --k was the camera's scale, and a calc() reading it
# now resolves against a variable nothing sets, which is a silently wrong size
# rather than an error.
assert_eq "$(printf '%s' "$_maphtml" | grep -c 'var(--k')" "0" \
  "nothing reads --k, the retired camera's scale factor"

# Order is carried by style.order, never by moving nodes: re-appending children
# to sort them moves whichever one has focus, and moving a focused element
# drops the focus — so a keyboard user tabbed onto a figure would lose it every
# three seconds.
for _upd in updateDistrict updateBuilding updateZone updateFigure; do
  _fn=$(printf '%s' "$_maphtml" | awk "/^function ${_upd}\(/{f=1} f{print; if (/^\}/) exit}")
  assert_contains "$_fn" '.style.order = ' \
    "$_upd writes its sorted position as style.order rather than re-appending"
done

# ⚠️ Ordering must not read status. A figure that moved when its status changed
# would make position useless for finding a session again, which is the only
# thing position is for here — and it is why the sort is on the name.
_bwm=$(printf '%s' "$_maphtml" | awk '/^function buildWorldModel\(/{f=1} f{print; if (/^\}/) exit}')
# ⚠️ `.*`, not `[^)]*`. The first version of this pattern stopped at the first
# `)`, so in a comparator written `sort((p, q) => (q.sev || 0) - (p.sev || 0))`
# it never reached `sev` at all — it reported 0 against a board sorted entirely
# by severity. Green and unable to fail; it is in the mutation table.
assert_eq "$(printf '%s' "$_bwm" | grep -cE 'sort\(.*(sev|token|worst)')" "0" \
  "buildWorldModel sorts on identity, never on severity or status"
assert_contains "$_bwm" 'sort(byName)' "and the sort it uses is the name comparator"
# ⚠️ Not localeCompare: its answer depends on the browser's locale and ICU
# build, so two machines could order the same sessions differently and this
# suite could pass on one and fail on the other.
# ⚠️ Matches the CALL, not the word: the comment in map.html that explains why
# localeCompare is not used would satisfy a grep for the bare name. That exact
# mistake — a guard tripped by its own documentation — is in the mutation table.
assert_eq "$(printf '%s' "$_maphtml" | grep -c 'localeCompare(')" "0" \
  "and the comparator is locale-independent, never a localeCompare() call"

# ⚠️ A missing branch must read as an absence, never as a placeholder. The zone
# label printed `r.branch || "?"`, so a session the collector had explicitly
# reported as having no branch (bin/ccwatch:908 normalises an empty branch to
# null on purpose) was labelled `?` on the page — a value invented for a field
# that said it had none, in a vocabulary where `?` already means "suspected"
# (HUNG?). The CLI's own answer is omission: `${branch:+branch $branch}` at
# bin/ccwatch:1328 prints the clause only when there is one to print.
assert_not_contains "$_bwm" 'r.branch || "?"' \
  "buildWorldModel does not substitute a placeholder for a missing branch"
assert_contains "$_bwm" 'r.branch || NO_BRANCH' \
  "and routes a missing branch through the NO_BRANCH sentinel"
# The sentinel is the empty string because git cannot name a branch that, so it
# can never collide with a real branch — which "?" could.
assert_contains "$_maphtml" 'const NO_BRANCH = "";' \
  "and the sentinel is the one string git cannot name a branch"
_updatezone_js=$(printf '%s' "$_maphtml" | awk '/^function updateZone\(/{f=1} f{print; if (/^\}/) exit}')
assert_contains "$_updatezone_js" 'z.branch === NO_BRANCH' \
  "updateZone branches on the sentinel rather than printing it"
assert_contains "$_updatezone_js" 'label.hidden = true' \
  "and hides the label entirely, leaving no empty line where a branch would be"
assert_contains "$_updatezone_js" 'div.removeAttribute("title")' \
  "and drops the hover too, rather than offering \"branch \" with nothing after it"

# A card without a remote is named by a directory basename, which is not unique
# across machines — `scratch` could be anywhere — so the hover carries the full
# path and says why there is no repo, not merely that there is not one.
_updatebuilding_js=$(printf '%s' "$_maphtml" | awk '/^function updateBuilding\(/{f=1} f{print; if (/^\}/) exit}')
assert_contains "$_updatebuilding_js" 'b.dir' \
  "updateBuilding names the real directory of a card that has no git remote"
assert_contains "$_updatebuilding_js" 'no git remote' \
  "and says why it has no repo, not just that it has none"

# ⚠️ The figure animations must hold discrete poses, never interpolate. They
# animate `transform` on an SVG <g>, which Chrome cannot promote to a
# composited layer, so a tweened figure re-rasters the SVG subtree on the main
# thread every frame for as long as any session is busy: measured at 4.1% of a
# core in the renderer plus 3.7% in the GPU process on an otherwise idle map,
# against a 1.5% floor with the animations off. `step-end` costs 2.8%.
# The timing function is what is asserted, not the presence of the animation,
# because that is the whole of the difference — and the cost does not scale
# with how many figures move (3 and 7 measured the same), so an assertion that
# merely counted the animations would pass while the page burned a core.
for _fanim in '\.busy \.body' '\.waiting \.arm' '\.waiting \.bubble' '\.hung \.body'; do
  _frule=$(printf '%s' "$_maphtml" | grep -E "^[[:space:]]*${_fanim} \{.*animation:" | head -1)
  assert_contains "$_frule" 'step-end' \
    "${_fanim}'s animation holds its poses with step-end"
done
# The companion check, phrased so it cannot be satisfied by the comment that
# explains it: the pattern anchors on a rule's selector and its animation
# shorthand, so the prose above naming `ease-in-out` does not match it. (A
# guard that failed on its own explanatory comment is in the mutation table.)
_tweened=$(grep -cE '^[[:space:]]*\.(busy|waiting|hung) [^{]*\{[^}]*animation:[^;]*(ease|linear|cubic-bezier)' \
  "$ROOT/web/map.html")
assert_eq "$_tweened" "0" \
  "no figure animation uses an interpolating timing function"

# The dashboard must never derive its own version of the status: two renderings
# that compute it separately will eventually disagree, and the one you are not
# looking at is the one that is wrong. So /api/state is asserted to be the same
# shape the CLI produces.
if [ "$FAST" -eq 0 ] && command -v curl >/dev/null 2>&1; then
  # Find a port nothing is already listening on, and afterwards confirm the
  # server answering is the one this test started. Without that, a stale
  # `ccwatch serve` left behind by an earlier run answers instead — and since
  # it predates whatever route is under test, the failure reads as a missing
  # feature rather than as a dirty environment. Seven of them were found this
  # way.
  # ⚠️ Every port issued is recorded, so `cleanup_suite` reaps what was
  # actually used rather than a hand-maintained list of variable names. A test
  # that starts a server cannot forget to register it, because taking the port
  # IS the registration.
  free_port() {
    local try n=0
    while [ "$n" -lt 25 ]; do
      try=$((18000 + RANDOM % 1500))
      if ! curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$try/" 2>/dev/null; then
        printf '%s\n' "$try" >> "$SERVE_PORTS"
        printf '%s' "$try"
        return 0
      fi
      n=$((n + 1))
    done
    return 1
  }
  SPORT=$(free_port) || SPORT=""
  mksess 9107 ssssssss-0000-0000-0000-000000000001 serverow /fake/repo idle cli
  mktrans ssssssss-0000-0000-0000-000000000001 20
  mkps 9107 "0:10.00" > "$WORK/ps-sv"
  ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
    CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT" >"$WORK/serve.log" 2>&1 & )
  wait_until 20 srv_up "$SPORT" || true
  assert_not_contains "$(cat "$WORK/serve.log" 2>/dev/null)" "could not bind" \
    "the test server got the port it asked for"
  _w=no
  wait_until 90 srv_warm "$SPORT" && _w=false
  _api=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT/api/state" 2>/dev/null)
  assert_contains "$_api" '"sessions"' "/api/state serves the same snapshot shape as the CLI"
  if [ "$_w" = "false" ]; then
    assert_eq "$(printf '%s' "$_api" | jq -r '[.sessions[].name] | index("serverow") != null')" "true" \
      "and the session the CLI would show is in it"
  else
    # A warm-up that has not finished is a slow machine, not a defect. Failing
    # here sends someone hunting a bug that is not there.
    t_skip "and the session the CLI would show is in it" "snapshot still warming after 90s"
  fi
  # Every panel carries its own age, so one slow collector cannot make a stale
  # panel look current.
  assert_contains "$_api" '"ages"' "each panel reports its own age"

  # G1, FR-034, SC-009: parse_failed is the fourth of the four consumers and
  # must equal the CLI's --json value for the same fabricated registry.
  printf '{"pid":9108,"cwd":' > "$FH/sessions/9108.json"   # truncated mid-write
  wait_until 30 srv_field "$SPORT" '.parse_failed // empty' 1 || true
  _pf_api=$(curl -s --max-time 3 "http://127.0.0.1:$SPORT/api/state" 2>/dev/null | jq -r '.parse_failed // empty')
  _pf_cli=$(printf '%s' "$(ccwatch_json "$WORK/ps-sv")" | jq -r '.parse_failed')
  assert_eq "$_pf_api" "$_pf_cli" \
    "/api/state's parse_failed matches ccwatch --json's for the same registry"
  rm -f "$FH/sessions/9108.json"
  # The handler must not block: it was serving from a per-request subprocess at
  # first, and eleven concurrent requests piled up without one completing.
  _t=$( { time -p curl -s -o /dev/null --max-time 8 "http://127.0.0.1:$SPORT/api/state"; } 2>&1 \
        | awk '/^real/{print ($2 < 3) ? "fast" : "slow"}')
  assert_eq "$_t" "fast" "the handler answers from memory rather than shelling out per request"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SPORT/")" "200" \
    "and the dashboard itself is served"
  # Loopback only: this exposes which repositories you work in and fragments of
  # peer messages.
  assert_contains "$(cat "$WORK/serve.log")" "127.0.0.1" "serve binds loopback, not every interface"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SPORT/map")" "200" \
    "the map view is served too"
  # The markdown renderer is a second asset the map view loads, served by the
  # static fallback rather than by a route of its own — so nothing in `serve`
  # names it, and if it stopped arriving the inspector would go on working
  # while quietly showing every turn as raw asterisks.
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SPORT/md.js")" "200" \
    "and the markdown renderer it loads is served beside it"

  # ⚠️ Invoked through a SYMLINK, which is the install the README documents —
  # `ln -s .../bin/ccwatch /usr/local/bin/ccwatch`, so that `git pull` upgrades
  # the tool. `${BASH_SOURCE[0]}` is then the symlink, and the naive dirname put
  # the web root at /usr/local: `serve` died for everyone who installed it the
  # documented way, while working perfectly from the checkout. A chain of two
  # links, because Homebrew and dotfiles repos both produce one.
  SPORT4=$(free_port) || SPORT4=""
  mkdir -p "$WORK/link1" "$WORK/link2"
  ln -sf "$CCWATCH" "$WORK/link1/ccwatch"
  ln -sf "$WORK/link1/ccwatch" "$WORK/link2/ccwatch"
  ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
    CCWATCH_DEPLOY_TTL=999999 "$WORK/link2/ccwatch" serve --port "$SPORT4" \
    >"$WORK/serve-link.log" 2>&1 & )
  wait_until 20 srv_up "$SPORT4" || true
  assert_not_contains "$(cat "$WORK/serve-link.log" 2>/dev/null)" "cannot find web/index.html" \
    "serve finds its web assets when installed as a symlink, as the README says to"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SPORT4/")" "200" \
    "and actually serves the dashboard through the link"
  pkill -f "ccwatch serve --port $SPORT4" 2>/dev/null || true

  # --- the send endpoint, which is the part with teeth ---------------------
  #
  # Binding to loopback is NOT a security boundary for this: any page open in
  # the browser can POST to 127.0.0.1. Without a gate, a random site could
  # inject prompts into every agent running on the machine. Both checks are
  # asserted because either alone is insufficient.
  _tok=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT/map" \
         | grep -oE 'const SEND_TOKEN = "[0-9a-f]+"' | sed 's/.*"\(.*\)"/\1/')
  [ -n "$_tok" ] && t_pass "the page is served with a per-run send token" \
    || t_fail "the page is served with a per-run send token" "no token found in the served HTML"
  assert_eq "${#_tok}" "64" "and it is 32 bytes of entropy, not a guessable constant"

  _notok=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT/api/send" \
           -H 'Content-Type: application/json' -d '{"target":"x","message":"y"}')
  assert_contains "$_notok" "bad or missing token" "a POST with no token is refused"

  _badorigin=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT/api/send" \
               -H "X-CCWatch-Token: $_tok" -H "Origin: https://evil.example" \
               -H 'Content-Type: application/json' -d '{"target":"x","message":"y"}')
  assert_contains "$_badorigin" "unexpected Origin" \
    "a POST from another origin is refused even WITH the token"

  # A token that is right and an origin that is ours gets through the gate and
  # is then judged on the target, which is the correct order of checks.
  _through=$(curl -s --max-time 20 -X POST "http://127.0.0.1:$SPORT/api/send" \
             -H "X-CCWatch-Token: $_tok" -H "Origin: http://127.0.0.1:$SPORT" \
             -H 'Content-Type: application/json' \
             -d '{"target":"definitely-not-a-session","message":"y"}')
  assert_contains "$_through" "no live session matches" \
    "a correctly-authorised POST reaches the send logic"
  assert_contains "$_through" "failed" "and an unknown target is reported as a failure"

  # Size and shape limits, so the endpoint cannot be used to wedge the server.
  # A well-formed body with a field missing gets a specific reason, not a
  # generic one — the caller can act on "message is required" and cannot act on
  # "bad request".
  _empty=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT/api/send" \
           -H "X-CCWatch-Token: $_tok" -H 'Content-Type: application/json' -d '{"target":"x"}')
  assert_contains "$_empty" "both required" "a body missing the message says which field is missing"
  # Genuinely unparseable input is a different failure and says so.
  _bad=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT/api/send" \
         -H "X-CCWatch-Token: $_tok" -H 'Content-Type: application/json' -d 'not json at all')
  assert_contains "$_bad" "bad request" "an unparseable body is rejected as a bad request"
  _long=$(python3 -c "import json;print(json.dumps({'target':'x','message':'z'*5000}))" \
          | curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT/api/send" \
            -H "X-CCWatch-Token: $_tok" -H 'Content-Type: application/json' --data-binary @-)
  assert_contains "$_long" "too long" "an oversized message is rejected"

  # Killing from a browser is OFF unless asked for. Sending to the wrong agent
  # is embarrassing; killing the wrong one costs work in flight, so it needs an
  # explicit flag on top of the token every other write already requires.
  _kd=$(curl -s --max-time 15 -X POST "http://127.0.0.1:$SPORT/api/kill" \
        -H "X-CCWatch-Token: $_tok" -H "Origin: http://127.0.0.1:$SPORT" \
        -H 'Content-Type: application/json' -d '{"target":"anything"}')
  assert_contains "$_kd" "--allow-kill" \
    "the kill endpoint is refused by default, and names the flag that enables it"
  assert_eq "$(curl -s --max-time 5 "http://127.0.0.1:$SPORT/api/state" | jq -r '.can_kill')" "false" \
    "and the page is told it cannot kill, so no button is drawn"

  pkill -f "ccwatch serve --port $SPORT" 2>/dev/null || true

  # --- killing, when explicitly enabled ------------------------------------
  SPORT4=$(free_port) || SPORT4=""
  if [ -n "$SPORT4" ]; then
    mksess 9501 aaaaaaaa-9999-0000-0000-000000000001 killable "$WORK/other" busy cli
    mktrans aaaaaaaa-9999-0000-0000-000000000001 10
    mkps 9501 "0:10.00" > "$WORK/ps-k4"
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-k4" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT4" --allow-kill \
      >"$WORK/serve-k.log" 2>&1 & )
    wait_until 40 srv_warm "$SPORT4" || true
    assert_eq "$(curl -s --max-time 5 "http://127.0.0.1:$SPORT4/api/state" | jq -r '.can_kill')" "true" \
      "with --allow-kill the page is told it may kill"
    _tok4=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT4/map" \
            | grep -oE 'const SEND_TOKEN = "[0-9a-f]+"' | sed 's/.*"\(.*\)"/\1/')
    # The guards still apply over HTTP — enabling the endpoint does not bypass
    # them, which is the whole point of putting them in the command.
    _kb4=$(curl -s --max-time 25 -X POST "http://127.0.0.1:$SPORT4/api/kill" \
           -H "X-CCWatch-Token: $_tok4" -H "Origin: http://127.0.0.1:$SPORT4" \
           -H 'Content-Type: application/json' \
           -d '{"target":"aaaaaaaa-9999-0000-0000-000000000001"}')
    assert_contains "$_kb4" "mid-turn" "a mid-turn session is refused over HTTP too"
    assert_contains "$_kb4" "refused" "and the refusal is reported as such, not as a failure"
    # The refusal text is passed through verbatim: it explains what would have
    # been lost, and reducing it to "failed" throws that away.
    assert_contains "$_kb4" "half-edited" "with the reason preserved verbatim"
    pkill -f "ccwatch serve --port $SPORT4" 2>/dev/null || true
    rm -f "$FH/sessions/9501.json"
  else
    t_skip "kill over HTTP" "no free port"
  fi

  # --- and the read-only mode, for anyone who wants no endpoint at all -----
  SPORT2=$(free_port) || SPORT2=""
  ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
    CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT2" --read-only \
    >"$WORK/serve-ro.log" 2>&1 & )
  wait_until 30 srv_up "$SPORT2" || true
  assert_not_contains "$(cat "$WORK/serve-ro.log" 2>/dev/null)" "could not bind" \
    "the read-only test server got the port it asked for"
  _ro=$(curl -s --max-time 10 -X POST "http://127.0.0.1:$SPORT2/api/send" \
        -H 'Content-Type: application/json' -d '{"target":"x","message":"y"}')
  assert_contains "$_ro" "read-only" "--read-only refuses the send endpoint outright"
  _rotok=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT2/" \
           | grep -oE 'const SEND_TOKEN = "[0-9a-f]+"' | sed 's/.*"\(.*\)"/\1/')
  assert_eq "$_rotok" "" "and serves no token, so the page shows itself as read-only"
  pkill -f "ccwatch serve --port $SPORT2" 2>/dev/null || true

  # Killing the wrapper must take the HTTP server with it. It did not: python
  # ran in the foreground of the shell, so Ctrl-C reached it but any other kill
  # orphaned a server holding a port with no visible owner. Two were found
  # still running after a suite, and one then answered a request this very
  # suite believed it was making to its own server — which is how the leak was
  # noticed at all.
  SPORT3=$(free_port) || SPORT3=""
  if [ -n "$SPORT3" ]; then
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT3" >"$WORK/serve-l.log" 2>&1 & )
    wait_until 25 srv_up "$SPORT3" || true
    assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$SPORT3/")" "200" \
      "a third server starts and answers"
    pkill -f "ccwatch serve --port $SPORT3" 2>/dev/null || true
    # Waiting for the port to go quiet, rather than a fixed 3s: the wrapper
    # normally takes its child down in well under a second, and the deadline
    # is what makes a leak a failure instead of a hang.
    wait_until 8 srv_dead "$SPORT3" || true
    # `curl -w %{http_code}` prints 000 on a refused connection AND exits
    # non-zero, so appending `|| echo gone` produced "000gone" and the
    # comparison never matched. Only the code is captured, and the branch is a
    # plain if — the `a || b && pass || fail` form runs both branches when the
    # first test fails.
    _after=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
             "http://127.0.0.1:$SPORT3/" 2>/dev/null) || _after="000"
    if [ "$_after" = "000" ]; then
      t_pass "killing the wrapper takes the HTTP server with it, leaving no orphan"
    else
      t_fail "killing the wrapper takes the HTTP server with it, leaving no orphan" \
             "something is still listening on $SPORT3 (HTTP $_after)"
    fi
    # ⚠️ And it stops QUIETLY. `srv_pid` was a `local` of cmd_serve while the
    # EXIT trap that reaps the child read it after cmd_serve had returned, so
    # under `set -u` the trap aborted with "srv_pid: unbound variable" on every
    # ordinary stop: a clean Ctrl-C looked like a crash, exited non-zero, and
    # printed the same thing a real child crash would. Reported from a real
    # terminal, three times in a row, at a different line number each time -
    # bash names wherever execution had reached, which is why it reads like a
    # different bug each time.
    assert_not_contains "$(cat "$WORK/serve-l.log" 2>/dev/null)" "unbound variable" \
      "and stops without an error of its own, so a clean stop cannot be read as a crash"
  else
    t_skip "killing the wrapper leaves no orphan" "no free port"
  fi
  pkill -f "ccwatch serve --port $SPORT" 2>/dev/null || true
  rm -f "$FH/sessions/9107.json"

  # --- idle-aware collection: no reader, no work (FR-001, FR-002, SC-001) --
  #
  # With a short grace period and nobody reading /api/state, a single read
  # after the grace has lapsed must show the snapshot age tracking the whole
  # idle span (collection stopped), not the ~2s cadence it would show if
  # collection had kept running unread. A following read must show collection
  # resuming, so this first post-idle read reports feed=idle.
  SPORT5=$(free_port) || SPORT5=""
  if [ -n "$SPORT5" ]; then
    mksess 9601 iiiiiiii-0000-0000-0000-000000000001 idlerow /fake/repo idle cli
    mktrans iiiiiiii-0000-0000-0000-000000000001 5
    mkps 9601 "0:10.00" > "$WORK/ps-idle"
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-idle" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 CCWATCH_IDLE_GRACE=2 \
      "$CCWATCH" serve --port "$SPORT5" >"$WORK/serve-idle.log" 2>&1 & )
    wait_until 40 srv_warm "$SPORT5" || true
    # ⚠️ The idle window and its threshold are DERIVED from what a collection
    # costs on this host, not fixed. Two earlier versions were fixed and both
    # were coin flips on a loaded machine:
    #
    #   `sleep 6` with `age > 4` put the pass/fail line exactly on the
    #   expected value (6s idle − 2s grace = 4.0).
    #
    #   `sleep 12` with `age > 6` moved the line but kept the premise that a
    #   collection completes quickly. It does not always: a snapshot measured
    #   2.1s warm and 24s cold under load here. A collection still in flight
    #   when the window opens publishes partway through it, leaving an age of
    #   (window − however long it took) — under 6s whenever a collection takes
    #   more than six. That is the check failing for the one reason it must
    #   not: the feature working slowly. It failed twice in eight runs today.
    #
    # So a collection is timed first, and the window is sized to clear it with
    # room: a stopped collector then leaves an age near the whole window,
    # while a still-running one leaves an age at its ~2s cadence, and the two
    # outcomes stay far apart however slow the host is. It remains a hard
    # assertion rather than a skip, because a broken idle gate is exactly what
    # a small age means once the window is known to be wide enough.
    _t0=$(python3 -c 'import time; print(time.time())')
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-idle" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" --json >/dev/null 2>&1 )
    _t1=$(python3 -c 'import time; print(time.time())')
    _cost=$(awk -v a="$_t0" -v b="$_t1" 'BEGIN{printf "%.1f", b - a}')
    # grace (2s) + one collection's worth of headroom + 5s of margin, and
    # never less than 8s so a fast host still separates the two outcomes.
    _window=$(awk -v c="$_cost" 'BEGIN{w = 2 + c * 2 + 5; print (w < 8) ? 8 : w}')
    _floor=$(awk -v w="$_window" -v c="$_cost" 'BEGIN{printf "%.1f", w - c - 3}')
    sleep "$_window"
    _idle=$(curl -s --max-time 10 "http://127.0.0.1:$SPORT5/api/state")
    assert_eq "$(printf '%s' "$_idle" | jq -r '.feed')" "idle" \
      "the first read after the grace period reports the feed as idle"
    _ia=$(printf '%s' "$_idle" | jq -r '.ages.snapshot')
    assert_eq "$(awk -v a="$_ia" -v f="$_floor" 'BEGIN{print (a > f) ? "yes" : "no"}')" "yes" \
      "collection stopped while nobody read /api/state (age tracks the full idle span, not the 2s cadence)"
    # ⚠️ The contract is that a read RESUMES collection — not that a collection
    # completes inside any fixed number of seconds. This assertion used to
    # sleep 3 and require an age under 2.5s, which is one machine's speed
    # written down as a requirement: a snapshot measured 2.1s warm but 24s on a
    # cold cache under load on the development host, and it failed there while
    # the feature worked correctly (verified by hand — the feed went idle at
    # age 11.9s and the next read produced a 0.5s-old snapshot).
    #
    # So the deadline is derived from what a collection actually costs on THIS
    # host. It stays a hard assertion rather than a skip on a slow host,
    # because a broken resume ALSO produces no fresh snapshot, and reporting
    # that as "skipped: host too slow" would count a regression as coverage.
    # Three collections' worth of headroom plus the cadence, so an ordinarily
    # busy machine passes and only a pathological one runs out of deadline.
    # `_cost` is the collection timed above, rather than a second one: the
    # measurement is the same and this test already paid for it.
    _deadline=$(awk -v c="$_cost" 'BEGIN{d=c*3+6; print (d<10)?10:d}')
    _fresh=no _waited=0
    while [ "$(awk -v w="$_waited" -v d="$_deadline" 'BEGIN{print (w<d)?1:0}')" = "1" ]; do
      sleep 0.5; _waited=$(awk -v w="$_waited" 'BEGIN{print w + 0.5}')
      _ra=$(curl -s --max-time 10 "http://127.0.0.1:$SPORT5/api/state" \
            | jq -r '.ages.snapshot' 2>/dev/null)
      # Younger than the idle span it replaced is the proof a new collection
      # landed. Had collection stayed stopped, the age would keep climbing.
      if [ "$(awk -v a="${_ra:-0}" -v i="$_ia" 'BEGIN{print (a < i - 1) ? 1 : 0}')" = "1" ]; then
        _fresh=yes; break
      fi
    done
    assert_eq "$_fresh" "yes" \
      "and a read resumes collection, which catches up on its own cadence"
    pkill -f "ccwatch serve --port $SPORT5" 2>/dev/null || true
    rm -f "$FH/sessions/9601.json"
  else
    t_skip "idle-aware collection" "no free port"
  fi

  # --- conditional responses: the validator covers every measurement -------
  # (FR-010, FR-011, FR-012)
  #
  # A 304 must guarantee that nothing measured changed, so the ETag has to be
  # a hash of the published payload with `ages`/`stale`/`feed` excluded — those
  # are recomputed per request from the wall clock and would otherwise churn
  # the validator on every single read, defeating the whole point of a 304.
  SPORT6=$(free_port) || SPORT6=""
  if [ -n "$SPORT6" ]; then
    mksess 9701 eeeeeeee-0000-0000-0000-000000000001 etagrow /fake/repo idle cli
    mktrans eeeeeeee-0000-0000-0000-000000000001 5
    mkps 9701 "0:10.00" > "$WORK/ps-etag"
    # ⚠️ A 120s snapshot cadence, so no collection can land between the two
    # reads this section compares. At the 2s default the assertion was a race
    # the machine decided: each `curl` under load takes longer than the
    # cadence, a collection lands in between, and the ETag differs for a reason
    # that has nothing to do with the validator. It failed here for real while
    # another pipeline was running. Removing the race beats re-rolling it.
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-etag" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 CCWATCH_SNAPSHOT_CADENCE=120 \
      "$CCWATCH" serve --port "$SPORT6" >"$WORK/serve-etag.log" 2>&1 & )
    # ⚠️ Wait for ALL THREE collectors to have published, not just the snapshot.
    #
    # The ETag covers the whole published payload, and `refresh_etag` runs on
    # every publish — so `deploys` and `peers` change the validator exactly as
    # `snapshot` does. Waiting only on `warming` (which tracks the snapshot
    # alone) left their FIRST publish free to land between the two reads below,
    # and it usually did on a loaded host: `deploys` shells out to `gh` and
    # `peers` scans transcripts, so both finish well after the snapshot.
    #
    # This is the fourth attempt at this assertion and the previous three each
    # fixed a different wrong theory: that two back-to-back reads could not
    # straddle a collection (false under load), that retrying would find a
    # clean pair (false — the race was certain, not unlucky), and that pinning
    # the cadence was enough (false — a cadence delays the *next* publish, not
    # the first). Waiting for the premise to actually hold is what makes it
    # deterministic.
    _all_collected() {
      [ "$(curl -s --max-time 5 "http://127.0.0.1:$1/api/state" 2>/dev/null \
           | jq -r '[.warming == false,
                     (.collected_at.snapshot != null),
                     (.collected_at.deploys  != null),
                     (.collected_at.peers    != null)] | all' 2>/dev/null)" = "true" ]
    }
    _ready=false
    wait_until 60 _all_collected "$SPORT6" && _ready=true
    if [ "$_ready" != "true" ]; then
      # The premise could not be established, so the assertions below would be
      # measuring the host rather than the validator. Stated as a skip with the
      # reason, never as a pass and never as a failure.
      t_skip "the ETag is stable across reads" \
        "not all three collectors published within 60s on this host"
    else
    # ⚠️ The contract is that the same collected data yields the same validator.
    # The cadence above is 120s, so the two reads below are guaranteed to see
    # one collection — no retry loop, no timing assumption, and the same
    # outcome on an idle machine and a loaded one.
    #
    # An earlier attempt retried until it observed two reads sharing a
    # `collected_at`. That was still wrong: under load each request takes
    # longer than the 2s cadence, so a collection lands between EVERY pair and
    # no number of retries finds one. A race that is certain rather than
    # unlucky has to be removed, not re-rolled.
    #
    # `collected_at` is still compared, as the check that the premise held.
    curl -s --max-time 10 -D "$WORK/hdr1" -o "$WORK/body1" "http://127.0.0.1:$SPORT6/api/state"
    _etag1=$(tr -d '\r' < "$WORK/hdr1" | awk -F': ' 'tolower($1)=="etag"{print $2}')
    _ages1=$(jq -r '.ages.snapshot' "$WORK/body1")
    _ca1=$(jq -r '.collected_at.snapshot' "$WORK/body1")
    curl -s --max-time 10 -D "$WORK/hdr2" -o "$WORK/body2" "http://127.0.0.1:$SPORT6/api/state"
    _etag2=$(tr -d '\r' < "$WORK/hdr2" | awk -F': ' 'tolower($1)=="etag"{print $2}')
    _ages2=$(jq -r '.ages.snapshot' "$WORK/body2")
    _ca2=$(jq -r '.collected_at.snapshot' "$WORK/body2")
    assert_eq "$_ca2" "$_ca1" \
      "a 120s cadence means the two reads really did see one collection"
    assert_eq "$_etag2" "$_etag1" \
      "the ETag is unchanged across two reads with no intervening collection"
    [ "$_ages1" != "$_ages2" ] \
      && t_pass "even though the per-request ages differ between those same two reads" \
      || t_fail "even though the per-request ages differ between those same two reads" \
                "ages.snapshot was identical: $_ages1"
    # A matching validator gets a bodyless 304.
    # curl does not create the -o file at all for a bodyless 304 (nothing to
    # write), so the body is confirmed empty via %{size_download} rather than
    # by reading a file back.
    _rw304=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time 5 \
             -H "If-None-Match: $_etag1" "http://127.0.0.1:$SPORT6/api/state")
    assert_eq "${_rw304% *}" "304" "a matching If-None-Match gets a 304"
    assert_eq "${_rw304#* }" "0" "and the 304 body is empty"
    # A stale or unparseable validator still gets a full 200.
    _code200=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
               -H 'If-None-Match: "0000000000000000"' "http://127.0.0.1:$SPORT6/api/state")
    assert_eq "$_code200" "200" "a stale If-None-Match falls through to a full 200"
    # And the 304 exchange must not have perturbed collected_at — the very
    # instant a client needs to keep computing a truthful age from (FR-013).
    curl -s --max-time 5 -o "$WORK/body3" "http://127.0.0.1:$SPORT6/api/state"
    _ca3=$(jq -r '.collected_at.snapshot' "$WORK/body3")
    assert_eq "$_ca3" "$_ca1" \
      "collected_at is not reset by a 304 — the same instant survives the exchange"
    _now3=$(python3 -c 'import time; print(time.time())')
    assert_eq "$(awk -v n="$_now3" -v c="$_ca1" 'BEGIN{print (n - c > 0.2) ? "yes" : "no"}')" "yes" \
      "so the client-derived age (now - collected_at) keeps growing rather than freezing"
    fi
    pkill -f "ccwatch serve --port $SPORT6" 2>/dev/null || true
    rm -f "$FH/sessions/9701.json"
  else
    t_skip "conditional responses" "no free port"
  fi

  # --- a failed snapshot is a fact, not an empty set (US3) ------------------
  # (FR-024, FR-026, SC-007)
  #
  # A collection that exceeds its ceiling must read differently from a host
  # that genuinely has no sessions — snapshot_ok/snapshot_error is the pair
  # that makes the two distinguishable by inspecting the payload alone.
  SPORT7=$(free_port) || SPORT7=""
  if [ -n "$SPORT7" ]; then
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 CCWATCH_SNAPSHOT_TIMEOUT=0.001 \
      "$CCWATCH" serve --port "$SPORT7" >"$WORK/serve-to.log" 2>&1 & )
    wait_until 30 srv_up "$SPORT7" || true
    # Waiting for the failed collection to be published, which is the state
    # under test, rather than for a fixed two seconds.
    wait_until 20 srv_field "$SPORT7" '.snapshot_ok' false || true
    _to=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT7/api/state")
    assert_eq "$(printf '%s' "$_to" | jq -r '.snapshot_ok')" "false" \
      "a snapshot that exceeds its ceiling is reported as a failed collection, not an empty one"
    assert_contains "$(printf '%s' "$_to" | jq -r '.snapshot_error')" "time" \
      "and the failure reason names the timeout"
    assert_eq "$(printf '%s' "$_to" | jq -r '.warming')" "true" \
      "warming stays true because no snapshot has ever succeeded"
    assert_eq "$(printf '%s' "$_to" | jq -r '.sessions')" "null" \
      "and sessions is null, never a fabricated empty list"
    pkill -f "ccwatch serve --port $SPORT7" 2>/dev/null || true
  else
    t_skip "failed snapshot is distinguishable from an empty host" "no free port"
  fi

  # A healthy server on a host with genuinely no sessions must read the other
  # way, so the two payloads above are distinguishable and neither is confused
  # for the other.
  SPORT8=$(free_port) || SPORT8=""
  if [ -n "$SPORT8" ]; then
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT8" >"$WORK/serve-empty.log" 2>&1 & )
    wait_until 30 srv_warm "$SPORT8" || true
    _empty=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT8/api/state")
    assert_eq "$(printf '%s' "$_empty" | jq -r '.snapshot_ok')" "true" \
      "a genuinely empty host reports a successful collection"
    assert_eq "$(printf '%s' "$_empty" | jq -r '.snapshot_error')" "null" \
      "with no error"
    assert_eq "$(printf '%s' "$_empty" | jq -r '.sessions')" "[]" \
      "and sessions is an empty array, not null — the two payloads are distinguishable by inspection alone"
    pkill -f "ccwatch serve --port $SPORT8" 2>/dev/null || true
  else
    t_skip "empty host is distinguishable from a failed snapshot" "no free port"
  fi

  # --- a failed collection retains the prior snapshot, not blanks it (US3) --
  # (FR-025)
  #
  # Once a snapshot has succeeded, a later failure must leave the retained
  # `sessions` list and its original `collected_at` untouched, so the panel's
  # age keeps growing truthfully instead of resetting near zero as a fresh
  # empty collection would. Forced by making the running server's own copy of
  # the tool briefly unexecutable, so every subsequent collection attempt
  # fails — a private copy, so this cannot affect any other test in the suite.
  SPORT9=$(free_port) || SPORT9=""
  if [ -n "$SPORT9" ]; then
    TC="$WORK/toolcopy"
    mkdir -p "$TC/bin" "$TC/web"
    cp "$CCWATCH" "$TC/bin/ccwatch"
    chmod +x "$TC/bin/ccwatch"
    cp "$ROOT/web/"*.html "$TC/web/"
    mksess 9801 ffffffff-0000-0000-0000-000000000001 retainrow /fake/repo idle cli
    mktrans ffffffff-0000-0000-0000-000000000001 5
    mkps 9801 "0:10.00" > "$WORK/ps-retain"
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-retain" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$TC/bin/ccwatch" serve --port "$SPORT9" \
      >"$WORK/serve-retain.log" 2>&1 & )
    wait_until 40 srv_warm "$SPORT9" || true
    _before9=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT9/api/state")
    _sessions_before=$(printf '%s' "$_before9" | jq -c '.sessions')
    _ca_before=$(printf '%s' "$_before9" | jq -r '.collected_at.snapshot')
    chmod -x "$TC/bin/ccwatch"
    # ⚠️ Two waits, not one fixed sleep, because two separate things have to be
    # true: a collection must have been attempted and failed (that is the
    # state under test), and enough wall time must have passed for the
    # retained snapshot's age to be visibly growing rather than near zero. The
    # age threshold below is 3s, so 3.5s is the floor — the rest is polling.
    wait_until 20 srv_field "$SPORT9" '.snapshot_ok' false || true
    wait_until 40 srv_field "$SPORT9" '[.ages.snapshot > 3.5] | all' true || true
    _after9=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT9/api/state")
    assert_eq "$(printf '%s' "$_after9" | jq -r '.snapshot_ok')" "false" \
      "a subsequent collection failure is reported, not silently swallowed"
    assert_eq "$(printf '%s' "$_after9" | jq -c '.sessions')" "$_sessions_before" \
      "and the last successful sessions list is retained rather than blanked"
    _ca_after=$(printf '%s' "$_after9" | jq -r '.collected_at.snapshot')
    assert_eq "$_ca_after" "$_ca_before" \
      "collected_at is not refreshed by a failed attempt"
    _age_after=$(printf '%s' "$_after9" | jq -r '.ages.snapshot')
    assert_eq "$(awk -v a="$_age_after" 'BEGIN{print (a > 3) ? "yes" : "no"}')" "yes" \
      "so its age keeps growing truthfully, rather than resetting to near-zero as a fresh empty collection would"
    chmod +x "$TC/bin/ccwatch"
    pkill -f "ccwatch serve --port $SPORT9" 2>/dev/null || true
    rm -f "$FH/sessions/9801.json"
  else
    t_skip "a failed collection retains the prior snapshot" "no free port"
  fi
else
  if [ "$FAST" -eq 1 ]; then
    t_skip "serve" "--fast: 11 servers and every real-time wait in the suite"
  else
    t_skip "serve" "curl not available"
  fi
fi

# V1/V2 (FR-016): the rewritten map.html reconciles instead of replacing.
# Static, source-level guards — no server needed — so they still run even
# when curl is absent.
_ih_count=$(grep -c '\.innerHTML *=' "$ROOT/web/map.html")
assert_eq "$_ih_count" "2" \
  "map.html assigns innerHTML exactly twice: the once-built legend and the turn body"
_ih_legend_line=$(grep -n '\$("legend")\.innerHTML *=' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
_ih_tick_line=$(grep -n '^async function tick(' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
assert_eq "$(awk -v a="$_ih_legend_line" -v b="$_ih_tick_line" 'BEGIN{print (a>0 && b>0 && a<b) ? "yes" : "no"}')" "yes" \
  "the legend's innerHTML write sits before tick() is even defined, so no refresh reaches it"
assert_contains "$(grep '\.innerHTML *=' "$ROOT/web/map.html" | grep -v legend)" "CCWATCH_MD.render" \
  "the one refresh-reachable innerHTML write is the turn body, filled from md.js's escape-first render"

# FR-016/FR-017 (contracts/page-roster.md §1/§4): the roster's listbox, its
# row template and its keydown binding, checked statically so no browser is
# needed to know a screen reader would see the right roles.
assert_contains "$_maphtml" 'list.setAttribute("role", "listbox")' \
  "#rosterlist carries role=\"listbox\""
_makerow_js=$(awk '/^function makeRow\(sid\)/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_makerow_js" 'el.setAttribute("role", "option")' \
  "the .rrow template carries role=\"option\""
assert_contains "$_makerow_js" 'el.tabIndex' \
  "and a tabindex, for roving focus"
assert_contains "$_maphtml" 'rosterEls.list.addEventListener("keydown"' \
  "the roster's keydown listener is bound to #rosterlist"
assert_not_contains "$_maphtml" 'document.addEventListener("keydown"' \
  "and never to document, so it cannot also catch the map's own arrow keys"
_board_label=$(printf '%s' "$_board_tag" | sed -n 's/.*aria-label="\([^"]*\)".*/\1/p')
assert_contains "$_board_label" "companion" \
  "FR-013: #board's aria-label still names itself a companion view of the agent list"

# contracts/page-roster.md §6: the selection ring is its own rule on the outer
# .agent node (which applySelectionEmphasis toggles), never inside .figart
# which updateFigure rebuilds wholesale every tick.
assert_contains "$_maphtml" '.agent.selected {' \
  "the selection ring is a distinct .agent.selected rule"
assert_not_contains "$(grep '\.agent\.sev' "$ROOT/web/map.html")" 'border' \
  "and no status-appearance .agent.sevN rule also sets a border, which would collide with it"
_applyselemph_js=$(awk '/^function applySelectionEmphasis\(\)/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_applyselemph_js" 'b.classList.toggle("selected"' \
  "applySelectionEmphasis toggles .selected directly on the outer .agent button, not on a child it queries"
assert_not_contains "$_applyselemph_js" 'figart' \
  "and never reaches into .figart, which updateFigure rebuilds wholesale every tick"

# V16 (FR-047): the placeholder ships byte-identical in the source; the served
# page substitutes a real token in its place (asserted against a live server
# above, in the serve section).
assert_contains "$(cat "$ROOT/web/map.html")" 'const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";' \
  "the SEND_TOKEN placeholder is byte-identical in the map.html source"

# FR-028/D13 (contracts/page-roster.md §3, data-model.md §5): renderRoster's
# call inside applyFeed must sit after VOLATILE is set for this tick, so
# ctx/mem are withheld through that one gate and no second one.
_applyfeed_js=$(awk '/^function applyFeed\(/,/^\}/' "$ROOT/web/map.html")
_volatile_line=$(printf '%s\n' "$_applyfeed_js" | grep -n 'VOLATILE = cond.trust' | head -1 | cut -d: -f1)
_renderroster_line=$(printf '%s\n' "$_applyfeed_js" | grep -n 'renderRoster(' | head -1 | cut -d: -f1)
assert_eq "$(awk -v a="$_volatile_line" -v b="$_renderroster_line" 'BEGIN{print (a>0 && b>0 && a<b) ? "yes" : "no"}')" "yes" \
  "applyFeed's renderRoster call sits after its VOLATILE = cond.trust === \"ok\" line"

# FR-032 (contracts/page-roster.md §1): #rdivider carries the separator role,
# a tabindex so the keyboard path reaches it, and the three aria-value*
# attributes the width-by-keyboard path (T059) writes on every change.
assert_contains "$_maphtml" 'divider.setAttribute("role", "separator")' \
  "#rdivider carries role=\"separator\""
assert_contains "$_maphtml" 'divider.setAttribute("tabindex", "0")' \
  "and tabindex=\"0\", so it is reachable by Tab"
assert_contains "$_maphtml" 'divider.setAttribute("aria-label", "Roster width")' \
  "and an aria-label naming what it controls"
assert_contains "$_maphtml" 'rosterEls.divider.setAttribute("aria-valuenow"' \
  "setWidth writes aria-valuenow on every width change"
assert_contains "$_maphtml" 'rosterEls.divider.setAttribute("aria-valuemin"' \
  "and aria-valuemin"
assert_contains "$_maphtml" 'rosterEls.divider.setAttribute("aria-valuemax"' \
  "and aria-valuemax"

# The figure animations' reduced-motion block is the only one left in the file
# now that #camera.eased has gone with the camera, and it must stay paired with
# the rules it turns off: a reduced-motion block that drifts away from them
# silently stops covering one.
_first_reduced_motion_line=$(grep -n '@media (prefers-reduced-motion: reduce)' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
_figure_anim_line=$(grep -n '^  \.hung \.body { animation:' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
assert_eq "$(awk -v a="$_first_reduced_motion_line" -v b="$_figure_anim_line" 'BEGIN{print (a>0 && b>0 && a>b) ? "yes" : "no"}')" "yes" \
  "the reduced-motion block follows the figure animation rules it disables"

# FR-041: the roster is rendered event-driven, on a data change, a selection,
# a focus move, or a width change — never on its own timer or animation
# frame, so it cannot drift out of step with the map's one shared scheduler.
assert_eq "$(grep -c requestAnimationFrame "$ROOT/web/map.html")" "0" \
  "web/map.html still has no animation-frame loop after the roster panel was added"
assert_eq "$(grep -c 'setInterval(' "$ROOT/web/map.html")" "1" \
  "and still exactly one setInterval — the roster renders on calls from applyFeed/selection/focus/width, not a timer of its own"

# T069 (contracts/page-roster.md, FR-036): the roster render path is guarded
# so a page served without roster.js keeps working rather than throwing.
# Mutation-checked by hand: with this guard line removed from web/map.html,
# this assertion fails; restored, it passes again. Not exercised through a
# live serve process here, because that would mean pointing a real server at
# the suite's shared fixture directories mid-run, which corrupts state for
# every section that follows (confirmed while writing this assertion).
assert_contains "$_maphtml" 'if (!window.CCWATCH_ROSTER) return;' \
  "renderRoster's own body is guarded by window.CCWATCH_ROSTER"

# T021/contracts/page-modal.md §5: the figure's keyboard-opener aria-label is
# written from the same titleBits(row) the <title> uses, so the two cannot
# disagree. Mutation-checked: with the aria-label line removed, or written
# from a different call, this assertion fails.
_updatefigure_js=$(awk '/^function updateFigure\(/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_updatefigure_js" 'b.setAttribute("aria-label", "agent " + row.name + ": " + titleBits(row));' \
  "updateFigure writes aria-label from the same titleBits(row) call the tooltip uses"
assert_contains "$_updatefigure_js" 'b.title = titleBits(row);' \
  "and the tooltip is still the same titleBits(row) call"

# T029/FR-028/D17: #killbar is present whether or not killing is permitted —
# no display:none rule left on it — and the disabled attribute and doKill()'s
# own handler guard are two independent reasons a disabled control issues
# nothing. Mutation-checked: reintroducing `#killbar { display:none }`, or
# removing either the disabled write or doKill's early return, fails this.
assert_not_contains "$(grep '#killbar {' "$ROOT/web/map.html")" 'display:none' \
  "#killbar carries no display:none rule"
_dokill_js=$(awk '/^async function doKill\(/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_dokill_js" 'if (!CAN_KILL || !row) return;' \
  "doKill() guards independently of the disabled attribute"
_renderkill_js=$(awk '/^function renderKill\(/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_renderkill_js" 'startBtn.disabled = kill.state !== "ready";' \
  "and #killstart's disabled attribute is written from the kill model's state"

# T039/SC-010/FR-016: the conversation's own polling still runs through the
# page's one shared setInterval, no new requestAnimationFrame loop was added
# to drive it, and the turn body's single innerHTML write is still md.js's
# escape-first render. Mutation-checked: adding a second setInterval or a
# requestAnimationFrame call, or writing .what from anything but
# CCWATCH_MD.render, fails this.
_setinterval_count=$(grep -c 'setInterval(' "$ROOT/web/map.html")
assert_eq "$_setinterval_count" "1" "setInterval still occurs exactly once in web/map.html"
_raf_count=$(grep -c 'requestAnimationFrame(' "$ROOT/web/map.html")
assert_eq "$_raf_count" "0" "requestAnimationFrame occurs zero times in web/map.html"
assert_contains "$_maphtml" 'what.innerHTML = CCWATCH_MD.render(t.text || "");' \
  "the .what innerHTML write is still CCWATCH_MD.render's escape-first render"

# T049/FR-025/FR-026: doSend and doKill's fetch calls both still carry the
# per-run token, the SEND_TOKEN placeholder is byte-identical, and #ifoot is
# never assigned style.display (the send control stays present and disabled,
# never hidden). Mutation-checked: dropping either X-CCWatch-Token header,
# rewriting the placeholder, or reintroducing an ifoot.style.display write
# fails this.
_tokenheader_count=$(grep -c 'X-CCWatch-Token": SEND_TOKEN' "$ROOT/web/map.html")
assert_eq "$_tokenheader_count" "2" \
  "doSend and doKill's fetch calls both carry X-CCWatch-Token (2 occurrences)"
assert_contains "$_maphtml" 'const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";' \
  "the SEND_TOKEN placeholder line is byte-identical"
assert_not_contains "$_maphtml" '"ifoot").style.display' \
  "#ifoot is never assigned style.display in web/map.html"

# T056/FR-036/FR-038/D3: the dialog has no <form method="dialog"> (Enter would
# otherwise submit and close it unexpectedly), showModal() is called exactly
# once (the native trap/inert-background is supplied by the browser, not
# reimplemented), and every figure carries the attributes its keyboard opener
# needs. Mutation-checked: adding a <form method="dialog"> inside #agentmodal,
# a second showModal() call, or dropping tabindex/role from makeFigure all
# fail this.
assert_not_contains "$_maphtml" 'method="dialog"' \
  "web/map.html contains no <form method=\"dialog\">"
# Three: the agent panel, the map key and the alert popover. All are <dialog> +
# showModal() rather than styled divs, so the focus trap, the inert background
# and Escape-to-close come from the platform instead of being reimplemented
# three times — and a <dialog> in the top layer is also the one popover shape
# that cannot contribute to the flex column's height, which is the whole reason
# the alert panel is one (web/alerts.js).
_showmodal_count=$(grep -c '\.showModal()' "$ROOT/web/map.html")
assert_eq "$_showmodal_count" "3" "showModal() opens all three dialogs, and nothing else"
# ⚠️ A closed <dialog> must stay closed. An unconditional `display:flex` on the
# dialog overrode the user agent's `dialog:not([open]) { display:none }`, so the
# closed agent panel rendered in the document flow below the map — a chat window
# you could see and not use, and 176px of the page scroll it caused.
assert_eq "$(grep -c 'dialog#[a-z]*\[open\]' "$ROOT/web/map.html")" "3" \
  "each dialog's display is scoped to [open], so a closed one cannot render"

# ⚠️ The page fills the viewport and does not scroll — #board does, inside it.
# The map box was once `calc(100vh - 8rem)`, and 8rem was a guess at the chrome
# that missed three of its four parts — the host-pressure banner (present only sometimes, so the
# guess was wrong only sometimes), the legend and the footer. Measured 223px of
# chrome against a 128px allowance: the page scrolled by 258px and the map was
# shorter than the room it had. A flex column cannot be wrong about a height it
# never has to predict, so the guard is against the return of the prediction.
# The sometimes-appearing banners are themselves gone now — their conditions are
# in the header's alert control, out of this column's flow, and verify-ui
# asserts the board's top edge does not move when one arrives.
# ⚠️ Matches a DECLARATION, not the word. The first version grepped the whole
# file for `calc(100vh -` and was tripped by the comment above the fix that
# explains why the fix exists — an assertion failing on its own documentation.
assert_eq "$(grep -cE 'height: *calc\(100vh' "$ROOT/web/map.html")" "0" \
  "no hardcoded viewport-minus-chrome height — the page column derives it"
assert_contains "$_maphtml" 'html, body { height:100%; }' \
  "the page is a full-height column"
assert_contains "$_maphtml" '#stage { flex:1 1 auto; min-height:0; }' \
  "and the map stage takes the space the chrome leaves, shrinking below content"
# ⚠️ A figure is a real <button>, not an SVG group wearing role="button". As a
# <g> it needed an explicit tabindex, an explicit role, a drawn focus ring and
# a keydown handler to honour Enter and Space — four separate things that each
# had to be right for the map not to be a control some people cannot operate.
# What is asserted is the element, because the element is what supplies all
# four: a `<div role="button" tabindex="0">` would satisfy a grep for the role
# and still be the thing this replaced.
_makefigure_js=$(awk '/^function makeFigure\(/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_makefigure_js" 'el("button", "agent")' \
  "makeFigure builds each figure as a real <button>"
assert_contains "$_makefigure_js" 'b.type = "button"' \
  "and types it, so it cannot submit anything"
# And the hand-rolled keyboard support is gone with the reason for it: a
# keydown handler that re-implements Enter/Space on a real button is a second
# path to the same action, and the two drift.
assert_not_contains "$_maphtml" 'e.key === " " || e.key === "Spacebar"' \
  "and no hand-written Enter/Space handler shadows the button's own activation"

# T057/research.md D6: #rosteropen is built outside #rosterlist (role="option"
# rows have presentational children and cannot themselves host a button), and
# #rosterlist carries aria-keyshortcuts for its "o" opener. Mutation-checked:
# moving #rosteropen's creation inside the list builder, or dropping the
# aria-keyshortcuts write, fails this.
_rosterbuild_js=$(awk '/const list = document.createElement\("div"\);/,/roster.append\(/' "$ROOT/web/map.html")
assert_contains "$_rosterbuild_js" 'list.setAttribute("aria-keyshortcuts", "o");' \
  "#rosterlist carries aria-keyshortcuts"
assert_contains "$_maphtml" 'roster.append(title, open, note, gone, list);' \
  "and #rosteropen is a sibling of #rosterlist under #roster, not appended into the listbox"

# ============================================================ repo identity ==
printf '\nrepo identity\n'

# ⚠️ The project a session belongs to is the git REMOTE, not the directory
# basename. The path-based version was wrong three ways at once on one real
# machine — see collect_repos — and it also broke deploys silently, because
# `gh` returns owner/name and a territory labelled "platform" could never match
# a run on "acme/checkout-api".
RH="$WORK/repo-home"
mkdir -p "$RH"
# A repo whose DIRECTORY NAME DIFFERS FROM ITS REMOTE — the case the old code
# got wrong. A fixture that named them the same would pass either way.
mkrepo() { # mkrepo <dir> <remote-slug> <branch>
  mkdir -p "$1"
  git -C "$1" init -q -b "$3" 2>/dev/null
  git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name t
  git -C "$1" remote add origin "git@github.com:$2.git"
  printf 'x\n' > "$1/f"; git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm i
}
mkrepo "$WORK/localdirname" "acme/actual-repo-name" "main"
mkrepo "$WORK/other" "acme/other-repo" "feature/x"

mksess 9201 rrrrrrrr-0000-0000-0000-000000000001 alpha "$WORK/localdirname" idle cli
mktrans rrrrrrrr-0000-0000-0000-000000000001 20
mksess 9202 rrrrrrrr-0000-0000-0000-000000000002 beta "$WORK/other" busy cli
mktrans rrrrrrrr-0000-0000-0000-000000000002 20
mkps 9201 "0:10.00" >  "$WORK/ps-r"
mkps 9202 "0:10.00" >> "$WORK/ps-r"
rj() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-r" CCWATCH_HOME="$RH" \
       NO_COLOR=1 "$CCWATCH" --json 2>/dev/null; }
_rj=$(rj)
assert_eq "$(printf '%s' "$_rj" | jq -r '.sessions[] | select(.name=="alpha") | .repo')" \
  "acme/actual-repo-name" "the repo comes from the git remote, not the directory name"
assert_eq "$(printf '%s' "$_rj" | jq -r '.sessions[] | select(.name=="alpha") | .project')" \
  "actual-repo-name" "and the project shown is the repo, not the directory it sits in"
assert_eq "$(printf '%s' "$_rj" | jq -r '.sessions[] | select(.name=="beta") | .branch')" \
  "feature/x" "the branch is carried too, since that is what separates two worktrees of one repo"

# A directory with no remote must not be silently folded into a real
# repository — it falls back to its own name and reports no repo.
mkdir -p "$WORK/plainbox"
mksess 9203 rrrrrrrr-0000-0000-0000-000000000003 gamma "$WORK/plainbox" idle cli
mktrans rrrrrrrr-0000-0000-0000-000000000003 20
mkps 9203 "0:10.00" >> "$WORK/ps-r"
_rj2=$(rj)
assert_eq "$(printf '%s' "$_rj2" | jq -r '.sessions[] | select(.name=="gamma") | .repo')" "null" \
  "a directory with no git remote reports no repo rather than guessing one"
assert_eq "$(printf '%s' "$_rj2" | jq -r '.sessions[] | select(.name=="gamma") | .project')" \
  "plainbox" "and falls back to its own directory name"

# The identity is cached, because it costs two git subprocesses per directory.
[ -f "$RH/repos.json" ] && t_pass "the repo lookup is cached" \
  || t_fail "the repo lookup is cached" "no repos.json written"
assert_eq "$(jq -r --arg c "$WORK/localdirname" '.[$c].slug' "$RH/repos.json")" \
  "acme/actual-repo-name" "with the resolved slug keyed by directory"

# Unfinished runs carry it too, so a crashed run can be attributed to a repo.
RSPEC="$WORK/localdirname/specs/001-thing/.pipeline"
mkdir -p "$RSPEC"
cat > "$RSPEC/state.json" <<EOF
{"version":1,"feature_dir":"$WORK/localdirname/specs/001-thing","branch":"main",
 "phases":{"plan":{"status":"interrupted","session_id":"zzzz-1","model":"opus","cost_usd":3.5,
                   "started_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}}}
EOF
assert_eq "$(rj | jq -r '.unfinished[] | select(.phase=="plan") | .repo')" "acme/actual-repo-name" \
  "an unfinished run is attributed to the repo it belongs to"
rm -f "$FH/sessions/9201.json" "$FH/sessions/9202.json" "$FH/sessions/9203.json"

# ============================================================== transcript ===
printf '\nconversation\n'

# Being able to read what an agent is doing, without shipping whatever its tool
# calls happened to print.
CH="$WORK/convo-home"; mkdir -p "$CH"
CP="$FH/projects/-convo-repo"; mkdir -p "$CP"
CSID=cccccccc-0000-0000-0000-000000000001
{
  printf '{"type":"user","sessionId":"%s","timestamp":"2026-09-07T10:00:00Z","cwd":"/c",' "$CSID"
  printf '"message":{"role":"user","content":"please do the thing"}}\n'
  printf '{"type":"assistant","sessionId":"%s","timestamp":"2026-09-07T10:00:05Z","cwd":"/c",' "$CSID"
  printf '"message":{"role":"assistant","content":[{"type":"text","text":"on it"},'
  printf '{"type":"tool_use","name":"Bash","input":{"command":"cat /etc/hosts"}}]}}\n'
  printf '{"type":"user","sessionId":"%s","timestamp":"2026-09-07T10:00:06Z","cwd":"/c",' "$CSID"
  printf '"toolUseResult":{"x":1},"message":{"role":"user","content":[{"type":"tool_result",'
  printf '"content":"SECRET-FILE-CONTENTS-THAT-MUST-NOT-BE-SHIPPED"}]}}\n'
  printf '{"type":"user","sessionId":"%s","timestamp":"2026-09-07T10:00:07Z","cwd":"/c",' "$CSID"
  printf '"isMeta":true,"message":{"role":"user","content":"<task-notification>x</task-notification>"}}\n'
  printf '{"type":"user","sessionId":"%s","timestamp":"2026-09-07T10:00:08Z","cwd":"/c",' "$CSID"
  printf '"isMeta":true,"origin":{"kind":"peer","from":"uds:/tmp/cc-socks/9204.sock"},'
  printf '"message":{"role":"user","content":"a word from another session"}}\n'
} > "$CP/$CSID.jsonl"

mksess 9204 dddddddd-0000-0000-0000-00000000000c talker "$WORK/other" idle cli
mkps 9204 "0:10.00" > "$WORK/ps-c2"
cv() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-c2" CCWATCH_HOME="$CH" \
       NO_COLOR=1 "$CCWATCH" convo "$@" 2>/dev/null; }
_cv=$(cv --json -n 10 "$CSID")
assert_eq "$(printf '%s' "$_cv" | jq '.turns | length')" "5" "every conversational turn is read"
assert_eq "$(printf '%s' "$_cv" | jq -r '[.turns[].kind] | join(",")')" \
  "said,assistant,tool_result,system,said" \
  "and each is classified: what you said, what Claude said, a tool result, a system event, a peer"

# ⚠️ The one that matters. Tool results are whatever the tool printed — file
# contents, secrets, megabytes. They are reduced to a SIZE, never shipped.
assert_not_contains "$_cv" "SECRET-FILE-CONTENTS" \
  "a tool result's contents are NEVER included, only its size"
assert_contains "$_cv" "bytes" "the size is reported in its place"
# A tool call is summarised by name and one argument, not by its full input.
assert_contains "$_cv" "Bash" "a tool call is named"
assert_contains "$_cv" "cat /etc/hosts" "with a short argument summary so it is identifiable"

# A task-notification arrives as a user-role turn. Calling it "you" attributes
# machine output to the person.
assert_eq "$(printf '%s' "$_cv" | jq -r '[.turns[] | select(.kind=="system")] | length')" "1" \
  "a task notification is a system event, not something you said"
# ...but a peer message is a peer message even though it is also isMeta, which
# an earlier ordering of these checks got wrong.
assert_eq "$(printf '%s' "$_cv" | jq -r '[.turns[] | select(.origin=="peer")] | .[0].from')" \
  "talker" "and a peer message keeps its origin, resolved to the sender's name"

# Only the tail of the file is read. A transcript can be hundreds of megabytes.
assert_contains "$(cv -n 2 "$CSID")" "10:00" "the terminal view renders turns with timestamps"
_bytes=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-c2" CCWATCH_HOME="$CH" \
         CCWATCH_TAIL_BYTES=700 NO_COLOR=1 "$CCWATCH" convo --json -n 10 "$CSID" 2>/dev/null \
         | jq '.turns | length')
[ "${_bytes:-99}" -lt 5 ] && t_pass "a byte-limited tail reads fewer turns, so huge transcripts stay cheap" \
  || t_fail "a byte-limited tail reads fewer turns" "got $_bytes turns with a 700-byte tail"
# And a byte tail starts mid-line, which must not abort the parse.
[ "${_bytes:-0}" -ge 1 ] && t_pass "and a partial first line is skipped rather than aborting the read" \
  || t_fail "and a partial first line is skipped rather than aborting the read" "got 0 turns"
rm -f "$FH/sessions/9204.json"

# ================================================================= roster ====
printf '\nroster\n'

# The answer to "if the machine restarts, can I get back quickly". Transcripts
# survive and are the resume authority, but they do not record which sessions
# were open TOGETHER, what each was called, or what it was doing when
# everything stopped.
mksess 9205 eeeeeeee-0000-0000-0000-0000000000aa rostered "$WORK/other" waiting cli "your approval"
mktrans eeeeeeee-0000-0000-0000-0000000000aa 20
mkps 9205 "0:10.00" > "$WORK/ps-ro"
CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-ro" CCWATCH_HOME="$RH" \
  NO_COLOR=1 "$CCWATCH" once >/dev/null 2>&1
assert_eq "$(jq -r '[.sessions[] | select(.name=="rostered")] | length' "$RH/roster.json" 2>/dev/null)" "1" \
  "drawing the table writes down what was live"
assert_eq "$(jq -r '.sessions[] | select(.name=="rostered") | .token' "$RH/roster.json")" "waiting" \
  "including what each session was doing at the time"
assert_eq "$(jq -r '.sessions[] | select(.name=="rostered") | .repo' "$RH/roster.json")" \
  "acme/other-repo" "and which repo it was in"

# The reboot case: nothing is running, and the roster is the only thing that
# remembers the names and states.
: > "$WORK/ps-none"
_res=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-none" CCWATCH_HOME="$RH" \
       NO_COLOR=1 "$CCWATCH" resume -n 1 2>&1)
assert_contains "$_res" "LAST KNOWN ROSTER" "resume reports the last known roster when nothing is running"
assert_contains "$_res" "rostered" "naming the session"
assert_contains "$_res" "waiting" "and what it was doing when it stopped"
assert_contains "$_res" "claude --resume eeeeeeee-0000-0000-0000-0000000000aa" \
  "with the command to reopen it"
# A session that IS still running must not be listed as needing recovery.
_res2=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-ro" CCWATCH_HOME="$RH" \
        NO_COLOR=1 "$CCWATCH" resume -n 1 2>&1)
assert_not_contains "$_res2" "LAST KNOWN ROSTER" \
  "and says nothing about the roster when everything in it is still running"
rm -f "$FH/sessions/9205.json"

# ========================================================== pending asks =====
printf '\npending questions\n'

# WHAT a blocked session is asking, not merely that it is blocked. The registry
# only ever gives a label ("input needed"); the question, and every option with
# its description, is the input to an AskUserQuestion tool call in the
# transcript.
AH="$WORK/ask-home"; mkdir -p "$AH"
AP="$FH/projects/-ask-repo"; mkdir -p "$AP"
ASID=aaaaaaaa-1111-0000-0000-000000000001

# <sid> <tool-use-id> <question>: an AskUserQuestion call with two options.
mkask() {
  printf '{"type":"assistant","sessionId":"%s","timestamp":"2026-09-07T10:00:00Z","cwd":"/a",' "$1" >>"$AP/$1.jsonl"
  printf '"message":{"role":"assistant","content":[{"type":"tool_use","id":"%s",' "$2" >>"$AP/$1.jsonl"
  printf '"name":"AskUserQuestion","input":{"questions":[{"question":"%s","header":"H",' "$3" >>"$AP/$1.jsonl"
  printf '"options":[{"label":"Yes","description":"do it"},{"label":"No","description":"do not"}]}]}}]}}\n' >>"$AP/$1.jsonl"
}
# <sid> <tool-use-id>: the answer to one.
mkanswer() {
  printf '{"type":"user","sessionId":"%s","timestamp":"2026-09-07T10:00:01Z","cwd":"/a",' "$1" >>"$AP/$1.jsonl"
  printf '"toolUseResult":{"ok":1},"message":{"role":"user","content":[{"type":"tool_result",' >>"$AP/$1.jsonl"
  printf '"tool_use_id":"%s","content":"Yes"}]}}\n' "$2" >>"$AP/$1.jsonl"
}

mkask "$ASID" toolu_ANSWERED "an old question that was answered"
mkanswer "$ASID" toolu_ANSWERED
mkask "$ASID" toolu_PENDING "should I deploy on a Friday?"

mksess 9301 "$ASID" asker "$WORK/other" waiting cli "input needed"
mkps 9301 "0:10.00" > "$WORK/ps-ask"
aj() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-ask" CCWATCH_HOME="$AH" \
       NO_COLOR=1 "$CCWATCH" --json 2>/dev/null; }
_aj=$(aj)
assert_eq "$(printf '%s' "$_aj" | jq -r '.sessions[] | select(.name=="asker") | .questions[0].question')" \
  "should I deploy on a Friday?" "the pending question is read out of the transcript"
assert_eq "$(printf '%s' "$_aj" | jq -r '[.sessions[] | select(.name=="asker") | .questions[0].options[].label] | join(",")')" \
  "Yes,No" "with every option it offered"
assert_contains "$_aj" "do not" "and each option's description, which is where the reasoning is"

# ⚠️ The property that makes this trustworthy: an ANSWERED question must never
# be shown as pending. Otherwise the panel tells you an agent needs you when it
# does not, and you learn to ignore it.
assert_not_contains "$(printf '%s' "$_aj" | jq -c '.sessions[] | select(.name=="asker") | .questions')" \
  "an old question that was answered" "an already-answered question is not reported as pending"

# Answering the pending one must clear it.
mkanswer "$ASID" toolu_PENDING
assert_eq "$(aj | jq -r '.sessions[] | select(.name=="asker") | .questions')" "null" \
  "once answered, the question stops being reported"

# A question far from the end of a large transcript is still found. A fixed-size
# tail missed exactly this: a real 4.9MB transcript had its last question 850KB
# from the end.
mkask "$ASID" toolu_FARBACK "a question followed by a great deal of output"
python3 - "$AP/$ASID.jsonl" <<'PYEOF'
import json, sys
# ~900KB of unrelated turns after the question, which a fixed tail would skip past.
with open(sys.argv[1], "a") as fh:
    for i in range(700):
        fh.write(json.dumps({"type": "assistant", "sessionId": "x",
                             "timestamp": "2026-09-07T10:00:02Z", "cwd": "/a",
                             "message": {"role": "assistant",
                                         "content": [{"type": "text", "text": "x" * 1200}]}}) + "\n")
PYEOF
assert_eq "$(aj | jq -r '.sessions[] | select(.name=="asker") | .questions[0].question')" \
  "a question followed by a great deal of output" \
  "a pending question is found however far it sits from the end of the file"

# A waiting session with no AskUserQuestion at all — a permission prompt, say —
# must report no question rather than inventing one from an older call.
mksess 9302 aaaaaaaa-1111-0000-0000-000000000002 dialoger "$WORK/other" waiting cli "permission to run rm"
mktrans aaaaaaaa-1111-0000-0000-000000000002 20
mkps 9302 "0:10.00" >> "$WORK/ps-ask"
assert_eq "$(aj | jq -r '.sessions[] | select(.name=="dialoger") | .questions')" "null" \
  "a dialog that is not an AskUserQuestion reports no question rather than guessing"
assert_contains "$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-ask" CCWATCH_HOME="$AH" \
  NO_COLOR=1 "$CCWATCH" ask 2>&1)" "no question recorded" \
  "and says so, rather than showing an empty panel"
assert_contains "$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-ask" CCWATCH_HOME="$AH" \
  NO_COLOR=1 "$CCWATCH" ask 2>&1)" "a question followed by" "ask lists every blocked session at once"

# A session that is NOT waiting is not scanned for questions at all — that is
# what keeps this from being a transcript read per session per refresh.
mksess 9303 aaaaaaaa-1111-0000-0000-000000000003 busybody "$WORK/other" busy cli
mktrans aaaaaaaa-1111-0000-0000-000000000003 5
mkps 9303 "0:10.00" >> "$WORK/ps-ask"
assert_eq "$(aj | jq -r '.sessions[] | select(.name=="busybody") | .questions')" "null" \
  "a session that is not waiting carries no question"
rm -f "$FH/sessions/9301.json" "$FH/sessions/9302.json" "$FH/sessions/9303.json"

# =================================================================== host ====
printf '\nhost pressure\n'

# Why an agent died, when it died for a reason unrelated to Claude. A session
# killed by the OS under memory pressure leaves exactly the same trace as one
# that exited cleanly — its registry file disappears — so without this the tool
# can say a session is gone but not why. Measured on the machine this was built
# on: 26.3GB of 27.6GB swap in use, 58MB free RAM, and the OS reaping
# background tasks.
_h=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
     NO_COLOR=1 "$CCWATCH" --json 2>/dev/null | jq -c '.host')
t_note "host reports: ${_h:-<nothing>}"

# ⚠️ Asserted field by field, NOT by grepping the JSON for the substring
# "null". A host with swap disabled — a CI runner, a VM — legitimately reports
# `swap_used_pct: null`, and a substring check fails on that while the
# collection is working perfectly. That is exactly how this first went red on
# CI while passing on the machine it was written on.
assert_eq "$(printf '%s' "$_h" | jq -r \
    'if type == "object" and has("ram_free_mb") then "ok" else "missing" end')" "ok" \
  "host memory state is collected"

# A percentage requires swap to exist. Where it does not, `null` is the honest
# reading and 0% would be a lie — "0% of swap used" says there is swap and it
# is empty. So this skips rather than failing, with the reason stated: a host
# without swap is not a defect in ccwatch.
_swp=$(printf '%s' "$_h" | jq -r '.swap_used_pct // "none"')
_swt=$(printf '%s' "$_h" | jq -r '.swap_total_mb // "none"')
case "$_swp" in
  none) t_skip "swap usage is read as a percentage" \
          "this host reports no swap percentage (swap_total_mb=$_swt)";;
  ''|*[!0-9]*) t_fail "swap usage is read as a percentage" "got '$_swp'";;
  *) t_pass "swap usage is read as a percentage";;
esac
# The flag is derived from a threshold, so it can be exercised either way on any
# machine rather than only on one that happens to be struggling.
_hi=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
      CCWATCH_SWAP_WARN=0 NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_contains "$_hi" "host under memory pressure" \
  "past the threshold the table says the host is under pressure"
assert_contains "$_hi" "looks exactly" \
  "and explains that a killed session is indistinguishable from a clean exit"
# Below the threshold it says NOTHING. A monitoring tool that reports normal
# conditions on every refresh trains you to skip the line that eventually is not.
_lo=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-u" CCWATCH_HOME="$SLH" \
      CCWATCH_SWAP_WARN=101 NO_COLOR=1 "$CCWATCH" once 2>&1)
assert_not_contains "$_lo" "host under memory pressure" \
  "and stays silent when the host is healthy"

# =================================================================== kill ====
printf '\nkill\n'

# The one destructive thing the tool does, so the assertions are mostly about
# what it REFUSES. A real process is never killed here: the fixtures use pids
# that do not exist, so the guards are exercised without collateral.
KH="$WORK/kill-home"; mkdir -p "$KH"
kl() { CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-k" CCWATCH_HOME="$KH" \
       NO_COLOR=1 "$CCWATCH" kill "$@" 2>&1; }

# A session mid-turn may be part-way through a tool call, so the working tree
# could be left half-edited. Refused rather than warned about — a warning in a
# list of nineteen rows is a warning nobody reads.
mksess 9401 kkkkkkkk-0000-0000-0000-000000000001 busyone "$WORK/other" busy cli
mktrans kkkkkkkk-0000-0000-0000-000000000001 10
mkps 9401 "0:10.00" > "$WORK/ps-k"
_kb=$(kl -y busyone; echo "rc=$?")
assert_contains "$_kb" "mid-turn" "a session that is mid-turn is refused"
assert_contains "$_kb" "rc=1" "and refusing is a failure, not a silent no-op"
assert_contains "$_kb" "--force" "with the escape hatch named"

# A live spec-run phase is a paid model call in flight. Killing it wastes what
# has been spent and leaves the pipeline recording a crash.
KSPEC="$WORK/other/specs/001-k/.pipeline"; mkdir -p "$KSPEC"
cat > "$KSPEC/state.json" <<EOF
{"version":1,"feature_dir":"$WORK/other/specs/001-k","branch":"main",
 "phases":{"implement":{"status":"running","session_id":"kkkkkkkk-0000-0000-0000-000000000002",
                        "model":"sonnet","cost_usd":9.5,"runner_pid":$$,
                        "started_at":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}}}
EOF
mksess 9402 kkkkkkkk-0000-0000-0000-000000000002 phaserunner "$WORK/other" idle sdk-cli
mktrans kkkkkkkk-0000-0000-0000-000000000002 10
mkps 9402 "0:10.00" >> "$WORK/ps-k"
_kp=$(kl -y phaserunner; echo "rc=$?")
assert_contains "$_kp" "spec-run phase" "a session running a spec-run phase is refused"
assert_contains "$_kp" "paid model call" "and says what killing it would waste"
assert_contains "$_kp" "rc=1" "and is a failure"

# Declining at the prompt must change nothing.
mksess 9403 kkkkkkkk-0000-0000-0000-000000000003 idleone "$WORK/other" idle cli
mktrans kkkkkkkk-0000-0000-0000-000000000003 10
mkps 9403 "0:10.00" >> "$WORK/ps-k"
_kn=$(printf 'n\n' | CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-k" CCWATCH_HOME="$KH" \
      NO_COLOR=1 "$CCWATCH" kill idleone 2>&1)
assert_contains "$_kn" "Nothing killed" "declining the prompt kills nothing"

# What survives is stated every time, because that is what makes this
# recoverable rather than a deletion — and the operator should not have to
# remember it.
_kr=$(kl -y idleone)
assert_contains "$_kr" "conversation is kept" "the kill states that the conversation survives"
assert_contains "$_kr" "claude --resume kkkkkkkk-0000-0000-0000-000000000003" \
  "and prints the command that reopens it"
# A pid that does not exist is already gone, so this reports the outcome rather
# than hanging on a process that will never disappear.
assert_contains "$_kr" "killed" "a session whose process is already gone is reported as killed"
assert_eq "$(jq -r 'select(.event=="ccwatch.kill") | .target' "$KH/events.jsonl" 2>/dev/null | tail -1)" \
  "idleone" "every kill is recorded, so 'who stopped that agent' has an answer"
assert_contains "$(jq -c 'select(.event=="ccwatch.kill")' "$KH/events.jsonl" | tail -1)" '"rss_mb"' \
  "including how much memory it was holding"

# A waiting session is killable but says what is lost with it.
mksess 9404 kkkkkkkk-0000-0000-0000-000000000004 askingone "$WORK/other" waiting cli "your approval"
mktrans kkkkkkkk-0000-0000-0000-000000000004 10
mkps 9404 "0:10.00" >> "$WORK/ps-k"
assert_contains "$(kl -y askingone)" "waiting on you" \
  "killing a session that is waiting on you warns that its question is lost"
rm -f "$FH/sessions/9401.json" "$FH/sessions/9402.json" "$FH/sessions/9403.json" "$FH/sessions/9404.json"

# --- memory, which is the reason anyone reaches for kill -------------------
mksess 9405 kkkkkkkk-0000-0000-0000-000000000005 heavy "$WORK/other" idle cli
mktrans kkkkkkkk-0000-0000-0000-000000000005 10
# ps reports RSS in KB as its last column.
printf '%s %s %s %s\n' 9405 "$(date -r "$(( $(date '+%s') - 3600 ))" '+%a %b %e %T %Y')" "0:10.00" 204800 \
  > "$WORK/ps-mem"
_mem=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-mem" CCWATCH_HOME="$KH" \
       NO_COLOR=1 "$CCWATCH" --json 2>/dev/null)
assert_eq "$(printf '%s' "$_mem" | jq -r '.sessions[] | select(.name=="heavy") | .rss_mb')" "200" \
  "each session reports how much memory it is holding"
assert_eq "$(printf '%s' "$_mem" | jq -r '.host.idle_mb')" "200" \
  "and the host reports what the idle ones add up to, which is what killing them would release"
rm -f "$FH/sessions/9405.json"

# --- the regression that broke recovery ------------------------------------
#
# A transcript can end with metadata records carrying no cwd — `last-prompt`,
# `mode`, `pr-link` are written after the conversation. `resume` read only the
# LAST line, found a null cwd, and skipped the session: a session killed moments
# earlier was absent from its own recovery list. Found by killing one and
# looking for it.
MP="$FH/projects/-meta-repo"; mkdir -p "$MP"
MSID=ffffffff-0000-0000-0000-0000000000ff
{
  printf '{"type":"user","sessionId":"%s","cwd":"%s","gitBranch":"main","isSidechain":false,' "$MSID" "$WORK/other"
  printf '"message":{"role":"user","content":"real content"}}\n'
  printf '{"type":"last-prompt","sessionId":"%s","cwd":null}\n' "$MSID"
  printf '{"type":"mode","sessionId":"%s"}\n' "$MSID"
} > "$MP/$MSID.jsonl"
: > "$WORK/ps-empty2"
_rm=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-empty2" CCWATCH_HOME="$KH" \
      NO_COLOR=1 "$CCWATCH" resume -n 30 2>&1)
assert_contains "$_rm" "claude --resume $MSID" \
  "a transcript ending in metadata records is still offered for resume"


# ============================================================ roster-module ===
printf '\nroster-module\n'
#
# web/roster.js is the pure roster-row-shaping module for the docked agent
# panel (contracts/roster-js.md). It lives in its own file for the same
# reason web/md.js does: so these assertions
# can require() it under node without a browser.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/roster-check.js" <<'ROSTERJS'
var R = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}

// Seed: the module loads under node and exports an object.
(function () {
  check("seed require(roster.js) succeeds and exports an object",
        typeof R === "object" && R !== null, typeof R);
})();

// rowFields (contracts/roster-js.md §2, R-A..R-K)
(function () {
  check("R-A word is row.token verbatim, including an unrecognised token",
        R.rowFields({sid: "s", name: "n", token: "TELEPORTING"}, {}).word === "TELEPORTING");

  check("R-B where is repo · branch when repo is set",
        R.rowFields({sid: "s", name: "n", token: "idle", repo: "acme/checkout", branch: "main"}, {}).where
          === "acme/checkout · main");
  check("R-B where is exactly \"no repo\" when row.repo is null",
        R.rowFields({sid: "s", name: "n", token: "idle", repo: null}, {}).where === "no repo");

  check("R-C measure follows the waited row",
        R.rowFields({sid: "s", name: "n", token: "waiting", note: "input needed", waited: 90}, {}).measure
          === "input needed 1m");
  check("R-C measure follows the quiet note row",
        R.rowFields({sid: "s", name: "n", token: "HUNG?", note: "quiet", quiet: 700}, {}).measure
          === "quiet 11m");
  check("R-C measure falls back to a non-empty note",
        R.rowFields({sid: "s", name: "n", token: "sdk", note: "no status published", quiet: 5}, {}).measure
          === "no status published");
  check("R-C measure falls back to \"<quiet> ago\" with no note",
        R.rowFields({sid: "s", name: "n", token: "idle", note: "", quiet: 30}, {}).measure === "30s ago");

  check("R-D a null quiet with no note and no waited yields no measure key at all — never 0s",
        !("measure" in R.rowFields({sid: "s", name: "n", token: "idle", note: "", quiet: null}, {})));

  check("R-E no ctx key when context is null",
        !("ctx" in R.rowFields({sid: "s", name: "n", token: "busy", context: null}, {volatile: true})));
  check("R-E no ctx key when used_percentage is null",
        !("ctx" in R.rowFields({sid: "s", name: "n", token: "busy",
            context: {used_percentage: null}}, {volatile: true})));
  check("R-E no ctx key when not volatile, even with a real reading",
        !("ctx" in R.rowFields({sid: "s", name: "n", token: "busy",
            context: {used_percentage: 42}}, {volatile: false})));
  check("R-E ctx present and floored when volatile with a real reading",
        R.rowFields({sid: "s", name: "n", token: "busy",
          context: {used_percentage: 42.9}}, {volatile: true}).ctx === "ctx 42%");

  check("R-F no mem key when rss_mb is null",
        !("mem" in R.rowFields({sid: "s", name: "n", token: "busy", rss_mb: null}, {volatile: true})));
  check("R-F no mem key when not volatile, even with a real reading",
        !("mem" in R.rowFields({sid: "s", name: "n", token: "busy", rss_mb: 200}, {volatile: false})));
  check("R-F mem present when volatile with a real reading",
        R.rowFields({sid: "s", name: "n", token: "busy", rss_mb: 200}, {volatile: true}).mem === "200MB");

  check("R-G pipeline is a separate key from word, never concatenated",
        (function () {
          var f = R.rowFields({sid: "s", name: "n", token: "idle",
            pipeline: {phase: "plan", status: "running", crashed: true}}, {});
          return f.word === "idle" && f.pipeline === "plan/CRASHED" && f.word.indexOf("plan") === -1;
        })());
  check("R-H pipeline reads phase/CRASHED when crashed",
        R.rowFields({sid: "s", name: "n", token: "idle",
          pipeline: {phase: "plan", status: "running", crashed: true}}, {}).pipeline === "plan/CRASHED");
  check("R-H pipeline reads phase/status when not crashed",
        R.rowFields({sid: "s", name: "n", token: "idle",
          pipeline: {phase: "plan", status: "needs_input", crashed: false}}, {}).pipeline === "plan/needs_input");

  check("R-I an sdk-ts row carries its note and no invented measurement",
        R.rowFields({sid: "s", name: "n", token: "sdk-ts", note: "cannot verify progress", quiet: null}, {}).measure
          === "cannot verify progress");

  check("R-J asks present only with a question, bounded to ASK_CHARS",
        (function () {
          var noQ = R.rowFields({sid: "s", name: "n", token: "waiting", questions: null}, {});
          var longQ = "x".repeat(R.ASK_CHARS + 50);
          var f = R.rowFields({sid: "s", name: "n", token: "waiting",
            questions: [{question: longQ}]}, {});
          return !("asks" in noQ) && f.asks.length === R.ASK_CHARS;
        })());

  check("R-K age is absent when row.age is null — never dur(null)'s \"-\" as a reading",
        !("age" in R.rowFields({sid: "s", name: "n", token: "idle", age: null}, {})));
  check("R-K age present as a duration when row.age is a number",
        R.rowFields({sid: "s", name: "n", token: "idle", age: 90}, {}).age === "1m");

  // FR-006 spot-check (quickstart.md §2): every absent reading absent, never
  // 0/0%/0MB anywhere in the object.
  check("FR-006 a row with everything null yields no ctx, no mem, no 0/0%/0MB anywhere",
        (function () {
          var f = R.rowFields({sid: "s", name: "n", token: "sdk-ts", repo: null, branch: null,
            note: "cannot verify progress", quiet: null, waited: null, age: null,
            context: null, rss_mb: null, pipeline: null, questions: null}, {volatile: true});
          var s = JSON.stringify(f);
          return !("ctx" in f) && !("mem" in f)
            && s.indexOf("0%") === -1 && s.indexOf("0MB") === -1 && s.indexOf('"0"') === -1;
        })());
})();

// titleText (contracts/roster-js.md §3, T-A, T-B)
(function () {
  var row = {sid: "s", name: "n", token: "busy", note: "quiet but cpu moving", waited: null,
    quiet: 90, age: 300, pipeline: {phase: "plan", status: "running", crashed: false},
    questions: [{question: "proceed?"}], context: {used_percentage: 50}, rss_mb: 100};
  check("T-A titleText(row, true) contains every value rowFields produced",
        (function () {
          var f = R.rowFields(row, {volatile: true});
          var t = R.titleText(row, true);
          return t.indexOf(f.word) !== -1 && t.indexOf(f.measure) !== -1
            && t.indexOf(f.pipeline) !== -1 && t.indexOf(f.age) !== -1
            && t.indexOf(f.ctx) !== -1 && t.indexOf(f.mem) !== -1
            && t.indexOf("ASKS: " + f.asks) !== -1;
        })());
  check("T-B titleText(row, false) contains no % and no MB",
        R.titleText(row, false).indexOf("%") === -1 && R.titleText(row, false).indexOf("MB") === -1);
})();

// keysOf / reorderPlan (contracts/roster-js.md §4, O-A..O-E)
(function () {
  check("keysOf returns sids in arrival order, dropping any row with no sid",
        JSON.stringify(R.keysOf([{sid: "a"}, {sid: "b"}, {}, {sid: "c"}])) === '["a","b","c"]');

  check("O-A an unchanged order produces zero moves",
        R.reorderPlan(["a", "b", "c"], ["a", "b", "c"]).length === 0);

  check("O-B one row moving from last to first produces exactly one move",
        R.reorderPlan(["a", "b", "c", "d"], ["d", "a", "b", "c"]).length === 1);

  check("O-C a key in currentKeys but not wantedKeys produces no move for that key",
        R.reorderPlan(["a", "b", "x"], ["b", "a"]).every(function (m) { return m.key !== "x"; }));

  function applyPlan(current, plan) {
    var seq = current.slice();
    plan.forEach(function (m) {
      var pos = seq.indexOf(m.key);
      if (pos !== -1) seq.splice(pos, 1);
      var idx = m.before == null ? seq.length : seq.indexOf(m.before);
      seq.splice(idx === -1 ? seq.length : idx, 0, m.key);
    });
    return seq;
  }
  check("O-D applying the plan in order yields exactly wantedKeys",
        (function () {
          var current = ["a", "b", "c", "d"], wanted = ["c", "a", "d", "b"];
          var plan = R.reorderPlan(current, wanted);
          return JSON.stringify(applyPlan(current, plan)) === JSON.stringify(wanted);
        })());

  check("O-E a reversal of n keys produces at most n-1 moves",
        (function () {
          var current = ["a", "b", "c", "d", "e"];
          var wanted = current.slice().reverse();
          return R.reorderPlan(current, wanted).length <= current.length - 1;
        })());
})();

// nextFocus / focusTarget (contracts/roster-js.md §4, K-A..K-E, D4)
(function () {
  var keys = ["a", "b", "c"];

  check("K-A ArrowDown from the last row stays on the last row",
        R.nextFocus(keys, "c", "ArrowDown") === "c");
  check("K-B ArrowUp from the first row stays on the first row",
        R.nextFocus(keys, "a", "ArrowUp") === "a");
  check("ArrowDown moves to the next row",
        R.nextFocus(keys, "a", "ArrowDown") === "b");
  check("ArrowUp moves to the previous row",
        R.nextFocus(keys, "c", "ArrowUp") === "b");
  check("K-C Home returns the first key",
        R.nextFocus(keys, "c", "Home") === "a");
  check("K-C End returns the last key",
        R.nextFocus(keys, "a", "End") === "c");
  check("K-D a currentSid no longer in keys resolves to the first key",
        R.nextFocus(keys, "gone", "ArrowDown") === "a");
  check("K-E an empty keys list returns null for every key",
        R.nextFocus([], "a", "ArrowDown") === null
          && R.nextFocus([], null, "Home") === null);

  check("focusTarget keeps prevSid when it is still present",
        R.focusTarget("b", keys) === "b");
  check("D4 focusTarget returns null when prevSid has been dropped",
        R.focusTarget("gone", keys) === null);
})();

// resolveSelection / flyIdx (contracts/roster-js.md §5, S-A..S-I)
(function () {
  var sessions = [{sid: "a"}, {sid: "b"}];

  check("S-A sid present in a trusted payload resolves to present",
        R.resolveSelection("a", sessions, {trust: "ok"}).state === "present");
  check("S-B sid absent from a trusted payload resolves to gone",
        R.resolveSelection("z", sessions, {trust: "ok"}).state === "gone");
  check("S-C sid absent while the feed is down resolves to unknown, not gone",
        R.resolveSelection("z", sessions, {trust: "feed_down"}).state === "unknown");
  check("S-D sid absent while warming resolves to unknown",
        R.resolveSelection("z", sessions, {trust: "warming"}).state === "unknown");
  check("S-E no stored sid resolves to none regardless of the condition",
        R.resolveSelection(null, sessions, {trust: "ok"}).state === "none"
          && R.resolveSelection(null, sessions, {trust: "feed_down"}).state === "none");
  check("S-F sid present while the feed is down still resolves to present",
        R.resolveSelection("a", sessions, {trust: "feed_down"}).state === "present");
  check("S-G a malformed cond with no trust field is treated as untrusted, never ok",
        R.resolveSelection("z", sessions, {}).state === "unknown");

  // S-H/S-I retired with the camera: flyIdx answered "which zoom rung does a
  // far selection fly to", and there are no rungs. Revealing a selection is
  // now the figure's own scrollIntoView, which the browser owns and
  // verify-ui checks in a real one.
  check("S-H the module exports no camera-rung helper any more",
        R.flyIdx === undefined && R.NEAR_IDX === undefined);
})();

// Selection/width storage (contracts/roster-js.md §7, P-A..P-I)
(function () {
  var V = R.STORAGE_VERSION;

  check("P-A unparseable JSON returns null and does not throw",
        R.validateSelection("{not json") === null);
  check("P-B a wrong storage version returns null",
        R.validateSelection({v: V + 1, sid: "abc123"}) === null);
  check("P-C a sid that is not session-id-shaped returns null",
        R.validateSelection({v: V, sid: "not/a/sid!"}) === null);
  check("P-C a session-id-shaped sid round-trips",
        R.validateSelection({v: V, sid: "abc-123"}).sid === "abc-123");
  check("P-E an array, null or a primitive returns null",
        R.validateSelection([1, 2]) === null
          && R.validateSelection(null) === null
          && R.validateSelection("just a string, not json") === null);

  check("P-F a throwing getItem returns null and flips persistence to unavailable",
        (function () {
          var throwing = function () { throw new Error("boom"); };
          var before = R.persistence;
          var out = R.loadSelection(throwing);
          return out === null && R.persistence === "unavailable" && before !== undefined;
        })());
  check("P-G a throwing setItem flips persistence to unavailable and does not throw",
        (function () {
          var threw = false;
          try { R.saveSelection(function () { throw new Error("boom"); }, "x"); }
          catch (e) { threw = true; }
          return !threw && R.persistence === "unavailable";
        })());
  check("P-H persistence never returns to ok once unavailable, even after a call that succeeds",
        (function () {
          var calls = 0;
          R.saveSelection(function () { calls++; }, "x");
          return R.persistence === "unavailable" && calls === 1;
        })());
  check("P-I saveSelection(setItem, null) writes a fresh record clearing the old sid",
        (function () {
          var written = null;
          var freshSetItem = function (v) { written = v; };
          R.saveSelection(freshSetItem, null);
          if (written == null) return false;
          var parsed = JSON.parse(written);
          return parsed.sid === null && R.validateSelection(written) === null;
        })());
})();

// ⚠️ statements() and its nine assertions are gone with it. The roster no
// longer renders the feed condition in its own words: web/alerts.js does, in
// the header, and the assertions on those sentences are in the alerts-module
// section. Two renderings of one fact were two sets of words to keep in
// agreement, and the roster's own copy pushed the row list down whenever a
// condition arrived.

// goneText (contracts/roster-js.md §8, C-J).
//
// ⚠️ The other half of C-J — that the tombstone shares no leading clause with
// any sentence stating the feed is broken — has moved to the alerts-module
// section, where those sentences now live. It was written here as
// `if (typeof R.statements === "function")`, which is a check that reports
// nothing at all the moment that function stops existing; it would have gone
// quiet rather than red when statements() was deleted.
(function () {
  var gone = R.goneText("s1", "alpha");
  var goneLead = gone.split(" ").slice(0, 3).join(" ");

  check("C-J the tombstone names the session, not the feed",
        gone.indexOf("alpha") !== -1 && gone.toLowerCase().indexOf("the feed") === -1
          && gone.toLowerCase().indexOf("registry") === -1);

})();

// clampWidth/stacked (contracts/roster-js.md §6, W-A..W-F)
(function () {
  check("W-A a width below WIDTH_MIN clamps up",
        R.clampWidth(10, 1200) === R.WIDTH_MIN);
  check("W-B a width above WIDTH_MAX_PX clamps down",
        R.clampWidth(9999, 2000) === R.WIDTH_MAX_PX);
  check("W-C on a narrow window the fraction bound wins",
        R.clampWidth(500, 900) === 405);
  check("W-D a non-finite or non-number width returns WIDTH_DEFAULT",
        R.clampWidth(NaN, 1200) === R.WIDTH_DEFAULT
          && R.clampWidth("320", 1200) === R.WIDTH_DEFAULT
          && R.clampWidth(Infinity, 1200) === R.WIDTH_DEFAULT);
  check("W-E clampWidth is idempotent",
        (function () {
          var once = R.clampWidth(500, 900);
          return R.clampWidth(once, 900) === once;
        })());
  check("W-F the result never exceeds windowWidth for any windowWidth >= WIDTH_MIN / WIDTH_MAX_FRAC",
        (function () {
          var widths = [500, 1000, 2000, 4000];
          return widths.every(function (ww) {
            return R.clampWidth(99999, ww) <= ww;
          });
        })());
  check("stacked: below STACK_BREAKPOINT is stacked",
        R.stacked(500) === true);
  check("stacked: at or above STACK_BREAKPOINT is not stacked",
        R.stacked(720) === false && R.stacked(1200) === false);
})();

// width storage (contracts/roster-js.md §7, P-D plus the shared persistence
// flag from T035's selection storage)
(function () {
  check("P-D validateWidth returns null for a non-finite or non-number w",
        R.validateWidth({v: R.STORAGE_VERSION, w: "320"}) === null
          && R.validateWidth({v: R.STORAGE_VERSION, w: NaN}) === null);
  check("P-D validateWidth accepts a real number w at the current version",
        R.validateWidth({v: R.STORAGE_VERSION, w: 400}).w === 400);
  check("width storage round-trips through saveWidth/loadWidth",
        (function () {
          var store = {};
          R.saveWidth(function (v) { store.w = v; }, 444);
          return R.loadWidth(function () { return store.w; }).w === 444;
        })());
  check("saveWidth with a throwing setItem does not throw",
        (function () {
          var threw = false;
          try {
            R.saveWidth(function () { throw new Error("quota"); }, 400);
          } catch (e) { threw = true; }
          return !threw;
        })());
})();

process.stdout.write(out.join("\n") + "\n");
ROSTERJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/roster-check.js" "$ROOT/web/roster.js" 2>&1)
else
  t_skip "roster module" "node not installed"
fi


# =============================================================== modal-module ===
printf '\nmodal-module\n'
#
# web/modal.js is the pure per-agent-modal module (contracts/modal-js.md). It
# lives in its own file for the same reason web/md.js and web/roster.js do:
# so these assertions can require() it
# under node without a browser.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/modal-check.js" <<'MODALJS'
var M = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}

// Seed: the module loads under node and exports an object.
(function () {
  check("seed require(modal.js) succeeds and exports an object",
        typeof M === "object" && M !== null, typeof M);
})();

// statLines (contracts/modal-js.md §4, S-A..S-I)
(function () {
  var full = {age: "1m", ctx: "ctx 42%", mem: "200MB", pipeline: "plan/running", where: "acme/checkout · main"};
  var row = {sid: "s1", waited: 90, quiet: 700};

  check("S-A order is exactly silence, age, ctx, mem, pipeline, where, sid, edge:* for a row carrying all of them",
        (function () {
          var lines = M.statLines(full, row, {edges: [{dir: "out", other: "peer", count: 2, unknown: false}]});
          return lines.map(function (l) { return l.key; }).join(",")
            === "silence,age,ctx,mem,pipeline,where,sid,edge:0";
        })());

  check("S-B a waited row yields one silence line labelled waiting",
        M.statLines({}, {sid: "s", waited: 90}, {}).filter(function (l) { return l.key === "silence"; })[0].label
          === "waiting");
  check("S-B a quiet-only row yields one silence line labelled silent",
        M.statLines({}, {sid: "s", quiet: 700}, {}).filter(function (l) { return l.key === "silence"; })[0].label
          === "silent");
  check("S-B waited wins over quiet when both are present",
        M.statLines({}, {sid: "s", waited: 90, quiet: 700}, {}).filter(function (l) { return l.key === "silence"; }).length === 1
          && M.statLines({}, {sid: "s", waited: 90, quiet: 700}, {}).filter(function (l) { return l.key === "silence"; })[0].label === "waiting");

  check("S-C a row with neither waited nor quiet yields no silence line",
        M.statLines({}, {sid: "s", waited: null, quiet: null}, {}).filter(function (l) { return l.key === "silence"; }).length === 0);

  check("S-D an absent fields key yields no line at all — no 0/0%/0MB/-/null in any text",
        (function () {
          var lines = M.statLines({where: "no repo"}, {sid: "s", waited: null, quiet: null}, {});
          var s = JSON.stringify(lines);
          return lines.every(function (l) { return l.text !== "0" && l.text !== "0%" && l.text !== "0MB"
            && l.text !== "-" && l.text !== null; })
            && s.indexOf("0%") === -1 && s.indexOf("0MB") === -1;
        })());

  check("S-E with volatile: false (no ctx/mem keys), where and sid are still present",
        (function () {
          var lines = M.statLines({where: "acme/checkout · main"}, {sid: "s1"}, {});
          var keys = lines.map(function (l) { return l.key; });
          return keys.indexOf("ctx") === -1 && keys.indexOf("mem") === -1
            && keys.indexOf("where") !== -1 && keys.indexOf("sid") !== -1;
        })());

  check("S-F sid line text is row.sid verbatim, including a sid the module has never seen",
        M.statLines({}, {sid: "sid-never-seen-before"}, {}).filter(function (l) { return l.key === "sid"; })[0].text
          === "sid-never-seen-before");

  check("S-G where is exactly \"no repo\" with no repository named when row.repo is null",
        M.statLines({where: "no repo"}, {sid: "s"}, {}).filter(function (l) { return l.key === "where"; })[0].text
          === "no repo");

  check("S-H a crashed pipeline reads <phase>/CRASHED via fields.pipeline, not re-derived",
        M.statLines({pipeline: "plan/CRASHED"}, {sid: "s"}, {}).filter(function (l) { return l.key === "pipeline"; })[0].text
          === "plan/CRASHED");

  check("S-I every key in the returned array is unique",
        (function () {
          var lines = M.statLines(full, row, {edges: [
            {dir: "out", other: "a", count: 1, unknown: false},
            {dir: "in", other: "b", count: 2, unknown: false},
          ]});
          var keys = lines.map(function (l) { return l.key; });
          return keys.length === new Set(keys).size;
        })());

  // FR-011 spot-check (quickstart.md §2): a row with neither waited nor quiet
  // and no ctx/mem/age yields exactly where/sid, no 0/0%/0MB/-/null.
  check("FR-011 a row with nothing but where/sid yields exactly those two lines",
        (function () {
          var lines = M.statLines({where: "no repo"}, {sid: "s1", waited: null, quiet: null}, {});
          return lines.map(function (l) { return l.key; }).join(",") === "where,sid";
        })());
})();

// edgesFor (contracts/modal-js.md §5, E-A..E-H)
(function () {
  check("E-A an edge with neither end equal to name is excluded",
        M.edgesFor("me", [{from: "a", to: "b", count: 1}], ["a", "b", "me"]).length === 0);

  check("E-B from === name yields dir out",
        M.edgesFor("me", [{from: "me", to: "b", count: 1}], ["me", "b"])[0].dir === "out");
  check("E-B to === name yields dir in",
        M.edgesFor("me", [{from: "a", to: "me", count: 1}], ["me", "a"])[0].dir === "in");

  check("E-C count is e.count verbatim, no re-aggregation",
        M.edgesFor("me", [{from: "me", to: "b", count: 7}, {from: "me", to: "b", count: 3}], ["me", "b"])
          .map(function (e) { return e.count; }).join(",") === "7,3");

  check("E-D a far end absent from names sets unknown: true rather than dropping the edge",
        M.edgesFor("me", [{from: "me", to: "ghost", count: 1}], ["me"])[0].unknown === true);

  check("E-E a self-edge yields exactly one line",
        M.edgesFor("me", [{from: "me", to: "me", count: 1}], ["me"]).length === 1);

  check("E-F edges: [] yields []",
        M.edgesFor("me", [], ["me"]).length === 0);
  check("E-F edges: null yields []",
        M.edgesFor("me", null, ["me"]).length === 0);
  check("E-F an absent peers (undefined edges) yields []",
        M.edgesFor("me", undefined, ["me"]).length === 0);

  check("E-G neither last nor sample appears anywhere in the output",
        (function () {
          var out = M.edgesFor("me", [{from: "me", to: "b", count: 1, last: 123, sample: "secret text"}], ["me", "b"]);
          var s = JSON.stringify(out);
          return s.indexOf("123") === -1 && s.indexOf("secret text") === -1;
        })());

  check("E-H the rendered text carries the direction as a word as well as the arrow",
        (function () {
          var lines = M.statLines({}, {sid: "s"}, {edges: M.edgesFor("me", [{from: "me", to: "b", count: 2}], ["me", "b"])});
          var edgeLine = lines.filter(function (l) { return l.key.indexOf("edge:") === 0; })[0];
          return edgeLine.text.indexOf("→") !== -1 && edgeLine.text.indexOf("to") !== -1;
        })());
})();

// panel (contracts/modal-js.md §3, M-A..M-F)
(function () {
  var subject = {sid: "s1", name: "Foo"};
  var fields = {word: "busy", measure: "3m"};
  var row = {sid: "s1", name: "Foo"};

  check("M-A header.name is subject.name verbatim, not row.name",
        M.panel({row: {sid: "s1", name: "Different"}, fields: fields, subject: subject, names: [], edges: []})
          .header.name === "Foo");

  check("M-B header.status is \"<word> · <measure>\" when a measure exists",
        M.panel({row: row, fields: fields, subject: subject, names: [], edges: []}).header.status === "busy · 3m");
  check("M-B header.status is \"<word>\" when there is no measure",
        M.panel({row: row, fields: {word: "idle"}, subject: subject, names: [], edges: []}).header.status === "idle");
  check("M-B header.status is null when row is null",
        M.panel({row: null, fields: null, subject: subject, names: [], edges: []}).header.status === null);

  check("M-C header.status is byte-identical to the roster row's .rstatus join for the same fields",
        (function () {
          var status = M.panel({row: row, fields: fields, subject: subject, names: [], edges: []}).header.status;
          var rstatus = fields.measure != null ? `${fields.word} · ${fields.measure}` : fields.word;
          return status === rstatus;
        })());

  check("M-D panel invents no status word absent from row/fields — the header is a fixed join over fields alone",
        M.panel({row: row, fields: fields, subject: subject, names: [], edges: []}).header.status.indexOf("busy") !== -1);

  check("M-E with row: null, stats contains exactly the sid line",
        (function () {
          var m = M.panel({row: null, fields: null, subject: subject, names: [], edges: []});
          return m.stats.length === 1 && m.stats[0].key === "sid" && m.stats[0].text === "s1";
        })());

  check("M-F panel is a pure function: called twice with the same input it returns deeply equal models",
        (function () {
          var input = {row: row, fields: fields, subject: subject, names: ["Foo"], edges: []};
          var a = JSON.stringify(M.panel(input));
          var b = JSON.stringify(M.panel(input));
          return a === b;
        })());
  check("M-F panel mutates no part of its input",
        (function () {
          var edges = [{from: "Foo", to: "b", count: 1}];
          var input = {row: row, fields: fields, subject: subject, names: ["Foo", "b"], edges: edges};
          var before = JSON.stringify(input);
          M.panel(input);
          return JSON.stringify(input) === before;
        })());
})();

// killModel (contracts/modal-js.md §8, K-A..K-K)
(function () {
  var row = {sid: "s1", name: "web-app", rss_mb: 1832, token: "idle",
             pipeline: {status: "idle", phase: "plan"}};
  var fields = {mem: "1832MB"};

  check("K-A canKill: false yields state: disabled with a reason naming --allow-kill",
        (function () {
          var k = M.killModel({row: row, fields: fields, volatile: true, canKill: false, confirmOpen: false});
          return k.state === "disabled" && k.reason.indexOf("ccwatch serve --allow-kill") !== -1
            && k.startLabel.toLowerCase().indexOf("kill") !== -1;
        })());

  check("K-B canKill: false yields confirmOpen: false even when the caller passed confirmOpen: true",
        M.killModel({row: row, fields: fields, volatile: true, canKill: false, confirmOpen: true}).confirmOpen === false);

  check("K-C canKill: true with a row yields state: ready and a confirm object",
        (function () {
          var k = M.killModel({row: row, fields: fields, volatile: true, canKill: true, confirmOpen: true});
          return k.state === "ready" && k.confirm !== null && typeof k.confirm === "object";
        })());

  check("K-D frees is fields.mem verbatim when volatile and present",
        M.killModel({row: row, fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.frees === "1832MB");

  check("K-E volatile: true with rss_mb/mem absent yields frees: an unknown amount",
        M.killModel({row: row, fields: {}, volatile: true, canKill: true, confirmOpen: false}).confirm.frees === "an unknown amount");

  check("K-F volatile: false yields frees: null and a freesNote",
        (function () {
          var c = M.killModel({row: row, fields: fields, volatile: false, canKill: true, confirmOpen: false}).confirm;
          return c.frees === null && typeof c.freesNote === "string" && c.freesNote.length > 0;
        })());

  check("K-G confirm.resume is exactly \"claude --resume <sid>\"",
        M.killModel({row: row, fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.resume
          === "claude --resume s1");

  check("K-H pipeline.status === running sets confirm.phase; any other status leaves it null",
        (function () {
          var running = M.killModel({row: {sid: "s1", name: "n", pipeline: {status: "running", phase: "plan"}},
            fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.phase;
          var idle = M.killModel({row: {sid: "s1", name: "n", pipeline: {status: "idle", phase: "plan"}},
            fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.phase;
          return running === "plan" && idle === null;
        })());

  check("K-I token === busy sets confirm.busy; any other token leaves it null",
        (function () {
          var busy = M.killModel({row: {sid: "s1", name: "n", token: "busy"},
            fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.busy;
          var idle = M.killModel({row: {sid: "s1", name: "n", token: "idle"},
            fields: fields, volatile: true, canKill: true, confirmOpen: false}).confirm.busy;
          return busy === true && idle === null;
        })());

  check("K-J row: null yields state: disabled with a reason distinct from K-A's",
        (function () {
          var noRow = M.killModel({row: null, fields: null, volatile: true, canKill: true, confirmOpen: false});
          var noGate = M.killModel({row: row, fields: fields, volatile: true, canKill: false, confirmOpen: false});
          return noRow.state === "disabled" && noRow.reason !== noGate.reason;
        })());

  check("K-K no input yields a state other than ready or disabled",
        ["disabled", "ready"].indexOf(M.killModel({}).state) !== -1
          && ["disabled", "ready"].indexOf(M.killModel({row: row, fields: fields, volatile: true, canKill: true, confirmOpen: false}).state) !== -1);

  // quickstart.md §2 spot-checks
  check("SC-001/FR-028 ungated must still render a control naming the flag",
        (function () {
          var k = M.killModel({row: row, fields: fields, volatile: true, canKill: false, confirmOpen: true});
          return k.state === "disabled" && k.reason.indexOf("ccwatch serve --allow-kill") !== -1 && k.confirmOpen === false;
        })());

  check("FR-033/D10 withheld is not unmeasured across the three volatile/mem inputs",
        (function () {
          var f = function (volatile, mem) {
            return M.killModel({row: row, fields: mem ? {mem: mem} : {}, volatile: volatile, canKill: true, confirmOpen: true}).confirm;
          };
          var present = f(true, "1832MB");
          var absent = f(true, null);
          var stale = f(false, "1832MB");
          return present.frees === "1832MB" && absent.frees === "an unknown amount"
            && stale.frees === null && stale.freesNote !== null;
        })());
})();

// atBottom (contracts/modal-js.md §7, B-A..B-E)
(function () {
  check("B-A exactly at the bottom is true",
        M.atBottom({scrollTop: 100, scrollHeight: 200, clientHeight: 100}) === true);

  check("B-B within FOLLOW_EPS of the bottom is true",
        M.atBottom({scrollTop: 100 - (M.FOLLOW_EPS - 1), scrollHeight: 200, clientHeight: 100}) === true);

  check("B-C one 12px line above the bottom is false",
        M.atBottom({scrollTop: 100 - 12, scrollHeight: 200, clientHeight: 100}) === false);

  check("B-D a box shorter than its viewport is true",
        M.atBottom({scrollTop: 0, scrollHeight: 50, clientHeight: 100}) === true);

  check("B-E non-finite or missing measurements return true rather than throwing",
        M.atBottom({scrollTop: NaN, scrollHeight: 200, clientHeight: 100}) === true
          && M.atBottom({}) === true
          && M.atBottom(undefined) === true);
})();

// convoMessage (contracts/modal-js.md §11, C-A..C-E)
(function () {
  check("C-A row.entrypoint === sdk-ts yields the embedded-SDK sentence, whatever turnCount says",
        (function () {
          var withTurns = M.convoMessage({row: {entrypoint: "sdk-ts"}, ok: true, turnCount: 5});
          var without = M.convoMessage({row: {entrypoint: "sdk-ts"}, ok: true, turnCount: 0});
          return withTurns.message === without.message && withTurns.isError === false
            && withTurns.message.indexOf("embedded-SDK") !== -1;
        })());

  check("C-B ok: true, turnCount: 0 on a non-sdk-ts row yields a no-turns-yet sentence distinct from C-A's",
        (function () {
          var noTurns = M.convoMessage({row: {entrypoint: "cli"}, ok: true, turnCount: 0});
          var sdk = M.convoMessage({row: {entrypoint: "sdk-ts"}, ok: true, turnCount: 0});
          return noTurns.isError === false && noTurns.message !== sdk.message;
        })());

  check("C-C ok: false yields the reason verbatim with isError: true, distinct from C-A/C-B",
        (function () {
          var failed = M.convoMessage({row: {entrypoint: "cli"}, ok: false, reason: "server not reachable", turnCount: 0});
          return failed.isError === true && failed.message.indexOf("server not reachable") !== -1
            && failed.message !== M.convoMessage({row: {entrypoint: "cli"}, ok: true, turnCount: 0}).message
            && failed.message !== M.convoMessage({row: {entrypoint: "sdk-ts"}, ok: true, turnCount: 0}).message;
        })());

  check("C-D ok: true, turnCount > 0 yields message: null",
        M.convoMessage({row: {entrypoint: "cli"}, ok: true, turnCount: 3}).message === null);

  check("C-E no branch mentions a hang or the session's status",
        (function () {
          var all = [
            M.convoMessage({row: {entrypoint: "sdk-ts"}, ok: true, turnCount: 0}),
            M.convoMessage({row: {entrypoint: "cli"}, ok: true, turnCount: 0}),
            M.convoMessage({row: {entrypoint: "cli"}, ok: false, reason: "x", turnCount: 0}),
          ];
          return all.every(function (r) {
            return (r.message || "").toLowerCase().indexOf("hung") === -1
              && (r.message || "").toLowerCase().indexOf("status") === -1;
          });
        })());
})();

// askModel (contracts/modal-js.md §10, A-A..A-E)
(function () {
  var questions = [{text: "proceed?", options: ["yes", "no"]}];

  check("A-A a row with questions yields kind: questions, untruncated, and a how naming both phrases",
        (function () {
          var m = M.askModel({sid: "s", questions: questions});
          return m.kind === "questions" && m.questions === questions
            && m.how.indexOf("queued behind it") !== -1 && m.how.indexOf("does not answer it") !== -1;
        })());

  check("A-B no questions and sev === 4 yields kind: dialog with a how distinct from A-A's",
        (function () {
          var q = M.askModel({sid: "s", questions: questions});
          var d = M.askModel({sid: "s", sev: 4, note: "approve the plan"});
          return d.kind === "dialog" && d.note.indexOf("approve the plan") !== -1 && d.how !== q.how;
        })());

  check("A-C no questions and sev !== 4 yields kind: none and no sentences at all",
        (function () {
          var m = M.askModel({sid: "s", sev: 1});
          return m.kind === "none" && m.note === null && m.how === "" && m.questions.length === 0;
        })());

  check("A-D row: null yields kind: none",
        M.askModel(null).kind === "none");

  check("A-E a 4KB question and a fifteen-option question are returned whole",
        (function () {
          var big = new Array(4096 + 1).join("x");
          var opts = [];
          for (var i = 0; i < 15; i++) opts.push("option " + i);
          var m = M.askModel({sid: "s", questions: [{text: big, options: opts}]});
          return m.questions[0].text.length === big.length && m.questions[0].options.length === 15;
        })());
})();

// sendModel (contracts/modal-js.md §9, N-A..N-C)
(function () {
  var row = {sid: "s1", name: "web-app"};

  check("N-A canSend: false yields state: disabled with a reason naming --read-only",
        (function () {
          var m = M.sendModel({row: row, canSend: false});
          return m.state === "disabled" && m.reason.indexOf("--read-only") !== -1;
        })());

  check("N-B canSend: true with a row yields state: ready, reason: null",
        (function () {
          var m = M.sendModel({row: row, canSend: true});
          return m.state === "ready" && m.reason === null;
        })());

  check("N-C row: null yields state: disabled with a reason distinct from N-A's",
        (function () {
          var noRow = M.sendModel({row: null, canSend: true});
          var noGate = M.sendModel({row: row, canSend: false});
          return noRow.state === "disabled" && noRow.reason !== noGate.reason;
        })());
})();

// feedLines / goneText (contracts/modal-js.md §6, F-A..F-H)
(function () {
  var down = M.feedLines({trust: "feed_down", reason: "HTTP 500", dataAge: 42, unreadable: 0});
  var warm = M.feedLines({trust: "warming", reason: null, dataAge: null, unreadable: null});
  var ok   = M.feedLines({trust: "ok", reason: null, dataAge: 3, unreadable: null});

  check("a feed that is down names the reason it gave, verbatim",
        down.mainKind === "down" && down.main.indexOf("HTTP 500") >= 0, down.main);
  check("and states how old the readings still on screen are",
        down.main.indexOf("42s") >= 0, down.main);
  check("a warming feed says nothing has been collected yet, and states no age",
        warm.mainKind === "warming" && warm.main.indexOf("first snapshot") >= 0
        && !/\d/.test(warm.main), warm.main);
  // Principle XII: a line that appears on every refresh to say things are fine
  // is a line people stop reading, and then it is not there when it matters.
  check("a healthy feed says nothing at all",
        ok.main === "" && ok.mainKind === "", JSON.stringify(ok));

  // F-D/F-E: additive, never folded into the main sentence.
  var okUnread = M.feedLines({trust: "ok", unreadable: 2});
  var downUnread = M.feedLines({trust: "feed_down", reason: "boom", dataAge: 9, unreadable: 1});
  check("unreadable rows are reported on a healthy feed",
        okUnread.unreadable.indexOf("2 registry file") === 0, okUnread.unreadable);
  check("and on a broken one too — it is an additive fact, not a consequence",
        downUnread.unreadable !== "" && downUnread.main.indexOf("registry") < 0,
        downUnread.main + " / " + downUnread.unreadable);
  check("and never as a substring of the main sentence",
        okUnread.main.indexOf(okUnread.unreadable) < 0, okUnread.main);
  check("zero, null and undefined unreadable rows produce no sentence",
        M.feedLines({trust: "ok", unreadable: 0}).unreadable === ""
        && M.feedLines({trust: "ok", unreadable: null}).unreadable === ""
        && M.feedLines({trust: "ok"}).unreadable === "",
        JSON.stringify([M.feedLines({trust: "ok", unreadable: 0}).unreadable]));

  // F-H: an absent reading must not surface as null, undefined or 0s.
  var sparse = JSON.stringify([M.feedLines({trust: "feed_down"}),
                               M.feedLines({trust: "warming"}),
                               M.feedLines({trust: "ok"})]);
  check("no branch prints null, undefined or a fabricated zero for a missing reading",
        !/null|undefined|NaN/.test(sparse), sparse);

  // F-F
  var gone = M.goneText("web-app-fc", "abc-123");
  check("a session gone from the snapshot is named, with the command that reopens it",
        gone.indexOf("web-app-fc") === 0 && gone.indexOf("claude --resume abc-123") > 0, gone);

  // F-G/SC-009: five renderings, pairwise distinct, no shared leading clause.
  var five = [down.main, warm.main, ok.main, okUnread.unreadable, gone];
  var uniq = {}, dupes = 0, i;
  for (i = 0; i < five.length; i++) {
    if (uniq[five[i]]) dupes++;
    uniq[five[i]] = 1;
  }
  check("the five feed renderings are pairwise distinct", dupes === 0, five.join(" // "));
  var leads = five.filter(function (s) { return s !== ""; })
                  .map(function (s) { return s.split(" ").slice(0, 3).join(" "); });
  check("and share no leading clause, so which one you are reading is never in doubt",
        new Set(leads).size === leads.length, leads.join(" // "));

  // ⚠️ A missing row means either the session left or the read failed. Saying
  // "it is gone" on a failed read invents an exit (principle VI).
  var subj = {name: "web-app-fc", sid: "abc-123"};
  var goneOnOk = M.panel({row: null, subject: subj, cond: {trust: "ok"}});
  var goneOnDown = M.panel({row: null, subject: subj,
                            cond: {trust: "feed_down", reason: "boom", dataAge: 5}});
  check("a session missing from a trustworthy snapshot is reported as gone",
        goneOnOk.gone !== null, String(goneOnOk.gone));
  check("but a broken feed is never evidence that a session exited",
        goneOnDown.gone === null && goneOnDown.feed.mainKind === "down",
        String(goneOnDown.gone));
})();

// The export surface (contracts/modal-js.md §13). Asserted as a set, so a
// function that is written but never exported — or exported and then dropped
// in a refactor — fails here rather than in a browser.
(function () {
  var want = ["FOLLOW_EPS", "TRANSCRIPT_N", "dur", "panel", "statLines",
              "edgesFor", "feedLines", "goneText", "atBottom", "killModel",
              "sendModel", "askModel", "convoMessage"];
  var missing = want.filter(function (k) { return !(k in M); });
  check("every name the contract lists is exported", missing.length === 0,
        "missing: " + missing.join(", "));
  var callable = want.filter(function (k) {
    return typeof M[k] === "function" || typeof M[k] === "number";
  });
  check("and each is callable or a constant, not an accidental undefined",
        callable.length === want.length,
        want.filter(function (k) { return callable.indexOf(k) < 0; }).join(", "));
})();

process.stdout.write(out.join("\n") + "\n");
MODALJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/modal-check.js" "$ROOT/web/modal.js" 2>&1)
else
  t_skip "modal module" "node not installed"
fi


# =============================================================== alerts-module ===
printf '\nalerts-module\n'
#
# web/alerts.js holds the pages' trust model and the alert set both pages render
# from it. It is in its own file for the reason web/md.js, web/roster.js and
# web/modal.js are: so these assertions can require() it under node, without a
# browser. What a browser has to answer instead — whether the control can move
# the board — is asserted by `ccwatch verify-ui`, because it is a question about
# boxes and no amount of shaping here can answer it.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/alerts-check.js" <<'ALERTSJS'
var A = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}
var HOST = {pressure: true, swap_used_pct: 92, swap_used_mb: 8100,
            swap_total_mb: 9216, ram_free_mb: 210, sessions_mb: 1840, idle_mb: 420};
function texts(m) { return m.items.map(function (i) { return i.text; }); }
function keys(m) { return m.items.map(function (i) { return i.key; }); }

// Seed: the module loads under node and exports an object.
(function () {
  check("seed require(alerts.js) succeeds and exports an object",
        typeof A === "object" && A !== null, typeof A);
})();

// feedCondition — moved here from map.html so both pages judge one feed once
// (principle XI). The four outcomes, and the fields each carries.
(function () {
  var down = A.feedCondition({collected_at: {snapshot: Date.now() / 1000 - 60}}, "ECONNREFUSED");
  check("F-A a read that threw is feed_down, carrying the thrown reason verbatim",
        down.trust === "feed_down" && down.reason === "ECONNREFUSED", JSON.stringify(down));
  check("F-A and the age of what is still on screen, measured not stored",
        Math.round(down.dataAge) === 60, String(down.dataAge));
  // ⚠️ The fixture carries a collected_at instant deliberately. With none,
  // dataAge comes out null whatever the warming branch does, and the second
  // assertion here could not fail — which is how it was first written.
  var warming = A.feedCondition(
    {warming: true, collected_at: {snapshot: Date.now() / 1000 - 300}}, null);
  check("F-B a warming payload is warming", warming.trust === "warming",
        JSON.stringify(warming));
  check("F-B and states no age for data it does not have, whatever the payload carries",
        warming.dataAge === null, String(warming.dataAge));
  var failed = A.feedCondition({snapshot_ok: false, snapshot_error: "timed out after 90s"}, null);
  check("F-C a failed collection is feed_down, named by the collector's own error",
        failed.trust === "feed_down" && failed.reason === "timed out after 90s",
        JSON.stringify(failed));
  check("F-C and falls back to `error` when only that is set, never to a bare \"failed\"",
        A.feedCondition({snapshot_ok: false, error: "jq: parse error"}, null).reason
          === "jq: parse error");
  var ok = A.feedCondition({sessions: [{sid: "a"}], parse_failed: 2,
                            collected_at: {snapshot: Date.now() / 1000}}, null);
  check("F-D a good payload is ok, and carries the unreadable count through",
        ok.trust === "ok" && ok.unreadable === 2, JSON.stringify(ok));
  check("F-E zero sessions on a good payload is empty:true",
        A.feedCondition({sessions: [], collected_at: {}}, null).empty === true);
  // ⚠️ An errored payload is NOT an empty host. They are different facts, and
  // the table view's "No live sessions. After a reboot, run ccwatch resume."
  // would be an invented claim about a read that never landed (principle VI).
  check("F-F a payload with an error is never reported as an empty host",
        A.feedCondition({sessions: [], error: "boom"}, null).empty === false);
})();

// alerts() — the set, and what is deliberately not in it.
(function () {
  // A-A: nothing wrong says nothing at all (principle XII). Not "all clear",
  // not a zero count — no trigger for the page to render.
  var quiet = A.alerts({cond: {trust: "ok", unreadable: 0, empty: false},
                        host: null, volatile: true});
  check("A-A a healthy feed on a healthy host produces no items and no trigger",
        quiet.items.length === 0 && quiet.trigger === null, JSON.stringify(quiet));
  check("A-A and a host below the pressure threshold is not an item either",
        A.alerts({cond: {trust: "ok", unreadable: 0}, host: {pressure: false, swap_used_pct: 3},
                  volatile: true}).items.length === 0);

  // A-B: zero live sessions is a normal condition, not an alert. Each page
  // states it where a reader looks for sessions; a control that lights up for
  // an idle machine has lit up for nothing by the time a real one arrives.
  var idle = A.alerts({cond: {trust: "ok", unreadable: 0, empty: true},
                       host: null, volatile: true});
  check("A-B an empty host is not an alert — no item and no trigger for it",
        idle.items.length === 0 && idle.trigger === null, JSON.stringify(idle));

  // A-C: the measurement travels with the verdict (principle II).
  var down = A.alerts({cond: {trust: "feed_down", reason: "HTTP 503", dataAge: 125,
                              unreadable: 0}, host: null, volatile: false});
  check("A-C feed_down states the reason and the age of the data still on screen",
        down.items[0].text.indexOf("HTTP 503") !== -1
          && down.items[0].text.indexOf("2m") !== -1, down.items[0].text);
  check("A-C and is severity bad",
        down.items[0].sev === "bad", down.items[0].sev);
  check("A-C a feed_down with no reason reported still says so, never \"undefined\"",
        A.alerts({cond: {trust: "feed_down", dataAge: 1}, host: null, volatile: false})
          .items[0].text.indexOf("undefined") === -1);

  // A-D: the host-pressure numbers are VOLATILE readings. The pressure appears
  // at its own threshold either way; the numbers behind it are withheld, not
  // annotated, while the feed is not trusted (principle III).
  var hot = A.alerts({cond: {trust: "ok", unreadable: 0}, host: HOST, volatile: true});
  check("A-D host pressure with a trusted feed prints the swap and RAM figures",
        hot.items[0].text.indexOf("92%") !== -1
          && hot.items[0].text.indexOf("210MB RAM free") !== -1, hot.items[0].text);
  check("A-D and what the sessions themselves account for",
        hot.items[0].text.indexOf("1840MB") !== -1 && hot.items[0].text.indexOf("420MB") !== -1,
        hot.items[0].text);
  var hotStale = A.alerts({cond: {trust: "feed_down", reason: "x", dataAge: 5, unreadable: 0},
                           host: HOST, volatile: false});
  var pressureText = hotStale.items[1].text;
  check("A-D an untrusted feed still reports the pressure",
        pressureText.indexOf("host under memory pressure") === 0, pressureText);
  check("A-D but withholds every number rather than annotating a stale one",
        pressureText.indexOf("92") === -1 && pressureText.indexOf("210") === -1
          && pressureText.indexOf("1840") === -1
          && pressureText.indexOf("withheld") !== -1, pressureText);
  check("A-D and either way says a killed session looks like a clean exit",
        hot.items[0].text.indexOf("looks exactly like a clean exit") !== -1
          && pressureText.indexOf("looks exactly like a clean exit") !== -1);

  // A-E: additive, and never printed as a zero.
  check("A-E unreadable registry files are their own item, with the command to run",
        A.alerts({cond: {trust: "ok", unreadable: 3}, host: null, volatile: true})
          .items[0].text === "3 registry file(s) could not be read — run: ccwatch doctor");
  check("A-E zero, null and absent unreadable counts produce no item at all",
        A.alerts({cond: {trust: "ok", unreadable: 0}, host: null, volatile: true}).items.length === 0
          && A.alerts({cond: {trust: "ok", unreadable: null}, host: null, volatile: true}).items.length === 0
          && A.alerts({cond: {trust: "ok"}, host: null, volatile: true}).items.length === 0);

  // A-F: warming is not a failure, and must not be dressed as one — it says
  // the view has nothing behind it yet.
  var warm = A.alerts({cond: {trust: "warming", unreadable: 0}, host: null, volatile: false});
  check("A-F warming is an item, at severity info rather than bad or warn",
        warm.items.length === 1 && warm.items[0].sev === "info", JSON.stringify(warm.items));

  // A-G: order is by severity, worst first, and is carried as a field because
  // the map reconciles these nodes by key and never moves one.
  var all = A.alerts({cond: {trust: "feed_down", reason: "boom", dataAge: 10, unreadable: 4},
                      host: HOST, volatile: false});
  check("A-G the set is ordered worst first: feed, host, then unreadable rows",
        keys(all).join(",") === "feed_down,host_pressure,unreadable", keys(all).join(","));
  check("A-G and every item carries its rank as a field, not just its position",
        all.items.map(function (i) { return i.order; }).join(",") === "0,1,2");
  check("A-G every sev is one the CSS knows, never a number",
        all.items.every(function (i) { return A.SEV_RANK[i.sev] !== undefined; }),
        JSON.stringify(all.items.map(function (i) { return i.sev; })));

  // A-H: the items are pairwise distinct and share no leading clause, the same
  // discipline the modal's five renderings are held to — "the feed is gone" and
  // "the host is out of memory" must never be mistaken for each other mid-read.
  (function () {
    var seen = texts(all).concat(texts(warm));
    var clash = null;
    for (var i = 0; i < seen.length; i++) {
      for (var j = i + 1; j < seen.length; j++) {
        if (seen[i] === seen[j]) clash = "identical: " + seen[i];
        else if (seen[i].slice(0, 12) === seen[j].slice(0, 12))
          clash = "same opening: " + seen[i].slice(0, 12);
      }
    }
    check("A-H no two alert sentences are equal or share a leading clause",
          clash === null, clash || "");
  })();
})();

// triggerOf — the collapsed control. This is the part that has to carry a
// failure without the panel being open, or the whole change would have turned
// a stated failure into an absence (principle IV).
(function () {
  check("T-A no items means no trigger, so the control is absent rather than reassuring",
        A.triggerOf([]) === null);

  var one = A.alerts({cond: {trust: "ok", unreadable: 0}, host: HOST, volatile: true}).trigger;
  check("T-B a single alert names the condition in words, never a bare count",
        one.text.indexOf("host under memory pressure") !== -1
          && one.text.indexOf("1 alert") === -1, one.text);
  check("T-B and carries no +N when it is the only one",
        one.text.indexOf("+") === -1, one.text);
  check("T-B and a \"!\" so the severity survives NO_COLOR and a mono screen",
        one.text.indexOf("!") === 0, one.text);

  var two = A.alerts({cond: {trust: "feed_down", reason: "boom", dataAge: 3, unreadable: 0},
                      host: HOST, volatile: false}).trigger;
  check("T-C with several, the trigger names the WORST one, not the first read",
        two.text.indexOf("the feed is down") !== -1, two.text);
  check("T-C and counts the rest as +N",
        two.text.indexOf("+1") !== -1, two.text);
  check("T-C taking its severity from that worst item",
        two.sev === "bad", two.sev);
  // ⚠️ The visible text is ellipsised by the slot's width and "+1" is an
  // abbreviation regardless, so the accessible name spells the whole set out.
  check("T-D the accessible name lists every headline, not just the worst",
        two.label.indexOf("the feed is down") !== -1
          && two.label.indexOf("host under memory pressure") !== -1, two.label);
  check("T-D and counts them, in agreement with the visible +N",
        two.label.indexOf("2 alerts") === 0, two.label);
  check("T-D a single alert is announced in the singular",
        one.label.indexOf("1 alert:") === 0, one.label);

  var warmTrigger = A.alerts({cond: {trust: "warming", unreadable: 0},
                              host: null, volatile: false}).trigger;
  check("T-E an info-level condition carries no \"!\" — it is not a failure",
        warmTrigger.text.indexOf("!") === -1 && warmTrigger.sev === "info",
        warmTrigger.text);
})();

// C-J's other half, moved here from the roster section with the sentences it
// is about (contracts/roster-js.md §8). The roster's tombstone and the alert
// control's sentences describe different facts - "that session is gone" and
// "the feed is gone" - and a reader must never take one for the other
// mid-read.
//
// ⚠️ Not guarded by a `typeof` test. The version in the roster section was
// `if (typeof R.statements === "function")`, so when statements() was deleted
// it reported nothing at all rather than failing: a check that goes quiet
// instead of red is worse than no check. Here the module is required outright,
// so a missing goneText is a failure.
(function () {
  var R = require(process.argv[3]);
  var gone = R.goneText("s1", "alpha");
  var goneLead = gone.split(" ").slice(0, 3).join(" ");
  var everySentence = [];
  [{cond: {trust: "feed_down", reason: "boom", dataAge: 9, unreadable: 3}, host: HOST},
   {cond: {trust: "warming", unreadable: 0}, host: null}].forEach(function (input) {
    input.volatile = false;
    texts(A.alerts(input)).forEach(function (t) { everySentence.push(t); });
  });
  var clash = everySentence.filter(function (t) {
    return t.split(" ").slice(0, 3).join(" ") === goneLead;
  });
  check("C-J the roster's tombstone shares no leading clause with any alert sentence",
        everySentence.length > 0 && clash.length === 0,
        clash.join(" | ") || (everySentence.length + " sentences compared"));
})();

process.stdout.write(out.join("\n") + "\n");
ALERTSJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/alerts-check.js" "$ROOT/web/alerts.js" "$ROOT/web/roster.js" 2>&1)
else
  t_skip "alerts module" "node not installed"
fi

# Both pages load the module, and neither keeps a banner element that could
# reflow the page under a condition. Static, so it holds with no node and no
# browser. ⚠️ The element ids are what is asserted, not the CSS: a grep for a
# declaration is the check that once failed on the comment explaining the
# declaration (see the mutation table in README.md).
for _pf in "$ROOT/web/index.html" "$ROOT/web/map.html"; do
  assert_contains "$(cat "$_pf")" '<script src="/alerts.js">' \
    "$_pf loads the shared alert module"
  assert_eq "$(grep -c 'id="hostwarn"' "$_pf")" "0" \
    "$_pf has no block-level host-pressure banner left to push the page down"
  assert_contains "$(cat "$_pf")" 'id="alertslot"' \
    "$_pf carries the alert slot in its header"
  # ⚠️ The slot's size must not depend on its content, or the trigger's
  # arrival re-wraps the header — the same reflow, moved up one element. It
  # must also not be a fixed width: a 234px reservation wrapped the header by
  # itself, measured 52px -> 86px, which is a constant cost in place of an
  # intermittent one. `flex:1 1 0` is both: it asks for nothing and grows into
  # what the line has left. The geometric consequence is what verify-ui
  # asserts; this is the declaration that produces it.
  assert_contains "$(cat "$_pf")" '#alertslot { flex:1 1 0; min-width:12ch;' \
    "and sizes the slot from the header's free space, not from what it holds"
done
# One judgement of the feed, in the module, for both pages (principle XI).
assert_eq "$(grep -c 'function computeFeedCondition' "$ROOT/web/map.html")" "0" \
  "map.html no longer keeps a trust model of its own"
assert_contains "$_maphtml" 'CCWATCH_ALERTS.feedCondition' \
  "and reads the shared one"
assert_contains "$(cat "$ROOT/web/index.html")" 'CCWATCH_ALERTS.feedCondition' \
  "as does the table view, which used to decide it a second way in its own try/catch"


# =============================================================== usage-module ===
printf '\nusage-module\n'
#
# web/usage.js is the usage meter's arithmetic: how much of a window has
# elapsed, and when it resets in Eastern wall-clock time. In its own file for
# the reason the other web modules are: so these assertions can require() it
# under node, without a browser.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/usage-check.js" <<'USAGEJS'
var U = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}
var NOW = 1789700000;
var H = 3600;

(function () {
  check("seed require(usage.js) succeeds and exports an object",
        typeof U === "object" && U !== null, typeof U);
})();

// elapsedPct — the second bar's length, and the four ways it is unknowable.
(function () {
  check("U-A two hours left of a five-hour window is 60% elapsed",
        U.elapsedPct("five_hour", NOW + 2 * H, NOW) === 60,
        String(U.elapsedPct("five_hour", NOW + 2 * H, NOW)));
  check("U-A and three days left of the seven-day window is 57%",
        Math.round(U.elapsedPct("seven_day", NOW + 3 * 86400, NOW)) === 57,
        String(U.elapsedPct("seven_day", NOW + 3 * 86400, NOW)));
  // ⚠️ Each of these is null, not 0. A bar drawn at 0% reads as "the window
  // just started", which is a measurement nobody took (principle VI).
  check("U-B no reset instant means no elapsed fraction at all",
        U.elapsedPct("five_hour", null, NOW) === null
          && U.elapsedPct("five_hour", undefined, NOW) === null);
  check("U-C a window this module does not know the length of yields null, never a guess",
        U.elapsedPct("thirty_day", NOW + H, NOW) === null);
  check("U-D a reset instant already past yields null — that window has ended",
        U.elapsedPct("five_hour", NOW - 1, NOW) === null
          && U.elapsedPct("five_hour", NOW, NOW) === null);
  check("U-E a reset further out than the window is clamped to 0, never negative",
        U.elapsedPct("five_hour", NOW + 9 * H, NOW) === 0,
        String(U.elapsedPct("five_hour", NOW + 9 * H, NOW)));
  check("U-F a non-numeric reset instant yields null rather than NaN",
        U.elapsedPct("five_hour", "soon", NOW) === null);
})();

// resetClock — Eastern, with the abbreviation, and honest about daylight saving.
(function () {
  var july = Date.parse("2026-07-04T19:45:00Z") / 1000;
  var january = Date.parse("2026-01-04T19:45:00Z") / 1000;
  check("U-G the reset instant is stated as an Eastern wall clock",
        U.resetClock(july) === "3:45 PM EDT", String(U.resetClock(july)));
  // ⚠️ The same UTC instant is an hour apart in the two halves of the year,
  // and the abbreviation is what tells the reader which. A clock time without
  // one is ambiguous for half the year — and jq's strflocaltime got this
  // wrong, which is why bin/ccwatch uses `date -r` (see reset_clock there).
  check("U-G and follows daylight saving, naming EST in winter",
        U.resetClock(january) === "2:45 PM EST", String(U.resetClock(january)));
  check("U-H a missing or non-numeric instant has no clock, rather than a wrong one",
        U.resetClock(null) === null && U.resetClock(undefined) === null
          && U.resetClock("later") === null);
})();

// gauge — one window's model.
(function () {
  var ahead = U.gauge("five_hour", "5h", {used_percentage: 78.9, resets_at: NOW + 4 * H}, NOW);
  check("U-I the used percentage is floored, not rounded up",
        ahead.usedText === "78%", ahead.usedText);
  check("U-I and carries its own subject for a screen reader, which cannot read a bar",
        ahead.usedLabel === "78% of the 5h limit used"
          && ahead.elapsedLabel === "20% of the 5h window elapsed",
        ahead.usedLabel + " | " + ahead.elapsedLabel);
  check("U-J 78% used against 20% elapsed is reported as ahead of the clock",
        ahead.pace === "ahead", String(ahead.pace));
  var behind = U.gauge("five_hour", "5h", {used_percentage: 10, resets_at: NOW + 1 * H}, NOW);
  check("U-J 10% used against 80% elapsed is not — and says nothing at all",
        behind.pace === null, String(behind.pace));
  var level = U.gauge("five_hour", "5h", {used_percentage: 60, resets_at: NOW + 2 * H}, NOW);
  check("U-J and neither is consumption exactly level with the clock",
        level.pace === null, String(level.pace));
  // ⚠️ No elapsed fraction means no pace: "ahead" would be a comparison
  // against a number this module refused to produce two checks ago.
  var noWindow = U.gauge("seven_day_opus", "7d opus", {used_percentage: 99}, NOW);
  check("U-K a window with no reset instant has no time bar, no pace and no clock",
        noWindow.elapsedPct === null && noWindow.pace === null
          && noWindow.resetIn === null && noWindow.resetClock === null,
        JSON.stringify(noWindow));
  check("U-K but still reports what it does know — the consumption",
        noWindow.usedText === "99%", noWindow.usedText);
  var expired = U.gauge("five_hour", "5h", {used_percentage: 50, resets_at: NOW - 10}, NOW);
  check("U-L a window whose reset has passed states no reset time either",
        expired.resetIn === null && expired.resetClock === null,
        JSON.stringify([expired.resetIn, expired.resetClock]));
  check("U-M a window object with no percentage produces no gauge at all",
        U.gauge("five_hour", "5h", {resets_at: NOW + H}, NOW) === null
          && U.gauge("five_hour", "5h", null, NOW) === null);
  check("U-N the relative time and the wall clock are both stated",
        ahead.resetIn === "4h" && /(AM|PM) E[DS]T$/.test(ahead.resetClock),
        ahead.resetIn + " / " + ahead.resetClock);
})();

// gauges — the set, in the header's own order, with nothing filled in.
(function () {
  var all = U.gauges({
    five_hour: {used_percentage: 41, resets_at: NOW + H},
    seven_day: {used_percentage: 12, resets_at: NOW + 86400},
    seven_day_opus: {used_percentage: 3},
  }, NOW);
  check("U-O every window the payload reports gets a gauge, in the header's order",
        all.map(function (g) { return g.key; }).join(",")
          === "five_hour,seven_day,seven_day_opus",
        all.map(function (g) { return g.key; }).join(","));
  check("U-P a window absent from the payload is absent here, not zeroed",
        U.gauges({five_hour: {used_percentage: 41}}, NOW).length === 1);
  check("U-P and no usage at all is an empty set rather than three empty gauges",
        U.gauges(null, NOW).length === 0 && U.gauges(undefined, NOW).length === 0);
})();

// band — the same thresholds the terminal and both views already use.
(function () {
  check("U-Q the bar's severity bands at 90 and 70, as a word the page maps to a colour",
        U.band(90) === "bad" && U.band(89) === "warn" && U.band(70) === "warn"
          && U.band(69) === "ok",
        [U.band(90), U.band(89), U.band(70), U.band(69)].join(","));
})();

process.stdout.write(out.join("\n") + "\n");
USAGEJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/usage-check.js" "$ROOT/web/usage.js" 2>&1)

  # ⚠️ Two formatters of one instant, asserted to agree through the terminal's
  # REAL rendering path rather than a helper called in isolation. The terminal
  # cannot use web/usage.js and the browser cannot use `date -r`, so the same
  # reset time is formatted twice — and jq's strflocaltime, the obvious third
  # option, reported EST for an instant in September. Both sides of a
  # daylight-saving boundary are checked, because that is the half of the year
  # a wrong formatter is wrong in.
  mkdir -p "$WORK/usage-home"
  for _inst in 1783021500 1767551100; do
    _js=$(node -e 'process.stdout.write(String(require(process.argv[1]).resetClock(Number(process.argv[2]))))' \
          "$ROOT/web/usage.js" "$_inst" 2>/dev/null || true)
    cat > "$WORK/usage-home/usage.json" <<EOF
{"at": $(date '+%s'), "five_hour": {"used_percentage": 41, "resets_at": $_inst},
 "seven_day_opus": {"used_percentage": 3}}
EOF
    # /dev/null as the liveness probe: no session is live, which is fine
    # here — the usage line is printed above the table and before the "no live
    # sessions" return, so this exercises it without depending on a fixture
    # another section happens to have built.
    _line=$(CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS=/dev/null \
      CCWATCH_HOME="$WORK/usage-home" NO_COLOR=1 "$CCWATCH" once 2>/dev/null | head -1)
    assert_contains "$_line" "$_js" \
      "the terminal's usage line states the reset instant $_inst as the page does ($_js)"
  done
  # ⚠️ And a window with no reset instant gets no clause at all, rather than
  # "(resets ?)": the last fixture above carries seven_day_opus with no
  # resets_at precisely so this can be checked against real output.
  assert_not_contains "$_line" "7d-opus 3% (resets" \
    "and a window with no reset instant carries no reset clause"
else
  t_skip "usage module" "node not installed"
fi

# Both pages load the module, and neither keeps a usage formatter of its own.
for _pf in "$ROOT/web/index.html" "$ROOT/web/map.html"; do
  assert_contains "$(cat "$_pf")" '<script src="/usage.js">' \
    "$_pf loads the shared usage module"
  assert_contains "$(cat "$_pf")" 'CCWATCH_USAGE.gauges(' \
    "$_pf shapes its gauges from it rather than reading the payload directly"
  # ⚠️ The clock bar must be driven by the module's null — branched on, in
  # either direction — and never defaulted: `elapsedPct || 0` would draw a bar
  # at 0%, which reads as "the window just started". Matched as a pattern
  # rather than one spelling, because which way round the branch is written is
  # not the property; that it exists is.
  _elapsed_branch=$(grep -cE 'g\.elapsedPct [!=]= null' "$_pf" || true)
  [ "$_elapsed_branch" -ge 1 ] \
    && t_pass "$_pf draws the clock bar only when the elapsed fraction is known" \
    || t_fail "$_pf draws the clock bar only when the elapsed fraction is known" \
              "no branch on g.elapsedPct being null"
  assert_not_contains "$(cat "$_pf")" 'elapsedPct ||' \
    "and never defaults it to zero, which would read as a window that just started"
  # ⚠️ The meter's height is reserved whether or not there is a reading in
  # it. A usage reading is withheld whenever it goes stale or the feed stops
  # being trusted, and it returns on the next good snapshot — measured on the
  # map before this, the header was 89px with a reading and 52px without, so
  # the board moved 37px on its own. verify-ui asserts the geometry on both
  # views; this is the declaration that produces it.
  assert_contains "$(cat "$_pf")" 'min-height:4.8em' \
    "$_pf reserves the usage meter's height, so a withheld reading cannot move the page"
  # And the header is a two-column grid, because the reservation alone left
  # the WRAP state depending on the reading (127px with one, 90px without),
  # and a row of its own then left an 85px gap under the title. Columns decide
  # the layout up front: level with the title, and nothing wraps between them.
  assert_contains "$(cat "$_pf")" 'grid-template-columns:minmax(0, 1fr) auto' \
    "$_pf gives the meter a column of its own, level with the title"
  assert_contains "$(cat "$_pf")" '<div class="hleft">' \
    "and groups the title, the view switcher and the alert control in the other"
done
# reset_clock's own guard, in the one place it lives: an empty, null or
# non-numeric instant has no clock rather than a wrong one. Checked at the
# source level because the rendering path above can only reach it with real
# instants, and "what does it do with rubbish" is the question that matters.
_rcfn=$(sed -n '/^reset_clock() {/,/^}/p' "$ROOT/bin/ccwatch")
assert_contains "$_rcfn" "''|null|*[!0-9]*) return 0;;" \
  "reset_clock returns nothing for an empty, null or non-numeric instant"
assert_contains "$_rcfn" "TZ=America/New_York date -r" \
  "and formats with date -r, never jq, which reported the wrong zone here"


# =============================================================== markdown ====
printf '\nmarkdown\n'
#
# `web/md.js` renders transcript text, which is to say arbitrary file contents
# and tool output, into HTML. It lives in its own file precisely so that these
# assertions can run it: an escaping rule nobody executes is a comment.
if command -v node >/dev/null 2>&1; then
  # The program goes in -e and the INPUT goes in argv. Deliberately not stdin:
  # a heredoc feeding a program that also reads stdin has already cost this
  # project a debugging session once.
  md_render() { # md_render <markdown>
    node -e 'process.stdout.write(require(process.argv[1]).render(process.argv[2] || ""))' \
         "$ROOT/web/md.js" "$1" 2>&1
  }

  # ⚠️ A canary, because the failure mode here is misleading rather than loud:
  # if node cannot load the file at all, md_render returns an error message and
  # every `assert_not_contains` below passes against it. This happened while
  # these assertions were being written — a wrong path produced ten green
  # checks. One clear failure beats that.
  if md_render 'canary' >/dev/null 2>&1; then
    t_pass "the renderer loads"
  else
    t_fail "the renderer loads" "node could not load $ROOT/web/md.js"
  fi

  _md=$(md_render '**Fixed** the join and `ccwatch doctor` passes')
  assert_contains "$_md" "<strong>Fixed</strong>" "bold becomes bold"
  assert_contains "$_md" "<code>ccwatch doctor</code>" "and a code span becomes code"

  assert_contains "$(md_render '## Plan')" "<h5>Plan</h5>" \
    "a heading is a heading, demoted so it is not this page's h1"

  _md=$(md_render '```bash
ccwatch once | grep HUNG
```')
  assert_contains "$_md" "<pre data-lang=\"bash\"><code>ccwatch once | grep HUNG</code></pre>" \
    "a fenced block keeps its content and records the language"

  # ⚠️ A turn is truncated at 1200 characters, which lands mid-block most times
  # a model pastes a file. An unclosed fence must not swallow the rest of the
  # conversation into a code block.
  assert_contains "$(md_render '```python
print(1)')" "</code></pre>" \
    "a fence cut off by truncation is still closed"

  # ⚠️ The escaping assertions. These are the reason the file is testable.
  _md=$(md_render '<script>alert(1)</script> and <img src=x onerror=alert(1)>')
  assert_not_contains "$_md" "<script" "a script tag in a transcript is not a script tag"
  assert_not_contains "$_md" "<img" "nor is an img tag with an onerror"
  assert_contains "$_md" "&lt;script&gt;" "it is shown as the text it was"

  assert_not_contains "$(md_render '```
<img src=x onerror=alert(1)>
```')" "<img" "and markup inside a code fence is escaped too"

  # No anchors at all, for any scheme — a click in this panel must never become
  # an outbound request carrying transcript content.
  _md=$(md_render '[click](javascript:alert(1)) and [PR 12](https://example.com/pull/12)')
  assert_not_contains "$_md" "<a " "a markdown link does not become an anchor"
  assert_not_contains "$_md" "href" "and carries no href of any kind"
  assert_contains "$_md" "PR 12" "the label survives"
  assert_contains "$_md" "example.com/pull/12" "and the URL is readable as text"

  # ⚠️ ccwatch's own reduction of a tool use is not the model's prose, and the
  # argument in it is a shell glob, not a formatting instruction.
  # ⚠️ The fixture uses `*TODO*` deliberately. An earlier one used `**/*.ts`,
  # which the inline pass leaves alone anyway — so the assertion passed with the
  # verbatim handling removed, which makes it a test defect rather than
  # coverage. This argument would come back in italics.
  _md=$(md_render '→ Grep: *TODO* in web/')
  assert_contains "$_md" 'class="mdmeta"' \
    "a tool-use line is marked as ccwatch's own text, not the model's"
  assert_contains "$_md" "*TODO*" "and is kept verbatim"
  assert_not_contains "$_md" "<em>" "rather than read as emphasis"

  # ⚠️ Transcripts are full of identifiers. `__init__` rendered as a bold
  # "init", and `file_path` as file<em>path</em>, which is worse than no
  # rendering at all because it changes what the text says.
  _md=$(md_render 'the file_path and __init__ and tool_use_id are intact')
  assert_contains "$_md" "__init__" "a dunder is left alone"
  assert_contains "$_md" "file_path" "so is snake_case"
  assert_not_contains "$_md" "<strong>" "no emphasis is invented from underscores"

  # ⚠️ Multiplication is not rare in a conversation about token counts, and
  # `2 * 3 * 4` rendered as "2 <em> 3 </em> 4".
  assert_not_contains "$(md_render '2 * 3 * 4 tokens')" "<em>" \
    "an asterisk with spaces around it is arithmetic, not emphasis"

  # Nesting goes INSIDE the item, which is what makes the indent read as
  # subordination rather than as a second list.
  assert_contains "$(md_render '- corroborate
  - transcript mtime
- render')" "<li>corroborate<ul><li>transcript mtime</li></ul></li>" \
    "a nested bullet nests inside its parent item"

  assert_contains "$(md_render '1. read
2. corroborate')" "<ol><li>read</li><li>corroborate</li></ol>" \
    "a numbered list is ordered"

  # Unbounded input, bounded output. A turn that is all "> " is 600 levels at
  # the 1200-character cap, which is 600 nested elements for one turn on a panel
  # that re-renders every five seconds. Nesting stops at four and the rest of
  # the markers are shown as text.
  # ⚠️ The assertion is on the nesting, not on surviving: node renders 600
  # levels without overflowing, so an assertion phrased as "does not crash"
  # would pass with the cap removed and count as coverage it is not.
  _md=$(md_render "$(node -e 'process.stdout.write("> ".repeat(8) + "quoted")')")
  assert_contains "$_md" "<blockquote><blockquote><blockquote><blockquote>" \
    "quoting nests"
  assert_not_contains "$_md" "<blockquote><blockquote><blockquote><blockquote><blockquote>" \
    "but only four deep, however deep the input goes"
  assert_contains "$_md" "quoted" "and the content at the bottom still renders"
else
  t_skip "markdown renderer" "node not installed"
fi


printf '\n%s passed, %s failed' "$pass" "$fail"
[ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"
printf '\n'
floor="$TALLY_FLOOR"
if command -v node >/dev/null 2>&1; then
  floor=$((floor + TALLY_FLOOR_NODE))
fi
# ⚠️ The floor is a guard against assertions that run without being counted,
# so it can only mean anything on a full run. Under --fast the count is
# legitimately lower, and applying the floor would turn a documented choice
# into a failure — but the run must then say what it was, or a green --fast
# gets mistaken for a green suite.
if [ "$FAST" -eq 1 ]; then
  printf '    \033[33m--fast\033[0m: server and timing sections were skipped; run without it before committing.\n'
elif [ $((pass + fail)) -lt "$floor" ]; then
  printf '\n  \033[31m✗\033[0m only %s assertions were COUNTED, expected at least %s.\n' \
    "$((pass + fail))" "$floor"
  printf '    Assertions are running but not registering.\n'
  command -v node >/dev/null 2>&1 \
    || printf '    (node is absent, so the five module sections were skipped and the\n     lower floor applied — this is not that.)\n'
  printf '\n'
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
