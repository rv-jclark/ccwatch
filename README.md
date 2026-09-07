# ccwatch

Every Claude Code session on this machine, and which one is stuck.

```
NAME                  PROJECT            STATUS         AGE   LAST
crimeball-d9          crimeball          * waiting      3m    permission to run rm 3m
ganttlet-web-fc       ganttlet-web       ! HUNG?        4d    quiet 41m
screened-84           screened           + sdk          5m    no status published
  \_ 011-list-challenge-tracking  analyze/running  opus  $11.15
agents-38             agents             ~ sdk-ts       4d    cpu moving
agents-e6             agents             - idle         1d    14m ago

UNFINISHED RUNS — stopped in the last 24h, and no live session is holding them
  specify/failed       314-ganttlet-derived-capacity  opus  $55.19
      9h ago  claude --resume 15dbe4c0-58ef-4ace-8b21-f633c37caa85

19 live · 1 waiting on you · 1 suspect · 3 unfinished run(s)
```

```bash
ccwatch                  # live table, refreshed until you quit (q / Ctrl-C)
ccwatch once             # draw it once — safe in a pipe or a status bar
ccwatch --json           # the same data, for scripting
ccwatch serve            # table + map in a browser, with replies
ccwatch resume           # what to reopen after a crash or reboot
ccwatch send <who> <msg> # say something to a session that is already running
ccwatch deploys          # CI/deploy runs you are waiting on
ccwatch subscribe <wf>   # (run by an agent) tell me when that deploy lands
ccwatch peers            # which sessions have been talking to each other
ccwatch daemon           # watch deploys and notify subscribers while you are away
ccwatch doctor           # check that ccwatch's own view is trustworthy
```

`ccwatch serve --read-only` if you would rather the browser could not send.


Needs `jq`, plus `git`/`gh` for the deploy panel. Everything else ships with
macOS. One script, one HTML file.

## Why not just `claude agents`

Claude Code has a built-in fleet view — `claude agents`, and `claude agents
--json` for scripting. It is good, and if it answers your question you should
use it. Two things it does not do:

**It never re-checks `busy`.** The status is derived from UI state alone
(`isLoading || delegatedActive`), so a session wedged on a network stall or a
hung tool call reports `busy` forever. Nothing compares that claim against
whether any work is actually happening. This is the failure that costs you an
afternoon: an agent stopped an hour ago and the dashboard still says it is
working.

**It is empty after a reboot.** The registry is a directory of pid-named files,
filtered to live pids — so at the exact moment you need to know what you were in
the middle of, there is nothing there.

`ccwatch` also drops two fields the JSON output omits — `entrypoint` (which
distinguishes a headless run from an interactive one) and `waitingFor` (*what* a
session is blocked on, not just that it is).

## Nothing is allowed to fail quietly

That is the whole design. Every status is corroborated against a second,
independent signal:

| Signal | What it sees | What it cannot |
|---|---|---|
| `~/.claude/sessions/<pid>.json` | status, and `waitingFor` | never populated for SDK sessions; gone after a reboot |
| the transcript's mtime | whether the conversation is still growing | embedded-SDK sessions never write one |
| the process's CPU time | whether *any* work is happening, for any session | a long network wait looks idle |
| `.pipeline/state.json` + runner pid | a phase marked `running` whose runner is dead — a crash, as a fact | only exists for [spec-run](https://github.com/rv-jclark/speckit-pipeline) phases |

The corroboration cuts **both** ways, which matters more than the flagging. A
quiet transcript is reported as `HUNG?` only when CPU has also stopped moving —
because one `Bash` call running a long test suite is legitimately silent, and a
column that cries wolf on it is a column you stop reading. The measurement
behind every verdict is printed next to it, so the judgement stays yours.

### Usage, without handing your credential to a monitoring tool

The header shows how much of your rate limit you have used, and each session
shows how full its context window is:

```
5h 42% (resets 1h)   7d 18% (resets 3d)

NAME                  PROJECT            STATUS      AGE   CTX  LAST
speckit-pipeline-8e   speckit-pipeline   ● busy      2h    18%  3s ago
```

These come from a feed Claude Code is **already pushing**: it hands its
statusline command a JSON payload containing `rate_limits` (`five_hour`,
`seven_day`, `spend_limit`) and a per-session `context_window`. `ccwatch
statusline` reads that payload, records the numbers, and passes the payload on
to whatever statusline you already had:

```bash
ccwatch install-statusline    # wraps your existing statusline, does not replace it
```

The alternative would be `GET /api/oauth/usage`, which is where `/usage` gets
the same figures — but that needs your OAuth token out of the keychain, and a
monitoring tool that handles your credential in order to display a percentage
is a bad trade.

Two consequences, both stated in the output rather than hidden:

- Only sessions with a statusline report, which means only interactive ones.
  Fine for rate limits (they are account-wide, so one reporter is enough), and
  the reason the `CTX` column is blank for headless rows.
- A reading has an age. Past a minute the header says so, and a context reading
  that has stopped being refreshed is **dropped rather than shown** — a gauge
  frozen at the value it had an hour ago looks live, which is worse than no
  gauge at all.

### The status column

```
* waiting        blocked on you. LAST says on what, and for how long.
! HUNG?          says busy, but its transcript has stopped growing and its
                 CPU has stopped moving.
! HUNG!!         the same, past 3x the threshold.
! SDK STALE?     headless `claude -p` run, publishes no status, gone quiet.
! NO TRANSCRIPT  claims to be working with nothing to corroborate it.
+ busy / sdk     working, and a second signal proves it.
~ sdk-ts         an embedded-SDK session. See below.
~ shell          dropped to a shell.
- idle           waiting for a prompt, nothing pending.
```

Two things are deliberately **not** claimed:

- An embedded-SDK session (`entrypoint: sdk-ts`) writes no transcript and
  publishes no status, so silence there measures nothing. It is never escalated
  to a hang. The first version did, and fired on 4 of 19 real sessions — an
  embedded session waiting on its host program is quiet by design, and there is
  no way to tell that from wedged.
- A session's own status and its run's status are kept separate. A session can
  be honestly `idle` while the run it drove has crashed. Collapsing those
  produced rows reading `! idle`, which is not a sentence.

## Talking to a session that is already running

`claude --resume` opens a *copy* of a conversation in a new process. `ccwatch
send` puts a message into the session that is **already running**:

```bash
ccwatch send ganttlet-web-fc "the deploy failed, look at the migration step"
ccwatch send --dry-run agents-7b "..."   # show the exact frames first
```

This is not prising anything open. Claude Code exports
`CLAUDE_CODE_MESSAGING_SOCKET` and `CLAUDE_CODE_MESSAGING_TOKEN` into the
environment of every tool call, and prints the wire format in its own debug log:
newline-delimited JSON over a per-session Unix socket, with an optional auth
line whose token sits beside the registry entry. Messages arrive in the
receiver as a normal user turn, labelled `from: ccwatch`, and Claude Code wraps
them with its own warning that a peer cannot grant permission escalation.

**Delivery is observed, not assumed.** Writing to the socket proves nothing —
the server accepts the connection, parses lines, and can drop one silently. So
after sending, `ccwatch` watches the *receiver's* transcript for the message to
appear and reports one of three things:

```
delivered to agents-7b (confirmed in its transcript after 3s)
queued for agents-7b, but not in its transcript after 10s
      normal if it is mid-turn — the queue is drained between turns.
could not deliver to agents-7b: <the actual socket error>
```

That verification earned its place immediately. The first version printed
`sent` and stopped — and the first real end-to-end test showed the write
"succeeding" while nothing arrived, because the client was passing its own
program on stdin and so read an empty payload. `sent` was a lie, and only
checking the receiver caught it.

## Deploys, and agents that subscribe to them

```bash
ccwatch deploys      # in flight, and concluded in the last 24h
```

```
DEPLOYS — in flight, and concluded in the last 24h
  RUNNING   Deploy to ShipIt    rvohealth/ganttlet-web  main   started 5m ago
  FAILURE   deploy-production   jamiebclark/crimeball   main   1h ago
      https://github.com/jamiebclark/crimeball/actions/runs/2
```

Runs come from `gh run list` for every repo you have a session in, filtered to
deploy-shaped workflows (`CCWATCH_DEPLOY_PATTERN`, default
`deploy|release|rollback|publish|promote`) — a CI run on every push is noise. A
`gh` failure is reported **with its actual message**, because "no deploys" and
"HTTP 401: Bad credentials" are different facts.

**Agents can subscribe themselves.** Claude Code puts `CLAUDE_CODE_SESSION_ID`
in the environment of every tool call, so an agent needs no plumbing:

```bash
ccwatch subscribe deploy-production     # run by the agent, inside its own session
```

`ccwatch daemon` then watches, and messages that session when a matching run
finishes. The agent does not poll and does not hold a connection open — which
is the only design that survives it being mid-turn, compacting, or restarted.
Notifications are de-duplicated per subscriber *and* per run, so nobody gets
told about the same deploy every sixty seconds.

## Who is talking to whom

```bash
ccwatch peers
```

```
  ganttlet-web-fc ==> agents-7b        7 msgs, last 2026-09-07T14:04Z
  agents-7b ==> ganttlet-web-fc        6 msgs, last 2026-09-07T15:08Z
```

A message from another session is recorded in the **receiver's** transcript as
a user entry with `origin.kind == "peer"`, carrying the sender's declared name,
a `verifiedPeerPid` the server checked against the socket's peer credentials,
and a `hopChain` for relayed messages — so A→B→C reconstructs as a path rather
than two unrelated edges.

The verified pid is preferred over the declared name, because one was checked
and the other was merely asserted by the sender. Building the graph from
transcripts rather than by watching traffic means it works retrospectively and
survives a reboot.

## In a browser

```bash
ccwatch serve --open        # http://127.0.0.1:8787
```

Two views, same data: **`/`** is the table, **`/map`** groups agents into their
projects.

```
┌ agents:ganttlet-platform ─┐ ┌ screened ─────────────┐ ┌ crimeball ─ FAILURE ┐
│   ☺                       │ │  ☺    ☺──2──☺          │ │   ☺      ☺ᶻ         │
│   84                      │ │  4f   1f    d9         │ │   f6     d9         │
│ specify/failed  $55.19    │ │ plan/needs_input       │ │                     │
└───────────────────────────┘ └───────────────────────┘ └─────────────────────┘
```

Each project is a territory; each session is a figure inside it. Appearance
carries the status: a **raised arm and a pulsing `!`** for a session blocked on
you, a **tilted figure with `?`** for one that says it is busy but has gone
quiet, a **bobbing** figure for one that is working, an **outline** for a
session with nothing to corroborate it, and a `z` for idle. The fill level
inside the body is how full its context window is. Motion is only ever applied
to a state that is actually changing, so a still figure means a still session.

Unfinished runs lie in the territory they belong to, deploy badges sit in its
header, and messages between sessions are drawn as arrows between the two
figures — including across territories, which is the case worth seeing.

Territories are laid out in a plain responsive grid rather than as a
force-directed graph. With a dozen nodes a spring layout is harder to read than
the list it is drawn from, and it rearranges itself every time you look at it —
"did that agent move, or do I misremember" is not a question a monitoring view
should raise.

### Replying from the page

Click a figure (or the `reply` button in the table view) to send it a message.
You get the same three honest outcomes the terminal gives, because it is the
same code path — `ccwatch send`, which waits to see the message land in the
receiver's transcript:

```
delivered — it has the message
queued — mid-turn, it will read this next turn
failed — <the actual reason>
```

**The endpoint is gated, and loopback is not the gate.** Any page open in your
browser can POST to `127.0.0.1`, so without a real check a random site could
inject prompts into every agent you have running. Two things close that:

1. A **per-run token**, generated at startup and injected into the page
   `ccwatch` itself serves. Same-origin policy stops another site reading that
   HTML, so a drive-by request cannot obtain it.
2. An **Origin check**, because browsers attach `Origin` to cross-origin POSTs.

Both are asserted by tests that were verified to fail with either check
removed. `ccwatch serve --read-only` drops the endpoint entirely and serves no
token, and the page then shows itself as read-only.

### Why it refreshes the way it does

Each panel carries **its own age**, which exists because of how the first
version failed. It shelled out to `ccwatch --json` inside the request handler,
so a multi-second snapshot met a page polling every three seconds and the
requests piled up — Chrome showed eleven concurrent `/api/state` requests as
`pending` and not one completed. It now refreshes in three independent
background threads (sessions every 2s, peers every 45s, deploys every 60s) and
serves from memory in about 5ms, so a hanging `gh` can only make the deploys
panel stale, and the page says which panel is behind.

`/api/state` runs the very same commands the terminal does. A dashboard that
computes its own version of the status is one that will eventually disagree
with the terminal, and you would have no way to tell which was lying.

## After a reboot

`ccwatch resume` rebuilds the list from transcripts, which are append-only and
survive restarts — each line carries its own `cwd` and branch. It drops anything
already running, and flags any `spec-run` phase that needs a *rerun* rather than
just a reattach.

```bash
ccwatch resume --cd     # emit `cd <dir> && claude --resume <id>` to paste
ccwatch resume --all    # ignore the 14-day window
```

Two bugs found here worth knowing about, because both produced output that
looked fine:

- The live-session exclusion read the wrong JSON path, so `jq` errored on every
  invocation, the exclusion list came out **empty**, and resume cheerfully
  offered to reopen sessions that were still running. The error went to stderr
  under a heading that printed normally.
- Subagent transcripts live one level deeper, at
  `<sessionId>/subagents/agent-*.jsonl`, and are named for the *task*. Recursing
  into them offered `claude --resume agent-a9cec8c7fe67e1238` — a task id, not a
  session id, so the command could not have worked. There were 131 of them,
  crowding out the real sessions.

Both are now guarded twice over — by path depth and by the transcript's own
`isSidechain` flag — and the session id printed comes from *inside* the
transcript rather than from the filename, so the command is correct by
construction.

## Polling can still miss a prompt

A dialog that opens and closes between two refreshes leaves no trace in any
poll. `ccwatch install-hooks` adds four hooks — `Notification`, `SessionStart`,
`SessionEnd`, `Stop` — appending to `~/.claude/ccwatch/events.jsonl`, so "did
anything need me while I was away" has an answer that does not depend on having
been watching.

```bash
ccwatch install-hooks    # shows the exact change and asks first
ccwatch log 30           # recent events
```

It backs up your `settings.json` before writing, leaves hooks you already had
in place, and is idempotent — running it again after an upgrade repairs the
entries rather than installing a second copy of each.

## When ccwatch itself is the thing that broke

`ccwatch` reads an internal file layout, so a Claude Code upgrade could move it.
The failure that must never happen is an **empty, confident table**, so
`ccwatch doctor` cross-checks its own parse against the supported
`claude agents --json` and reports disagreement as a defect in ccwatch:

```
+ registry schema looks right (pid, cwd, sessionId, startedAt)
+ all status values are ones ccwatch understands
+ agrees with 'claude agents --json' exactly
~ hooks NOT installed — a prompt that opens and closes between polls will be missed
```

It also reports unreadable registry files, and any status value the classifier
does not recognise — rather than letting a new one fall through to a default
branch and be presented as though it had been read.

## Install

```bash
git clone https://github.com/rv-jclark/ccwatch
ln -s "$PWD/ccwatch/bin/ccwatch" /usr/local/bin/ccwatch
```

## Configuration

All environment variables, all optional.

| Variable | Default | |
|---|---|---|
| `CCWATCH_BUSY_STALE` | `600` | seconds of transcript silence before `busy` is suspect |
| `CCWATCH_SDK_STALE` | `900` | the same for headless `claude -p` sessions |
| `CCWATCH_CPU_MIN_GAP` | `1.5` | minimum seconds between CPU samples for a delta to count |
| `CCWATCH_CTX_STALE` | `120` | how old a context reading may be before it is dropped |
| `CCWATCH_REFRESH` | `2` | seconds between repaints |
| `CCWATCH_RESUME_DAYS` | `14` | how far back `ccwatch resume` looks |
| `CCWATCH_UNFINISHED_HOURS` | `24` | how recent an unfinished run must be to appear in the live table |
| `CCWATCH_SEND_VERIFY` | `10` | seconds to wait for a sent message to appear in the receiver |
| `CCWATCH_SEND_AS` | `ccwatch` | how sent messages identify themselves |
| `CCWATCH_DEPLOY_PATTERN` | `deploy\|release\|rollback\|publish\|promote` | which workflows count as deploys |
| `CCWATCH_DEPLOY_TTL` | `60` | seconds to cache `gh` results |
| `CCWATCH_PORT` | `8787` | port for `ccwatch serve` |
| `CCWATCH_HOME` | `~/.claude/ccwatch` | where the event log and usage feed live |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | which Claude Code config directory to read |
| `CCWATCH_PROFILE` | | print per-stage timings to stderr |
| `NO_COLOR` | | disable colour |

Colour is never the only thing carrying a meaning — every severity also has a
distinct word, so `ccwatch once | grep HUNG` works, and so does a screen reader.

## Tests

```bash
./tests/run.sh          # shellcheck + 118 assertions
```

**Hermetic.** Every assertion runs against a fabricated `~/.claude`: a suite
that reads the developer's live sessions asserts on whatever happened to be
open, which is not a test, it is a screenshot. `CLAUDE_CONFIG_DIR` moves the
registry and transcripts; `CCWATCH_FAKE_PS` substitutes the liveness probe,
without which no fabricated pid is ever live and every row would be filtered
out before reaching the classification — the part most worth testing.

**Mutation-checked.** Every assertion was confirmed to fail against an
implementation broken in the specific way it describes:

| Mutation | Caught by |
|---|---|
| drop the CPU cross-check from the `busy` path | 2 |
| drop the PID-reuse guard | 1 |
| attach the pipeline overlay by directory instead of session id | 3 |
| treat `sdk-ts` exactly like `sdk-cli` | 2 |
| restore the original `resume` live-exclusion bug | 2 |
| recurse into subagent dirs and trust the filename | 2 |
| drop the `install-hooks` de-dup filter | 1 |
| return the CPU cache to one global file | 1 |
| let `resolve_target` exit inside a command substitution | 1 |
| drop the sender label from the send frame | 1 |
| remove the 24h window on concluded deploys | 2 |
| prefer the asserted sender name over the verified pid | 2 |
| never drop a stale context reading | 1 |
| drop the deploy-notification de-duplication | 1 |
| let a failed send kill the daemon | 2 |
| drop the send endpoint's token check | 1 |
| drop the send endpoint's Origin check | 1 |
| run the web server in the foreground, orphaning it on kill | 1 |

That last table is not decoration. Two of those mutations are bugs that were
actually **in** the code and were found this way, and one entry started life as
a *test* defect: the de-duplication assertion passed against an implementation
with the de-duplication removed, because in the fixture the send could not
succeed anyway and the assertion only looked for the success message. An
assertion that passes against a broken implementation is worse than no
assertion, because it is counted as coverage.

Two flakes were found and fixed the same way: a backup-file count that depended
on whether two writes landed in the same second, and a `serve` warm-up that
competes with whatever else the machine is doing — the latter now skips rather
than failing, because a slow machine is not a defect.

And one dirty-environment bug worth naming, because it produced a failure that
looked exactly like a missing feature. `serve` ran its HTTP server in the
foreground of the shell, so Ctrl-C reached it but any other kill **orphaned**
it. Seven leaked servers accumulated across runs; one of them held a port a
later run picked at random, so that run's own server failed to bind and the
stale one — predating the route under test — answered `404`. The suite now
picks a port nothing is listening on, asserts it got the port it asked for,
and reaps its servers on every exit path; `serve` reaps its own child.

## Performance

A snapshot has to finish inside a repaint, and the first version did not: it
took about seven seconds. `CCWATCH_PROFILE=1` prints per-stage timings, which is
how the actual cost was found rather than guessed at.

| Stage | Before | After |
|---|---|---|
| `collect_pipelines` | 5372ms | 228ms |
| `collect_sessions` | one `jq` per file | one `jq` for all |
| `collect_live` | 19 `date` + 19 `awk` forks | one `python3` |
| `collect_transcripts` | one glob per session over a 1.7GB tree | one traversal |
| `peers` scan | 56s (a `grep` per transcript) | ~9s (one batched `grep`) |

The first round of this was guesswork and made things *slower*. The fork
overhead that looked obviously expensive turned out to be a fraction of the
cost; the real expense was filesystem traversal. Hence the profile flag.

## A note on what this reads

`ccwatch` reads two things Claude Code does not document as public interfaces:
`~/.claude/sessions/<pid>.json` and the transcript JSONL. That is a deliberate
trade — they carry information the supported CLI does not expose, and the whole
point of the tool is to know more than `busy`. `ccwatch doctor` exists so that
when the trade stops paying off, you find out from a failing check rather than
from an empty table.

It writes nothing except its own event log, its CPU-sample cache in `$TMPDIR`,
and — only when you run `install-hooks` and confirm — your `settings.json`.

## Licence

MIT. See [LICENSE](LICENSE).
