# ccwatch — notes for Claude Code

A single bash script that reports on every Claude Code session on the machine
and which one is stuck. No build, no dependencies to install, no package
manifest. Read `README.md` first: it explains *why* each verdict is shaped the
way it is, and most of the rules below are only sensible in light of that.

## Layout

```
bin/ccwatch      the whole tool (~2900 lines of bash + embedded python3/jq)
web/index.html   the table view, served by `ccwatch serve`
web/map.html     the map view — projects as territories, sessions as figures
tests/run.sh     shellcheck + the assertion suite; the only test entry point
```

`bin/ccwatch` is organised in banner-commented sections — `collection`,
`statusline`, `the join`, `rendering`, `resume`, `events`, `transcript`,
`pending asks`, `send`, `deploys`, `peers`, `serve`, `doctor`, `dispatch`. A new
subcommand needs a `cmd_*` function, a line in the `case` in `dispatch`, and an
entry in `usage()`.

## Running things

```bash
./tests/run.sh                  # everything: shellcheck, then the assertions
./bin/ccwatch once              # one paint against the real ~/.claude
./bin/ccwatch doctor            # is ccwatch's own view still trustworthy
CCWATCH_PROFILE=1 ./bin/ccwatch --json >/dev/null   # per-stage timings
```

The suite starts real HTTP servers on loopback and creates temp directories, so
it needs `mktemp -d` to work. **In a restricted sandbox it will fail ~13
assertions with empty output** (`resume`, `peers`, `serve`) — that is the
sandbox denying `mktemp`, not a regression. Re-run with the sandbox off before
believing a failure.

## The rules that are not negotiable

These are invariants, not preferences. Each one exists because breaking it
produced a specific wrong output that someone believed.

1. **Never make a claim on one signal.** A status is corroborated against a
   second, independent one (transcript mtime, CPU time, a runner pid) before it
   is escalated. `busy` from the registry alone is not evidence of work.
2. **Print the measurement next to the verdict.** `HUNG?` always shows the
   silence and the CPU reading that produced it. The judgement belongs to the
   person reading, and a column that cries wolf is a column they stop reading.
3. **A stale reading is withheld, not annotated.** A percentage on screen is
   read as current whatever is printed beside it. Usage and context readings
   past their staleness window are dropped; the header says how old the last one
   was. Never render a number with an "(old)" note and call that honest.
4. **A failure must never look like an absence.** "no deploys" and "HTTP 401:
   Bad credentials" are different facts and must read differently. A `gh`
   failure leaves the previous cache in place rather than replacing it with an
   empty list. An unreadable registry file costs one row and is counted, so
   `doctor` can report it.
5. **Never invent a status you did not read.** An unrecognised value from the
   registry is surfaced by `doctor` rather than falling through a default branch
   and being presented as though it had been understood.
6. **Say nothing rather than guess.** An embedded-SDK session (`sdk-ts`) writes
   no transcript and publishes no status, so its silence measures nothing and is
   never escalated to a hang. A directory with no git remote is marked `no repo`
   rather than folded into a real repository.
7. **Colour is never the only carrier of meaning.** Every severity also has a
   distinct word, so `ccwatch once | grep HUNG` works and so does a screen
   reader. Honour `NO_COLOR`.
8. **Delivery is observed, not assumed.** `ccwatch send` watches the receiver's
   transcript for the message to land and reports delivered / queued / failed
   with the real reason. Writing to a socket proves nothing.
9. **Loopback is not a security gate.** Any page in the browser can POST to
   `127.0.0.1`. The send endpoint requires both a per-run token injected into
   the page ccwatch serves *and* an `Origin` check. Never weaken one on the
   grounds that the other exists.
10. **Transcripts are sensitive.** They contain whole tool outputs and file
    contents. `convo` reads a bounded byte tail, keeps assistant/user text
    truncated, reduces a tool *use* to its name and a short argument summary,
    and a tool *result* to its size — never its content. Nothing may put that
    content on a socket.
11. **The dashboard runs the same code path as the terminal.** `/api/state`
    invokes the commands the CLI does. Two renderings that compute status
    separately will eventually disagree, and there is no way to tell which is
    lying.

## Portability constraints

- **bash 3.2**, because that is what macOS ships. No `mapfile`/`readarray`, no
  `declare -A`, no `${var,,}`/`${var^^}`. The suite greps for these.
- **macOS `stat -f` and `ps -o lstart=`** in their BSD forms. This is a macOS
  tool; CI runs on macOS only.
- `python3` is used for the socket client, date parsing and the HTTP server.
  Pass programs with `python3 -c`, never on stdin — a heredoc on stdin collides
  with the payload the program is trying to read, which cost a whole debugging
  session once.
- `shellcheck -x -S warning` must be clean for both `bin/ccwatch` and
  `tests/run.sh`. Suppress with a narrow `# shellcheck disable=` and a reason,
  never by loosening the severity.

## Test discipline

- **Hermetic.** Every assertion runs against a fabricated `~/.claude` under
  `$WORK` via `CLAUDE_CONFIG_DIR`, with `CCWATCH_FAKE_PS` substituting the
  liveness probe. Never assert against the developer's live sessions — that is
  a screenshot, not a test.
- **Mutation-check every new assertion.** Break the implementation in the
  specific way the assertion describes, confirm the assertion fails, then
  restore. An assertion that passes against a broken implementation is worse
  than none, because it is counted as coverage. Add a row to the mutation table
  in `README.md`.
- **Fixtures must be able to fail.** A fixture where the behaviour under test
  could not have succeeded anyway will pass either way — that has happened here
  (the de-duplication assertion) and is a test defect.
- `TALLY_FLOOR` in `tests/run.sh` guards against assertions that run but are
  never counted. Raise it when adding a batch.
- Reap anything you start. A leaked `serve` holds a port a later run may pick,
  and then that run tests the leaked binary.
- A slow machine is not a defect: prefer `t_skip` with a reason over a flake.

## Writing style, in code and in prose

Comments say **why**, and name the failure that motivated the code — the `⚠️`
comments are the load-bearing ones and should not be trimmed. Prefer the
concrete number that was measured ("850KB from the end of a real 4.9MB
transcript") over an adjective. This applies to `README.md` too: it documents
the reasoning and the bugs found, not just the flags.

Keep examples in the README **generic** (`acme/checkout-api`, `web-app`,
`pricing`). Do not paste real session names, repository slugs, feature ids or
costs from the machine this is developed on into documentation or fixtures.

## Commits

Conventional prefixes (`feat:`, `fix:`, `docs:`, `test:`), subject in the
imperative describing the user-visible change. Do not commit or push unless
asked. `~/.claude/ccwatch/` is runtime state and is never committed.
