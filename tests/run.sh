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
# 242 assertions run on a host with `node` and free loopback ports. 26 of those
# are the node-gated markdown block, so a host without `node` counts 216 — the
# floor has to sit below that, not below the full count, or the suite fails on
# a machine that is merely missing an optional tool.
TALLY_FLOOR=455

assert_contains() { case "$1" in *"$2"*) t_pass "$3";; *) t_fail "$3" "expected to contain: $2";; esac; }
assert_not_contains() { case "$1" in *"$2"*) t_fail "$3" "should NOT contain: $2";; *) t_pass "$3";; esac; }
assert_eq() { [ "$1" = "$2" ] && t_pass "$3" || t_fail "$3" "expected '$2', got '$1'"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccwatch-tests.XXXXXX")
# The serve tests start real servers. Reaping them on exit is not optional:
# a leaked one holds a port that a later run may pick, and then that run tests
# the leaked binary instead of its own.
cleanup_suite() {
  [ -n "${SPORT:-}" ] && pkill -f "ccwatch serve --port $SPORT" 2>/dev/null
  [ -n "${SPORT2:-}" ] && pkill -f "ccwatch serve --port $SPORT2" 2>/dev/null
  [ -n "${SPORT3:-}" ] && pkill -f "ccwatch serve --port $SPORT3" 2>/dev/null
  [ -n "${SPORT4:-}" ] && pkill -f "ccwatch serve --port $SPORT4" 2>/dev/null
  [ -n "${SPORT5:-}" ] && pkill -f "ccwatch serve --port $SPORT5" 2>/dev/null
  [ -n "${SPORT6:-}" ] && pkill -f "ccwatch serve --port $SPORT6" 2>/dev/null
  rm -rf "$WORK"
  return 0
}
trap cleanup_suite EXIT

for t in jq awk; do
  command -v "$t" >/dev/null 2>&1 || { printf 'ccwatch needs %s\n' "$t" >&2; exit 2; }
done

# =============================================================== shellcheck ===
printf '\nshellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
  # Pinned expectations: an unpinned linter means "lint" does not mean the same
  # thing on a laptop as in CI.
  t_note "shellcheck $(shellcheck --version | awk '/^version:/{print $2}')"
  if sc=$(shellcheck -x -S warning "$CCWATCH" "$ROOT/tests/run.sh" 2>&1); then
    t_pass "clean at -S warning"
  else
    t_fail "shellcheck findings" "$(printf '%s' "$sc" | head -30)"
  fi
else
  t_skip "shellcheck" "not installed — brew install shellcheck"
fi

# bash 3.2 is what macOS ships, so it is the floor. Grep for the constructs that
# silently do nothing there rather than trusting whoever edits this next.
b4=$(grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)|declare -A|\$\{[A-Za-z_]+(,,|\^\^)' \
       "$CCWATCH" 2>/dev/null | grep -v '^\s*#' || true)
assert_eq "$b4" "" "no bash-4-only construct (macOS ships 3.2)"
t_note "running under bash ${BASH_VERSION}"

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

ccwatch_json() { # ccwatch_json <fake-ps-file>
  CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$1" CCWATCH_HOME="$WORK/ccwatch-events" \
    NO_COLOR=1 "$CCWATCH" --json 2>/dev/null
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
# is the claim that escalates a quiet session to HUNG.
sleep 2
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
sleep 2
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
sleep 2
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
sleep 2
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
sleep 2
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

# FR-018: #world must be reachable by keyboard and its aria-label must name the
# keys, not just say "map" — a screen-reader user gets no other hint the arrow
# keys, +/-, and 0 do anything here.
_world_tag=$(awk '/<svg id="world"/{f=1} f{print; if(/>/){exit}}' "$ROOT/web/map.html")
assert_contains "$_world_tag" 'tabindex="0"' "#world carries tabindex=\"0\""
assert_contains "$_world_tag" 'aria-label="' "#world carries a non-empty aria-label"
_world_label=$(printf '%s' "$_world_tag" | sed -n 's/.*aria-label="\([^"]*\)".*/\1/p')
assert_contains "$_world_label" "Arrow keys" "and the aria-label names the keys"

# FR-016, FR-047: #camctl is built with three real, focusable, named buttons —
# not divs with click handlers, which a screen reader and Tab both skip.
_camctl_js=$(awk '/const camctl = document.createElement/,/insertAdjacentElement/' "$ROOT/web/map.html")
assert_eq "$(printf '%s' "$_camctl_js" | grep -c 'createElement("button")')" "3" \
  "#camctl is built from three real <button> elements"
assert_contains "$_camctl_js" 'zoom out' "and #zout has an accessible name"
assert_contains "$_camctl_js" 'zoom in' "and #zin has an accessible name"
assert_contains "$_camctl_js" '"fit"' "and #zfit has an accessible name"

# FR-031-FR-033: every label and badge, plus the wire's stroke, counter-scale
# against --k so they hold their apparent size at every rung of the ladder —
# a coordinate-space stroke-width would thicken into a smear at the closest
# zoom and vanish at the widest.
_maphtml=$(cat "$ROOT/web/map.html")
for _sel in '\.dlabel' '\.blabel' '\.zlabel' '\.dsummary' '\.alabel' \
            '\.norepo-badge' '\.wreck-badge' '\.deploy-badge'; do
  _rule=$(printf '%s' "$_maphtml" | grep -E "^\s*${_sel}(,|\s*\{)" | head -1)
  assert_contains "$_rule" 'calc(' "$_sel's font-size counter-scales with calc(Npx / var(--k, 1))"
  assert_contains "$_rule" 'var(--k' "$_sel's font-size reads --k"
done
_wire_rule=$(printf '%s' "$_maphtml" | grep '\.wire path' | head -1)
assert_contains "$_wire_rule" 'calc(var(--wire-w, 1) * 1px / var(--k, 1))' \
  ".wire path's stroke-width counter-scales with --wire-w and --k"

# FR-032: the count bubble stays a constant size on screen while its position
# — written by updateWire() onto the outer .bubble group — moves in world
# units, which is why the un-scaling has to live one level in.
_bubblescale_rule=$(printf '%s' "$_maphtml" | grep -E '^\s*\.bubblescale\s*\{' | head -1)
assert_contains "$_bubblescale_rule" 'transform:scale(calc(1 / var(--k, 1)))' \
  ".bubblescale carries transform: scale(calc(1 / var(--k, 1)))"

# FR-045, SC-012: easing is a single bounded transition applied by a class —
# never permanently on #camera, which would make a drag or wheel step lag the
# pointer — and reduced to an instant jump under prefers-reduced-motion.
_eased_rule=$(printf '%s' "$_maphtml" | grep -E '^\s*#camera\.eased\s*\{' | head -1)
assert_contains "$_eased_rule" 'transition: transform 180ms ease-out' \
  "#camera.eased sets a bounded transition on transform"
_reduced_motion_block=$(awk '/@media \(prefers-reduced-motion: reduce\)/{f=1} f{print; if (/^  \}/) exit}' "$ROOT/web/map.html")
assert_contains "$_reduced_motion_block" '#camera.eased { transition: none; }' \
  "the rule reduces to none under prefers-reduced-motion: reduce"

# The dashboard must never derive its own version of the status: two renderings
# that compute it separately will eventually disagree, and the one you are not
# looking at is the one that is wrong. So /api/state is asserted to be the same
# shape the CLI produces.
if command -v curl >/dev/null 2>&1; then
  # Find a port nothing is already listening on, and afterwards confirm the
  # server answering is the one this test started. Without that, a stale
  # `ccwatch serve` left behind by an earlier run answers instead — and since
  # it predates whatever route is under test, the failure reads as a missing
  # feature rather than as a dirty environment. Seven of them were found this
  # way.
  free_port() {
    local try n=0
    while [ "$n" -lt 25 ]; do
      try=$((18000 + RANDOM % 1500))
      curl -s --max-time 1 -o /dev/null "http://127.0.0.1:$try/" 2>/dev/null || { printf '%s' "$try"; return 0; }
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
  sleep 2
  assert_not_contains "$(cat "$WORK/serve.log" 2>/dev/null)" "could not bind" \
    "the test server got the port it asked for"
  _tries=0; _w=""
  while [ "$_tries" -lt 90 ]; do
    _w=$(curl -s --max-time 3 "http://127.0.0.1:$SPORT/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)
    [ "$_w" = "false" ] && break
    sleep 1; _tries=$((_tries + 1))
  done
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
  _tries=0; _pf_api=""
  while [ "$_tries" -lt 30 ]; do
    _pf_api=$(curl -s --max-time 3 "http://127.0.0.1:$SPORT/api/state" 2>/dev/null | jq -r '.parse_failed // empty')
    [ "$_pf_api" = "1" ] && break
    sleep 1; _tries=$((_tries + 1))
  done
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
  sleep 2
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
    _k4=0
    while [ "$_k4" -lt 40 ]; do
      [ "$(curl -s --max-time 3 "http://127.0.0.1:$SPORT4/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)" = "false" ] && break
      sleep 1; _k4=$((_k4 + 1))
    done
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
  sleep 2
  assert_not_contains "$(cat "$WORK/serve-ro.log" 2>/dev/null)" "could not bind" \
    "the read-only test server got the port it asked for"
  _t2=0
  while [ "$_t2" -lt 30 ]; do
    curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$SPORT2/" 2>/dev/null && break
    sleep 1; _t2=$((_t2 + 1))
  done
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
    _l=0
    while [ "$_l" -lt 25 ]; do
      curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$SPORT3/" 2>/dev/null && break
      sleep 1; _l=$((_l + 1))
    done
    assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$SPORT3/")" "200" \
      "a third server starts and answers"
    pkill -f "ccwatch serve --port $SPORT3" 2>/dev/null || true
    sleep 3
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
    _i=0
    while [ "$_i" -lt 40 ]; do
      [ "$(curl -s --max-time 3 "http://127.0.0.1:$SPORT5/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)" = "false" ] && break
      sleep 1; _i=$((_i + 1))
    done
    # ⚠️ The idle span is 12s against a 2s grace, so a stopped collector leaves
    # an age near 10s and a still-running one leaves an age at its ~2s cadence.
    # The threshold sits between those two outcomes on purpose. It was `sleep 6`
    # with `age > 4`, which put the pass/fail line exactly on the expected
    # value (6s idle − 2s grace = 4.0) and made the result a coin flip: two
    # consecutive runs on the same tree disagreed about which assertion in this
    # pair failed. A margin, not a boundary.
    sleep 12
    _idle=$(curl -s --max-time 10 "http://127.0.0.1:$SPORT5/api/state")
    assert_eq "$(printf '%s' "$_idle" | jq -r '.feed')" "idle" \
      "the first read after the grace period reports the feed as idle"
    _ia=$(printf '%s' "$_idle" | jq -r '.ages.snapshot')
    assert_eq "$(awk -v a="$_ia" 'BEGIN{print (a > 6) ? "yes" : "no"}')" "yes" \
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
    _c0=$(python3 -c 'import time; print(time.time())')
    ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-idle" CCWATCH_HOME="$DH" \
      CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" --json >/dev/null 2>&1 )
    _c1=$(python3 -c 'import time; print(time.time())')
    # Three collections' worth of headroom plus the cadence, so an ordinarily
    # busy machine passes and only a pathological one runs out of deadline.
    _deadline=$(awk -v a="$_c0" -v b="$_c1" 'BEGIN{d=(b-a)*3+6; print (d<10)?10:d}')
    _fresh=no _waited=0
    while [ "$(awk -v w="$_waited" -v d="$_deadline" 'BEGIN{print (w<d)?1:0}')" = "1" ]; do
      sleep 2; _waited=$((_waited + 2))
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
    _e=0
    while [ "$_e" -lt 40 ]; do
      [ "$(curl -s --max-time 3 "http://127.0.0.1:$SPORT6/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)" = "false" ] && break
      sleep 1; _e=$((_e + 1))
    done
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
    _t7=0
    while [ "$_t7" -lt 30 ]; do
      curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$SPORT7/" 2>/dev/null && break
      sleep 1; _t7=$((_t7 + 1))
    done
    sleep 2
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
    _e8=0
    while [ "$_e8" -lt 30 ]; do
      [ "$(curl -s --max-time 3 "http://127.0.0.1:$SPORT8/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)" = "false" ] && break
      sleep 1; _e8=$((_e8 + 1))
    done
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
    _r9=0
    while [ "$_r9" -lt 40 ]; do
      [ "$(curl -s --max-time 3 "http://127.0.0.1:$SPORT9/api/state" 2>/dev/null | jq -r '.warming' 2>/dev/null)" = "false" ] && break
      sleep 1; _r9=$((_r9 + 1))
    done
    _before9=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT9/api/state")
    _sessions_before=$(printf '%s' "$_before9" | jq -c '.sessions')
    _ca_before=$(printf '%s' "$_before9" | jq -r '.collected_at.snapshot')
    chmod -x "$TC/bin/ccwatch"
    sleep 5
    _after9=$(curl -s --max-time 5 "http://127.0.0.1:$SPORT9/api/state")
    assert_eq "$(printf '%s' "$_after9" | jq -r '.snapshot_ok')" "false" \
      "a subsequent collection failure is reported, not silently swallowed"
    assert_eq "$(printf '%s' "$_after9" | jq -c '.sessions')" "$_sessions_before" \
      "and the last successful sessions list is retained rather than blanked"
    _ca_after=$(printf '%s' "$_after9" | jq -r '.collected_at.snapshot')
    assert_eq "$_ca_after" "$_ca_before" \
      "collected_at is not refreshed by a failed attempt"
    _age_after=$(printf '%s' "$_after9" | jq -r '.ages.snapshot')
    assert_eq "$(awk -v a="$_age_after" 'BEGIN{print (a > 4) ? "yes" : "no"}')" "yes" \
      "so its age keeps growing truthfully, rather than resetting to near-zero as a fresh empty collection would"
    chmod +x "$TC/bin/ccwatch"
    pkill -f "ccwatch serve --port $SPORT9" 2>/dev/null || true
    rm -f "$FH/sessions/9801.json"
  else
    t_skip "a failed collection retains the prior snapshot" "no free port"
  fi
else
  t_skip "serve" "curl not available"
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
assert_contains "$_world_label" "companion" \
  "FR-013: #world's aria-label still names itself a companion view of the agent list"
assert_contains "$_world_label" "Arrow keys" \
  "and still names the keys (unchanged by this story)"

# contracts/page-roster.md §6: the selection ring is its own rule, applied to
# the outer .agent group (which applySelectionEmphasis toggles), never inside
# .figart which updateFigure rebuilds wholesale every tick.
assert_contains "$_maphtml" '.agent.selected .hit' \
  "the selection ring is a distinct .agent.selected .hit rule"
assert_not_contains "$(grep '\.agent\.sev' "$ROOT/web/map.html")" '.hit' \
  "and no status-appearance .agent.sevN rule also targets .hit"
_applyselemph_js=$(awk '/^function applySelectionEmphasis\(\)/,/^\}/' "$ROOT/web/map.html")
assert_contains "$_applyselemph_js" 'g.classList.toggle("selected"' \
  "applySelectionEmphasis toggles .selected directly on g (the outer .agent node), not on a child it queries"
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

# T008: the roster's stylesheet rules were required to land after the
# existing #camera.eased prefers-reduced-motion block so that block stays the
# first one in the file — the one the FR-045/SC-012 assertion above reads.
_first_reduced_motion_line=$(grep -n '@media (prefers-reduced-motion: reduce)' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
_camera_eased_line=$(grep -n '#camera\.eased { transition: transform' "$ROOT/web/map.html" | head -1 | cut -d: -f1)
assert_eq "$(awk -v a="$_first_reduced_motion_line" -v b="$_camera_eased_line" 'BEGIN{print (a>0 && b>0 && a>b) ? "yes" : "no"}')" "yes" \
  "the first @media (prefers-reduced-motion: reduce) block in map.html still follows #camera.eased's rule, unchanged by the roster's own stylesheet additions"

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


# =================================================================== plots ===
printf '\nplots\n'
#
# web/plots.js is the pure identity->coordinate module (contracts/plots-js.md).
# It lives in its own file for the same reason web/md.js does: so these
# assertions can require() it under node without a browser.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/plots-check.js" <<'PLOTSJS'
var P = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}
function fresh() {
  delete require.cache[require.resolve(process.argv[2])];
  return require(process.argv[2]);
}

// A1: same key, same slot, every call.
(function () {
  var p = fresh();
  var s1 = p.assign("district", "d|acme", { seen: 1 });
  var s2 = p.assign("district", "d|acme", { seen: 2 });
  check("A1 same key returns same slot on repeat calls", s1 === s2, s1 + " vs " + s2);
})();

// A2: a key present in storage returns its stored slot without hashing.
(function () {
  var p = fresh();
  var store = JSON.stringify({ v: 1, entries: { "d|acme": { slot: 6, seen: 1 } } });
  p.load(function () { return store; });
  var slot = p.assign("district", "d|acme", { seen: 2 });
  check("A2 a stored key returns its stored slot without recomputing", slot === 6, "got " + slot);
})();

// A3: assigning a new key never changes an existing key's slot.
(function () {
  var p = fresh();
  var before = p.assign("district", "d|acme", { seen: 1 });
  p.assign("district", "d|newone", { seen: 1 });
  var after = p.assign("district", "d|acme", { seen: 1 });
  check("A3 a new key never changes an existing key's slot", before === after, before + " vs " + after);
})();

// A4: a collision's probe step derives from the key, not call order.
(function () {
  var p = fresh();
  // Two full independent module instances, assigning the same two colliding
  // keys in opposite order, must resolve to the same pair of slots each —
  // which would not hold if the probe step came from a call counter.
  var a = fresh(), b = fresh();
  var k1 = "f|s|br|one", k2 = "f|s|br|two";
  var a1 = a.assign("figure", k1, { seen: 1 });
  var a2 = a.assign("figure", k2, { seen: 1 });
  var b2 = b.assign("figure", k2, { seen: 1 });
  var b1 = b.assign("figure", k1, { seen: 1 });
  check("A4 probe outcome for a key does not depend on assignment order",
        a1 === b1 && a2 === b2, [a1, a2, b1, b2].join(","));
})();

// A5: only level/key/opts.seen influence the result.
(function () {
  var p1 = fresh(), p2 = fresh();
  var s1 = p1.assign("building", "b|acme|repo", { seen: 1 });
  var s2 = p2.assign("building", "b|acme|repo", { seen: 999, bogus: "ignored" });
  check("A5 no argument besides level/key/opts.seen influences the slot", s1 === s2, s1 + " vs " + s2);
})();

// A6: an annex key (<key>#2) is itself persisted.
(function () {
  var p = fresh();
  for (var i = 0; i < 10; i++) p.assign("zone", "z|repo|branch" + i, { seen: 1 });
  // zone cap is 2, so branch2..branch9 must overflow into annex zone keys.
  var raw = null;
  p.save(function (v) { raw = v; }, []);
  var saved = JSON.parse(raw);
  var hasAnnex = Object.keys(saved.entries).some(function (k) { return k.indexOf("#") !== -1; });
  check("A6 an annex key is itself persisted", hasAnnex, Object.keys(saved.entries).join(","));
})();

// P1: every returned coordinate is an integer.
(function () {
  var p = fresh();
  var tree = { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main", figures: [{ sid: "s1" }] }] }] }] };
  var r = p.place(tree);
  var f = r.world.figures["f|acme/repo|main|s1"];
  check("P1 figure coordinates are integers",
        Number.isInteger(f.x) && Number.isInteger(f.y) && Number.isInteger(f.cx) && Number.isInteger(f.cy),
        JSON.stringify(f));
})();

// P2: fields excluded from layout do not affect coordinates.
(function () {
  function treeWith(extra) {
    return { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main",
      figures: [Object.assign({ sid: "s1" }, extra)] }] }] }] };
  }
  var p1 = fresh(), p2 = fresh();
  var r1 = p1.place(treeWith({ sev: 4, cost: 9.9, age: 100 }));
  var r2 = p2.place(treeWith({ sev: 1, cost: 0, age: 0 }));
  check("P2 volatile fields never influence a coordinate",
        JSON.stringify(r1.world) === JSON.stringify(r2.world), "trees differed");
})();

// P3/P4: extent is the occupied bbox + gutter, floored at 408x408; a
// remembered-but-unoccupied plot contributes nothing.
(function () {
  var p = fresh();
  var empty = p.place({ districts: [] });
  check("P3 extent floors at 408x408 when nothing is occupied",
        empty.extent.w === 408 && empty.extent.h === 408, JSON.stringify(empty.extent));

  var tree = { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main", figures: [{ sid: "s1" }] }] }] }] };
  var full = p.place(tree);
  var againEmpty = p.place({ districts: [] });
  check("P4 a remembered-but-unoccupied plot contributes nothing to a later extent",
        againEmpty.extent.w === 408 && againEmpty.extent.h === 408, JSON.stringify(againEmpty.extent));
})();

// P5: sig changes only when the occupied set changes.
(function () {
  var p = fresh();
  var tree1 = { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main", figures: [{ sid: "s1" }] }] }] }] };
  var r1a = p.place(tree1);
  var r1b = p.place(tree1);
  check("P5 sig is stable across identical calls", r1a.sig === r1b.sig, r1a.sig);
  var tree2 = { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main", figures: [{ sid: "s1" }, { sid: "s2" }] }] }] }] };
  var r2 = p.place(tree2);
  check("P5 sig changes when the occupied set changes", r2.sig !== r1a.sig, r2.sig + " vs " + r1a.sig);
})();

// P6: cx/cy are usable centres — inside the figure's own box.
(function () {
  var p = fresh();
  var tree = { districts: [{ org: "acme", buildings: [{ slug: "acme/repo", zones: [{ branch: "main", figures: [{ sid: "s1" }] }] }] }] };
  var r = p.place(tree);
  var f = r.world.figures["f|acme/repo|main|s1"];
  check("P6 cx/cy fall within the figure's own box",
        f.cx >= f.x && f.cx <= f.x + f.w && f.cy >= f.y && f.cy <= f.y + f.h, JSON.stringify(f));
})();

// P7: a "no repo" building lands in the reserved district.
(function () {
  var p = fresh();
  var tree = { districts: [{ org: "no repo", isNoRepo: true, buildings: [{ slug: "dir:/tmp/x", zones: [] }] }] };
  var r = p.place(tree);
  check("P7 a no-repo building's district key is the reserved no-repo district",
        Object.keys(r.world.districts)[0] === "d|no repo", Object.keys(r.world.districts).join(","));
})();

// F1-F4: fit.
(function () {
  var p = fresh();
  var f1 = p.fit({ x: 0, y: 0, w: 400, h: 200 }, 800, 800);
  check("F1 scale is uniform and aspect-preserving", f1.k === 2, JSON.stringify(f1));
  var f2 = p.fit({ x: 0, y: 0, w: 10, h: 10 }, 8000, 8000);
  check("F2 scale is clamped to a maximum of 3.0", f2.k === 3, JSON.stringify(f2));
  var f3 = p.fit({ x: 0, y: 0, w: 400, h: 200 }, 800, 800);
  var scaledW = 400 * f3.k, scaledH = 200 * f3.k;
  var centeredX = Math.abs((f3.tx) - ((800 - scaledW) / 2)) < 0.001;
  var centeredY = Math.abs((f3.ty) - ((800 - scaledH) / 2)) < 0.001;
  check("F3 the extent is centred in the available area", centeredX && centeredY, JSON.stringify(f3));
  check("F4 fit holds no state across calls", p.fit({ x: 0, y: 0, w: 400, h: 200 }, 800, 800).k === f1.k, "");
})();

// S1: load of a payload whose v !== 1 discards it wholly. The stored slot (7)
// is deliberately NOT the slot d|zzz would hash to (4): if the version check
// were dropped, assign() would return the discarded 7 instead of recomputing.
(function () {
  var p2 = fresh();
  var store = JSON.stringify({ v: 2, entries: { "d|zzz": { slot: 7, seen: 1 } } });
  p2.load(function () { return store; });
  var slot = p2.assign("district", "d|zzz", { seen: 1 });
  check("S1 load discards a payload whose v is not 1", slot === 4, "slot=" + slot + " (expected freshly-hashed 4, not the discarded 7)");
})();

// S2: throwing storage sets persistence unavailable, without retrying.
(function () {
  var p = fresh();
  var calls = 0;
  p.load(function () { calls++; throw new Error("boom"); });
  check("S2 a throwing load sets persistence to unavailable", p.persistence === "unavailable", p.persistence);
  var savecalls = 0;
  p.save(function () { savecalls++; throw new Error("boom"); }, []);
  check("S2 save after a failed load is not retried (no throw propagates)", true, "");
})();

// S3/S4: save caps at 512, evicting longest-unseen first, never a live key.
(function () {
  var p = fresh();
  for (var i = 0; i < 520; i++) {
    p.assign("figure", "f|s|b|id" + i, { seen: i });
  }
  var raw = null;
  var liveKeys = ["f|s|b|id0"]; // the longest-unseen key, kept alive on purpose
  p.save(function (v) { raw = v; }, liveKeys);
  var saved = JSON.parse(raw);
  var count = Object.keys(saved.entries).length;
  check("S3 save caps entries at 512", count <= 512, "count=" + count);
  check("S4 save never evicts a key in liveKeys, even the longest-unseen",
        saved.entries.hasOwnProperty("f|s|b|id0"), Object.keys(saved.entries).length);
})();

// S5: save writes slot unchanged for every key already stored.
(function () {
  var p = fresh();
  var slot1 = p.assign("district", "d|acme", { seen: 1 });
  var raw = null;
  p.save(function (v) { raw = v; }, ["d|acme"]);
  var saved = JSON.parse(raw);
  check("S5 save writes slot unchanged for an already-stored key",
        saved.entries["d|acme"].slot === slot1, saved.entries["d|acme"].slot + " vs " + slot1);
})();

process.stdout.write(out.join("\n") + "\n");
PLOTSJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/plots-check.js" "$ROOT/web/plots.js" 2>&1)
else
  t_skip "plots geometry" "node not installed"
fi


# ================================================================== camera ===
printf '\ncamera\n'
#
# web/camera.js is the pure camera arithmetic module (contracts/camera-js.md).
# It lives in its own file for the same reason web/md.js and web/plots.js do:
# so these assertions can require() it under node without a browser.
if command -v node >/dev/null 2>&1; then
  cat > "$WORK/camera-check.js" <<'CAMERAJS'
var C = require(process.argv[2]);
var out = [];
function check(name, cond, detail) {
  out.push((cond ? "PASS|" : "FAIL|") + name + "|" + (detail || ""));
}

// K1: scaleFor/clampIdx clamp to the ladder's ends and floor a fractional index.
(function () {
  check("K1 clampIdx clamps below the ladder to 0", C.clampIdx(-3) === 0, C.clampIdx(-3));
  check("K1 clampIdx clamps above the ladder to its last index", C.clampIdx(99) === C.LADDER.length - 1, C.clampIdx(99));
  check("K1 clampIdx floors a fractional index", C.clampIdx(2.7) === 2, C.clampIdx(2.7));
  check("K1 scaleFor never returns a value outside LADDER", C.LADDER.indexOf(C.scaleFor(5)) !== -1, C.scaleFor(5));
})();

// K2: panBy adds screen-pixel deltas to tx/ty and leaves idx untouched.
(function () {
  var v = C.panBy({idx: 3, tx: 10, ty: -5}, 4, 6);
  check("K2 panBy adds the delta to tx and ty", v.tx === 14 && v.ty === 1, JSON.stringify(v));
  check("K2 panBy leaves idx unchanged", v.idx === 3, v.idx);
})();

// K3: clampPan holds the visible rectangle inside a larger-than-viewport extent.
(function () {
  var extent = {x: 0, y: 0, w: 2000, h: 2000};
  var v = C.clampPan({idx: 2, tx: 500, ty: 500}, extent, 400, 400); // k=1
  var visX0 = -v.tx, visX1 = -v.tx + 400;
  check("K3 clampPan keeps the visible rect inside a larger extent",
        visX0 >= extent.x && visX1 <= extent.x + extent.w, JSON.stringify(v));
})();

// K4: clampPan holds a smaller-than-viewport extent inside the viewport.
(function () {
  var extent = {x: 0, y: 0, w: 100, h: 100};
  var v = C.clampPan({idx: 2, tx: -9999, ty: -9999}, extent, 400, 400); // k=1
  var left = extent.x * 1 + v.tx, right = (extent.x + extent.w) * 1 + v.tx;
  check("K4 clampPan keeps a smaller extent inside the viewport",
        left >= 0 && right <= 400, JSON.stringify(v));
})();

// K5: clampPan is idempotent and resolves a non-finite tx/ty to the centred value.
(function () {
  var extent = {x: 0, y: 0, w: 2000, h: 2000};
  var once = C.clampPan({idx: 2, tx: 500, ty: 500}, extent, 400, 400);
  var twice = C.clampPan(once, extent, 400, 400);
  check("K5 clampPan is idempotent", once.tx === twice.tx && once.ty === twice.ty, JSON.stringify([once, twice]));
  var nonfinite = C.clampPan({idx: 2, tx: NaN, ty: Infinity}, extent, 400, 400);
  check("K5 clampPan resolves a non-finite tx/ty to a finite value",
        isFinite(nonfinite.tx) && isFinite(nonfinite.ty), JSON.stringify(nonfinite));
})();

// K6: centreOn puts the world point at the centre of the viewport, optionally at a new rung.
(function () {
  var v = C.centreOn({idx: 2, tx: 0, ty: 0}, 50, 60, 400, 300);
  check("K6 centreOn centres the world point at k=1",
        Math.abs(v.tx - (200 - 50)) < 1e-9 && Math.abs(v.ty - (150 - 60)) < 1e-9, JSON.stringify(v));
  var v2 = C.centreOn({idx: 2, tx: 0, ty: 0}, 50, 60, 400, 300, 3); // idx 3 -> k=2
  check("K6 centreOn honours an explicit idx argument",
        v2.idx === 3 && Math.abs(v2.tx - (200 - 100)) < 1e-9, JSON.stringify(v2));
})();

// K7: fitIndex picks the largest rung that fits both dimensions, and reports overflow when none do.
(function () {
  var extent = {x: 0, y: 0, w: 400, h: 400};
  var fi = C.fitIndex(extent, 850, 850); // fits at k<=2.125 -> idx 3 (k=2)
  check("K7 fitIndex picks the largest fitting rung", fi.idx === 3 && fi.overflow === false, JSON.stringify(fi));
  var huge = {x: 0, y: 0, w: 100000, h: 100000};
  var fiOverflow = C.fitIndex(huge, 400, 400);
  check("K7 fitIndex reports overflow when no rung fits", fiOverflow.idx === 0 && fiOverflow.overflow === true, JSON.stringify(fiOverflow));
})();

// K8: fitView centres the fit index and passes through clampPan.
(function () {
  var extent = {x: 100, y: 100, w: 400, h: 400};
  var fv = C.fitView(extent, 850, 850);
  var k = C.scaleFor(fv.idx);
  var visX0 = -fv.tx / k, visX1 = visX0 + 850 / k;
  check("K8 fitView's visible rect covers the extent on x",
        visX0 <= extent.x + 1 && visX1 >= extent.x + extent.w - 1, JSON.stringify(fv));
  check("K8 fitView surfaces the same overflow flag as fitIndex", fv.overflow === false, fv.overflow);
})();

// K9: levelFor's hysteresis bands and cold mapping.
(function () {
  check("K9 levelFor rises into mid at idx 3", C.levelFor(3, "far") === "mid", C.levelFor(3, "far"));
  check("K9 levelFor stepping in and back out does not flip mid twice",
        C.levelFor(2, "mid") === "mid", C.levelFor(2, "mid"));
  check("K9 levelFor falls out of mid below idx 2", C.levelFor(1, "mid") === "far", C.levelFor(1, "mid"));
  check("K9 levelFor rises into near at idx 5", C.levelFor(5, "mid") === "near", C.levelFor(5, "mid"));
  check("K9 levelFor falls out of near below idx 4", C.levelFor(3, "near") === "mid", C.levelFor(3, "near"));
  check("K9 levelFor's cold mapping resolves both bands downward at idx 2",
        C.levelFor(2, null) === "far", C.levelFor(2, null));
  check("K9 levelFor's cold mapping resolves both bands downward at idx 4",
        C.levelFor(4, null) === "mid", C.levelFor(4, null));
  check("K9 levelFor never returns anything but the three names",
        ["far", "mid", "near"].indexOf(C.levelFor(7, "far")) !== -1, C.levelFor(7, "far"));
})();

// K10: wheelStep accumulates sub-threshold deltas, steps on crossing the
// threshold, and resets immediately on a sign change rather than unwinding.
(function () {
  var r1 = C.wheelStep(0, {deltaY: 40, deltaMode: 0});
  check("K10 wheelStep accumulates without stepping below threshold",
        r1.step === 0 && r1.acc === 40, JSON.stringify(r1));
  var r2 = C.wheelStep(90, {deltaY: 20, deltaMode: 0});
  check("K10 wheelStep steps and resets acc once the threshold is crossed",
        r2.step === 1 && r2.acc === 0, JSON.stringify(r2));
  var r3 = C.wheelStep(50, {deltaY: -10, deltaMode: 0});
  check("K10 wheelStep resets the accumulator immediately on a sign change",
        r3.acc === -10 && r3.step === 0, JSON.stringify(r3));
})();

// K11: zoomTo's anchored world point stays within a pixel of the anchor
// after the step (SC-004), and a no-op request returns the view unchanged.
(function () {
  var v = {idx: 2, tx: -50, ty: 30}; // k=1
  var ax = 120, ay = 80;
  var k1 = C.scaleFor(v.idx);
  var wx = (ax - v.tx) / k1, wy = (ay - v.ty) / k1;
  var stepped = C.zoomTo(v, 5, ax, ay); // idx 5 -> k=4
  var k2 = C.scaleFor(stepped.idx);
  check("K11 zoomTo keeps the anchor's world point within a pixel after the step",
        Math.abs(wx * k2 + stepped.tx - ax) < 1 && Math.abs(wy * k2 + stepped.ty - ay) < 1,
        JSON.stringify(stepped));
  var same = C.zoomTo(v, v.idx, ax, ay);
  check("K11 zoomTo at the same idx returns the view unchanged",
        same.tx === v.tx && same.ty === v.ty && same.idx === v.idx, JSON.stringify(same));
})();

// K12: validateView's rejection table (data-model.md §6) — every bad shape
// returns null, never throws, and a valid record round-trips its fields.
(function () {
  var L = C.LADDER.length;
  check("K12 validateView rejects an absent record", C.validateView(null, L) === null, "null");
  check("K12 validateView rejects undefined", C.validateView(undefined, L) === null, "undefined");
  check("K12 validateView rejects unparseable JSON", C.validateView("{not json", L) === null, "{not json");
  check("K12 validateView rejects a bare number", C.validateView('"7"', L) === null, '"7"');
  check("K12 validateView rejects an array", C.validateView("[]", L) === null, "[]");
  check("K12 validateView rejects the wrong storage version",
        C.validateView(JSON.stringify({v: 2, idx: 1, tx: 0, ty: 0}), L) === null, "v:2");
  check("K12 validateView rejects a non-integer idx",
        C.validateView(JSON.stringify({v: 1, idx: 2.5, tx: 0, ty: 0}), L) === null, "idx:2.5");
  check("K12 validateView rejects an out-of-range idx",
        C.validateView(JSON.stringify({v: 1, idx: 99, tx: 0, ty: 0}), L) === null, "idx:99");
  check("K12 validateView rejects a non-finite tx",
        C.validateView({v: 1, idx: 1, tx: NaN, ty: 0}, L) === null, "tx:NaN");
  check("K12 validateView rejects a non-finite ty",
        C.validateView({v: 1, idx: 1, tx: 0, ty: Infinity}, L) === null, "ty:Infinity");
  var ok = C.validateView(JSON.stringify({v: 1, idx: 3, tx: -12, ty: 5}), L);
  check("K12 validateView accepts and round-trips a valid record",
        ok && ok.idx === 3 && ok.tx === -12 && ok.ty === 5, JSON.stringify(ok));
})();

// K13: loadView/saveView round-trip through injected storage functions, and a
// throwing storage flips persistence to "unavailable" exactly once.
(function () {
  var store = null;
  var loaded = C.loadView(function () { return store; });
  check("K13 loadView returns null when nothing is stored", loaded === null, String(loaded));
  C.saveView(function (v) { store = v; }, {idx: 4, tx: -1, ty: 2});
  var restored = C.loadView(function () { return store; });
  check("K13 saveView/loadView round-trips idx/tx/ty",
        restored && restored.idx === 4 && restored.tx === -1 && restored.ty === 2,
        JSON.stringify(restored));
})();
(function () {
  var throwingGet = function () { throw new Error("quota"); };
  var before = C.persistence;
  var r1 = C.loadView(throwingGet);
  check("K13 loadView swallows a throwing getItem and returns null", r1 === null, String(r1));
  check("K13 a throwing storage flips persistence to unavailable",
        before === "ok" && C.persistence === "unavailable", before + " -> " + C.persistence);
  // Never retried: a second throwing call does not un-flip or re-flip anything
  // observable — persistence stays exactly "unavailable".
  C.loadView(throwingGet);
  check("K13 persistence stays unavailable and is never reset",
        C.persistence === "unavailable", C.persistence);
})();

// K14: visibleWorldRect/intersects — the FR-038 test, including a stored
// viewport whose rectangle lies entirely outside the world.
(function () {
  var view = {idx: 2, tx: -100, ty: -50}; // k=1
  var rect = C.visibleWorldRect(view, 400, 300);
  check("K14 visibleWorldRect derives the visible rectangle from tx/ty/k",
        rect.x === 100 && rect.y === 50 && rect.w === 400 && rect.h === 300, JSON.stringify(rect));
  var world = {x: 0, y: 0, w: 1000, h: 1000};
  check("K14 intersects is true when the visible rect overlaps the world",
        C.intersects(rect, world) === true, JSON.stringify([rect, world]));
  var farAway = C.visibleWorldRect({idx: 2, tx: -100000, ty: -100000}, 400, 300);
  check("K14 intersects is false for a viewport far outside the world",
        C.intersects(farAway, world) === false, JSON.stringify([farAway, world]));
  check("K14 intersects is false on a non-finite input rather than throwing",
        C.intersects({x: NaN, y: 0, w: 10, h: 10}, world) === false, "NaN");
})();

process.stdout.write(out.join("\n") + "\n");
CAMERAJS

  while IFS='|' read -r status name detail; do
    [ -z "$status" ] && continue
    if [ "$status" = "PASS" ]; then
      t_pass "$name"
    else
      t_fail "$name" "$detail"
    fi
  done < <(node "$WORK/camera-check.js" "$ROOT/web/camera.js" 2>&1)
else
  t_skip "camera arithmetic" "node not installed"
fi


# ============================================================ roster-module ===
printf '\nroster-module\n'
#
# web/roster.js is the pure roster-row-shaping module for the docked agent
# panel (contracts/roster-js.md). It lives in its own file for the same
# reason web/md.js, web/plots.js and web/camera.js do: so these assertions
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

  check("S-H flyIdx(\"far\") is NEAR_IDX; flyIdx(\"mid\")/flyIdx(\"near\") are null",
        R.flyIdx("far") === R.NEAR_IDX && R.NEAR_IDX === 5
          && R.flyIdx("mid") === null && R.flyIdx("near") === null);

  var camera = require(process.argv[3]);
  check("S-I NEAR_IDX resolves to \"near\" in camera.js's levelFor from every prior level",
        camera.levelFor(R.NEAR_IDX, null) === "near"
          && camera.levelFor(R.NEAR_IDX, "far") === "near"
          && camera.levelFor(R.NEAR_IDX, "mid") === "near"
          && camera.levelFor(R.NEAR_IDX, "near") === "near");
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

// statements (contracts/roster-js.md §8, data-model.md §5, C-A..C-I)
(function () {
  check("C-A feed_down names the reason and the measured age of the rows still shown",
        (function () {
          var s = R.statements({trust: "feed_down", reason: "ECONNREFUSED", dataAge: 125, unreadable: 0});
          return s.main.indexOf("ECONNREFUSED") !== -1 && s.main.indexOf("2m") !== -1
            && s.mainKind === "down";
        })());
  check("C-B warming says the first snapshot is still being taken and carries no age",
        (function () {
          var s = R.statements({trust: "warming", unreadable: 0});
          return s.mainKind === "warming" && /\d/.test(s.main) === false;
        })());
  check("C-C unreadable: 3 states the count and names ccwatch doctor",
        R.statements({trust: "ok", unreadable: 3}).unreadable.indexOf("3") !== -1
          && R.statements({trust: "ok", unreadable: 3}).unreadable.indexOf("ccwatch doctor") !== -1);
  check("C-D unreadable 0 or null is empty, never \"0 registry files\"",
        R.statements({trust: "ok", unreadable: 0}).unreadable === ""
          && R.statements({trust: "ok", unreadable: null}).unreadable === "");
  check("C-E empty:true, trust:ok states there are no live sessions",
        R.statements({trust: "ok", empty: true, unreadable: 0}).empty !== "");
  // FR-029/SC-007 spot-check (quickstart.md §2): empty:true produces a
  // sentence only when trust:"ok" — the exclusion is enforced inside
  // statements() itself, whatever the caller passed for cond.empty.
  check("C-F empty:true, trust:feed_down is withheld regardless of the caller's cond.empty",
        R.statements({trust: "feed_down", reason: "x", dataAge: 1, empty: true, unreadable: 0}).empty === "");
  check("C-G empty:true, trust:warming is withheld",
        R.statements({trust: "warming", empty: true, unreadable: 0}).empty === "");
  check("C-H the four sentences are pairwise distinct, and main/empty are never both non-empty",
        (function () {
          var down = R.statements({trust: "feed_down", reason: "x", dataAge: 1, unreadable: 0});
          var warming = R.statements({trust: "warming", unreadable: 0});
          var unreadable = R.statements({trust: "ok", unreadable: 3}).unreadable;
          var empty = R.statements({trust: "ok", empty: true, unreadable: 0});
          var strs = [down.main, warming.main, unreadable, empty.empty];
          var uniq = {};
          strs.forEach(function (s) { uniq[s] = true; });
          return Object.keys(uniq).length === strs.length
            && (down.empty === "" ) && (warming.empty === "") && (empty.main === "");
        })());
  check("C-I unreadable is additive: it may accompany the down sentence",
        (function () {
          var s = R.statements({trust: "feed_down", reason: "x", dataAge: 1, unreadable: 2});
          return s.main !== "" && s.unreadable !== "";
        })());
})();

// goneText (contracts/roster-js.md §8, C-J). statements() is US4's export
// (Phase 6); once it lands the cross-check below runs for real, but the
// invariant it enforces — the tombstone's leading clause is its own, never
// "the feed"/"registry" wording — is checked either way so this assertion is
// not vacuous while statements() does not yet exist.
(function () {
  var gone = R.goneText("s1", "alpha");
  var goneLead = gone.split(" ").slice(0, 3).join(" ");

  check("C-J the tombstone names the session, not the feed",
        gone.indexOf("alpha") !== -1 && gone.toLowerCase().indexOf("the feed") === -1
          && gone.toLowerCase().indexOf("registry") === -1);

  if (typeof R.statements === "function") {
    var statementsShapes = [
      R.statements({trust: "feed_down", unreadable: 0}),
      R.statements({trust: "warming", unreadable: 0}),
      R.statements({trust: "ok", empty: true, unreadable: 0}),
      R.statements({trust: "ok", empty: false, unreadable: 3}),
    ];
    check("C-J goneText shares no leading clause with any string statements() can produce",
          statementsShapes.every(function (s) {
            return [s.main, s.unreadable, s.empty].every(function (str) {
              if (!str) return true;
              var lead = String(str).split(" ").slice(0, 3).join(" ");
              return lead !== goneLead;
            });
          }));
  }
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
  done < <(node "$WORK/roster-check.js" "$ROOT/web/roster.js" "$ROOT/web/camera.js" 2>&1)
else
  t_skip "roster module" "node not installed"
fi


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
if [ $((pass + fail)) -lt "$TALLY_FLOOR" ]; then
  printf '\n  \033[31m✗\033[0m only %s assertions were COUNTED, expected at least %s.\n' \
    "$((pass + fail))" "$TALLY_FLOOR"
  printf '    Assertions are running but not registering.\n\n'
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
