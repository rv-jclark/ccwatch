# Feature Specification: Map — per-agent modal with stats, conversation, chat, and a visible kill gate

**Feature Branch**: `005-agent-modal`

**Created**: 2026-09-08

**Status**: Draft

**Input**: Roadmap `city-map`, entry `map-agent-modal` — "Replace the existing `#reply` inspector with a per-agent modal, opened from a figure click or from a roster row, and make the kill capability visible when it is disabled."

## Overview

The four entries before this one built the city (`map-stable-world`), the camera
over it (`map-camera-lod`), and the docked roster that owns all volatile
ordering and carries every claim a figure draws as text (`map-roster`). What
none of them touched is the thing you open once you have found the agent you
were looking for: the `#reply` inspector, which predates the rebuild and is
still the panel a click on a figure opens (`web/map.html:320-333`,
`web/map.html:1292-1352`).

Five things are wrong with it, and the first is the one this entry is named for.

1. **A disabled capability is hidden, not shown as disabled.** `renderKill`
   returns early and clears `#killbar` whenever `CAN_KILL` is false
   (`web/map.html:1254`), and `CAN_KILL` is `!!s.can_kill` from the payload
   (`web/map.html:2062`), which is `ALLOW_KILL` server-side — `--allow-kill`
   *and* a send token (`bin/ccwatch:2769`, `bin/ccwatch:2881`). So on the
   default `ccwatch serve`, the whole kill control is absent from the page. An
   operator looking for a way to end a session that is holding 1.8GB finds
   nothing, and an absent control reads as a feature that was never built
   rather than as one turned off by a flag. Constitution IV is explicit about
   this shape: "A capability that is disabled by configuration is shown as
   disabled with the reason, never hidden — hiding it reads as 'not built'."

2. **It is not a modal, and it is not reachable from the roster or from the
   keyboard.** `#reply` is a fixed drawer toggled by an `.on` class
   (`web/map.html:155-159`). Focus is not moved into it except for the reply
   input when sending is possible (`web/map.html:1308`), is not trapped, and is
   not returned to whatever opened it on close (`web/map.html:1311-1316`).
   Escape closes it only while the reply input itself has focus
   (`web/map.html:1340-1343`). The only opener is a document click handler
   matching `.agent[data-sid]` (`web/map.html:1345-1352`), and the `.agent`
   groups are not focusable — so the panel is pointer-only. Entry 004
   deliberately kept a roster row selection from opening it (FR-021,
   `web/map.html:1956-1961`) because selection means "fly there", not "open
   that"; the roster therefore has no opener at all.

3. **The stats the roster row now carries are not in it.** The header shows
   `repo · branch · token` and nothing else (`web/map.html:1295-1296`,
   refreshed at `web/map.html:2074`). The status word's measurement (silence or
   waited time), the age, the context percentage, the memory, the pipeline
   phase and status, the session id, and the peer edges touching this session
   are all in the `/api/state` row — `rowFields` in `web/roster.js:51-78`
   already shapes the first six of them, and `wires` already reads
   `peers.edges` (`web/map.html:867-890`) — and none of them appear in the
   panel you opened in order to decide what to do about the session. You must
   read the row behind the drawer to see them, which is exactly what the drawer
   is covering.

4. **Nothing in it says the feed has stopped.** `renderTrust` states the four
   feed conditions above the map (`web/map.html:1706` onward, from
   `computeFeedCondition` at `web/map.html:1677-1692`). A drawer sitting over
   that region shows its stats, its question and its `frees NMB` figure as
   current while the snapshot behind them is minutes old and the fetch is
   failing. That is the same shape as the bug entry 002 fixed on the map
   itself, re-created one layer up.

5. **Its volatile readings are not withheld.** `applyFeed` sets `VOLATILE`
   from `cond.trust === "ok"` and every roster and figure primitive honours it
   (`web/map.html:2057-2058`), but the inspector's own header is rewritten
   unconditionally (`web/map.html:2071-2075`), and the kill confirmation's
   `frees NMB` figure is written from `row.rss_mb` with no staleness gate
   (`web/map.html:1257-1258`). A memory figure is exactly the kind of number
   that is read as current whatever is beside it (Constitution III).

This feature replaces `#reply` with a per-agent modal: one panel per session,
opened from a figure or from a roster row by pointer or by keyboard, showing
the payload's own stats for that row, the bounded and redacted conversation,
the pending-ask panel, the send control, and a kill control that is present
and disabled — with the flag that would enable it named — when the server did
not opt in.

It adds no endpoint. `/api/state`, `/api/transcript`, `/api/send` and
`/api/kill` are the four that exist and the four that are used. It changes no
collector, no kill semantics, no gate, and no redaction rule, and it introduces
no status, severity or verdict that the payload does not already carry.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Open one agent and see everything the snapshot says about it (Priority: P1)

An engineer has found the session that needs them — from the top of the roster,
or by spotting a raised arm in the city. They open it. In front of them is that
session's name, its status word with the measurement that produced it, how long
it has been silent or has been waiting, its age, its context percentage, its
memory, its pipeline phase and status, its repo and branch, its session id, and
the message edges that touch it. Every one of those is a value the snapshot
already carries; none of them is computed here.

**Why this priority**: This is the reason the panel exists. Today it shows
three of those twelve, and the decision the person is about to make — message
it, wait for it, kill it — depends on the rest.

**Independent Test**: Open the modal for a fixture session whose row carries a
measurement, an age, a context percentage, a memory figure, a pipeline phase
and a peer edge, and assert each one appears with the same text the roster row
and the figure's hover reading give it.

**Acceptance Scenarios**:

1. **Given** a session whose row has `token: "waiting"`, `waited: 900` and
   `note: "input needed"`, **When** its modal is opened, **Then** the status
   word and the measurement behind it are both shown, reading the same as the
   roster row's `.rstatus` for the same snapshot.
2. **Given** a session whose row has no `rss_mb` and no `context`, **When** its
   modal is opened, **Then** those two readings are absent from the panel —
   not `0MB`, not `ctx 0%`, not `-`.
3. **Given** a session with two peer edges naming it and one edge between two
   other sessions, **When** its modal is opened, **Then** the two edges
   touching it are listed with their direction and count, and the third is not.
4. **Given** an open modal, **When** a tick arrives in which that session's
   context percentage has changed, **Then** the panel shows the new value
   without having been rebuilt around the reader.
5. **Given** an open modal whose session had a recorded question, **When** a
   tick arrives in which the question has been answered in that session's own
   terminal and is gone from the row, **Then** the pending-ask panel stops
   showing it.

---

### User Story 2 - See that killing is possible, and why it is not available (Priority: P1)

An operator running the default `ccwatch serve` opens an agent that has gone
quiet holding 1.8GB. The modal shows a kill button, disabled, saying that
killing is disabled and that `ccwatch serve --allow-kill` is the flag that
enables it. They restart the server with the flag, reopen the modal, and the
same button is live — behind the same two-step confirmation, the same
`frees NMB` figure, the same pipeline and mid-turn warnings, and the same
verbatim refusal text as before.

**Why this priority**: The named defect of this entry, and a Constitution IV
violation as it stands. It is also the cheapest thing on this list to get
wrong in the other direction: a kill button that looks live on a server that
will refuse it is worse than none.

**Independent Test**: Render the modal against a payload with
`can_kill: false` and assert a disabled kill control naming `--allow-kill` is
present; render it against `can_kill: true` and assert the control is enabled
and no unconditional kill request can be issued from the disabled state.

**Acceptance Scenarios**:

1. **Given** a snapshot with `can_kill: false`, **When** a modal is opened,
   **Then** a kill control is present, is disabled, and states that killing is
   disabled and names `ccwatch serve --allow-kill` as what would enable it.
2. **Given** a snapshot with `can_kill: false`, **When** the disabled kill
   control is activated by pointer or by keyboard, **Then** no request is made
   and no confirmation step opens.
3. **Given** a snapshot with `can_kill: true`, **When** the kill control is
   activated, **Then** a second, distinct confirmation step appears naming the
   session, the memory it would free, and `claude --resume <sid>` as the way
   back to the conversation.
4. **Given** a session whose row has `pipeline.status: "running"`, **When** the
   confirmation step is shown, **Then** it names the phase and states that
   killing aborts a paid model call.
5. **Given** a session whose row has `token: "busy"`, **When** the confirmation
   step is shown, **Then** it states that the session is mid-turn and a tool
   call may be left half-applied.
6. **Given** an enabled kill that the server refuses, **When** the reply
   arrives, **Then** the refusal's own text is shown verbatim rather than
   reduced to "failed".
7. **Given** an open modal and a tick in which the feed is down, **When** the
   confirmation step is showing a memory figure, **Then** the figure is
   withheld and the panel says the reading is no longer current, rather than
   presenting a stale figure as what would be freed.

---

### User Story 3 - Read what it is doing, without the transcript leaving the machine's own rules (Priority: P1)

The engineer reads the conversation in the modal: the last turns, the model's
text and their own truncated, each tool use reduced to its name and a short
argument summary, each tool result reduced to its size. It follows the session
while they watch, on a slower cadence than the map's own tick. When they are
at the bottom, new turns bring them with them; when they have scrolled up to
read something, a refresh leaves them where they are.

**Why this priority**: The conversation is the other half of why the panel is
opened, and Constitution X is non-negotiable: none of the reduction may be
loosened by moving the panel.

**Independent Test**: Open the modal against a fixture transcript containing a
long assistant message, a tool use with an argument, and a large tool result;
assert the text is truncated, the tool use shows its name and a short argument
summary, the result shows its size and no part of its content, and the poll
cadence while open is slower than the map's tick.

**Acceptance Scenarios**:

1. **Given** a fixture transcript with a tool result of several kilobytes,
   **When** the modal shows the conversation, **Then** the result's size is
   shown and no byte of its content is.
2. **Given** a session that writes no transcript (`sdk-ts`), **When** its modal
   is opened, **Then** the panel says so as a fact about embedded-SDK sessions
   rather than showing an empty conversation.
3. **Given** the transcript request fails, **When** the reply arrives, **Then**
   the panel says the transcript could not be read and gives the reason — not
   an empty conversation.
4. **Given** an open modal scrolled to the bottom, **When** new turns arrive,
   **Then** the view follows them.
5. **Given** an open modal scrolled up into earlier turns, **When** new turns
   arrive, **Then** the scroll position is unchanged.
6. **Given** an open modal, **When** the tab becomes hidden, **Then** the
   conversation's own polling stops with the rest of the page's periodic work.

---

### User Story 4 - Answer the one that is blocked, and be told what actually happened (Priority: P1)

The session is waiting on a question. The modal gives the question the most
prominent place in the panel, with its options, and states plainly that a
dialog can only be answered in that session's own terminal and that a message
sent from here is queued *behind* it rather than answering it. The engineer
sends a message anyway; the panel reports delivered, or queued with the reason,
or failed with the server's real reason. On a `--read-only` server the send
control is there and disabled, saying why.

**Why this priority**: Claiming a message answered a dialog would be the worst
lie this tool could tell — the sentence in `web/map.html:1170-1176` exists for
that reason and must survive the move verbatim in meaning. The three send
outcomes are Constitution VIII.

**Independent Test**: Open the modal for a waiting fixture session with a
recorded question and assert the question, its options and both statements are
present; then for a waiting session with no recorded question and assert the
distinct dialog wording; then exercise the send path for each of the three
outcomes.

**Acceptance Scenarios**:

1. **Given** a session with a recorded question and options, **When** its modal
   is opened, **Then** the question and its options appear above the
   conversation, and the panel states that the dialog can only be answered in
   that session's own terminal and that a message from here is queued behind it.
2. **Given** a waiting session with no recorded question, **When** its modal is
   opened, **Then** the panel says it is waiting, states what it is waiting
   for, and says the dialog's text exists only in that session's terminal —
   wording distinct from the recorded-question case.
3. **Given** a send that the server reports as `delivered`, **When** the reply
   arrives, **Then** the panel says it was delivered and the message box is
   cleared.
4. **Given** a send that the server reports as `queued`, **When** the reply
   arrives, **Then** the panel says it was queued and why.
5. **Given** a send the server refuses, **When** the reply arrives, **Then**
   the server's own reason is shown.
6. **Given** a server started `--read-only`, **When** a modal is opened,
   **Then** the send control is present, disabled, and states that the server
   was started read-only.
7. **Given** any send from the page, **When** the request is made, **Then** it
   carries the per-run token header and is subject to the server's `Origin`
   check, with neither relaxed.

---

### User Story 5 - Operate it as a modal, without losing work to a tick (Priority: P2)

The engineer opens an agent with the keyboard from a roster row. Focus lands
inside the panel. Tab cycles within it and does not reach the map behind.
Escape closes it and focus returns to the row they opened it from. While it is
open, ticks arrive every three seconds: a half-typed message, the scroll
position in the conversation, and an open kill confirmation all survive them.

**Why this priority**: The panel is opened over a live, self-refreshing page.
A drawer that discards a half-typed message every three seconds is not usable,
and a panel that cannot be reached or dismissed from the keyboard is not
reachable at all for some readers (Constitution VII).

**Independent Test**: Open the modal from a roster row by keyboard, assert
focus is inside it and cannot leave by Tab, assert Escape closes it and returns
focus to the row; drive several ticks with a message half-typed and a
confirmation open, and assert both survive.

**Acceptance Scenarios**:

1. **Given** a focused roster row, **When** the opening key is pressed,
   **Then** the modal opens for that row's session and focus moves into it.
2. **Given** a focused figure in the city, **When** the opening key is pressed,
   **Then** the modal opens for that figure's session and focus moves into it.
3. **Given** an open modal, **When** Tab is pressed repeatedly, **Then** focus
   stays within the modal.
4. **Given** an open modal, **When** Escape is pressed, **Then** the modal
   closes and focus returns to the element it was opened from.
5. **Given** an open modal with text half-typed in the message box, **When**
   three ticks arrive, **Then** the text is still there.
6. **Given** an open modal with the kill confirmation step showing, **When**
   three ticks arrive, **Then** the confirmation is still showing and has not
   reverted to the first step.
7. **Given** an open modal whose session disappears from the payload, **When**
   the tick arrives, **Then** the panel says the session is gone rather than
   continuing to present its last stats as current.

---

### User Story 6 - Know when what the modal shows cannot be believed (Priority: P2)

The engineer has a modal open when the server behind it stops answering. The
panel says so, and says how old the reading in front of them is. The stats that
are still true — the repo, the branch, the session id — stay; the ones that are
volatile go. The conversation says it is no longer following.

**Why this priority**: This is the failure-versus-absence rule (Constitution
IV) and the staleness rule (Constitution III) applied to the one surface on
this page that covers the place they are currently stated.

**Independent Test**: Open the modal, then make `/api/state` fail; assert the
modal states the feed is down with the reason and the measured age, that the
volatile readings are withheld, and that the identity fields remain.

**Acceptance Scenarios**:

1. **Given** an open modal, **When** the state fetch fails, **Then** the modal
   states that the feed is down, with the reason and the age of the reading it
   is still showing.
2. **Given** an open modal during a `feed_down` tick, **When** the panel
   redraws, **Then** the context percentage and the memory figure are absent
   and the repo, branch and session id remain.
3. **Given** an open modal while the first snapshot is still warming, **Then**
   the modal says the snapshot is warming and shows no volatile reading and no
   age.
4. **Given** an open modal and a snapshot reporting unreadable registry files,
   **Then** that count is stated, additively, alongside whatever else the
   modal is saying.

---

### Edge Cases

- **A modal open on a session that vanishes.** The row is gone from the next
  payload. The panel states it, keeps the identity it was opened with, and
  offers the way back to the conversation (`claude --resume <sid>`) rather than
  freezing its last stats as current or closing itself out from under the
  reader.
- **A modal open when the kill succeeds.** The session it describes no longer
  exists. The panel reports the kill and closes, and the reader's focus goes
  back to what opened it — not to a row that is no longer there.
- **`can_kill` flips between ticks** (a server restarted with the flag while a
  page is open). The control's enabled state follows the payload; an open
  confirmation step under a `can_kill` that has gone false is closed, and the
  disabled reason is shown instead.
- **A session with no git remote.** Repo reads `no repo`, and it is never shown
  under an organisation it does not belong to (Constitution VI).
- **An `sdk-ts` session.** No transcript, no published status. The conversation
  says why, and nothing in the panel escalates its silence to a hang.
- **A pending question with fifteen options, or a question 4KB long.** The
  panel stays scrollable and the conversation below it does not disappear.
- **A tool result whose reduction is the string `0 bytes`.** Shown as the size
  it is; an absent size is absent, not `0`.
- **Two modals.** Opening a second agent while one is open replaces the
  subject; there is never more than one modal, and the in-progress message of
  the panel being left is not carried to the new subject.
- **A drag that ends on a figure.** A pan never opens the modal, the way it
  never opened the inspector.
- **A send of an over-long message.** The server's size reason is shown, not
  "failed".
- **`prefers-reduced-motion`.** The modal's appearance carries no motion that
  is required to understand it.
- **The narrow, stacked layout** (below the roster's stacking breakpoint). The
  modal is usable at that width: the conversation, the ask panel, the send
  control and the kill control are all reachable.

## Requirements *(mandatory)*

### Functional Requirements

**Opening, closing and subject**

- **FR-001**: The page MUST present exactly one per-agent modal element, which
  replaces the existing `#reply` inspector. There MUST NOT be a second
  inspector surface left on the page.
- **FR-002**: The modal MUST be openable from a figure in the city, by pointer
  and by keyboard, for the session that figure represents.
- **FR-003**: The modal MUST be openable from a roster row, by pointer and by
  keyboard, for the session that row represents.
- **FR-004**: Opening from a roster row MUST NOT be the row's selection action:
  selecting a row keeps its existing meaning (emphasise the figure and fly the
  camera to it) and the modal opens from a distinct, labelled affordance or key.
- **FR-005**: A pan gesture that ends over a figure MUST NOT open the modal.
- **FR-006**: Opening the modal for a second session while one is open MUST
  replace the subject wholly: the previous session's in-progress message,
  confirmation step and outcome text MUST NOT appear under the new subject.
- **FR-007**: The modal MUST close on Escape, on its own close control, and on
  a successful kill of the session it describes.

**Stats, from the payload only**

- **FR-008**: The modal MUST show, for the session it was opened on: name,
  status word, the measurement behind that status word, silence or waited
  time, age, context percentage, memory, pipeline phase and status, repo,
  branch, session id, and the peer edges touching this session.
- **FR-009**: Every value in FR-008 MUST be a verbatim copy of a `/api/state`
  row value or a fixed join of verbatim row values. The modal MUST NOT derive
  a status, severity, verdict or ordering of its own (Constitution XI).
- **FR-010**: The status word MUST be accompanied by the measurement that
  produced it wherever the payload carries one (Constitution II), and MUST
  read identically to the same snapshot's roster row and figure hover reading
  for that session.
- **FR-011**: An absent reading MUST be absent from the panel — never `0`,
  `0%`, `0MB`, `-` or `null`.
- **FR-012**: Volatile readings (context percentage, memory, and any other
  reading the page already treats as volatile) MUST be withheld when the
  snapshot is not trusted, rather than shown with a staleness note
  (Constitution III). Identity and structural fields (name, repo, branch,
  session id) MUST remain.
- **FR-013**: The peer edges shown MUST be only those with this session at one
  end, with their direction and message count as the payload gives them.
- **FR-014**: The whole stats panel MUST stay current as ticks arrive,
  including a pending question that has since been answered elsewhere, without
  being rebuilt around the reader (see FR-040).

**Conversation**

- **FR-015**: The conversation MUST come from `/api/transcript` and MUST keep
  the current treatment exactly: a bounded byte tail, assistant and user text
  truncated, a tool *use* reduced to its name and a short argument summary, and
  a tool *result* reduced to its size and never its content (Constitution X).
- **FR-016**: Transcript text reaching the page MUST be escaped before it is
  formatted, and a markdown link MUST render as text and never as an anchor.
- **FR-017**: While the modal is open, the conversation MUST poll on its own
  cadence, slower than the map's state tick, and MUST stop entirely when the
  tab is hidden.
- **FR-018**: When the reader is at the bottom of the conversation, new turns
  MUST bring the view with them. When the reader has scrolled away from the
  bottom, a refresh MUST NOT change their scroll position.
- **FR-019**: A session that writes no transcript MUST be stated as such, and a
  failed transcript read MUST be stated with its reason. Neither may render as
  an empty conversation (Constitution IV).

**Pending ask**

- **FR-020**: A recorded question MUST keep the most prominent position in the
  panel, above the conversation, with its options.
- **FR-021**: The panel MUST state, verbatim in meaning, that a dialog can only
  be answered in that session's own terminal and that a message sent from here
  is queued *behind* it and does not answer it.
- **FR-022**: A waiting session with no recorded question MUST get its own
  distinct wording, saying what it is waiting for and that the dialog's text
  exists only in that session's terminal.
- **FR-023**: A session that is not waiting and has no recorded question MUST
  show no ask panel at all (Constitution XII).

**Send**

- **FR-024**: Sending MUST use `/api/send` and MUST report the three observed
  outcomes distinctly: delivered, queued with the reason, and failed with the
  server's own reason text (Constitution VIII).
- **FR-025**: Every send MUST carry the per-run token header, and the server's
  `Origin` check MUST remain in force. Neither may be weakened on the grounds
  that the other exists (Constitution IX).
- **FR-026**: On a `--read-only` server the send control MUST be present and
  disabled, stating that the server was started read-only. It MUST NOT be
  hidden (Constitution IV).
- **FR-027**: A disabled send control MUST NOT issue a request when activated.

**Kill**

- **FR-028**: When the payload reports killing is not permitted, the modal MUST
  render a **disabled** kill control that states killing is disabled and names
  `ccwatch serve --allow-kill` as the flag that would enable it. The control
  MUST NOT be omitted (Constitution IV).
- **FR-029**: A disabled kill control MUST NOT issue a request and MUST NOT
  open the confirmation step when activated.
- **FR-030**: When killing is permitted, the control MUST keep its existing
  two-step confirmation, and the second step MUST name the session, the memory
  it would free — taken from the same snapshot the map drew — and
  `claude --resume <sid>` as the way back to the conversation.
- **FR-031**: The confirmation step MUST warn when the session is running a
  pipeline phase (naming the phase, and that killing aborts a paid model call)
  and when the session is mid-turn (that a tool call may be left half-applied).
- **FR-032**: A refusal from the kill endpoint MUST be shown verbatim. It MUST
  NOT be flattened to "failed", and a refusal, a success and a transport
  failure MUST read as three distinct outcomes.
- **FR-033**: The `frees NMB` figure MUST be subject to the same staleness
  withholding as every other volatile reading (FR-012): during an untrusted
  tick it is withheld and the panel says the reading is not current, rather
  than a stale figure being presented as what would be freed.
- **FR-034**: `can_kill` going false while a confirmation step is open MUST
  close that step and show the disabled reason instead.
- **FR-035**: Nothing about the `/api/kill` endpoint, the `--allow-kill` gate,
  the confirmation requirement or the refusal texts may change. This feature is
  the view over them.

**Modal behaviour**

- **FR-036**: On open, focus MUST move into the modal, and while it is open
  focus MUST be trapped within it.
- **FR-037**: On close, focus MUST return to the element the modal was opened
  from, and MUST land somewhere sensible when that element no longer exists.
- **FR-038**: The modal MUST be announced as a modal dialog to assistive
  technology, with an accessible name identifying the session it describes.
- **FR-039**: The content behind the modal MUST NOT be operable while it is
  open by keyboard; the map's own key handling MUST NOT act on keys pressed
  inside the modal.
- **FR-040**: An in-progress message, the conversation's scroll position, an
  open confirmation step, an outcome message and the current focus MUST all
  survive the 3s state tick and the conversation's own refresh.
- **FR-041**: The modal MUST be usable in the narrow, stacked layout: every
  control in it reachable, and the conversation still readable.

**Failure states inside the modal**

- **FR-042**: The modal MUST state a feed-down condition with its reason and
  the measured age of the reading it is showing, rather than presenting its
  last stats as current.
- **FR-043**: The modal MUST state a warming condition without an age and
  without any volatile reading.
- **FR-044**: The modal MUST state an unreadable-registry count additively,
  alongside whatever else it is saying, and MUST NOT state it when the count
  is zero.
- **FR-045**: A session that has disappeared from the payload while its modal
  is open MUST be stated as gone — distinct from a feed failure — with the
  identity it was opened on retained.

**No regressions elsewhere on the page**

- **FR-046**: Identity-derived figure positions, the camera and its
  level-of-detail behaviour, the persisted viewport, the roster's order, its
  selection and its width, and the four distinct feed conditions above the map
  MUST all keep working exactly as they do now.
- **FR-047**: The page MUST remain a static page with no build step, no
  dependency and no runtime fetch of anything but its own assets and the four
  existing endpoints. No new endpoint may be added.
- **FR-048**: No new status, severity, verdict or feed condition may be
  introduced.
- **FR-049**: The refresh path MUST NOT introduce a wholesale `innerHTML`
  assignment on a container it reaches, and MUST NOT introduce a second
  periodic timer or an animation loop — the modal's own polling uses the
  page's single shared timer mechanism.
- **FR-050**: The modal's rendering decisions — which fields are shown, the
  enabled/disabled state of the kill and send controls and the exact reason
  text for each, and the wording of each failure condition — MUST be derived by
  logic that can be exercised hermetically outside a browser, in the way the
  roster's shaping logic already is, so each is assertable.

**Tests and documentation**

- **FR-051**: New assertions MUST be hermetic: a fabricated configuration
  directory, the fake liveness probe, no reliance on live sessions, and
  anything started by a test reaped.
- **FR-052**: Every new assertion MUST be mutation-checked — break the
  implementation in the specific way the assertion describes, confirm the
  assertion fails, restore — with a row added to the mutation table in
  `README.md` for each.
- **FR-053**: The disabled-kill-control-when-ungated behaviour MUST have an
  assertion of its own.
- **FR-054**: `TALLY_FLOOR` MUST be raised to cover the new assertions.
- **FR-055**: `README.md` MUST document the modal and MUST state why a disabled
  kill control with the flag named beats an absent one.
- **FR-056**: `./tests/run.sh` MUST pass, with `shellcheck -x -S warning` clean
  for `bin/ccwatch` and `tests/run.sh`, and where a host cannot supply what an
  assertion needs it MUST skip with the reason stated rather than fail.

### Key Entities

- **Modal subject**: the identity the modal was opened on — session id and name
  — held independently of the payload so the panel can still say something
  when the row disappears.
- **Session row**: one entry of `/api/state`'s `sessions`; the sole source of
  every stat, question, pipeline fact and memory figure the modal shows.
- **Capability flags**: whether sending is possible (a per-run token was
  injected into the page) and whether killing is permitted (`can_kill` in the
  payload). Each has two renderings — enabled, and present-but-disabled with
  its reason.
- **Feed condition**: the page's existing trust reading (ok, warming, feed
  down, plus the additive unreadable count and the empty case), which the modal
  restates for itself rather than relying on a banner it covers.
- **Conversation turns**: the reduced transcript entries — text truncated, tool
  uses named and summarised, tool results reduced to a size.
- **Peer edges**: the message edges from the payload, filtered to those with
  this session at one end, with direction and count.
- **Send outcome**: delivered, queued, or failed with the server's reason.
- **Kill outcome**: killed, refused with the verbatim refusal, or failed with a
  transport reason.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a server started without the kill flag, a reader can tell from
  the modal alone, within 5 seconds and without consulting documentation, that
  killing exists, that it is switched off, and which flag switches it on.
- **SC-002**: 100% of the twelve stats named in FR-008 are present in the modal
  for a session whose row carries them, and read identically to that snapshot's
  roster row for every stat the row also shows.
- **SC-003**: 0 of the modal's displayed values are computed from anything but
  a payload value — verified by an assertion that the modal states no status
  word, measurement or severity absent from the row it was opened on.
- **SC-004**: 0 bytes of tool-result content and 0 clickable outbound links
  reach the page from a transcript, across the fixture set.
- **SC-005**: A half-typed message, a scroll position, an open confirmation
  step and the current focus survive 10 consecutive state ticks with 0 losses.
- **SC-006**: The modal can be opened, read, operated and closed using the
  keyboard alone, from both a figure and a roster row, with focus returning to
  the opener in 100% of closes.
- **SC-007**: Each of the three send outcomes and each of the three kill
  outcomes produces a distinct, reader-distinguishable message; the refusal
  text appears verbatim in 100% of refusals.
- **SC-008**: With the feed failing, 0 volatile readings remain on screen
  inside the modal and the panel states the reason and the age of what it is
  showing.
- **SC-009**: The four feed conditions and the vanished-session case are five
  pairwise-distinct renderings inside the modal.
- **SC-010**: The page still has no build step, no dependency and no endpoint
  beyond the four that already exist; the count of periodic timers on the page
  is unchanged and there is no animation loop.
- **SC-011**: With a modal open and the tab hidden, the page performs no
  periodic work of any kind.
- **SC-012**: `./tests/run.sh` passes, every new assertion has a mutation-table
  row, and `TALLY_FLOOR` matches the new total.

## Assumptions

- **The panel replaces `#reply` in place.** The existing drawer's structure,
  wording and reductions are the starting point, not a rewrite: the ask panel's
  two statements, the kill confirmation's sentences, the send outcome messages
  and the transcript reduction all carry over as they are, and what changes is
  the surface they sit on plus the additions this entry names. This is the
  cheapest reading of "keeps its current prominence" and "verbatim in meaning".
- **The stats reuse the roster's shaping.** `rowFields` in `web/roster.js`
  already produces the status word, its measurement, the age, the pipeline
  phase and status, the truncated question, and the volatile-gated context and
  memory. The modal delegates to it rather than formatting a second time, which
  is what makes SC-002's "read identically" true by construction rather than by
  vigilance. The session id and the peer edges are the two additions it needs.
- **"Follows only when already at the bottom" is partly new.** Today the
  conversation preserves scroll position because reconciliation never removes a
  turn still wanted (`web/map.html:1098-1100`); it does not follow new turns at
  all. The non-disturbance property is kept and the follow-at-bottom property
  is added, which is the behaviour the roadmap entry names.
- **Opening from a roster row is a distinct affordance from selecting it.**
  Entry 004 established that a row's activation flies the camera; a second,
  labelled control or key on the row opens the modal. Merging the two would
  change the roster's behaviour, which this entry is told not to do.
- **Peer edges are matched by session name**, as the map's own wire drawing
  already does (`web/map.html:867-890`), and an edge whose other end is not in
  the payload is stated as such rather than silently dropped.
- **The vanished-session tombstone reuses the roster's wording pattern** rather
  than inventing a fifth sentence shape, and stays distinct from the feed-down
  sentence as the roster's already is.
- **No collector, endpoint, gate or redaction rule changes.** The `--allow-kill`
  gate, the token check, the `Origin` check, the message size limits, the
  transcript byte tail and the reduction rules are all read as fixed.
- **macOS, bash 3.2, no new dependency.** Any test-side helper stays within the
  existing suite's shapes, and `web/*` stays static with inline CSS and JS
  plus the existing separate script files.

## Out of Scope

- Any change to kill semantics, the `--allow-kill` gate, the per-run token, the
  `Origin` check, the message size limits, or the transcript redaction rules.
- Any new endpoint, or any change to what `/api/state`, `/api/transcript`,
  `/api/send` or `/api/kill` return.
- Any new status, severity, verdict or feed condition.
- Any change to the world layout, the camera, the level-of-detail behaviour,
  the persisted viewport, or the roster's order, selection or width beyond what
  opening and closing the modal requires.
- Any change to the table view (`web/index.html`) or to terminal output.
- Bulk actions: killing or messaging more than one session at a time.
- A second modal, a modal history, or deep links to a session's modal.
- Editing, resuming or answering a dialog from the browser — a dialog is
  answered in its own terminal, and this feature states that rather than
  changing it.

**This is the last entry in the `city-map` roadmap. Nothing in it may be
deferred past it.**
