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
TALLY_FLOOR=90

assert_contains() { case "$1" in *"$2"*) t_pass "$3";; *) t_fail "$3" "expected to contain: $2";; esac; }
assert_not_contains() { case "$1" in *"$2"*) t_fail "$3" "should NOT contain: $2";; *) t_pass "$3";; esac; }
assert_eq() { [ "$1" = "$2" ] && t_pass "$3" || t_fail "$3" "expected '$2', got '$1'"; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ccwatch-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

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
rm -f "$FH/sessions/9009.json"

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
assert_contains "$_old" "old]" "a stale usage reading says how old it is"
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
 {"databaseId":1,"workflowName":"Deploy to ShipIt","status":"in_progress","conclusion":None,
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

# The dashboard must never derive its own version of the status: two renderings
# that compute it separately will eventually disagree, and the one you are not
# looking at is the one that is wrong. So /api/state is asserted to be the same
# shape the CLI produces.
if command -v curl >/dev/null 2>&1; then
  SPORT=$((18000 + RANDOM % 900))
  mksess 9107 ssssssss-0000-0000-0000-000000000001 serverow /fake/repo idle cli
  mktrans ssssssss-0000-0000-0000-000000000001 20
  mkps 9107 "0:10.00" > "$WORK/ps-sv"
  ( CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS="$WORK/ps-sv" CCWATCH_HOME="$DH" \
    CCWATCH_DEPLOY_TTL=999999 "$CCWATCH" serve --port "$SPORT" >"$WORK/serve.log" 2>&1 & )
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
  # The handler must not block: it was serving from a per-request subprocess at
  # first, and eleven concurrent requests piled up without one completing.
  _t=$( { time -p curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$SPORT/api/state"; } 2>&1 \
        | awk '/^real/{print ($2 < 1) ? "fast" : "slow"}')
  assert_eq "$_t" "fast" "the handler answers from memory rather than shelling out per request"
  assert_eq "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SPORT/")" "200" \
    "and the dashboard itself is served"
  # Loopback only: this exposes which repositories you work in and fragments of
  # peer messages.
  assert_contains "$(cat "$WORK/serve.log")" "127.0.0.1" "serve binds loopback, not every interface"
  pkill -f "ccwatch serve --port $SPORT" 2>/dev/null || true
  rm -f "$FH/sessions/9107.json"
else
  t_skip "serve" "curl not available"
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
