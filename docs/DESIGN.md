# ccwatch — design notes

This is the reasoning behind every verdict ccwatch gives, and the record of the
bugs that shaped them. If you only want to install and use the tool, the
[README](../README.md) is the place to start. Read this before changing
anything: most of the rules in [CLAUDE.md](../CLAUDE.md) only make sense in
light of what is written here.

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
| the git remote | which repository a session is really in | nothing, for a directory with no remote — and it says so |
| host swap and free RAM | that the OS is about to start killing things | which process it will pick |

The corroboration cuts **both** ways, which matters more than the flagging. A
quiet transcript is reported as `HUNG?` only when CPU has also stopped moving —
because one `Bash` call running a long test suite is legitimately silent, and a
column that cries wolf on it is a column you stop reading. The measurement
behind every verdict is printed next to it, so the judgement stays yours.

And the signals themselves are held to it. `collect_live` reads `ps`, and where
`ps` cannot run — refused by a sandbox, missing — it prints nothing, so the
collector would have reported "no sessions are live" and every row would have
been filtered out. Found exactly that way: 18 sessions running, `0 live` on
screen, stated with no hedge. An empty answer is now cross-checked against a
query that cannot legitimately be empty (the process's own pid), and where that
fails `ccwatch` says so instead. **An empty list is a claim, and it has to be
corroborated like any other.**

### Usage, without handing your credential to a monitoring tool

The header shows how much of your rate limit you have used, and each session
shows how full its context window is:

```
5h 42% (resets 1h · 3:45 PM EDT)   7d 18% (resets 3d · 1:12 PM EDT)

NAME                  PROJECT            STATUS      AGE   CTX  LAST
checkout-api-8e       checkout-api       ● busy      2h    18%  3s ago
```

In a browser each window is drawn as **two stacked bars** instead — see below.

⚠️ **When your sessions disagree about the figure, no figure is shown.** The
numbers arrive from the statusline of whichever sessions are running, and they
are supposed to be account-wide — but they are not always. Measured on a real
machine: four sessions wrote 12%, 14%, 15% and nothing at all inside one
minute, and the menu bar cycled 101% / 88% / 62%. Three figures, at most one
true, each shown with no hedge.

So readings are kept **per reporter** and cross-checked. If two taken close
together differ by more than a few points, you get the range and the count
instead of a number:

```
usage: 3 sessions report different figures (62%–101%) — not shown
       (are they signed in to the same account? ccwatch doctor)
```

`ccwatch doctor` then lists each reading with the session that gave it and how
old it is, which is what tells you where to look. Readings that merely drift
apart as usage accrues are not a disagreement — only ones taken within
`CCWATCH_USAGE_AGREE_WINDOW` of each other are compared at all. Picking the
newest would have been easy and would only have made the wrong number stable.

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
- **A stale reading has its numbers withheld, not annotated.** Past
  `CCWATCH_USAGE_STALE` (10 minutes, against a 10-second refresh) the header
  says how old the last reading is and shows nothing else.

That last rule is not caution for its own sake. An earlier version rendered any
reading with an `[1h old]` note beside it, and a leftover test fixture sat on
the dashboard reading **52%** while the real figure was **7%** — a whole
five-hour window had passed and reset underneath it. A percentage on screen is
read as current no matter what is printed next to it, so a monitoring tool
showing a confidently wrong number is worse than one showing none. The same
rule already applied to the context gauge; it should have applied here from the
start.

#### Consumption against the clock, as two bars

A single percentage does not answer the question people actually have. "78% of
the five-hour limit used" is a crisis an hour in and spare capacity four hours
in, and the payload gives no hint which — so the reader was left doing the
arithmetic from a `(resets 1h)` in the corner.

So each window in the browser draws two bars, stacked, to one scale:

```
5h  78% used · 20% elapsed
    ████████████████░░░░░   ahead of the clock
    ████░░░░░░░░░░░░░░░░
    resets 3h · 5:45 PM EDT
```

The top bar is consumption, the bottom one is how much of the window has gone.
One scale and one width, stacked rather than side by side, because the only
question that matters — am I burning this faster than the clock — is then a
comparison of two lengths and not a calculation. When the top bar is the longer
one it also **says so in words**, because a length is not available to a screen
reader and a colour is not a carrier of meaning on its own. Running *under* the
clock says nothing at all: that is the normal condition, and a label that
appears every time is a label people stop reading.

The clock bar is **absent, not zero**, in three cases: a payload with no reset
instant for that window, a window whose length `web/usage.js` does not know,
and a reset instant already in the past. A bar drawn at 0% reads as "this
window just started", which is a measurement nobody took — the `7d opus` window
routinely arrives with no reset instant, and it shows one bar.

The reset is stated **twice**: the relative time, which is what you act on, and
the wall clock, which is what you put in a calendar. The wall clock is always
**Eastern with its abbreviation** (`5:45 PM EDT`), not the reader's own zone,
so two people looking at the same dashboard say the same time out loud, and so
the half of the year when EDT and EST are an hour apart is not ambiguous.

The meter's height is **reserved whether or not there is a reading in it**,
which is not a detail. A usage reading is withheld the moment it goes stale
(past `CCWATCH_USAGE_STALE`) or the feed stops being trusted, and it comes back
on the next good snapshot — so before the reservation the header measured 89px
with a reading and 52px without, and the board shifted **37px** up and back
down on its own while nobody touched anything. That is the same defect as the
banners, one element over, and `verify-ui` now asserts on both views that the
header's height does not depend on whether a reading arrived.

It took **four** goes, and each failed fix looked like the whole answer:

| Attempt | What it fixed | What it left |
|---|---|---|
| `min-height` on the meter | a withheld reading no longer shortened its own row | the header still moved 127px → 90px: what changed was whether the blocks *wrapped onto a row of their own*, not the height of a row |
| the meter gets its own row (`flex-basis:100%`) | the wrap no longer depended on the reading | an 85px gap under the title, which reads as a mistake — and is what prompted "too much padding on top of the status bar" |
| a two-column grid | the meter sits level with the title, and nothing wraps between the columns | the meter's column was still sized to its contents: 576px with a reading, 297px without, so the *title* beside it re-wrapped — 108px against 92px at 1100px |
| `min-width` on that column too | the column is the same width in every state, so nothing beside it re-wraps | the reservation is 45em, wider than a phone, so it is dropped where the columns stack |

Both reservations are measured rather than chosen: 4.8em against a block of
57.6px on the map and 64.0px in the table view, and 45em against a column of
44.3em and 43.4em. The header now measures the same height in all three usage
states — a reading, a withheld stale reading, and no usage at all — at every
width from 1440px down to 900px.

**Below roughly 1000px the columns stack, and below roughly 720px the
guarantee stops.** The three blocks wrap among themselves there (248px with a
reading against 187px without, at 420px), and stabilising it would mean a
header wider than the window — which `body { overflow:hidden }` would clip,
turning a reading into an absence. That is a worse trade than the shift, so the
boundary is stated here and in the stylesheet rather than papered over.

The assertion for this sits at **1100px**, not at the 900px it was first
written against. The reserved width only matters in the two-column band; below
1000px the columns stack and nothing sits beside the meter to be squeezed. At
900px the check was green with the reservation removed — a check in the wrong
regime, which is the same family of mistake as the six in the table below.

That clock is formatted twice — `Intl` in the browser, `date -r` in the
terminal — and **the suite asserts the two agree**, on both sides of a
daylight-saving boundary. That is not ceremony: the obvious third option,
`jq`'s `strflocaltime` under `TZ=America/New_York`, reported **EST for an
instant in September**. An hour wrong, half the year, on the one number whose
whole purpose is to be written down.

### Projects are repositories, not directory names

A session's project comes from its **git remote**, not the name of the folder
it sits in. Using the folder name was wrong three ways at once on one real
machine:

| Directory | Shown as | Actually |
|---|---|---|
| `~/code/platform` | `platform` | `acme/checkout-api` |
| `~/code/platform/.claude/worktrees/X` | `platform:X`, a separate project | the **same** repo, on another branch |
| `.../worktrees/X/services/pricing` | grouped under the outer one | a **different** repo nested inside |

It also broke deploys silently. Runs come back from `gh` keyed `owner/name`, so
a deploy on `acme/checkout-api` could never match a territory labelled
`platform` — those badges simply never appeared, and nothing said so.

Worktrees of one repository now share a territory, with the branch shown, since
that is what actually distinguishes them. A directory with **no** remote keys on
its own path and is marked `no repo`, rather than being quietly folded into a
real repository. The lookup is cached, because it costs two `git` subprocesses
per directory.

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

### Why an agent died, when it was not Claude's fault

A session killed by the OS under memory pressure leaves **exactly the same
trace** as one that exited cleanly: its registry file disappears. So the table
says so, once, when it matters:

```
! host under memory pressure  swap 95% used (26155/27648MB), 58MB RAM free
  — the OS may kill sessions, and a killed session looks exactly like a clean exit
```

This was added after the host it was built on hit 26.3GB of 27.6GB swap with
58MB of free RAM and a load average of 128, with nineteen sessions running and
no single large consumer — and the OS started reaping background tasks. Nothing
in the tool could have explained a session vanishing at that moment.

Shown only past `CCWATCH_SWAP_WARN` (80%). Below it the line is absent, not
green: a monitor that reports normal conditions on every refresh trains you to
skip the line that eventually is not normal.

## Killing a session

```bash
ccwatch kill agents-aa            # asks first, and says what is at stake
ccwatch serve --allow-kill        # enables the button in the browser
```

The one destructive thing this tool does, so it is the most careful thing in
it.

**What survives:** the transcript. It is append-only and flushed as the session
runs, so the conversation is kept and `claude --resume <sid>` reopens it — the
same guarantee `claude stop` gives a background session. That is printed every
time, so you do not have to remember it. A background session is stopped with
`claude stop`; anything else gets **SIGTERM, never SIGKILL**, so it can flush.
Escalation is not offered: a session that ignores TERM is doing something, and
the right response is to look at it.

**What does not survive:** whatever was in flight. So two cases are *refused*
rather than warned about — a warning in a list of nineteen rows is a warning
nobody reads:

| Refused | Because |
|---|---|
| the session is **mid-turn** | a tool call may be part-applied, leaving the working tree half-edited |
| it is running a **spec-run phase** | that is a paid model call in flight; killing it wastes what has been spent and leaves the pipeline recording a crash |

`--force` overrides either. Every kill is recorded to the event log with the
memory it was holding, because a monitoring tool that can destroy without
leaving a trace is one you cannot audit.

**In the browser it is off by default.** Sending a message to the wrong agent
is embarrassing; killing the wrong one costs work. So `/api/kill` needs
`--allow-kill` *in addition to* the token every other write requires, and the
page is told whether it may draw the button at all. The confirmation is two
steps and names the session, the memory it frees, and the resume command.

### Does killing agents actually help?

Only sometimes, so the numbers are shown rather than implied:

```
host under memory pressure — swap 97% used (26749/27648MB), 59MB RAM free.
Sessions account for 2055MB of it (1289MB of that idle).
```

On the machine this was built on, nineteen sessions came to ~2GB against 26GB
of swap in use — enough to be worth reclaiming, nowhere near enough to explain
the pressure. A tool that offered a kill button without that second sentence
would be inviting you to destroy work for a rounding error.

## What a blocked session is asking

```bash
ccwatch ask              # every session waiting on you, and what for
ccwatch convo <who>      # the recent conversation
```

`waitingFor` in the registry only gives a label — "input needed". The actual
question, with every option and its description, is in the transcript as the
input to an `AskUserQuestion` call:

```
web-app-fc  web-app  waiting 1013s — input needed
  Should the release ship today or wait for the audit?
    1. Ship today
       Proceed with the release immediately without waiting for audit completion
    2. Wait for audit
       Hold the release until the audit is complete and findings are addressed
```

The pending one is the tool call with **no matching `tool_result`** — an
answered question has a result referencing its id, so "unanswered" is a fact in
the file rather than a guess from recency. Finding it seeks to the last such
call by byte offset instead of reading a fixed-size tail, because a fixed tail
is wrong in both directions: one real 4.9MB transcript had its last question
850KB from the end, and a window that clips a `tool_result` while keeping its
`tool_use` makes an **answered** question look pending.

### You can read the question. You cannot answer it from here.

This was tested rather than assumed, and the result is a limitation worth
stating plainly: injecting a message into a session with an open dialog does
**not** answer that dialog. The session stays `waiting`, no `tool_result`
appears, and the message is queued behind it — read only once the dialog is
resolved in the session's own terminal. There is no socket frame for answering
an elicitation (the `elicitation` type in Claude Code is an MCP control-protocol
path, not the peer socket).

So the UI shows the question and its options, and says exactly that. It does not
offer buttons that look like answers.

A waiting session with **no** recorded question — a permission prompt, say —
reports that there is none rather than showing an older question or an empty
panel.

**The modal's ask panel is the same two wordings, not a third.** `askModel(row)`
returns `kind: "questions"` with the question(s) and their options untruncated
(the roster still truncates at 100 characters for the table; the modal never
does) when one is recorded, `kind: "dialog"` with the distinct "waiting on
you" wording when none is recorded but the session is waiting, and `kind:
"none"` — no panel at all, not an empty one — otherwise. Both non-`"none"`
wordings carry the same limitation stated above: a message sent from the
modal is queued behind the open dialog and does not answer it.

## Talking to a session that is already running

`claude --resume` opens a *copy* of a conversation in a new process. `ccwatch
send` puts a message into the session that is **already running**:

```bash
ccwatch send web-app-fc "the deploy failed, look at the migration step"
ccwatch send --dry-run pricing-7b "..."   # show the exact frames first
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
delivered to pricing-7b (confirmed in its transcript after 3s)
queued for pricing-7b, but not in its transcript after 10s
      normal if it is mid-turn — the queue is drained between turns.
could not deliver to pricing-7b: <the actual socket error>
```

That verification earned its place immediately. The first version printed
`sent` and stopped — and the first real end-to-end test showed the write
"succeeding" while nothing arrived, because the client was passing its own
program on stdin and so read an empty payload. `sent` was a lie, and only
checking the receiver caught it.

## Unsticking an agent that stopped too early

`ccwatch revive` watches for a session that stopped when it should not have,
and sends what you would have typed yourself:

```
ccwatch revive — dry run, nothing is sent
  ASK       web-app-fc  paused 46m mid-roadmap checkout 4/5 · next entry cutover is in_progress · no runner, no question pending
            would send: Are you actually done with the work and this pause is intentional?
  RETRY     pricing-7b  API error 6m ago (Can't reach the API server …) · API reachable · retry 1 of 6
  wait      billing-2a  session limit · resets in 14m
  wait      search-9d   paused 5m mid-roadmap reindex 0/3 · asking at 10m
```

It exists because both kinds of stop were measured on the machine this was
built on, over the month before it was written:

- **API errors.** Claude Code records these as an assistant entry with
  `isApiErrorMessage` and an `error` field: 86 "Can't reach the API server",
  33 "Connection lost mid-response", 23 "went to sleep mid-response", 19
  "Request timed out", and about 200 session limits. Typing `retry` once the
  network is back fixes all of them, and nobody is there to type it.
- **An update instead of the next step.** 47 messages were some form of
  "keep going" or "are you done?". 44 were followed straight away by the
  agent going back to tool calls, and the agent had sat idle for a median of
  30 minutes first. Asking *"are you actually done with the work and this
  pause is intentional?"* worked every time it was tried by hand.

### What it will not prod

The hard part is not sending the message, it is not talking an agent out of
a pause that was right. Every action is gated on the reading that justifies
it, and a gate that cannot be read refuses (principle VI):

| Gate | Why |
|---|---|
| only `idle`, never `waiting` | a permission prompt is your gate, whatever the transcript says |
| not a turn ending in `?` | it asked you something |
| not a session you interrupted | you stopped it on purpose |
| asked once and answered with fewer than 10 tool calls → not again until you write | it has said the pause is intentional, and that is its call. Checking before answering is not resuming |
| at most 3 asks per stretch since your last message | asking is cheap, asking forever is not |
| no `spec-run`/`spec-roadmap` process beneath it | it is quiet because it is waiting on its runner |
| a process table that cannot be read → no ask | `[]` would mean "no runner anywhere", the empty-machine shape again |
| no live recurring cron of its own | it will be woken by its own schedule |
| no background subagent still to hand back | the hand-back will wake it |
| a retry only once the API host accepts a connection | retrying into a DNS outage just records another error |
| retries back off 1m, 2m, 4m…, and stop at 6 | a persistent failure is a fact to report, not a loop |
| `continue` only past the reset the limit message states, at most twice | the message names a wall clock and a zone, and is read in that zone |

### The roadmap is the evidence, not a guess about the text

The ask is only for a session that **ran `spec-roadmap` itself** and whose
directory has a roadmap with entries not yet `done`. It does not try to judge
from the agent's prose whether it is finished. Both facts are already on disk:
the commands are in the transcript, and the progress is in
`.specify/roadmaps/<slug>.state.json`.

Two things went wrong on the way there, and both were caught by measuring
first:

- **"Mentions spec-roadmap" matched 88% of sessions.** Every session carries
  the skill listing, which names it, and a byte search found it in 1,952 of
  2,213 transcripts. Only a `Bash` call to `spec-roadmap run`, a `Skill` call
  or a slash command now counts.
- **Two guards blocked the very stalls they were for.** The detector was
  replayed against a month of real stops, with each transcript cut at the
  moment it stopped. At first it would have asked in only 21 of the 38 stops
  that were later nudged by hand. Counting every background `Bash` as pending
  work blocked 8 of them, because a dev server or a watcher never reports back
  (11 launches against 2 notifications in one real stretch). Counting every
  `CronCreate` blocked 5 more, because a one-shot job is spent once it fires
  and a recurring one expires after seven days. With only subagents counted
  (each ends in exactly one hand-back) and only recurring crons from the last
  week, it asks in 33 of 38. The other 5 are 4 turns that ended on a
  question, which were right to leave, and 1 with a live recurring cron.

**Its first real ask was asked twice.** The first session revive asked
answered "yes, intentional", and ten minutes later it was asked again, so the
answered-once gate did nothing. The transcripts sampled while designing it
had peer messages carrying an `origin.body`. Revive's own messages carry
none: the text is only in `content`, inside Claude Code's envelope
("Another Claude session sent a message:", the text, then a paragraph about
peers). Compared whole, that never equalled the ask, so revive never saw it
had asked. It now finds its own text as a line within the envelope, and the
fixture records an ask exactly as the real one was recorded.

**And then a third time, for a different reason.** With the envelope read,
a session that had answered was still re-asked until the cap. Its answer had
been a `SendMessage` back to the asker followed by its closing text, and the
gate was "answered with no tool calls since", so the reply counted as more
work. Tools that only talk to other sessions (`SendMessage`, `ListAgents`)
are no longer counted.

**And then, in use, every session was asked two or three times in a row.**
Over one day, one session was asked 20 times. Asked whether it is done, an
agent usually *checks* before answering: a `git status`, a `spec-roadmap
show`, one to three commands, then "yes, intentional". The gate was "no tool
calls since the ask", so the check read as the work resuming, and ten minutes
later the same session was a new stall, until the cap of three. The agents
that really had resumed ran 16 to 438 tool calls before stopping again. So
the gate is now `CCWATCH_REVIVE_RESUMED` (10) tool calls since the most
recent ask. Fewer is an answer, and the session is not asked again until you
next write in it.

**"Ran spec-roadmap" is read from command text, and that has a known false
positive.** A session whose commands merely *contain* `spec-roadmap run`
(in a `grep`, a `pgrep`, a test fixture) counts as having run it. The session
that built revive was flagged this way, because its fixtures contain the
string and its repository has a roadmap with no state. Two tighter rules
were measured against a month of transcripts and rejected. "At command
position" lost 4 of 27 real roadmap sessions (`SPEC_RUN_CLAUDE_BIN=claude
spec-roadmap run …`, prefixed absolute paths). "Not inside a quoted string"
lost a real run whose quote closes after the path, and still flagged the
builder session. Requiring an explicit `/spec-roadmap` or `Skill` call would
lose 20 of 27, because most roadmaps are launched from Bash. The cost of the
false positive is one ask, which the answered-once gate holds to one.

What it still cannot tell apart is a turn that is waiting on you without
ending in a question mark ("if you can get the repo name, I'll add the
check"). The obvious discriminators were measured and do not separate the two
groups. Tool calls since your last message have a median of 39 for stops you
nudged and 36.5 for the rest. Whether your last message was a question is
much the same for both. So the design accepts the ask in that case and relies
on the answered-once gate. The same replay puts that at about 180 asks a month
that you would have answered yourself, each costing one short reply.

Delivery goes through `cmd_send`, so it is observed in the receiver's
transcript rather than assumed. Every action and its outcome goes to the event
log as `ccwatch.revive`, `failed` included.

### A switch, not a button, and serve runs it

The first version was a command you had to leave running in a terminal, and
a "run a pass" button in the page would have been the same thing: a manual
step in a tool whose whole purpose is to remove one. So the page has a
**switch**, and `ccwatch serve` hosts revive:

- **One thread in serve runs a pass every minute**, as `ccwatch revive --json
  --send`, which is the same decision table the terminal uses. Unlike the three
  refreshers beside it, it does not idle when nobody is reading
  `/api/state`. Those idle by design, and revive exists for exactly the
  hours nobody is reading.
- **A serve with revive on does not idle-exit.** The 30-minute exit exists so
  a forgotten serve does not accumulate. A serve somebody has asked to watch
  their agents is not a forgotten one, and exiting would stop revive at the
  moment it was turned on for. The menu bar app keeps serve up across crashes,
  so on a machine running the app, one click is the whole setup.
- **The switch is a file**, `~/.claude/ccwatch/revive.json`, read on every
  pass. So it outlives the page, the serve and a reboot, and `ccwatch revive
  --enable` writes the same one.
- **Off by default.** A tool that started messaging your agents because it was
  installed would be acting on a decision nobody made. While it is off, serve
  still runs a *dry* pass whenever a page is open, so the panel shows what it
  would do, against your own sessions, before you let it.
- **The switch is gated like send** (token and Origin check). Turning it on is
  consent to messages being sent on your behalf, and a page that could flip
  it could have every idle agent asked a question. `--read-only` has no
  token, so revive there is `unavailable` and says why.
- **One pass at a time, machine-wide.** Serve's loop and a terminal `ccwatch
  revive` would otherwise both see the same unanswered stall in the same
  second and ask it twice. The pass takes a `mkdir` lock holding its pid, and a
  lock whose pid is dead is taken over.
- **Revive takes the same cadence floor as the other publishers.** Every
  publish changes the ETag, and the ETag checks pin `CCWATCH_SNAPSHOT_CADENCE`
  so that two reads see one collection. Revive was a fourth publisher outside
  that floor, and the checks failed under load until it was inside it.
- **`--json` sends only with `--send`.** `ccwatch revive --json`, typed to have
  a look, must never be what messages six agents.

Two layout bugs turned up the first time the panel was rendered, and neither
was visible to the checks that existed:

- **The switch jumped 220px.** Its label grows from `revive: off` to
  `revive: on · 3 sent`. With a `min-width`, the nav grew with it and wrapped
  the header's left half onto a second line. The header's height did not
  change, because the usage gauges on the right set it, so "the header did not
  re-wrap" stayed green. The switch now has a fixed width, and `verify-ui`
  asserts that the switch itself does not move.
- **The panel opened at x=−385.** Anchored by its right edge, as the alert
  panel is, a 640px panel under a switch that had wrapped to x=255 opened off
  the left of the window. It is now anchored by the switch's left edge and
  clamped into the window.

## Deploys, and agents that subscribe to them

```bash
ccwatch deploys      # in flight, and concluded in the last 24h
```

```
DEPLOYS — in flight, and concluded in the last 24h
  RUNNING   Deploy to staging    acme/web-app       main   started 5m ago
  FAILURE   deploy-production    acme/checkout-api  main   1h ago
      https://github.com/acme/checkout-api/actions/runs/2
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
  web-app-fc ==> pricing-7b        7 msgs, last 2026-09-07T14:04Z
  pricing-7b ==> web-app-fc        6 msgs, last 2026-09-07T15:08Z
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

## In the menu bar

```bash
./app/build.sh --run        # builds ccwatch.app and launches it
```

One app owns the three surfaces: the menu bar item, an always-on-top overlay,
and the `ccwatch serve` it supervises. It is the only part of this repository
that needs a compiler.

```
┌─ menu bar ────────────────────────────┐
│ cc 6 · 1 waiting                      │
├───────────────────────────────────────┤
│ 6 live · 1 waiting on you             │
│ 5h 42%  7d 9%                         │
│ * checkout-api-d9  waiting  perm… 3m  │
│ ! web-app-fc       HUNG?    quiet 41m │
├───────────────────────────────────────┤
│ Show Overlay                     ⌘O   │
│ Open Dashboard in Browser        ⌘D   │
├───────────────────────────────────────┤
│ serve: running (pid 4821)             │
│ Restart serve                         │
├───────────────────────────────────────┤
│ Open at Login                     ✓   │
│ Quit ccwatch                     ⌘Q   │
└───────────────────────────────────────┘
```

**The app decides nothing.** It runs `ccwatch bar --no-actions` and renders
what comes back — every verdict, count, word, colour and measurement is the
CLI's. What the app adds is verbs. That is the same rule `/api/state` follows
by invoking the CLI rather than reimplementing the join, and the overlay is a
`WKWebView` on the same `/map` the browser gets, so there is one renderer for
that too.

Four window properties make the overlay work, and the obvious choice is wrong
for the first: `.statusBar` rather than `.floating`, because `.floating` sits
*under* a full-screen app — exactly when you most want to see that an agent is
blocked on you. Plus `.canJoinAllSpaces` so it follows you, `.fullScreenAuxiliary`
so it may appear over a full-screen Space at all, and `.nonactivatingPanel` so
clicking it does not steal focus from the terminal you are working in. All four
are asserted by `./app/build.sh --selftest`, because they fail **invisibly**: a
panel at the wrong level looks perfect until something covers it.

And one it must **not** have: `.fullSizeContentView`. It lays the web view under
the title bar, and a `WKWebView` takes every click it covers, so the strip you
drag a window by was the page's header — the overlay could be resized and not
moved. The selftest asserts the title bar is outside the content view.

It supervises `serve` rather than assuming it. If something is already
listening on the port — most likely a `ccwatch serve` you started in a terminal
— it adopts it and labels it `not started by this app`, because killing it or
fighting it for the port are both worse. A serve that keeps dying is restarted
three times and then reported, with the reason, instead of respawned forever
under a menu that says "running". The three are a guard against a crash
*loop*: a serve that stayed up for a minute or more gets a fresh budget when it
dies, and so does **Restart serve**. Before that, a serve that ran for two days
and was then taken down by an edit to its own script spent the budget one
death at a time, and after the fourth the app had no serve at all.

**Show Overlay** starts serve again if it is down, because the overlay is
nothing without it. And a map that cannot load is never a blank page: the panel
says `The map is not loading`, with WebKit's reason and the menu's serve line,
and retries every 3s while it is open. It was a plain white window, and it
stayed white even after serve came back — the panel reloaded `webView.url`,
which a failed first load leaves nil, so it had forgotten which page it was for.

From a figure's panel, **open in browser** takes that agent to a browser tab —
`/map?sid=<session>`, where there is room to read the transcript. It is a real
link with `target="_blank"`, and the app hands it to your default browser,
because a `WKWebView` drops both that and `window.open()` in silence unless its
host intervenes. A stale or hand-typed `sid` opens nothing rather than a panel
titled `undefined`.

`Open at Login` registers the app with `SMAppService`, and only when you click
it. Signing is ad-hoc, which is fine for an app built on the machine it runs
on. A copied build has to be allowed under **System Settings → Privacy &
Security → Open Anyway**, since right-click → Open no longer overrides
Gatekeeper on recent macOS. Notarising would remove that step, and it needs an
Apple Developer account.

<details>
<summary>SwiftBar/xbar plugin (superseded)</summary>

Before the app there was a plugin, kept for a machine that cannot run the app:

```bash
ln -s "$PWD/extra/swiftbar/ccwatch.10s.sh" ~/Library/Application\ Support/SwiftBar/
```

It renders the same `ccwatch bar` output the app does, so the two cannot
disagree about status — only about what the menu items do. A plugin is a script
that prints text on a timer, so it cannot hold the overlay, cannot supervise
`serve`, and its items can only shell out.
</details>

`ccwatch bar` is the format both read: a title line for the menu bar itself,
then the dropdown behind it.

```
cc 6 · 1 waiting · 1 suspect          ← what sits in the menu bar
---
6 live · 1 waiting on you · 1 suspect
5h 42%  7d 9%
---
* checkout-api-d9  checkout-api  waiting  3m   permission to run rm 3m
! web-app-fc       web-app       HUNG?    4d   quiet 41m
+ pricing-84       pricing       sdk      5m   no status published
    \_ 011-usage-report  analyze/running  opus  $11.15
- infra-e6         infra         idle     1d   14m ago
---
Open dashboard
Refresh now
```

**With nothing wrong the title is `cc 6` and nothing else.** No tick, no
"all clear", no icon — a menu bar item that always has something to say is one
you stop reading, and then it is not saying anything when it matters. Every
condition it does find goes in the title rather than only the loudest, because
the title is the one surface visible without a click and a condition left out
of it reads as no condition at all.

Unfinished runs are the one exception. They are runs that already stopped, not
a session blocked on you right now, and on a laptop the notch leaves little
room: an item that does not fit is simply not drawn, which is a far worse
absence than a count moved one click away. So the title and its icon leave
them out, and the dropdown's summary line and `UNFINISHED RUNS` block still
list every one. The reset time is floored to one decimal once it is in hours —
`resets in 2.5h`, and `2h` rather than `2.0h` when it is whole — because at
2h59m a bare `2h` is an hour short, and flooring means it can read early but
never late.

Nothing is behind a submenu, though the format offers them and they would tidy
the list up considerably. A submenu is a collapsed badge: it turns a crashed
phase into something you have to hover to discover, which is the same
failure-as-an-absence the header alert control exists to avoid.

**The plugin contains no judgement.** It finds `ccwatch`, fixes up `PATH`, and
runs `ccwatch bar`. Every verdict, threshold and word comes from the same jq
program the table is rendered from, for the reason `/api/state` invokes the CLI
rather than reimplementing the join: two renderings that decide "is anything
stuck" separately will eventually disagree, and then there is no way to tell
which one is lying. The measurement in each row is the table's own `LAST`
column, not a second calculation of it.

The one thing the plugin does decide is whether it got an answer at all, and
that is why it does not `exec`. `ccwatch` can exit before printing anything —
`need jq` does exactly that, and the plugin host's `PATH` is the reason it
might — and the host renders stdout, so an `exec` into a tool that died would
leave a blank item with nothing under it. That is indistinguishable from a
machine running nothing. An empty result is reported as the failure it is,
with `ccwatch`'s own diagnosis from stderr underneath it.

A stale usage reading is **withheld here too**, and if the snapshot itself
fails the title is `cc ?` rather than `cc 0`. The menu bar is the worst place
for either mistake: a percentage up there is read as current with nothing
around it to date it, and a quiet machine and a blind tool look identical.

⚠️ **Session names and `waitingFor` notes are stripped of `|` before they reach
a line.** That is a security control, not tidying: a bare pipe opens the plugin
format's parameter list, and `bash=` is one of the parameters it accepts — so
an unsanitised note would put a clickable command in the menu. It becomes `¦`,
so the name still reads as the name it is.

Two things worth knowing about the interval. The `10s` is in the **filename**,
read by the plugin host rather than by anything here, so renaming the file
changes it — and ten rather than the terminal's two because `ccwatch` walks the
transcript tree on every snapshot, which was 1.7GB on a working machine.
Measure your own with `CCWATCH_PROFILE=1 ccwatch --json` before going faster.
Install the plugin as a **symlink**, both so `git pull` upgrades it and because
that is how the script locates the checkout it came from.

For any other status bar — tmux, Übersicht, a shell prompt — `ccwatch bar
--title` prints just that first line, with no parameters on it. And
`--no-actions` prints the status without the dashboard/refresh items, for a
host that supplies its own verbs, which is what the app uses.

## In a browser

```bash
ccwatch serve --open        # http://127.0.0.1:8787
```

Two views, same data: **`/`** is the table, **`/map`** groups agents into their
projects.

```
┌ acme/checkout-api ────────┐ ┌ acme/pricing ─────────┐ ┌ acme/web-app ─ FAILURE ┐
│   ☺                       │ │  ☺    ☺──2──☺          │ │   ☺      ☺ᶻ            │
│   84                      │ │  4f   1f    d9         │ │   f6     d9            │
│ specify/failed  $55.19    │ │ plan/needs_input       │ │                        │
└───────────────────────────┘ └───────────────────────┘ └────────────────────────┘
```

Each project is a territory; each session is a small pixel-art character
inside it. The board is drawn as a place, in the three-quarter view of a 16-bit
Zelda: an owner is a field of grass fenced by a hedge, a repo is a room seen in
cutaway — a brick north wall casting its shadow across a plank floor — and a
branch is a rug on that floor, with its sessions standing on it. A repo with an
unfinished run stands behind scorched, cracked bricks. Appearance carries the status, in shape as well
as colour: a **raised arm and a pulsing `!` bubble** for a session blocked on
you, **eyes down, a bead of sweat and a `?`** for one that says it is busy but
has gone quiet, a **hammer held up, bobbing** for one that is working, a
**hollow outline** for a session with nothing to corroborate it, and **eyes
shut with a `z`** for idle. The bar under the feet is how full its context
window is. Hair and skin are picked from the session id, so the same session is
the same character on every refresh, and they mean nothing else. Motion is only
ever applied to a state that is actually changing, so a still figure means a
still session.

That motion is **stepped, not tweened** — each pose is held, and the figure
snaps between poses. That is a performance constraint, not a style choice.
These animations move `transform` on an SVG `<g>`, and Chrome cannot promote an
SVG group to its own composited layer, so a tweened figure re-rasterises the
SVG subtree on the main thread every frame for as long as any session is busy.
Measured on an idle map with three busy figures: 4.1% of a core in the renderer
plus 3.7% in the GPU process, against a 1.5% floor with the animations off.
Holding the poses with `step-end` changes the style twice per cycle instead of
roughly 54 times, and the same page costs 2.8%.

The cost is a **cliff, not a slope**: three animated figures and seven measured
the same (4.3% + 3.8%), and `tilt` at 3.4s (now `sway`) cost exactly what `bob`
at 0.9s did.
The price is 60fps frame production at all, not the number of things moving —
so thinning the animations out or slowing them down buys nothing, and only
losing the tween does. This is worth stating because the obvious reading of a
map that costs 8% of a core was that its pan-and-zoom camera was expensive. It
was not: the camera scheduled nothing at rest. It was replaced for an entirely
separate reason — see below — and the animation cost would have followed it
into the new view untouched if it had not been measured first.

Unfinished runs lie in the territory they belong to, deploy badges sit in its
header, and messages between sessions are drawn as arrows between the two
figures — including across territories, which is the case worth seeing.

### The world is a frame round each block, not a scene

The hedges, walls and rugs are CSS `border-image` 9-slices painted by
`web/sprites.js`, each deeper on its north side than anywhere else — the whole
of the 2.5D is that one rule, because in a three-quarter view only a north wall
shows its face. That shape was chosen over drawing a scene and fitting the
blocks into it, for the reason the camera went: a scene is a placement, and a
placement can put a session somewhere you are not looking. A border-image
decorates whatever box flow layout produced, so the board is still the
scrolling list that cannot lose one — it only looks like a place.

Three things this costs, and how each is held:

- **The red border that marked an unfinished run is gone**, because
  `border-color` is ignored under a border-image. It would have kept its rule
  and silently stopped drawing anything. The scorched wall replaces it, and is
  a different *shape* (cracks), not only a different colour; the suite reduces
  both walls to which pixels match which, with the colours thrown away, and
  requires them to differ. `verify-ui` checks the computed style really swaps.
- **Text is printed on scenery now**, so every text token is measured against
  every ground it can land on — grass, floor and rug, in both palettes — and
  must reach 4.5:1. Measured before the fix: `--dim` was 4.49:1 on daylight
  grass and `--ok` about 4.1:1 everywhere, so the light theme darkens both on
  the board. The colours are read from `map.html`'s own stylesheet, so the
  check measures what the page paints, not a copy of it.
- **The slice numbers live in two places**: `FRAME` in `web/sprites.js`, and
  the `border-image` lines in the CSS. A wall painted 16 deep and sliced at 12
  cuts the bricks in half and fails nothing but the look, so the suite computes
  the CSS each frame should have from `FRAME` and requires it verbatim, at
  exactly 2x.

A failure of the scenery must not look like an empty board either: if the
paint script never runs, every frame falls back to a transparent border of the
same width, so nothing moves — and `verify-ui` asserts the computed
`border-image` of every owner, repo and branch is a painted one, because that
fallback is a tidy page that is quietly wrong.

### The figures are pixel art, written as text

Every sprite is a 16x20 grid of letters in `web/sprites.js`, one letter per
colour, and the page draws each colour as a single SVG path of horizontal runs
with `shape-rendering: crispEdges`. That shape was chosen over the obvious one,
a sprite sheet shown through `<img>` with `image-rendering: pixelated`, for
three reasons:

- **An image can still be decoding when the page is measured.** `verify-ui`
  asserts that every session has a figure with a non-zero box, and an `<img>`
  that has not loaded yet is a 0x0 box standing for a session that exists.
- **A raster cannot take a CSS token.** The tunic is the status colour, and it
  has to be the *same* `var(--ok)` the label uses, in both themes, or the two
  can drift apart.
- **A diff can show a pixel.** Changing a pose is a text edit that review can
  read.

It is hand-drawn rather than a downloaded tileset because the network it was
built on blocks the tileset's host (the CC0 *Ninja Adventure* pack on itch.io
was the first choice). Swapping one in later means replacing the grids in
`web/sprites.js` and nothing else; no other file draws a pixel.

Three details matter more than they look:

- **Whole pixels only.** At the default 16px root a figure is 2em = 32px for a
  16-cell sprite, exactly 2x, and `verify-ui` asserts that ratio: at 1.5x some
  art pixels are one screen pixel and some are two, and pixel art at a
  fractional scale looks smeared. Every animation moves by one cell of the grid
  (an SVG child's `px` are viewBox units), and nothing rotates, because a
  rotated sprite is resampled. That is why the suspected hang now sways by one
  pixel instead of tilting. The narrow layouts give up the whole-pixel scale
  on purpose, to fit more agents.
- **The hollow outline is the silhouette's edge**, not the sprite's outline
  pixels. Those include the lines between the arms and the torso and between
  the legs, and drawn alone they looked like a pair of headphones.
- **The bubble is white with a dark glyph**, with the status colour only on its
  rim. With the glyph in the status colour as well, rim and glyph ran together
  at 2x, and `!` read as `H` and `?` as `A`. Found in a screenshot at 8x, which
  is where pixel art has to be checked.

### Warnings live in the header, because a banner moves the board

Both views used to print each condition — the feed being down, the host
swapping, registry files that could not be read — as a block-level banner
between the header and the content. Each one appeared and cleared on its own
schedule, because each is derived from a reading collected every couple of
seconds, and every arrival pushed everything below it down. Measured on the map
at 1180x760, against a board 676px tall:

| On screen | Board top | Board height |
|---|---|---|
| nothing wrong | 52px | 676px |
| feed down | 83px | 645px |
| host under memory pressure | 102px | 626px |
| both, plus unreadable registry files | 133px | 595px |

So the map lost up to **81px — 12% of its height** — and every figure on it
moved, while you were looking at the figures. A view whose geometry depends on
whether the machine is swapping cannot be compared against itself from one
glance to the next, which for a monitoring view is most of its value.

The conditions now go to one control in the header, with the details in a
popover anchored under it. What matters is what the collapsed control says:

```
ccwatch  8 live · 2 waiting on you   table | map   [! the feed is down +1]   5h 41%
──────────────────────────────────────────────────────────────────────────────────
(the board starts here, at the same y whatever the machine is doing)
```

It names the **worst live condition in that condition's own words**, and counts
the rest as `+N`. A control reading "2 alerts" was the obvious design and is the
wrong one: it turns a stated failure into an absence, which is the one thing
this tool is not allowed to do. The `!` matches the terminal's own marker, so
the severity survives `NO_COLOR` and a monochrome screen; the accessible name
spells out the whole list, since `+1` is an abbreviation and the visible text is
ellipsised at narrow widths. The measurement behind each verdict is in the
popover — one click, not gone.

Two things are deliberately **not** in it:

- **Nothing, when nothing is wrong.** Not a green tick, not "0 alerts" — the
  control is not rendered at all, and is out of the tab order and the
  accessibility tree with it. A line that appears on every refresh to say
  things are fine is a line people learn to skip.
- **"No live sessions."** An idle machine is a normal condition, not a failure.
  It is still stated in flow, where — there being no figures — there is nothing
  below it to push down, and where a reader looking for sessions will find it.

The slot the trigger sits in keeps its width whether or not it holds anything.
That looks like waste and is not: the header's free space is there anyway,
between the view switcher and the right-aligned gauges, and a slot that
collapsed when the machine was quiet would let the trigger's *arrival* re-wrap
the header at narrow widths — the same reflow, moved up one element. At 420px
that is a whole header line.

The popover is a `<dialog>` opened with `showModal()`, like the map key, rather
than a hand-rolled dropdown: the focus move, the focus restore, Escape and a
stacking context above everything come from the platform, and a closed
`<dialog>` occupies nothing. It is positioned against its trigger's measured box
at open time rather than at an offset from the top of the page, because this
header wraps — a panel positioned against a guessed header height is the
258px-below-the-fold bug in a smaller box.

Both pages render this from one module, `web/alerts.js`, which also holds the
trust model itself. The table view used to decide separately whether the feed
could be believed — a `try/catch` that wrote its own sentence into the footer,
below a table that is often longer than the screen. Two renderings that judge
the same feed independently will eventually disagree, and a reader has no way
to tell which of them is lying.

`verify-ui` asserts the part of this that only a browser can answer: that the
board's top edge and height are **identical** with three live alerts and with
none, at 1180px and again at 420px where the header has no room to spare, and
that opening the panel moves nothing either.

### The map is a scrolling list of blocks, not a camera over a world

`/map` is a column of owner sections. Each owner holds a responsive grid of
repository cards; each card holds its branches; each branch holds the figures
standing in it. It is ordinary block layout in one scroll container, so the
browser does the placement and the browser's scrollbar does the navigation.

The grid is `auto-fit`, not `auto-fill`, and a figure is as wide as its name
rather than as wide as its drawing. Both were changed after looking at the
rendered page: `auto-fill` keeps the empty columns it creates, so an owner with
one repo — which most of them are — put a 400px card beside 400px of nothing,
and a 3.1rem figure clipped `agents-ba` and `agents-62` both to `agents…`,
which is worse than no label at all.

**This replaced a pan-and-zoom SVG camera, and not because the camera was
slow.** It was replaced because it could not be relied on to show you your
agents. Measured on a real eight-session machine, the default view had **1 of
4 territories fully visible and 2 of 8 sessions entirely off-screen** — one of
them the session running ccwatch itself. The suite was green and `verify-ui`
was green throughout, because what `verify-ui` asserted was that *an* agent
was visible, which was true the whole time. A monitoring view whose honest
reading is "some of your agents are somewhere off to the bottom-right" is
worth less than a list.

What went with it:

- `web/plots.js`, the identity→coordinate module, and its persisted plot
  record. Flow layout needs no coordinates, so there is nothing to store and
  none of the failure modes storing it had — a private-mode `localStorage`
  that throws, a full origin quota, an annex plot when a parent's raster
  filled up.
- `web/camera.js`, the zoom ladder, the three detail levels, and the stored
  viewport. 701 lines of arithmetic, and the 73 assertions that covered it.
- The level-of-detail rules. Those are worth naming separately, because the
  camera's worst bug was one of them: fit-to-world on a wide, short world
  picked a scale below `2×`, and every rung below `2×` set `display:none` on
  every figure. The opening view was empty **by construction**, and it got
  worse as you added projects rather than better. **Nothing in the stylesheet
  now hides a session at any window size**, and the suite asserts that no
  `[data-lod]` rule and no reader of the camera's `--k` scale comes back.

What a force-directed graph would have done is still worse, and that reasoning
is unchanged: with a dozen nodes it rearranges itself every time you look at
it, and "did that agent move, or do I misremember" is not a question a
monitoring view should raise. Flow layout answers it permanently — **order is
alphabetical at every level**, so a session's position is something you can
predict and re-find.

Ordering deliberately **does not read status**. Sorting the loudest session to
the front is tempting and wrong: a figure that moves when its status changes
makes position useless for finding a session again, which is the only thing
position is for here. The roster panel beside the map is where severity
ordering belongs, and it has it. The comparator is also not `localeCompare` —
its answer depends on the browser's locale and ICU build, so two machines
could order the same sessions differently and the suite could pass on one and
fail on the other.

Every draw is **reconciled by key**, one element per identity, rather than
rebuilt wholesale: an element whose key is still wanted gets its attributes
updated in place, one absent from this tick's wanted set is removed, and
nothing already onscreen that is still wanted is ever destroyed and recreated.
That is what lets an open inspector, a hover, a focus ring and a text
selection all survive a refresh — the only remaining wholesale `innerHTML`
write is a turn's rendered markdown body inside an already-reconciled
container.

Sorted order is carried by `style.order`, **never by moving nodes**.
Re-appending children to sort them moves whichever one currently has focus,
and moving a focused element drops the focus — so a keyboard user tabbed onto
a figure would lose it every three seconds.

A figure is a real `<button>`. As an SVG `<g role="button" tabindex="0">` it
needed an explicit tabindex, an explicit role, a hand-drawn focus ring (an SVG
group takes no outline) and a keydown handler to honour Enter and Space — four
separate things that each had to be right for the map not to be a control some
people simply cannot operate. A button is all four by default, and the scroll
container is keyboard-operable for the same reason: a focusable overflow box
scrolls on the arrow keys, PageUp/PageDown and Home/End with no script at all,
which is what the camera's hand-written keymap was standing in for.

The board scrolls on **both** axes (`overflow:auto`), even though the layout is
built so nothing overflows sideways — `min-width:0` and an ellipsis on every
long label, and a grid whose columns collapse to one at narrow widths. If
something ever does overflow, `hidden` would clip it and the clipped part would
be unreachable at every scroll position: a failure presenting as an absence,
which is the one thing this tool may not do. A scrollbar is the same bug made
visible. `verify-ui` asserts that at its own width nothing actually overflows,
so the fallback stays a fallback.

A session with **no git branch shows no branch line**, not a placeholder one.
The zone label printed `r.branch || "?"`, so a session the collector had
explicitly reported as having none — `bin/ccwatch` normalises an empty branch
to `null` on purpose — was labelled `?` on the page. That is a value invented
for a field that said it had none, in a vocabulary where `?` already means
"suspected", as in `HUNG?`. The CLI had the right answer all along:
`${branch:+branch $branch}` prints the clause only when there is one. The
sentinel behind it is the empty string, because git cannot name a branch that,
so it can never be confused with a real one — which `?` could.

A card with no remote is labelled by its directory and **names the full path on
hover**, because a directory basename is not unique across machines: `scratch`
could be anywhere. The hover also says *why* there is no repo rather than only
that there is none. (Where the directory really is `/`, `/` is what it says —
that one is not a derivation bug, it is a session running at the filesystem
root.)

The map key's `?` button lives in the **header**, beside the view switcher. It
inherited the retired camera cluster's floating position at the bottom-left of
the map area, and once the board scrolled underneath it, it sat on top of
whatever was there — measured, it covered two `implement/CRASHED` badges. A
control that floats over a scroll container needs a reason to, and a help
button that is always in the same place does not have one. `verify-ui` now
checks this geometrically, for any control, rather than checking one
position value.

Message arrows survive, drawn on an SVG overlay inside the scroll content. Its
endpoints are measured from the figures' own boxes relative to that content, so
the overlay scrolls with the blocks for free — there is no scroll listener and
no per-frame work, and it is remeasured once per tick and once per resize.

A snapshot that is not `ok` — the feed down, a snapshot never taken, or a
registry file that would not parse — is a different sentence in each of those
three cases, not a variation in wording on the same one. Owners, repositories
and branches stay drawn with their age marked stale; only the readings that
change every tick (context fill, gauge percentages, host-pressure numbers) are
withheld, because a stale percentage read as current is a false claim, and
"no sessions" and "can't tell" are different facts that must read differently.

### Why volatile ordering lives in the roster, not the map

`/map` also docks a roster panel: one row per session, in the payload's own
needs-you-first order (`bin/ccwatch:953` sorts `-max(sev, psev)`, then
`-(waited // quiet // 0)`), each row carrying its name, repo/branch, status
word and the measurement behind it, as text. `web/roster.js` shapes that text
— `rowFields`, `titleText`, `keysOf`, `reorderPlan` — and contains **no
comparator of its own**: the order it reconciles `#rosterlist` to is exactly
`s.sessions`'s own array order, nothing recomputed and nothing re-derived.

The reason the ordering has to live somewhere that never touches a
coordinate is the bug an earlier version of this page actually had: severity
was once folded into the same per-tick sort that decided a district's
position, and a status change on one session reordered the CSS grid — moving
a whole project's district to the front of the page and dragging every other
project's district along with it on the very same repaint. A monitoring view
that rearranges itself on every refresh answers "did that agent move, or do I
misremember" with "sometimes, whenever the severity sort changes," which is
the one question this view exists to never raise (see "The map is a scrolling
list of blocks, not a camera over a world" above). Splitting the roster's
ordering into its own reconciled list — keyed by `sid`, moved by
`reorderPlan`'s minimal `insertBefore` plan, never a wholesale rebuild — means
a status change can reorder *rows in a list* without ever being in a position
to move a *figure*, because the board's own ordering never reads a severity, a
status word or an ordering value at all. The suite asserts that: no `sort()` in
`buildWorldModel` may mention `sev`, `psev`, `token` or `worst`.

### The roster is operable without a mouse or without sight

Every row `web/roster.js`'s `rowFields`/`titleText` can produce is also a row
in `#rosterlist`, `role="listbox"` with each `.rrow` carrying `role="option"`
and a roving `tabindex`: exactly one row is reachable by `Tab` at a time, moved
by `ArrowDown`/`ArrowUp`/`Home`/`End` (`nextFocus`, clamped — never wrapping
past the first or last row) and restored **by `sid`**, not by position, after
a tick reorders the list (`focusTarget`), so a status change mid-navigation
never drops focus onto the wrong agent or out of the list altogether. `Enter`
selects the focused row. The listener is bound to `#rosterlist` itself, never
`document`, so the roster's arrow keys can never scroll the board and the
board's own arrow-key scrolling (which is the browser's, on a focusable
overflow box) can never move roster focus — two independent keyboard surfaces
on the same page, each scoped to the element it operates.

`#board`'s own `aria-label` names itself a companion view of the agent
list, rather than the sole carrier of the page's meaning: a screen reader
lands on the roster and hears every claim the figures draw — the status word,
the measurement, the repo/branch — as text, before it ever reaches the map.

### Selecting a row scrolls to the figure, and remembers the choice

Clicking a roster row — or activating it with `Enter` — marks that row
selected, rings the matching figure with its own rule (`.agent.selected`,
applied to the outer `<button class="agent">` node `applySelectionEmphasis`
toggles, never to the `.figart` span `updateFigure` rebuilds wholesale every
tick, so a status change can never clobber the ring), and brings that figure
into the board with its own `scrollIntoView`. That is what "fly the camera
there" became without a camera, and it is strictly less code: the browser owns
the arithmetic, including the case where the figure is already visible and
nothing should move. The scroll only fires when the selection actually changes
(`sid !== lastRevealedSid`), so a tick that merely re-renders the same
selection never yanks the board, and it reads
`matchMedia("(prefers-reduced-motion: reduce)")` at the moment of the scroll
rather than leaving it to a CSS `scroll-behavior` — the setting has to be able
to turn a specific movement off, not a rule.

That reveal is also the check that taught this project the most about its own
tests. Three versions of the `verify-ui` assertion for it **could not fail**:
the first called `scrollIntoView` itself and then asserted the figure was on
screen; the second reported a pass worded "already on screen; nothing to
reveal" whenever the target happened to be visible, which against the real
`~/.claude` varied run to run; the third scrolled to the bottom assuming that
put the first figure off screen, which on a fixture overflowing by 346px it
does not. The version that ships searches both ends of the scroll range for a
figure that is genuinely off screen, and **skips with the reason** when the
fixture cannot pose the question at all. See the mutation table.

The selection persists across a reload — one JSON record, one storage version,
validated on the way back in — and is *not* the same file `ccwatch resume` reads: this feature reads and
writes neither `~/.claude/ccwatch/roster.json` (the `write_roster` record) nor
anything else under `~/.claude/ccwatch/`, only the browser's own storage. If
the stored session has since left the machine's session list, the roster says
so with its own sentence, worded so it shares no leading clause with any
sentence the alert control can produce — "that session is gone" and "the feed
is gone" describe different facts and must never be mistaken for each other
mid-read. That tombstone pins above the row list, carries a real `<button>` to
dismiss it, and never blocks the remaining rows from continuing to render.

A session absent from a payload the map does not yet trust (`warming`) or has
lost entirely (`feed_down`) resolves to "unknown", never "gone" — a feed that
cannot be read is not evidence that a session exited, only that this run has
nothing to say about it either way.

### The roster used to state its own trust, and no longer does

The roster had its own condition panel above the row list, rendering the same
`FeedCondition` in a second set of words: "the feed is down: ECONNREFUSED —
rows shown are 2m old", the warming sentence, the unreadable-registry count,
and "No live sessions right now." It read the *same* `cond` object the rest of
the page did, which was the right call at the time, and it is gone anyway.

The reason is the header. With an alert control that is always on screen
directly above the panel, the roster's copy meant one fact stated twice in two
phrasings — two strings to keep in agreement, for a reader who has already read
it — and the panel pushed the row list down every time a condition arrived,
which is the reflow the banners were removed to stop. `web/alerts.js` owns
those sentences now; `statements()` and its nine assertions were deleted rather
than kept "just in case", because a second rendering that nothing reads is a
second rendering that will drift.

What the roster still owns is the **tombstone** — "that session is gone" — and
`resolveSelection`. Those are questions about *your selection*, not about the
feed, and a session absent from a payload the map does not yet trust
(`warming`) or has lost entirely (`feed_down`) still resolves to "unknown",
never "gone": a feed that cannot be read is not evidence that a session exited.

Nothing about the condition is latched anywhere: `cond` is recomputed fresh
every tick from the read outcome and the body, so a good snapshot right after a
down one clears the alert and restores `ctx`/`mem` on that same repaint,
through the same `VOLATILE` gate `applyFeed` sets before it renders anything —
one gate, read once, not two gates that could drift apart.

### The roster's width is yours, not the map's

The panel is dragged wider or narrower from `#rdivider`, a `role="separator"`
between it and `#wrap`, reachable by `Tab` and operable with `ArrowLeft`/
`ArrowRight` (`Shift` for the larger step) and `Home`/`End` to the clamped
extremes — the same three `aria-value*` attributes a native range control
carries, kept current on every change rather than set once at load.

`clampWidth(w, windowWidth)` is the one place a width is ever bounded: never
below `WIDTH_MIN`, never above the smaller of a fixed pixel ceiling and a
fraction of the current window, so a panel sized against a wide monitor does
not swallow a laptop's viewport on the next load. The stored width is
re-clamped against *this* load's `innerWidth`, not the one it was saved
under. Below `STACK_BREAKPOINT` the stored width is not applied and the
divider is hidden at all — `stacked(windowWidth)` reads the same constant the
`@media` rule does, so the two can never disagree about where the panel
stacks above the map instead of beside it. Changing the width only calls
`relayoutWires()`: the blocks reflow themselves, which is what flow layout is,
and all the map is owed is a wire redraw, because the figures the wires connect
have just moved and a wire still pointing where a figure used to be is worse
than no wire.

The width persists across a reload through the same one-way `persistence`
flag and JSON-record shape the selection uses (`validateWidth`/`loadWidth`/
`saveWidth`): a wrong storage version or a non-finite `w` is not a reading to
clamp, it falls back to `WIDTH_DEFAULT` rather than propagating `NaN` into
the stylesheet.

### Message lines are drawn for the agents you are looking at

The map used to draw every peer edge it knew about as a permanent line from
sender to receiver. `serve` reads `peers --days 2`, so a pair that exchanged
one message yesterday got the same line as a pair talking right now, and every
line crossed the owner blocks between its ends. The lines were history drawn as
though they were activity, and the more agents talked the less of the rest of
the map could be read.

Two things replace them, both decided in `web/comms.js`:

- **A comms marker**, a pixel-art envelope over the figure's right shoulder,
  on any agent that sent or received a message in the last two minutes. It is
  absent below that threshold, not dimmed (rule 12), and it is positioned out
  of flow so a message arriving never moves the rug it stands on. The words
  go on the figure's title and accessible name ("messaged web-app 40s ago;
  heard from pricing 1m ago"), because an envelope says neither who nor when.
  Two minutes and not one because `serve` refreshes peers every 45s at best:
  at 60s a marker could be up for fifteen seconds and be missed between two
  glances.
- **Lines only for the figures being looked at**: hovered, keyboard-focused,
  or selected, and all of their edges of any age, with the last two minutes
  drawn stronger. Clicking a figure selects it as well as opening the
  inspector, which is what pins its lines. The inspector is modal, so a click
  could otherwise never leave them on screen. It is also the way in on the
  menu bar overlay, a non-activating panel whose web view cannot be relied on
  to get hover at all.

Hidden by default is not the same as absent (rule 4), so the footer says what
is not drawn: "3 message edges between agents on the map — hover or select one
to draw its own", or "drawing 1 of 3" while you are. With no edges it says
nothing.

### The modal says which of five things is true, never two of them at once

Clicking a figure or a roster row opens a panel on one agent: its status and
the measurement behind it, the peer edges touching it, its conversation, a
reply box, and a kill control. Four openers reach it — a figure by pointer, a
figure by keyboard, a roster row by pointer, a roster row by keyboard — and all
four go through one code path, because four ways in that each set up the panel
slightly differently is four panels to keep in agreement.

The panel keeps its readings on screen when the feed breaks, so it has to say
which way it is broken. There are five renderings and they are asserted
**pairwise distinct**, sharing no leading clause:

| condition | what the panel says |
|---|---|
| the feed is down | `the feed is down: <reason> — the readings in this panel are <age> old` |
| the first snapshot has not landed | `taking the first snapshot — nothing has been collected about this session yet` |
| the feed is healthy | *nothing* |
| rows could not be read | `<n> registry file(s) could not be read — run: ccwatch doctor` |
| the session is gone | `<name> is gone from the snapshot … claude --resume <sid>` |

Three of those are worth explaining.

**A healthy feed says nothing.** Not "feed OK" — a line that appears on every
refresh to confirm things are fine is a line people learn to skip, and then it
is not there on the refresh when it matters.

**Unreadable rows are an additive fact, not a consequence.** The string is a
separate node and is never joined into the main sentence: rows that could not
be read is equally true of a healthy feed and a broken one, and folding it in
would make it read as fallout from the breakage. It is empty for `0`, `null`
and absent, because "0 registry files could not be read" is a sentence nobody
needs.

**A broken feed is never evidence that a session exited.** A session missing
from the snapshot means one of two very different things: it left the machine,
or the read that would have found it failed. The panel only says "gone" when
the feed is trustworthy; otherwise it reports the feed and says nothing about
where the session went. Announcing an exit on the strength of a failed read
invents an event that may never have happened.

The condition object is the same one the header's alert control and the roster
read — `lastCond`, passed in, not recomputed. Two renderings that decide
independently whether the feed can be trusted will eventually disagree, and a
reader has no way to tell which of them is lying.

### The transcript inspector renders markdown

Clicking a figure opens the recent conversation before it offers the reply box,
because reading comes before writing. Claude writes markdown, so the panel
renders it: a numbered plan is a numbered list, a pasted diff is a scrolling
code block, and the sentence with the conclusion in it is bold. Unrendered, the
turn you opened the drawer for arrives as a wall of asterisks in a 560px column.

The renderer is deliberately small, and every rule in it is a rule about
untrusted input, because transcript text *is* file contents and tool output:

- **Escape first, then add tags.** No branch puts a substring of a transcript
  into the page unescaped, and there is no sanitise-afterwards pass — that is
  the pass with the hole in it. A `<script>` or an `<img onerror=…>` in a file
  someone read shows as the text it is, inside a code fence as much as outside.
- **Code spans are handled by splitting the line on them**, not by swapping in
  a placeholder. A placeholder is a string the input can also contain, which
  makes it forgeable.
- **No anchors, for any scheme.** A link here would be a one-click outbound
  request carrying content derived from a transcript. `[PR 12](https://…)`
  renders as its label with the URL beside it as dimmed text: readable and
  copyable, and nothing leaves the machine because you clicked a conversation.
- **`ccwatch`'s own words stay verbatim.** A reduced tool use (`→ Grep: *TODO*`)
  is not the model's prose, and its argument is a shell glob rather than a
  formatting instruction.
- **Identifiers are not emphasis.** `_` pairs only around text containing a
  space, because a transcript is full of `file_path` and `__init__`, and
  `file<em>path</em>` does not just look wrong, it changes what the text says.
  An asterisk with a space beside it is left alone too — `2 * 3 * 4` is
  arithmetic, and this tool talks about token counts constantly.
- **Nesting is bounded at four.** A turn that is all `> ` is 600 levels at the
  1200-character cap, and following it builds 600 nested elements for one turn
  on a panel that repaints every five seconds. Past the cap the markers show as
  text. (Measured rather than assumed: node renders that depth without
  complaining, so the cap is about bounded output, not a crash.)
- **If `md.js` fails to load, the text is still there**, escaped and wrapped as
  before. A missing renderer must not present itself as a session with nothing
  to say.

System reminders and `← 4821 bytes` results are *not* run through it. They are
already-reduced machine text, and a markdown pass over them would find headings
in XML-ish tags and emphasis in paths — inventing structure that was never in
the transcript.

`web/md.js` is a separate file rather than an inline script so the suite can run
it under node and assert on the HTML, escaping included. An XSS assertion you
cannot execute is a comment, not a test.

### The conversation follows you only while you are already at the bottom

Ticks keep arriving while the modal is open, and a reader partway up the
scrollback is reading something specific — pinning them back to the newest
turn on every refresh would throw away the thing they opened the panel to
look at. `atBottom({scrollTop, scrollHeight, clientHeight})` is sampled
*before* the conversation is reconciled and the scroll position is only reset
to the bottom *after*, and only when that sample was true. A reader within
`FOLLOW_EPS` (8px) of the bottom counts as caught up — a fractional scroll
position or a rounding difference between browsers should not be the reason a
reader stops following — but one line's worth of scroll above that is enough
to hold their position through the next refresh. A conversation shorter than
its own viewport, or a scroll box handed non-finite measurements, is treated
as "at the bottom" rather than throwing, since there is nothing to scroll
away from either way.

The empty and failure states are three distinct sentences, not one, because
each names a different fact: an embedded-SDK session (`entrypoint: "sdk-ts"`)
never writes a transcript at all, so it states that rather than "no turns
yet" — the same silence-is-not-evidence rule the status column follows — a
session that simply has not turned yet states that distinctly, and a
transcript fetch that failed states its own reason with `isError: true`
rather than reading like either. None of the three escalates the session's
silence into a hang; that verdict belongs to the status column, corroborated
against CPU time and a runner pid, not to an empty conversation panel.

### The per-agent modal reads the roster's own fields, not a second formatting pass

Clicking a figure — or opening the focused roster row with `o` or a double
click — opens a `<dialog>` with every stat the roster row carries: the same
silence, age, context percentage, memory figure, pipeline phase, repository
and peer edges, reading identically because they *are* the same reading.
`web/modal.js`'s `panel()` is handed `CCWATCH_ROSTER.rowFields(row, {volatile:
VOLATILE})`'s own output rather than formatting `row` a second time, so "the
modal agrees with the roster" is true by construction instead of by
vigilance — a second formatter is a second place the `VOLATILE` staleness
gate can be forgotten, and the modal's kill confirmation used to be exactly
that: it read `row.rss_mb` directly, bypassing the gate every other reading on
the page already honours.

This is also why the panel is a pure function of its input: `panel(input) →
PanelModel` returns the whole rendering as data — twelve stats' worth of
strings, an ordered edge list, the header text — and `map.html` writes that
into DOM nodes built once at load, keyed by `StatLine.key` so a line
appearing or disappearing never rebuilds the ones around it. Almost everything
this feature can get wrong is a sentence, not a layout, and a sentence is
cheap to assert under `node` against a plain object and expensive to assert
against a live browser.

**Why the kill control is disabled and visible, never hidden.** The previous
panel hid the kill button entirely when the server did not opt into
`--allow-kill`, which reads as "this session cannot be killed" when the fact
is "you did not ask the server to allow it" — a failure that looked like an
absence. The control is now always present: enabled with its two-step
confirmation, or disabled and naming the flag that would enable it
(`ccwatch serve --allow-kill`) beside it. The same `disabled` attribute and an
independent guard inside the click handler are both required before a
request is issued, so a stray attribute removal in devtools is not by itself
enough to fire a kill nobody authorised.

**The two-step confirmation names what is actually at stake, from the same
gated reading every other stat honours.** What killing would free is
`fields.mem` when `VOLATILE` is true, "an unknown amount" when volatile but
the reading has not arrived yet, and — when the reading is stale — not stated
at all, with a note saying why, rather than showing a number that may no
longer be true. Two further warnings are additive, not exclusive: a session
whose `pipeline.status` is `"running"` names the phase and says killing it
aborts a paid model call, and a session that is mid-turn (`token: "busy"`)
says a tool call may be left half-applied. Both come from the same snapshot
row the confirmation already reads, never a second lookup.

A kill request that never gets a reply — a dropped connection, not a refusal
— is prefixed `the kill request did not complete: <reason>`, so it cannot be
misread as the server having refused the kill. `doSend`'s transport failure is
worded the same way, for the same reason (see below).

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

**The send control in the modal is the same present-and-disabled shape as the
kill control, for the same reason.** `sendModel(input)` yields `state:
"disabled"` naming `--read-only` when the server was started that way, or
naming that the session is no longer in the snapshot when it has vanished —
never `state: "ready"` with a request nobody authorised. `#ifoot` is never
hidden; only `#replyText`/`#replySend` are disabled, and `doSend()` carries
its own independent guard so a stray attribute removal in devtools cannot fire
a send by itself. A transport failure — the fetch itself never completing —
is worded `the send request did not complete: <reason>`, distinct from both a
refusal and a delivered/queued outcome, for the same reason `doKill`'s wording
is (above).

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

It also prints a **`LAST KNOWN ROSTER`** — who was live the last time anything
looked, and what each one was doing when everything stopped:

```
LAST KNOWN ROSTER — 6 session(s) were live 12m ago; these are not running now

  web-app-fc  web-app  waiting  (input needed)
      claude --resume 15dbe4c0-58ef-4ace-8b21-f633c37caa85  (~/code/web-app)
```

Transcripts remain the resume *authority* — that is where the session id comes
from — but they do not record which sessions were open **together**, what each
was called, or what it was doing at the moment the machine went down, and that
is exactly the part you would otherwise rebuild from memory. So every snapshot
taken for display writes the roster down. Rows already running are dropped from
it, and it is written from `render`, not from `snapshot`, so a `--json` consumer
polling the state does not rewrite history as a side effect.

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

### A syntax error naming a line that is not wrong

A long-running `ccwatch` — `serve`, `watch`, `daemon` — used to die like this
when the script was edited while it ran:

```
ccwatch: line 5582: syntax error near unexpected token `)'
ccwatch: line 5582: `bscribe)       shift; cmd_subscribe "$@";;'
```

Nothing is wrong with the file. Bash reads a script incrementally and remembers
a byte offset into it; when it wants the next command it seeks back to that
offset and reads the bytes that are there **now**. A `serve` blocks for hours,
so an edit in between means the read after it lands in rewritten bytes. In the
case above the offset was 281701 — the start of line 5582 as that process had
counted the lines — which in the newer file is four characters into the
`subscribe)` line. Hence a token (`bscribe)`) that exists in no revision, and a
line number that is correct in both.

The dispatch is now one `{ … }` block ending in `exit`, so bash must parse to
the end of the file before it runs any command, and never returns to the file
afterwards. Two notes for anyone who meets this elsewhere:

- It needs an **in-place** rewrite, the same inode. An editor that writes a temp
  file and renames it leaves the running shell reading the old inode, where this
  cannot happen — which is why it looks intermittent.
- `git commit` does not do it, but a session editing the working tree does, and
  this repository is worked on by several at once.

## Install, in detail

The install commands are in the [README](../README.md#install). This is what
they do and why.

`setup` does one thing and tells you the rest. It symlinks `ccwatch` into the
first writable of `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`
(creating the first if it has to), **runs what it just installed** to prove the
link works, says whether that directory is on your `PATH` and prints the line
to add if it is not, and lists which optional tools are missing with what each
absence costs. Running it twice is a no-op that says so.

```
ccwatch 1.1.0 /Users/you/code/ccwatch/bin/ccwatch

  ✓ python3      Python 3.9.6
  ✓ git         repository names come from the git remote
  ! gh          absent — no deploy panel (brew install gh)

✓ linked /Users/you/.local/bin/ccwatch -> /Users/you/code/ccwatch/bin/ccwatch
✓ runs through the link (ccwatch 1.1.0)
✓ /Users/you/.local/bin is on your PATH
```

`--bin-dir DIR` if you want it somewhere specific. **Do not run it under
`sudo`** — it refuses an unwritable directory rather than asking you to, because
the old instructions here said `/usr/local/bin`, which is root-owned on a stock
Apple Silicon machine, and the reader's next move was a root-owned symlink to a
file in their home directory.

A symlink rather than a copy, so `git pull` upgrades it — and because `serve`
finds `web/` relative to its own *resolved* path, a copy sitting alone in a bin
directory cannot find the pages at all. `bin/ccwatch` runs from anywhere, so it
does not matter where the clone lives.

Then, optionally, and each shows its exact change and asks first:

```bash
ccwatch install-statusline    # wrap your statusline to report usage + context
ccwatch install-hooks         # never miss a prompt that opened between polls
```

`setup` deliberately does not run those two for you. Each already shows its own
change and asks, and a second place asking the same question is a second place
to keep honest.

On macOS it ends by printing the command that builds and installs the menu bar
app ([The menu bar app](../README.md#the-menu-bar-app)), for the same reason it
doesn't run it: building needs `swiftc` and writes `/Applications`. It used to
print the SwiftBar plugin instead. Because that line is the last thing a new
user reads, it sent every one of them to install a third-party host for the
fallback, while the app it had been replaced by went unmentioned.

## Tests

```bash
./tests/run.sh          # shellcheck, then the whole assertion suite
```

CI runs the same script on macOS and on Windows. The Windows job is
`continue-on-error` because the Windows read path does not work yet: its first
real run had 145 failures, nearly all an empty result. What follows is the
design that job is working towards. It does not describe a platform that works
today. Windows runs under the runner's Git Bash,
not WSL — WSL cannot see Windows process ids, which is the corroborating
signal behind every verdict. Every host-dependent measurement goes through a
named probe in the `platform` section: macOS keeps `ps -o lstart=`, `stat -f`,
`date -r`, `vm_stat` and `sysctl` in their BSD forms unchanged; Windows uses
`ctypes` (`OpenProcess`/`GetProcessTimes`/`GetProcessMemoryInfo`, with a
`Get-CimInstance Win32_Process` fallback) for process facts, GNU `stat` for
transcript mtimes, and PowerShell for host pressure. Windows has no load
average (`load1` is `null`, never `0`), no `send`/`kill`/`peers` (these need
POSIX signals and the per-session Unix socket, so `serve` is read-only there),
and no separate "compressed" memory figure — each is stated as unavailable
with the reason rather than omitted. Bash 3.2 is still the floor on both
platforms, because that is what macOS ships and Git-for-Windows bash tracks
it closely enough to matter.

An assertion that needs something the host cannot provide **skips with the
reason**, rather than failing. A runner with swap disabled has no swap
percentage to report, and `null` is the honest reading there — 0% would claim
that swap exists and is empty. The first CI run went red on exactly that, while
passing on the machine the assertion was written on, which is the ordinary way
a suite ends up encoding one machine's configuration.

**Hermetic.** Every assertion runs against a fabricated `~/.claude`: a suite
that reads the developer's live sessions asserts on whatever happened to be
open, which is not a test, it is a screenshot. `CLAUDE_CONFIG_DIR` moves the
registry and transcripts; `CCWATCH_FAKE_PS` substitutes the liveness probe,
without which no fabricated pid is ever live and every row would be filtered
out before reaching the classification — the part most worth testing.

**Mutation-checked.** Rows marked `(verify-ui)` were confirmed against
`ccwatch verify-ui`, which renders the pages in a browser rather than reading
them; the rest are `tests/run.sh`. Every assertion was confirmed to fail against an
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
| render a stale usage reading instead of withholding it | 2 |
| report an already-answered question as still pending | 1 |
| read a fixed tail instead of seeking to the last question | 1 |
| derive the project from the directory name instead of the git remote | 3 |
| ship a tool result's contents instead of only its size | 1 |
| report host pressure on every refresh instead of only when it matters | 1 |
| allow killing a mid-turn or mid-phase session without refusing | 4 |
| enable the kill endpoint without an explicit flag | 2 |
| read only the last transcript line when rebuilding the resume list | 1 |
| resolve the script's own location without following the install symlink | 2 |
| drop the HTML escaping in the transcript renderer | 4 |
| render a markdown link as an anchor | 2 |
| put a reduced tool-use line through the markdown pass | 3 |
| emphasise underscores without requiring a space inside | 2 |
| let an emphasis delimiter hug a space | 1 |
| flatten a nested list instead of nesting it inside its item | 1 |
| drop an unterminated code fence instead of closing it | 1 |
| remove the fenced-code branch from the block renderer | 2 |
| remove the heading branch from the block renderer | 1 |
| render a numbered list as bullets | 1 |
| follow blockquote nesting as deep as the input goes | 1 |
| remove `web/md.js` from the web directory | 1 |
| revert the idle gate so collection never stops when nobody reads `/api/state` | 4 |
| latch the idle gate, so collection stops but a read never resumes it | 2 |
| add a second `setInterval` to a page instead of routing through the shared scheduler | 1 |
| include `ages` in the ETag hash, so no two reads ever share a validator | 1 |
| restore the old `snapshot_ok()` fabrication of an empty result on failure | 3 |
| stop propagating `parse_failed` from `collect_sessions` through the snapshot and the footer | 2 |
| let `/api/state` disagree with `--json` about `parse_failed` for the same registry | 1 |
| reintroduce a wholesale `innerHTML =` on a refresh-reachable container in `map.html` | 1 |
| add a second `setInterval` or a `requestAnimationFrame` call to the rewritten `map.html` | 1 |
| restore the silent fall-through in `resolve_target`, so a failed snapshot is described as an ambiguous match with a blank count | 2 |
| check a collector's output with `jq -e .` instead of `jq empty`, so a legitimate `null` reads as a failed collector | 1 |
| drop or alter the `SEND_TOKEN` placeholder in the served `map.html` | 1 |
| skip the once-only latch and re-flip `persistence` on a second throwing storage call | 2 |
| drop the `volatile` gate from `rowFields`'s `ctx`/`mem` withholding | 1 |
| make `reorderPlan` always return no moves | 1 |
| sort sessions by `sev` alone instead of `max(sev, psev)` | 1 |
| let `nextFocus`'s `ArrowDown`/`ArrowUp` wrap instead of clamping at the ends | 2 |
| let `focusTarget` return `prevSid` even when it has dropped out of `wantedKeys` | 1 |
| drop `role="listbox"` from `#rosterlist` | 1 |
| drop `role="option"` or the roving `tabindex` from the `.rrow` template | 2 |
| bind the roster's keydown handling to `document` instead of `#rosterlist` | 2 |
| drop the "companion view" clause from `#board`'s `aria-label` | 1 |
| resolve a session absent from a `feed_down`/`warming` payload to `gone` instead of `unknown` | 2 |
| let `flyIdx` return a rung for `"mid"`/`"near"` instead of only `"far"` | 1 |
| let `validateSelection` accept a `sid` that is not session-id-shaped | 1 |
| re-flip `persistence` back to `"ok"` after a throwing selection read/write | 2 |
| let `saveSelection(setItem, null)` leave the previous sid's record in place | 1 |
| word the tombstone with the same leading clause as an alert sentence | 1 |
| merge the selection ring into a status-appearance `.agent.*` rule instead of its own `.agent.selected .hit` | 1 |
| word the tombstone with the same leading clause as the feed-down sentence | 1 |
| move `renderRoster`'s call in `applyFeed` ahead of the `VOLATILE =` line | 1 |
| toggle the selection class on a queried child (e.g. inside `.figart`) instead of on `g` itself | 2 |
| drop `clampWidth`'s upper or lower bound, or let it return the raw width unclamped | 1 |
| drop the `WIDTH_DEFAULT` fallback for a non-finite or non-number width | 1 |
| let `stacked` disagree with `STACK_BREAKPOINT` about where the panel stacks | 2 |
| accept a stored width record with a non-finite or non-number `w` | 1 |
| drop `role="separator"`, `tabindex="0"`, or an `aria-value*` attribute from `#rdivider` | 3 |
| reorder `statLines`'s output instead of the fixed silence/age/ctx/mem/pipeline/where/sid/edge sequence | 1 |
| let `quiet` win over `waited` in `statLines`'s silence line instead of `waited` taking priority | 1 |
| emit a `0`/`0%`/`0MB`/`-`/`null` line for a `fields` key that is absent instead of omitting the line | 1 |
| re-aggregate `edgesFor`'s `count` across duplicate edges instead of returning each verbatim | 1 |
| drop an edge whose far end is absent from `names` instead of marking it `unknown: true` | 1 |
| let `edgesFor` leak `last`/`sample` into its output | 1 |
| drop the direction word from an edge's rendered text, leaving only the arrow | 1 |
| read `row.name` instead of `subject.name` for `panel()`'s header | 1 |
| let `panel()`'s `header.status` diverge from the roster row's `.rstatus` join for the same `fields` | 1 |
| let `panel({row: null, ...})` return stats beyond the `sid` line | 1 |
| let `panel()` mutate its input or return a different model on a second call with the same input | 2 |
| write a figure's `aria-label` from a string other than the same `titleBits(row)` call the `<title>` uses | 1 |
| let `killModel({canKill: false, ...})` report `state: "ready"` or open the confirmation anyway | 2 |
| let `killModel`'s `frees` read `fields.mem` when `volatile: false` instead of withholding it with a note | 1 |
| drop `confirm.phase`/`confirm.busy` instead of setting them from `pipeline.status`/`token` | 2 |
| restore `#killbar { display:none }` instead of leaving the bar always present | 1 |
| drop `doKill()`'s own `!CAN_KILL || !row` guard, leaving only the `disabled` attribute | 1 |
| widen `atBottom`'s threshold past `FOLLOW_EPS`, so a reader scrolled up is dragged back down | 1 |
| let `convoMessage` skip the `sdk-ts` check, so an embedded-SDK session reads "no turns yet" instead of its own sentence | 2 |
| add a second `setInterval`, a `requestAnimationFrame` call, or a second refresh-reachable `innerHTML` write to the rewritten `map.html` | 1 |
| let `askModel` report `kind: "dialog"` from the same branch as `kind: "questions"` instead of a distinct `how` | 1 |
| let `sendModel({canSend: false, ...})` report `state: "ready"` instead of naming `--read-only` | 1 |
| drop one of `doSend`/`doKill`'s `X-CCWatch-Token` headers, or reintroduce an `#ifoot` `style.display` write | 1 |
| drop a session from the board's figure loop, so the map shows fewer figures than the roster lists | 1 (verify-ui) |
| hide a figure with `display:none`, or collapse it to zero size | 2 (verify-ui) |
| position a figure outside the scrollable content, where no scroll position can reach it | 1 (verify-ui) |
| give a repo card a `min-width` wider than the board, so the layout overflows sideways | 1 (verify-ui) |
| change `#board` to `overflow:hidden`, so nobody can scroll it with a wheel, a scrollbar or a key | 2 (verify-ui) + 2 |
| build a figure as a `<div>` instead of a `<button>` | 2 (verify-ui) + 2 |
| remove `scrollIntoView` from `revealSelection`, so selecting a roster row never brings the figure into view | 1 (verify-ui) |
| let `ccwatch bar`'s title carry only the highest severity instead of every condition it found | 1 |
| drop the pipe strip from a session name on a menu line | 3 |
| drop the pipe strip from a `waitingFor` note on a menu line | 1 |
| print a menu row's verdict with no measurement beside it | 1 |
| put the pipeline sub-row behind a `--` submenu | 1 |
| render a stale usage reading in the menu instead of withholding it | 2 |
| let a failed snapshot fall through to `ccwatch bar`'s ordinary rendering | 3 |
| offer "Start dashboard" whether or not one is already listening | 2 |
| drop `parse_failed` from the menu bar title | 1 |
| drop `parse_failed` from the menu's dropdown sentence | 2 |
| add an all-clear clause to a menu bar title with nothing wrong | 1 |
| put the unfinished-run count back into the menu bar title | 1 |
| flag unfinished runs with the title's icon while the title names no condition | 1 |
| print a reset time in whole hours only | 2 |
| print a whole-hour reset time as `2.0h` | 1 |
| drop the words that say a crashed phase needs a rerun | 1 |
| render an empty menu for a machine with no live sessions | 2 |
| map `sev` to a different glyph in the menu than the table's awk does | 2 |
| `exec` into `ccwatch` from the plugin, so a tool that died leaves a blank item | 2 |
| pass `ccwatch`'s stderr into a menu line without the pipe strip | 1 |
| have the plugin report a failure whatever `ccwatch` printed | 1 |
| check a collector's output with `jq empty`, which accepts a stream where `--argjson` accepts one value | 2 |
| check it with `jq -e .` instead, so a legitimate `null` reads as a failed collector | 6 |
| weld `collect_live`'s fallback back onto the end of its pipeline, so it appends a second value | 10 |
| let `collect_live` believe an empty answer without checking that `ps` can run at all | 1 |
| let `collect_live` call a working `ps` with no live pids a failure rather than an absence | 1 |
| read the CPU cache with a per-value filter instead of slurping, so a poisoned cache stays poisoned | 3 |
| drop the `$TMPDIR` template from `mktemp -d` in `resume`/`peers` | 1 sandboxed, 4 not (see below) |
| fail rather than skip the orphan check on a host that refuses process enumeration | 1 (observed red before the guard was added) |
| have `setup` copy `bin/ccwatch` instead of symlinking it | 5 |
| have `setup` report success from the `ln` without running what it installed | 3 |
| have `setup` clobber a plain file already at that path | 3 |
| repoint an existing symlink even when the answer was no | 2 |
| drop `setup`'s `PATH` check | 1 |
| list an absent tool without saying what its absence costs | 1 |
| have `setup` point at the SwiftBar plugin instead of the menu bar app | 2 |
| offer the macOS app from `setup` on Windows too | 1 |
| have a Windows `setup` stop before its optional steps (the guard behind the line above) | 1 |
| drop a dispatched subcommand (`kill`) from `usage()` | 1, naming it |
| have the dispatch extraction find nothing, so "every subcommand is documented" holds of zero | 1 (the count guard; the main assertion stayed green) |
| stop toggling `.selected`, so the selected row's figure carries no mark | 1 (verify-ui) |
| leave the wire overlay unsized, so every wire is clipped to the SVG's default 300x150 | 1 (verify-ui) |
| draw every edge on the map again, whether or not anything is looked at | 2 node, 9 verify-ui (10 on a machine with live peer traffic) |
| ignore hover / focus / the selection when choosing a figure's lines | 4 / 1 / 2 (verify-ui) |
| have a figure click open the inspector without selecting, so nothing pins its lines | 2 (verify-ui) |
| keep a figure's marker once its traffic is older than the window | 1 (verify-ui) |
| mark a figure for an edge older than the recency window, or for an unreadable or future timestamp | 1 each |
| record a sent message as heard, or never mark the receiver | 5 / 3 |
| shorten the recency window below a minute past serve's 45s peers cadence | 3 |
| put the comms marker in the button's flow instead of absolute | 1 (verify-ui) |
| drop the words from the marker, leaving it only a picture | 1 node, 1 verify-ui |
| say nothing in the footer while the edges are hidden | 1 node, 1 verify-ui |
| draw a line to a session that has exited, or count one as drawable | 2 / 1 |
| break the envelope's rim, or paint it off the wires' colour | 1 each |
| drop `--force-prefers-reduced-motion` from verify-ui's Chrome, so the reveal check races a compositor that virtual time never advances | 1 (verify-ui) |
| drop `min-height:0` from `#stage`, so it refuses to shrink below its content and the page scrolls | 1 (verify-ui) |
| drop the `aria-label` from the map-key button, leaving a control named only by a glyph | 1 (verify-ui) |
| reintroduce a `[data-lod]` rule, or a reader of the retired camera's `--k` scale | 2 |
| sort the board on `sev`/`psev`/`token` instead of on the name | 1 |
| re-append children to sort them instead of writing `style.order` | 4 |
| substitute a placeholder (`r.branch || "?"`) for a session with no git branch | 2 + 1 (verify-ui) |
| make the no-branch sentinel a string git could actually name a branch | 1 |
| print the sentinel in the zone label instead of branching on it | 3 |
| blank the branch label with `textContent = ""` instead of hiding it, leaving a visible empty line | 1 |
| drop the directory path from a no-repo card's hover, leaving an ambiguous basename | 2 |
| float the map-key button back over the board, where it covers whatever has scrolled under it | 1 (verify-ui) + 2 |
| give any figure animation an interpolating timing function again (`ease-in-out`, `linear`, a `cubic-bezier`) instead of `step-end` | 2 |
| drop the thrown reason, or the measured age of the retained data, from `feedCondition`'s `feed_down` | 2 |
| leak a `dataAge` into the `warming` condition | 1 |
| let a failed collection fall through `feedCondition` as healthy, or replace the collector's own error with a generic one | 4 |
| report an errored payload as an empty host, so "No live sessions" is claimed about a read that never landed | 1 |
| stop propagating `parse_failed` through `feedCondition` | 1 |
| return a trigger for an empty alert set, so a quiet machine grows a control | 3 |
| add `cond.empty` to the alert set, so an idle machine raises an alert | 1 |
| report host pressure below its own threshold | 1 |
| print the swap/RAM/session-share figures while the feed is untrusted, instead of withholding them | 3 |
| drop the "a killed session looks exactly like a clean exit" clause from the pressure sentence | 1 |
| treat `unreadable: 0`/`null` as truthy in the alert set, printing "0 registry file(s)" | 1 |
| drop `ccwatch doctor` from the unreadable-rows sentence | 1 |
| escalate `warming` from `info` to `bad`, so "taking the first snapshot" reads as a failure | 2 |
| remove the severity sort, or the `order` field it writes, from the alert set | 2 |
| make a `sev` a number the page's CSS cannot read | 2 |
| give two alert sentences the same leading clause | 2 |
| collapse the trigger to a bare count, or drop the `!` marker, so severity rests on colour alone | 5 |
| pick the last alert read for the trigger instead of the worst | 1 |
| drop the `+N` count, or print `+0` for a single alert | 2 |
| let the trigger's accessible name list only the worst condition, or disagree with the visible count | 3 |
| mark an `info` condition with the `!` a failure carries | 1 |
| remove `web/alerts.js` from a page, or let either page keep a trust model of its own | 5 |
| let the alert slot collapse when the machine is quiet, so the trigger's arrival re-wraps the header | 1 (verify-ui) + 2 |
| give the loud state styling of its own that grows the header (the block banner, smaller) | 3 (verify-ui) |
| leave the trigger hidden under a live condition, or show it on a quiet machine | 2 (verify-ui) |
| render only the worst alert in the popover, or the headline in place of the measured sentence | 2 (verify-ui) |
| hide a popover item with `display:none` | 1 (verify-ui) |
| position the popover off the top of the viewport | 1 (verify-ui) |
| make the popover neither modal nor out of flow — a hand-rolled `<div>` dropdown in all but name | 1 (verify-ui) |
| stop the trigger opening the panel, or closing it again on a second click | 2 (verify-ui) |
| invert `elapsedPct`, so the clock bar shows the time remaining rather than the time gone | 5 |
| give a usage window the wrong length, or default an unknown one to five hours | 2 |
| treat a missing reset instant as "the window just started" instead of unknowable | 3 |
| report 100% elapsed for a window whose reset has already passed | 1 |
| let a reset further out than the window length produce a negative elapsed fraction | 1 |
| coerce a non-numeric reset instant rather than refusing it | 1 |
| format the reset clock in UTC, or drop the zone abbreviation | 3 |
| hand a null instant to the clock formatter | 1 |
| round the used percentage up instead of flooring it | 1 |
| strip the subject from a bar's accessible reading, leaving a bare "78%" | 1 |
| report the pace from consumption alone, from `>=` instead of `>`, or never | 4 |
| claim a pace for a window whose elapsed fraction is unknown | 1 |
| print a reset time for a window whose reset has passed | 1 |
| unwrap the dispatch block, so bash re-reads the script after a long command and parses whatever is at the offset it left | 1 |
| return `reap_serve`'s fallback to a call of itself, as the rewrite that introduced it did | 2 |
| pass `reap_serve` the name of a port variable rather than its value | 1 |
| produce a gauge for a window carrying no percentage | 1 |
| drop the relative time, leaving only the wall clock | 1 |
| order the gauges by the payload instead of the header's own order | 1 |
| fill an absent window in with an empty gauge | 1 |
| remove `gauges()`'s null guard (throws, so the section fails loudly rather than passing) | all of them |
| shift the bar's severity bands off 90/70 | 1 |
| draw the consumption bar at a constant width, ignoring its percentage | 1 (verify-ui) |
| wire the clock bar to the consumption number | 1 (verify-ui) |
| draw a clock bar at zero rather than omitting it when the fraction is unknown | 1 (verify-ui) |
| give the two bars of a gauge different widths, so their lengths are not comparable | 1 (verify-ui) |
| leave the pace to the bar lengths alone, with no word for it | 1 (verify-ui) |
| drop a bar's `aria-label`, leaving a length with no reading | 1 (verify-ui) |
| drop the Eastern wall clock, leaving only the relative time | 1 (verify-ui) |
| draw only the first usage window in the header | 1 (verify-ui) |
| drop the meter's reserved height, so a withheld reading moves the page | 2 (verify-ui) + 2 |
| reserve less height than the gauge block needs (4.5em against a 64px block) | 1 (verify-ui) |
| build the table view's gauge head and never attach it, leaving bars under nothing | 3 (verify-ui) |
| leave `#frame2` unsized in the harness, so the table view is measured at 300px | 1 (verify-ui) |
| let the meter share the title's header row, so the reading decides whether it wraps | 1 (verify-ui) + 2 |
| drop the meter column's reserved width, so a withheld reading narrows it and the title beside it re-wraps | 1 (verify-ui) |
| keep that reservation at phone width, making the header wider than the window | 1 (verify-ui) |
| write the narrow-width override as `.gauges` rather than `header .gauges`, so it loses to a later rule | 1 (verify-ui) |
| turn `_probe_proc_windows`'s "winpid missing → fail" branch into "winpid missing → absent, print `[]`" | 3 |
| collapse `_probe_proc_bsd_parse`'s `absent`/`ok` branches into a single unconditional `ok` | 1 |
| drop `probe_mtimes`'s control-query guard, so an unreadable root reports `ok` with an empty listing instead of `failed` | 3 |
| report `load1: 0` in `_probe_host_windows`'s jq transform instead of `null` | 2 |
| plant a real `date -r` call outside the platform section (FR-001) | 1 |
| split a Windows bar-document line on the last `" | "` instead of the first | 1 (app-win, gated — see below) |
| drop a line carrying an unknown parameter instead of retaining it | 1 (app-win, gated — see below) |
| remove `WS_EX_NOACTIVATE` from the overlay's extended window style | 1 (app-win, gated — see below) |
| remove the `%SystemRoot%\System32\bash.exe` exclusion from `BashLocator` | 1 (app-win, gated — see below) |
| leave the overlay's web view with no navigation delegate, so a load against a dead serve fails into a blank white panel | 1 (app selftest) |
| give a serve that ran for days no fresh restart budget, so its fourth death over the app's life is final | 1 (app selftest) |
| put `.fullSizeContentView` back on the overlay, so the page covers the title bar and the panel cannot be dragged | 1 (app selftest) |
| drop one character from a sprite row | 1 |
| draw the suspected hang with the idle pose, so it differs from idle only in colour | 1 |
| draw the raised arm into the body instead of its own group | 1 |
| fill the uncorroborated figure instead of drawing it hollow | 1 |
| fall back to the working pose for a class the sprites do not know | 1 |
| paint either half of the tunic a fixed grey instead of the status token | 1 each (the first version of this check was satisfied by the other half and missed it) |
| pick a session's look at random instead of from its id | 1 |
| give every session the same hair | 1 |
| draw the context meter with no reading, or leave it dark at 4% | 1 each |
| move the context meter's bad threshold from 80% to 90%, or stop clamping it | 1 each |
| have any part of the world (grass, floor, hedge, rug, either wall) reference an external image | 1 |
| paint a wall's middle, leave a gap in the hedge's top, or shrink a frame's north side to match the others | 1 each |
| stop the north wall casting its shadow | 1 |
| draw the scorched wall without its cracks, so it is the plain wall recoloured | 1 |
| drop the light theme's board-only `--dim`/`--ok`, darken the daylight grass, or lighten the dusk rug | 1 each |
| paint the wall 15 deep, the rug's border 3 wide, or the hedge's south side 4 deep without changing the CSS that slices them | 1 each |
| stop painting the hedge, leaving owners in a transparent border of the right width | 1 (verify-ui) |
| drop the rule that puts a repo with an unfinished run behind the scorched wall | 1 (verify-ui) |
| have the sprite module return no paths, leaving figure-sized empty boxes | 1 (verify-ui) |
| load `sprites.js` after the script that draws with it, or not at all | 1 |
| size the figure in `em`, so it resolves against the button's 13px font and a 16-cell sprite renders at 26px | 1 (verify-ui) — not a planted mutation: this was the implementation, and the check's first run caught it |
| put `.zones` back to a flex column, so every branch takes its room's full width | 2 (verify-ui: the default width and 470px) |
| leave `} background:…; }` where `.agent:hover {` was, which also drops `.agent:focus-visible` | 1 (verify-ui) — not a planted mutation: a7b7967 shipped it, and it was found by reading the CSS |
| stop removing the previous screenshot, and have the browser write nothing, so last run's images are left in place | 2 (verify-ui --shots). Removing the `rm` alone is not a reliable mutation: whether the old code left a stale image or hung for ten minutes in `wait` depended on whether Chrome survived the early TERM, and here it did — so the check needed the browser taken out as well to go red |
| `revive`: drop the ends-on-a-question gate | 1 |
| `revive`: drop the answered-once gate | 1 |
| `revive`: drop the live-runner gate | 2 |
| `revive`: let a runner's name in an *argument* count (a `tail -f …/spec-roadmap` watcher) | 3 |
| `revive`: report an unreadable process table as `[]`, or drop the gate on it | 2 each |
| `revive`: drop the ten-minute delay | 1 |
| `revive`: ask whatever the roadmap's progress | 1 |
| `revive`: treat any line containing `spec-roadmap` as having run it | 1 |
| `revive`: drop the recurring-cron gate, or count one-shot crons | 1 each |
| `revive`: drop the subagent gate, or count every background `Bash` | 1 each |
| `revive`: drop the interrupted branch | 1 |
| `revive`: consider sessions that are `waiting` (both filters — either alone is masked by the other) | 1 |
| `revive`: drop the retry backoff, the retry cap or the network gate | 2, 1, 2 |
| `revive`: drop the wait for a limit's reset, or the cap on continues | 2, 1 |
| `revive`: read every reset as am. Only caught by a fixture pinned to an afternoon: the other two follow the clock, and a morning run cannot tell 3pm from 3am | 1 |
| `revive`: record every send as `sent` | 1 |
| `revive`: let `--json` send without `--send` | 1 |
| `revive`: take no lock, never take over a dead pass's lock, or release it on neither path (either path alone is covered by the other) | 1, 4, 1 |
| `revive --enable`: write `false` | 1 |
| `revive-module`: drop the failed-pass line, the rows, or the reason in each row | 1, 2, 1 (verify-ui) |
| `revive-module`: give the switch a `min-width` instead of a width | 2 (verify-ui) |
| `revive-module`: anchor the panel by its right edge | 1 (verify-ui) |
| `revive`: compare a peer message's whole `content` rather than finding the ask as a line inside Claude Code's envelope | 1 |
| `revive`: count a `SendMessage` reply as work | 1 |
| `revive`: treat any tool call after an ask as resumed work (threshold 1), or never (threshold huge) | 1, 1 |
| `serve`: let a serve with revive on idle-exit | 2 |
| `serve`: drop the `/api/revive` route | 6 |
| `serve`: idle revive's loop without a reader, as the other refreshers do. It stayed green until a check asserted a pass made with nobody reading: a live serve doing nothing looks exactly like one that is working. That check first measured when the last pass *finished* and failed at load average 200 on a working revive; it now measures when one *started* | 1 |
| `serve`: publish the switch only after the next pass (both the immediate publish and the pre-pass publish — either alone is masked by the other) | 1 |

The four `app-win` rows above were confirmed by tracing the C# against the
mutation by hand, not by watching `tests/run.sh` turn red: there is no .NET
SDK on the macOS machine this was authored on, so the assertions that
exercise them (`tests/run.sh`'s `app-win` section) skip here with the reason
stated rather than running. They are mechanically re-confirmed the first time
`./app-win/build.ps1 -SelfTest` runs on Windows — see the `windows-latest` CI
job (FR-032) — and this row should be updated to drop the "gated" qualifier
once that has happened at least once.

That last table is not decoration. Two of those mutations are bugs that were
actually **in** the code and were found this way, and two entries started life
as *test* defects. The de-duplication assertion passed against an
implementation with the de-duplication removed, because in the fixture the send
could not succeed anyway and the assertion only looked for the success message.
The tool-use row is the second: its fixture was `→ Grep: **/*.ts`, which the
inline pass leaves alone regardless, so the assertion passed with the verbatim
handling deleted — the fixture now uses an argument that would actually come
back in italics. An assertion that passes against a broken implementation is
worse than no assertion, because it is counted as coverage.

The blockquote row is a third kind of correction, and a cheaper one. The cap was
written with a comment claiming an uncapped renderer would overflow the stack;
the mutation was caught by **nothing**, because 600 levels render fine. The
guard is worth keeping for bounded output, but the assertion and the comment now
say what it actually does.

The block-layout rewrite added a fourth kind, and six entries' worth of it: a
check that is **green and cannot go red**. Every one of these was written, run,
and believed before a mutation showed it up.

| The check | Why it could not fail |
|---|---|
| `board.scrollWidth <= board.clientWidth` for horizontal overflow | `overflow-x:hidden` clamps `scrollWidth` to `clientWidth`, so it was true however wide the content was — it passed against a card given `min-width:3000px` |
| `scrollHeight > clientHeight` plus a `scrollTop` poke, for "the board scrolls" | an `overflow:hidden` box reports its full content height *and* moves under a programmatic `scrollTop`, so it passed against a board nobody can scroll with a wheel, a scrollbar or a key |
| "selecting a roster row reveals its figure", v1 | the check called `scrollIntoView` **itself** and then asserted the figure was visible |
| "selecting a roster row reveals its figure", v2 | reported a PASS worded "already on screen; nothing to reveal" whenever the target happened to be visible — and against the real `~/.claude` that varied run to run |
| "selecting a roster row reveals its figure", v3 | scrolled to the bottom assuming that put the first figure off screen; on a fixture that overflows by 346px it does not, so the premise silently never held |
| `grep -cE 'sort\([^)]*(sev\|psev\|token\|worst)'`, guarding against ordering by status | `[^)]*` stops at the first `)`, so in `sort((p, q) => (q.sev \|\| 0) - (p.sev \|\| 0))` it never reached `sev` — it reported a clean 0 against a board sorted entirely by severity |

The first two were fixed by asserting the thing the user actually depends on —
the computed `overflow` value, and geometry — rather than a number the browser
derives from it. The third, fourth and fifth were fixed by **searching** for a
figure that is genuinely off screen and skipping with the reason when the
fixture cannot produce one. The sixth was a character class.

Two of the six were only found because the *mutation* was wrong too: prepending
`min-width:3000px` to a rule that ends in `min-width:0` changes nothing, and a
mutation that does not mutate looks exactly like a check that does not check.
That is the argument for the rule above in its strongest form — the only way to
know a check works is to watch it go red on purpose, and the only way to know
the mutation works is to watch something go red because of it.

The alert control and the usage meter added four more of the same kind, all
four caught before they were trusted:

| The check | Why it could not fail, and what it is now |
|---|---|
| "a warming payload states no data age" | the fixture was `{warming: true}` with no `collected_at`, so `dataAge` came out `null` whatever the branch did. The fixture now carries a snapshot instant on purpose, which is the only way the assertion can see the branch inheriting one |
| "three live alerts do not re-wrap the header" | true at the harness's 1180px whether or not the slot reserves its width, because the header has room to absorb the trigger either way — it passed against an unreserved slot. There is now a second pass at 420px, where an unreserved slot wraps the gauges onto a second line |
| "a withheld usage reading does not move the board", at 900px | 900px is below the header's stacking breakpoint, so the meter has nothing beside it to squeeze there and the reserved *width* plays no part. The check was green with that reservation removed; it now runs at 1100px, in the two-column band, with the title posed to a fixed length so the result does not depend on how many sessions the machine is running |
| "opening the panel does not move the board" | no **single**-property mutation turns it red: a `<dialog>` in the top layer is out of flow whatever `position` says, and a non-modal dialog is still `position:absolute` by the UA sheet. It goes red only when the panel is both non-modal *and* in flow — which is exactly what a hand-rolled `<div>` dropdown is, and is the rewrite it guards. Recorded rather than deleted, because "this check can only fail one way" is worth knowing at the moment somebody changes that one way |

The last is the case the rule's own wording covers: make a check report the
failure you are looking for, **or establish that it can**. Two mutations that
should have broken it did not, and the reason they did not is a fact about the
platform that the next person to touch this will want.

The reaper guard added a fifth kind, and the cheapest one to fix: a check that
was **red against correct code**. "`reap_serve`'s fallback is not itself"
greps the function body with comment lines stripped, and the body's first line
is `reap_serve() { # reap_serve <port>` — a trailing comment naming the
function, which whole-line stripping leaves behind. It is the same shape as the
`grep -c 'calc(100vh -'` that matched the comment explaining why it existed,
and it is worth stating that this direction of failure is the lucky one: a
guard that fires on correct code gets fixed within the minute, where a guard
that cannot fire is counted as coverage for as long as nobody checks.

The third is the one worth generalising. A geometric check is only as good as
the *regime* it measures in — a width where the thing under test does not
participate, a title short enough not to wrap, a machine whose session count
happens to fit — and a green check in the wrong regime is indistinguishable
from a working page. Both usage-meter checks now pose their own inputs: the
window's percentages, the reading's staleness, and the title's own length.

The collector fixes added a **fifth** kind, and it is the subtlest yet: a check
that goes red on one host and stays green on another, for the same bug.

Reverting the `$TMPDIR` template on `mktemp -d` is caught by four assertions
worded "`resume` takes its temp directory from `$TMPDIR`" — on a normal
machine. Under a sandbox that refuses `/var/folders`, bare `mktemp -d` dies
too, so all four stay **green against the bug**, and the only thing that moves
is the positive case at the end ("a usable `$TMPDIR` lets resume report"),
which on a normal machine passes either way. Neither direction is a check on
its own; between them they cover both hosts, and deleting the positive case as
redundant would leave a sandboxed run blind to the regression. Measured by
reverting the template and watching which went red where.

The lesson generalises past this one assertion: *where* a check can fail is a
property of the host, not just of the code, and "I watched it go red" is only
evidence for the host you watched it on.

`setup` added one more, and it is the message-versus-behaviour trap in its
purest form. "setup runs what it installed rather than reporting success from
the `ln`" was written as a check that the words *runs through the link* appear
in the output — which they do whether or not it ran anything, so faking the
version string it compares left the assertion green. The claim needs a link
that genuinely cannot run, and the realistic way to get one is a checkout that
has lost its executable bit. That is not hypothetical: a
`git update-index --cacheinfo 100644` did exactly that to this repository, and
the symlink was correct in every other respect.

The menu bar added two more, and the first is the plainest example of the kind
in the whole file:

| The check | Why it could not fail, and what it is now |
|---|---|
| "the menu bar title is a single line" | written as `printf '%s\n' "$title" \| wc -l`, which **appends the newline it then counts** — so it reports 1 for a title that is the empty string. It stayed green through an entire run in which every other assertion in the section was failing on empty output, because the harness was pointing `$CCWATCH` at a path that did not exist. It is now `printf '%s' \| awk 'END{print NR}'`, which reports 0 for nothing at all |
| "an unreadable registry file reaches the title" | asserted against the whole document, and matched the phrase out of the dropdown's summary *line* instead — so deleting the title clause left it green. The title and the dropdown are two surfaces making two claims, and they now have an assertion each, the first against `bar --title` |

Both are the same mistake in different clothes: the check was reading a
*superset* of what it claimed to read. The first counted a character the
assertion itself had added, the second matched a string the document contained
somewhere else. Neither is visible from a green run, and only the mutation
showed them up — the second one went through green and would have been counted
as coverage for a title that had stopped reporting.

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

### The feed's duty cycle

Before the idle-aware feed, `ccwatch serve` collected on a fixed cadence
regardless of whether anyone was reading `/api/state` — the visible-tab column
below is what every condition cost. Measured with `times` over a 60s window
(the whole subshell's reaped children, not just the python pid, which misses
the transient `jq`/`ps`/`git` forks) against this machine's real
`~/.claude` — 34 live sessions across 94 projects, a heavier population than a
typical dev box:

| Condition | Before | After |
|---|---|---|
| no client at all | ~37% of one core | ~14% of one core |
| a page open in a hidden tab | ~37% of one core | same as no client — a hidden tab issues zero `/api/state` requests, so nothing distinguishes it |
| a page open and visible | ~37% of one core | ~37% of one core — reported, not improved; panel freshness and update interval are unchanged |

The "after, no client" figure is not near-zero the way SC-001 expects on a
lighter host: `LAST_READ` is seeded at server start (so the very first paint
is warm without requiring a real reader first), which lets each collector run
its normal cadence for the first `CCWATCH_IDLE_GRACE` (15s) before going idle
for the rest of the window — on this population a single snapshot collection
costs close to a second, so several fit in that warm-up. Over a window longer
than the grace period the idle share dominates and the duty cycle keeps
falling; the reduction shown here is the warm-up amortized over the fixed 60s
the measurement method calls for, not the steady-state idle cost.

## A note on what this reads

`ccwatch` reads two things Claude Code does not document as public interfaces:
`~/.claude/sessions/<pid>.json` and the transcript JSONL. That is a deliberate
trade — they carry information the supported CLI does not expose, and the whole
point of the tool is to know more than `busy`. `ccwatch doctor` exists so that
when the trade stops paying off, you find out from a failing check rather than
from an empty table.

It writes nothing except its own event log and caches under
`~/.claude/ccwatch/`, its CPU-sample cache in `$TMPDIR`, and — only when you run
`install-hooks` or `install-statusline` and confirm — your `settings.json`.
The docked agent roster panel (`web/roster.js`) is unrelated despite the
name-collision: it writes only the browser's own storage, never
`~/.claude/ccwatch/roster.json` — see [Selecting a row scrolls to the figure
there](#selecting-a-row-scrolls-to-the-figure-and-remembers-the-choice).

## Releases

The version comes from the commit log rather than from someone remembering to
bump it. Every push to `main` is read as [Conventional
Commits](https://www.conventionalcommits.org): `fix:` moves the patch, `feat:`
the minor, a `!` or a `BREAKING CHANGE:` footer the major.
[release-please](https://github.com/googleapis/release-please) keeps a release PR
up to date with the pending number and the changelog entry it would write, and
merging that PR is what patches `CCWATCH_VERSION`, tags `vX.Y.Z` and cuts the
GitHub release.

A PR rather than a tag straight off `main`, because the number in the script and
the tag on the commit have to agree, and the PR is where that pairing is visible
while it is still free to change. It is also the last point at which the
generated changelog can be edited.

Two consequences worth knowing before committing:

- **The commit subject is the changelog line.** "update transcript.js" tells a
  reader nothing; the subject is expected to describe the user-visible change,
  which is the same standard the rest of this repo applies to its comments.
- **`CCWATCH_VERSION` is never edited by hand.** It carries an
  `x-release-please-version` marker and is rewritten by the release PR. A
  hand-edit makes the tag and the script disagree about what shipped, which is
  the one thing a version number exists to prevent.

`CHANGELOG.md` entries from 1.1.0 onward are generated. The 1.0.0 entry predates
all of this and is written by hand, which is why `bootstrap-sha` in
`release-please-config.json` pins where history starts being read.

