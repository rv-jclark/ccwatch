# ccwatch

[![ci](https://github.com/rv-jclark/ccwatch/actions/workflows/ci.yml/badge.svg)](https://github.com/rv-jclark/ccwatch/actions/workflows/ci.yml)
[![licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Every Claude Code session on this machine, and which one is stuck.

```
NAME                  PROJECT            STATUS         AGE   LAST
checkout-api-d9       checkout-api       * waiting      3m    permission to run rm 3m
web-app-fc            web-app            ! HUNG?        4d    quiet 41m
pricing-84            pricing            + sdk          5m    no status published
  \_ 011-usage-report  analyze/running  opus  $11.15
infra-38              infra              ~ sdk-ts       4d    cpu moving
infra-e6              infra              - idle         1d    14m ago

UNFINISHED RUNS — stopped in the last 24h, and no live session is holding them
  specify/failed       314-cohort-capacity  opus  $55.19
      9h ago  claude --resume 15dbe4c0-58ef-4ace-8b21-f633c37caa85

19 live · 1 waiting on you · 1 suspect · 3 unfinished run(s)
```

```bash
ccwatch                  # live table, refreshed until you quit (q / Ctrl-C)
ccwatch once             # draw it once — safe in a pipe or a status bar
ccwatch --json           # the same data, for scripting
ccwatch serve            # table + map in a browser, with replies
ccwatch ask              # what each blocked session is actually asking
ccwatch convo <who>      # the recent conversation of one session
ccwatch resume           # what to reopen after a crash or reboot
ccwatch send <who> <msg> # say something to a session that is already running
ccwatch deploys          # CI/deploy runs you are waiting on
ccwatch subscribe <wf>   # (run by an agent) tell me when that deploy lands
ccwatch peers            # which sessions have been talking to each other
ccwatch kill <who>       # stop a session — refuses when it would cost you work
ccwatch daemon           # watch deploys and notify subscribers while you are away
ccwatch log              # recent hook events (needs install-hooks)
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
| the git remote | which repository a session is really in | nothing, for a directory with no remote — and it says so |
| host swap and free RAM | that the OS is about to start killing things | which process it will pick |

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
checkout-api-8e       checkout-api       ● busy      2h    18%  3s ago
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

### The city's geography comes from identity, not from a layout pass

Districts, buildings, zones and figures each get their world coordinate from
what they *are* — an org, a repository, a branch, a session id — never from
their position in the payload or from a force-directed graph. A dozen nodes
under a spring layout is harder to read than the list it is drawn from, and it
rearranges itself every time you look at it: "did that agent move, or do I
misremember" is not a question a monitoring view should raise. This entry
replaced an earlier CSS grid that answered that question with "sometimes,
whenever the severity sort changes" — a district reordered on a status change
alone, a refresh rebuilt the whole tree and dropped whatever you had open, and
a stopped feed rendered no differently from a machine with nothing running on
it.

`web/plots.js` is the pure identity→coordinate module (loaded by both
`map.html` and, under `node`, `tests/run.sh`, the same way `web/md.js` is).
Each level — district, building, zone, figure — is a fixed-column raster keyed
by hash: `i = h1(key) mod C`, then `i = (i + h2(key)) mod C` on a collision,
with `h2` odd and coprime to the column count, for up to `C` probes. A
**persisted assignment always wins and is never recomputed**, which is what
makes a coordinate survive every future refresh once it exists. When a
parent's capacity is exhausted, the identity claims an annex plot — `<key>#2`,
`<key>#3`, … — in the grandparent's space by the same rule, under the same
label, rather than displacing anything already placed. A district's capacity
doubles, never shrinks, when a new district cannot be placed; doubling is safe
because existing districts are read back from storage, not re-derived, so the
modulus changing cannot move them.

Every draw is now **reconciled by key**, one `<g>` per identity, rather than
rebuilt wholesale: an element whose key is still wanted gets its attributes
updated in place, one absent from this tick's wanted set is removed, and
nothing already onscreen that is still wanted is ever destroyed and recreated.
That is what lets an open inspector, a hover, a focus ring and a text
selection all survive a refresh — the only remaining wholesale `innerHTML`
write is a turn's rendered markdown body inside an already-reconciled
container.

The whole occupied city fits to the viewport on load — `k = min(vw/W, vh/H)`
clamped to the ladder's rungs, the extent centred in the available space — and
from there the camera is yours: drag or the arrow keys pan, the wheel or
`+`/`-` zoom in discrete steps, `0` refits, and the viewport survives a
reload.

### Zoom is a ladder, and each rung is a fixed scale, not a smooth number

`web/camera.js`'s `LADDER` is `[0.25, 0.5, 1, 2, 3, 4, 6, 8]` — eight fixed
scales, never a continuously dragged number. A discrete ladder is what gives
"which level am I at" an unambiguous answer: a scale of 2.999 and a scale of 3
would otherwise be the same rung read two different ways, and a boundary that
can only be crossed by a whole step is a boundary a hysteresis band can be
drawn around cleanly (`levelFor`, contracts/camera-js.md §8).

Three named detail levels — `far`, `mid`, `near` — sit on that ladder and
control **what is drawn, never a coordinate**. Nothing moves or resizes in
world space when the level changes; the level only toggles which elements are
in the DOM at all:

- **`far`** (ladder rungs 0–2, scale ≤ 1): each district collapses to its
  aggregate — a session count and its worst status word (`DistrictSummary`,
  data-model.md §5). Buildings, branch zones, figures and district labels are
  hidden; only the aggregate is legible at a scale where a building's own
  label would not be.
- **`mid`** (rungs 3–4, scale 2–3): buildings and their branch zones appear,
  each carrying its own label; the district aggregate is hidden in favour of
  the district label. Figures are drawn but unlabelled — legible as shapes,
  too small yet for a name.
- **`near`** (rungs 5–7, scale ≥ 4): figures gain their name labels
  (`.alabel`) on top of everything `mid` already shows.

Level of detail is semantic rather than a scale factor because the three
things it is standing in for — a count, a shape, a name — are legible at
different sizes and become clutter before they become readable at any smaller
one; fading them in continuously would just mean redrawing the same decision
every frame for no benefit over toggling it once at a threshold crossing.

A snapshot that is not `ok` — the feed down, a snapshot never taken, or a
registry file that would not parse — is a different sentence in each of those
three cases, not a variation in wording on the same one. Districts, buildings
and zones stay drawn with their age marked stale; only the readings that
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
the one question this view exists to never raise (see "The city's geography
comes from identity, not from a layout pass" above). Splitting the roster's
ordering into its own reconciled list — keyed by `sid`, moved by
`reorderPlan`'s minimal `insertBefore` plan, never a wholesale rebuild — means
a status change can reorder *rows in a list* without ever being in a position
to move a *figure*, because nothing in `web/plots.js`'s placement ever reads
a severity, a status word or an ordering value at all.

### The roster is operable without a mouse or without sight

Every row `web/roster.js`'s `rowFields`/`titleText` can produce is also a row
in `#rosterlist`, `role="listbox"` with each `.rrow` carrying `role="option"`
and a roving `tabindex`: exactly one row is reachable by `Tab` at a time, moved
by `ArrowDown`/`ArrowUp`/`Home`/`End` (`nextFocus`, clamped — never wrapping
past the first or last row) and restored **by `sid`**, not by position, after
a tick reorders the list (`focusTarget`), so a status change mid-navigation
never drops focus onto the wrong agent or out of the list altogether. `Enter`
selects the focused row. The listener is bound to `#rosterlist` itself, never
`document`, so the roster's arrow keys can never pan the map and the map's own
arrow-key panning (bound to `#world`) can never move roster focus — two
independent keyboard surfaces on the same page, each scoped to the element it
operates.

`#world`'s own `aria-label` now names itself a companion view of the agent
list, rather than the sole carrier of the page's meaning: a screen reader
lands on the roster and hears every claim the figures draw — the status word,
the measurement, the repo/branch — as text, before it ever reaches the map.

### Selecting a row flies the camera there, and remembers the choice

Clicking a roster row — or activating it with `Enter` — marks that row
selected, outlines the matching figure with its own rule (`.agent.selected
.hit`, applied to the outer `<g class="agent">` node `applySelectionEmphasis`
toggles, never to the `.figart` group `updateFigure` rebuilds wholesale every
tick, so a status change can never clobber the ring mid-flight), and flies
`CCWATCH_MAP_CAMERA` to that figure's own `cx`/`cy` — the same coordinates
`web/plots.js` already computed, read once out of `drawWorld`'s figure loop
rather than recomputed. This is the camera module's first caller: entry 003
shipped it with none. The fly only fires when the selection actually changes
(`sid !== lastFlownSid`), so a tick that merely re-renders the same selection
never re-triggers a flight, and it reads
`matchMedia("(prefers-reduced-motion: reduce)")` at the moment of the fly
rather than trusting the stylesheet alone — a `transition: none` fires no
`transitionend`, which would leave the camera's `.eased` class on forever.

The selection persists across a reload the same way the camera's own viewport
does — one JSON record, one storage version, validated on the way back in —
and is *not* the same file `ccwatch resume` reads: this feature reads and
writes neither `~/.claude/ccwatch/roster.json` (the `write_roster` record) nor
anything else under `~/.claude/ccwatch/`, only the browser's own storage. If
the stored session has since left the machine's session list, the roster says
so with its own sentence, worded so it shares no leading clause with any of
`statements()`'s four failure sentences — "that session is gone" and "the feed
is gone" describe different facts and must never be mistaken for each other
mid-read. That tombstone pins above the row list, carries a real `<button>` to
dismiss it, and never blocks the remaining rows from continuing to render.

A session absent from a payload the map does not yet trust (`warming`) or has
lost entirely (`feed_down`) resolves to "unknown", never "gone" — a feed that
cannot be read is not evidence that a session exited, only that this run has
nothing to say about it either way.

### The roster states when it cannot be believed, in four distinct sentences

The map's own trust model (`computeFeedCondition`) already decides, every
tick, whether the payload is `ok`, `feed_down`, or `warming`, and whether
`s.sessions` came back empty. `statements(cond)` reads that *same* object —
never a second derivation of trust — and maps it to the roster's own wording,
because two renderings that compute trust separately will eventually disagree,
and there is no way to tell which one is lying:

- **feed down** — the reason the read failed, and the measured age of the
  rows still shown, because those rows are retained, not current.
- **warming** — the first snapshot has not landed yet; no rows are listed at
  all, because there is nothing yet to state an order over.
- **N registry files unreadable** — additive, can accompany any of the other
  three, and disappears the moment `cond.unreadable` is `0` or absent, never
  printed as `"0 registry files"`.
- **no live sessions** — stated only when the feed is `ok` and genuinely
  reports zero sessions. This exclusion is enforced *inside* `statements()`
  itself, not by its caller, so a warming or down tick can never be misread as
  "nothing is running" — those are different facts.

Nothing here is latched: `cond` is recomputed fresh every tick from the read
outcome and the body, so a good snapshot right after a down one clears the
statement and restores `ctx`/`mem` on that same repaint, through the same
`VOLATILE` gate `applyFeed` already sets before calling `renderRoster` — one
gate, read once, not two gates that could drift apart.

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
stacks above the map instead of beside it. Changing the width calls
`reflowWorld()`, never `fitView`, because a drag is the visitor choosing how
much city to see, not a request to re-frame it.

The width persists across a reload through the same one-way `persistence`
flag and JSON-record shape the selection uses (`validateWidth`/`loadWidth`/
`saveWidth`): a wrong storage version or a non-finite `w` is not a reading to
clamp, it falls back to `WIDTH_DEFAULT` rather than propagating `NaN` into
the stylesheet.

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

## Install

```bash
git clone https://github.com/rv-jclark/ccwatch.git
ln -s "$PWD/ccwatch/bin/ccwatch" /usr/local/bin/ccwatch
ccwatch doctor          # confirm it can read what it needs to read
```

A symlink rather than a copy, so `git pull` upgrades it. `bin/ccwatch` runs from
anywhere and finds `web/` relative to its own resolved path, so it does not
matter where the clone lives.

Optional, and each shows the exact change before making it:

```bash
ccwatch install-hooks         # never miss a prompt that opened between polls
ccwatch install-statusline    # wrap your statusline to report usage + context
```

### Requirements

| | |
|---|---|
| macOS | `stat -f` and `ps -o lstart=` are used in their BSD forms |
| `bash` 3.2+ | what macOS ships, and the floor the test suite enforces |
| `jq` | `brew install jq` — the only hard dependency not already present |
| `python3` | ships with macOS; used for the socket client and date parsing |
| `git`, `gh` | only for the deploy panel and repo identity; degrades with a message |

### Uninstall

```bash
rm /usr/local/bin/ccwatch && rm -rf ~/.claude/ccwatch
```

Hooks and the statusline wrapper, if you installed them, are entries in
`~/.claude/settings.json` — remove the ones naming `ccwatch`. Every write is
preceded by a timestamped backup of that file.

## Configuration

All environment variables, all optional.

| Variable | Default | |
|---|---|---|
| `CCWATCH_BUSY_STALE` | `600` | seconds of transcript silence before `busy` is suspect |
| `CCWATCH_SDK_STALE` | `900` | the same for headless `claude -p` sessions |
| `CCWATCH_CPU_MIN_GAP` | `1.5` | minimum seconds between CPU samples for a delta to count |
| `CCWATCH_CTX_STALE` | `120` | how old a context reading may be before it is dropped |
| `CCWATCH_USAGE_STALE` | `600` | how old a usage reading may be before its numbers are withheld |
| `CCWATCH_REPO_TTL` | `21600` | how long a directory's resolved repo is cached |
| `CCWATCH_TAIL_BYTES` | `400000` | how much of a transcript `convo` reads |
| `CCWATCH_SWAP_WARN` | `80` | swap percentage at which the host is called out |
| `CCWATCH_KILL_GRACE` | `8` | seconds to wait for a killed session to exit |
| `CCWATCH_TAIL_TEXT` | `1200` | how much of one turn's text `convo` keeps |
| `CCWATCH_ASK_BYTES` | `600000` | cap on the seek back to the last question |
| `CCWATCH_DEPLOY_LIMIT` | `20` | runs requested per repo from `gh` |
| `CCWATCH_REFRESH` | `2` | seconds between repaints |
| `CCWATCH_RESUME_DAYS` | `14` | how far back `ccwatch resume` looks |
| `CCWATCH_UNFINISHED_HOURS` | `24` | how recent an unfinished run must be to appear in the live table |
| `CCWATCH_SEND_VERIFY` | `10` | seconds to wait for a sent message to appear in the receiver |
| `CCWATCH_SEND_AS` | `ccwatch` | how sent messages identify themselves |
| `CCWATCH_DEPLOY_PATTERN` | `deploy\|release\|rollback\|publish\|promote` | which workflows count as deploys |
| `CCWATCH_DEPLOY_TTL` | `60` | seconds to cache `gh` results |
| `CCWATCH_PORT` | `8787` | port for `ccwatch serve` |
| `CCWATCH_IDLE_GRACE` | `15` | seconds `/api/state` may go unread before `ccwatch serve` stops collecting |
| `CCWATCH_SNAPSHOT_TIMEOUT` | `90` | seconds the snapshot collector may run before it is reported as a failed collection |
| `CCWATCH_SNAPSHOT_CADENCE` | `2` | seconds between snapshot collections while the feed is being read; settable so an assertion can make the cadence longer than the exchange it measures |
| `CCWATCH_HOME` | `~/.claude/ccwatch` | where the event log and usage feed live |
| `CLAUDE_CONFIG_DIR` | `~/.claude` | which Claude Code config directory to read |
| `CCWATCH_PROFILE` | | print per-stage timings to stderr |
| `NO_COLOR` | | disable colour |

Colour is never the only thing carrying a meaning — every severity also has a
distinct word, so `ccwatch once | grep HUNG` works, and so does a screen reader.

## Tests

```bash
./tests/run.sh          # shellcheck + 188 assertions
```

CI runs the same script on macOS, and macOS only: `stat -f` and `ps -o lstart=`
are used in their BSD forms and bash 3.2 is the floor, so a suite green on
Linux would not be testing the thing anyone runs.

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
| let `assign` re-hash a key already in storage instead of returning its stored slot | 1 |
| make the probe step a call counter instead of deriving it from the key | 1 |
| let `place` read `sev`/`cost`/`age` when computing a coordinate | 1 |
| include a remembered-but-unoccupied plot in the extent | 1 |
| drop the `liveKeys` guard from `save`'s eviction | 1 |
| remove the version check from `load` | 1 |
| drop the max-scale clamp from `fit` | 1 |
| stop propagating `parse_failed` from `collect_sessions` through the snapshot and the footer | 2 |
| let `/api/state` disagree with `--json` about `parse_failed` for the same registry | 1 |
| reintroduce a wholesale `innerHTML =` on a refresh-reachable container in `map.html` | 1 |
| add a second `setInterval` or a `requestAnimationFrame` call to the rewritten `map.html` | 1 |
| restore the silent fall-through in `resolve_target`, so a failed snapshot is described as an ambiguous match with a blank count | 2 |
| check a collector's output with `jq -e .` instead of `jq empty`, so a legitimate `null` reads as a failed collector | 1 |
| drop or alter the `SEND_TOKEN` placeholder in the served `map.html` | 1 |
| let `clampIdx`/`scaleFor` fall through the ladder's ends instead of clamping | 2 |
| drop the delta from `panBy` | 1 |
| unclamp `clampPan`'s axis interval | 2 |
| iterate `fitIndex`'s ladder ascending instead of from the largest rung down | 1 |
| drop the centring translation from `centreOn` | 1 |
| resolve `levelFor`'s cold mapping upward instead of downward | 2 |
| let `wheelStep` unwind a reversed gesture instead of resetting on a sign change | 1 |
| let `zoomTo` drift the anchor point instead of solving for the pixel it must land on | 2 |
| accept a stored viewport with the wrong storage version | 1 |
| accept a stored viewport with a non-integer or out-of-range `idx` | 2 |
| accept a stored viewport with a non-finite `tx`/`ty` | 2 |
| skip the once-only latch and re-flip `persistence` on a second throwing storage call | 2 |
| let `intersects` report an overlap for a viewport far outside the world | 1 |
| drop the `volatile` gate from `rowFields`'s `ctx`/`mem` withholding | 1 |
| make `reorderPlan` always return no moves | 1 |
| sort sessions by `sev` alone instead of `max(sev, psev)` | 1 |
| let `nextFocus`'s `ArrowDown`/`ArrowUp` wrap instead of clamping at the ends | 2 |
| let `focusTarget` return `prevSid` even when it has dropped out of `wantedKeys` | 1 |
| drop `role="listbox"` from `#rosterlist` | 1 |
| drop `role="option"` or the roving `tabindex` from the `.rrow` template | 2 |
| bind the roster's keydown handling to `document` instead of `#rosterlist` | 2 |
| drop the "companion view" clause from `#world`'s `aria-label` | 1 |
| resolve a session absent from a `feed_down`/`warming` payload to `gone` instead of `unknown` | 2 |
| let `flyIdx` return a rung for `"mid"`/`"near"` instead of only `"far"` | 1 |
| let `validateSelection` accept a `sid` that is not session-id-shaped | 1 |
| re-flip `persistence` back to `"ok"` after a throwing selection read/write | 2 |
| let `saveSelection(setItem, null)` leave the previous sid's record in place | 1 |
| word the tombstone with the same leading clause as a `statements()` sentence | 1 |
| merge the selection ring into a status-appearance `.agent.*` rule instead of its own `.agent.selected .hit` | 1 |
| drop the reason or the measured age from the feed-down sentence | 1 |
| leak an age into the warming sentence | 1 |
| hardcode the unreadable count instead of reading `cond.unreadable` | 1 |
| treat `unreadable: 0` as truthy, printing "0 registry file(s)" | 1 |
| always render the empty-sessions sentence regardless of `empty` | 1 |
| drop the `trust === "ok"` gate `statements()` enforces on its own `empty` output | 2 |
| leak the down/empty sentences into each other instead of keeping the four pairwise distinct | 1 |
| drop `unreadable` when the feed is down, instead of keeping it additive | 1 |
| word the tombstone with the same leading clause as the feed-down sentence | 1 |
| move `renderRoster`'s call in `applyFeed` ahead of the `VOLATILE =` line | 1 |
| toggle the selection class on a queried child (e.g. inside `.figart`) instead of on `g` itself | 2 |
| drop `clampWidth`'s upper or lower bound, or let it return the raw width unclamped | 1 |
| drop the `WIDTH_DEFAULT` fallback for a non-finite or non-number width | 1 |
| let `stacked` disagree with `STACK_BREAKPOINT` about where the panel stacks | 2 |
| accept a stored width record with a non-finite or non-number `w` | 1 |
| drop `role="separator"`, `tabindex="0"`, or an `aria-value*` attribute from `#rdivider` | 3 |

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

It writes nothing except its own event log, its CPU-sample cache in `$TMPDIR`,
and — only when you run `install-hooks` and confirm — your `settings.json`.
The docked agent roster panel (`web/roster.js`) is unrelated despite the
name-collision: it writes only the browser's own storage, never
`~/.claude/ccwatch/roster.json` — see [Selecting a row flies the camera
there](#selecting-a-row-flies-the-camera-there-and-remembers-the-choice).

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

## Contributing

Patches welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). The one thing to know
in advance is that every assertion here has been mutation-checked, and new ones
are expected to be: break the implementation in the way your assertion
describes, watch it fail, then restore. [CLAUDE.md](CLAUDE.md) states the
invariants in full, for humans and agents alike.

Security-relevant reports go through [SECURITY.md](SECURITY.md) rather than a
public issue. That file also lists exactly what `ccwatch` reads and writes, if
you would rather judge the risk yourself than take the summary above on trust.

## Licence

MIT. See [LICENSE](LICENSE).
