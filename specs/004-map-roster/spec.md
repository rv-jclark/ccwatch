# Feature Specification: Map — docked agent roster, severity-sorted, keyboard navigable, camera fly-to

**Feature Branch**: `004-map-roster-panel`

**Created**: 2026-09-08

**Status**: Draft

**Input**: Roadmap `city-map`, entry `map-roster` — "Add the docked roster panel that owns all volatile ordering and serves as the map's textual representation."

## Overview

`map-stable-world` and `map-camera-lod` between them gave `/map` a city whose
geography comes from identity and a camera that can be flown over it. In doing
so they deliberately took something away.

The page that existed before entry 002 sorted projects by their worst
inhabitant's severity into a responsive CSS grid, on every tick. A session
going from `busy` to `waiting` moved its project to the front of the grid,
which moved every other project — so the answer to "did that agent move, or do
I misremember" was "sometimes, whenever the severity sort changed". That is the
**re-orientation bug**, and entry 002 fixed it by deleting the sort
(`specs/002-map-stable-world/spec.md` FR-008). Since then a figure's coordinate
comes from `owner/name`, the branch and the `sid`, and nothing volatile touches
a position.

What the fix did not do is put the ordering back anywhere. So today:

1. **There is no "what needs me first" on this page at all.** The payload
   arrives sorted needs-you-first — `bin/ccwatch:951` sorts
   `-([.sev, .psev] | max)` then `-(.waited // .quiet // 0)` — and `/map`
   throws that order away by design, keying everything by `sid`
   (`web/map.html:1567`). A person with eighteen sessions must find the one
   with a raised arm by scanning the city. The table view still has the order;
   the map does not.

2. **The city is the only carrier of most of what it claims.** A figure's
   pose, colour, animation and internal context fill are drawn in SVG with
   `aria-hidden="true"` on the art (`web/map.html:366`) and the whole reading
   of the row compressed into an SVG `<title>` (`titleBits`,
   `web/map.html:677-692`) that is reachable by hover and by nothing else. The
   `.agent` groups are not focusable, so the click handler at
   `web/map.html:1248-1256` — the only way to open a session's conversation —
   is pointer-only. The legend explains "raised arm", "bobbing", "tilted, ?"
   and "fill level inside the body" in prose (`web/map.html:322-333`), which
   tells a screen-reader user what the shapes would mean if they could reach
   them. Constitution VII asks for an equivalent textual representation of
   every claim the graphic draws, and a `<title>` on an unfocusable node is not
   one.

3. **`CCWATCH_MAP_CAMERA` has no caller.** Entry 003 shipped
   `centreOn(wx, wy, {animate, idx})`, `fit()` and `current()` and said so:
   "No caller ships with this feature" (`web/map.html:1461-1462`). The
   per-figure world centres it needs are already computed every tick
   (`plots.js` returns `cx`/`cy` per figure, `web/map.html:779`). The API is
   built, tested and unused.

4. **The four failure states read in one place only.** `renderTrust`
   (`web/map.html:1603-1623`) states them above the map. A panel that lists
   sessions and does not repeat them would show its last-known rows with no
   statement that the feed behind them has stopped — which is the exact shape
   of the bug entry 002 fixed on the map itself.

This feature adds the docked roster: one row per session, ordered needs-you-
first from the payload's own `sev`/`psev`, carrying every claim a figure draws
as text, keyboard navigable, and selecting a row emphasises its figure and
flies the camera to it. The ordering lives here and stays out of the city,
because a list is expected to be ordered and a spatial arrangement is expected
to be remembered (Constitution XIII).

It adds no endpoint, changes no collector, changes no terminal output, and
introduces no status, severity or verdict that the payload does not already
carry.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See what needs me, in order, without scanning the city (Priority: P1)

An engineer opens `/map` with eighteen sessions spread over four
organisations. Beside the city is a list. The top row is the session that is
blocked on them, and it says so in words: the session's name, its repository
and branch, the word `waiting`, and how long it has been waiting. Below it are
the two sessions whose runs have crashed, then the busy ones, then the idle
ones. They can read the list top to bottom and stop as soon as they reach
something that does not need them.

**Why this priority**: It is the entry's reason to exist and the half of the
re-orientation fix that entry 002 could not deliver. Without it `/map` has no
"needs you first" ordering anywhere, and finding the one blocked session among
eighteen means scanning a picture. It delivers value with nothing else in this
entry built.

**Independent Test**: Fabricate a registry with sessions at several distinct
severities — one `waiting`, one whose pipeline phase `needs_input`, one
`HUNG?`, one `busy`, one `idle` — open `/map`, and confirm the roster's row
order runs highest-severity first and that each row's text contains its status
word and the measurement behind it. Fully checkable against a fabricated
`~/.claude` with no live session involved.

**Acceptance Scenarios**:

1. **Given** a payload containing sessions at severities 4, 3, 2, 1 and 0,
   **When** the roster renders, **Then** its rows appear in descending order of
   the greater of that session's `sev` and `psev`.
2. **Given** two sessions with the same greater-of-`sev`-and-`psev`, **When**
   the roster renders, **Then** the one with the larger `waited` (or, absent
   that, `quiet`) is listed first, and the order of the two does not change on
   a tick in which neither value changed.
3. **Given** a session whose status word is `HUNG?`, **When** its row renders,
   **Then** the row contains the word `HUNG?` and the silence measurement that
   produced it.
4. **Given** a session that is `waiting`, **When** its row renders, **Then**
   the row contains the word `waiting` and how long it has been waiting.
5. **Given** a session that is honestly `idle` while the run it belongs to has
   crashed, **When** its row renders, **Then** both the session's status word
   and the pipeline's phase and status appear as separate statements, not
   collapsed into one.
6. **Given** a session in a directory with no git remote, **When** its row
   renders, **Then** the row reads `no repo` and names no repository.
7. **Given** the roster is rendered, **When** a tick arrives that changes a
   session's severity, **Then** the roster reorders and no figure on the map
   changes its coordinate.

---

### User Story 2 - Read and operate the city without a mouse or without sight (Priority: P1)

A person using a keyboard, or a screen reader, reaches the roster by tabbing.
It is announced as a list of active agents with a count. Down and up arrows
move between rows, `Home` and `End` jump to the ends, and each row is read out
as one sentence: the session, its repository and branch, its status word, and
the measurement. Pressing `Enter` selects the agent. Everything the drawing
claims — the pose, the colour, the halo, the animation, the level of the
context fill — is in that sentence, because the drawing itself is presented as
a companion to the list rather than as the thing that carries the meaning.

**Why this priority**: Constitution VII, and the reason this entry precedes the
modal. Right now the SVG city is the only carrier of pose, colour, animation
and context fill, and the only way to open a session is a pointer click on an
unfocusable node. Until the roster exists, a screen-reader user can read the
legend's explanation of shapes they cannot reach.

**Independent Test**: With a fabricated registry, confirm every distinct figure
appearance has a corresponding word or phrase in its roster row; confirm the
roster's rows are focusable and that arrow, `Home`, `End` and `Enter` move and
activate the focused row; confirm the list and its rows carry accessible names
and a selected state.

**Acceptance Scenarios**:

1. **Given** the roster has focus on its first row, **When** the person presses
   the down arrow, **Then** focus moves to the next row and only one row is
   tabbable at a time.
2. **Given** focus is anywhere in the roster, **When** the person presses
   `Home` or `End`, **Then** focus moves to the first or last row respectively.
3. **Given** a focused row, **When** the person presses `Enter`, **Then** that
   agent becomes selected.
4. **Given** a session whose figure is drawn bobbing in the `working` colour
   with a context fill at 72%, **When** its row is read as text, **Then** the
   row states the status word, the measurement, and `ctx 72%` — no claim is
   left to colour or motion alone.
5. **Given** a screen reader is reading the page, **When** it reaches the map
   graphic, **Then** the graphic is labelled as a companion view and does not
   present itself as the only representation of the sessions.

---

### User Story 3 - Select an agent and have the city take me there (Priority: P2)

The engineer clicks (or `Enter`s) the top row. The row is marked selected, the
matching figure in the city is emphasised so it can be picked out among its
neighbours, and the camera flies to it — a short animated move, or an instant
jump if the person has asked for reduced motion. They close the browser, come
back later, and the same agent is still selected. When that session finally
exits, the roster says so in the selected row's place rather than quietly
losing the selection — and that sentence is not the same sentence as "the feed
is down".

**Why this priority**: It is what makes the roster part of the map rather than
a sidebar next to it, and it is the first caller of the camera API entry 003
shipped unused. It depends on stories 1 and 2 existing to have rows to select,
which is why it is P2.

**Independent Test**: With a fabricated registry, select a row and confirm the
row carries a selected state, the matching figure carries an emphasis, and the
camera's reported centre has moved to that figure's world position; reload and
confirm the same row is still selected; then serve a payload with that session
removed and confirm the roster states that the selected session is gone.

**Acceptance Scenarios**:

1. **Given** a roster of rows, **When** the person selects one, **Then** that
   row is marked selected, at most one row is selected, and the corresponding
   figure on the map is emphasised.
2. **Given** a selection, **When** it is made, **Then** the camera centres on
   the selected figure's world position, animated by default and as an instant
   jump when reduced motion is preferred.
3. **Given** a selection and a subsequent tick with the same session present,
   **Then** the selection, its row emphasis and the figure emphasis all
   survive, and the camera does not move again.
4. **Given** a selection, **When** the page is reloaded, **Then** the same
   session is selected and its figure is emphasised.
5. **Given** a selection, **When** a tick arrives in which that session is
   absent from an otherwise trusted payload, **Then** the roster states that
   the selected session has gone, in a sentence distinct from the feed-down
   sentence, and the remaining rows continue to render.
6. **Given** a selection, **When** the person selects a different row, **Then**
   the previous row's selected state and the previous figure's emphasis are
   both cleared.
7. **Given** a selected row, **When** the person clicks a figure on the map,
   **Then** the existing inspector opens exactly as it does today.

---

### User Story 4 - Know when the list cannot be believed (Priority: P2)

The engineer leaves `/map` open and `ccwatch serve` stops. The roster does not
keep presenting its rows as current: it states that the feed is down and how
old the sessions it is still showing are, and the context percentages and
memory figures in every row disappear rather than sitting there looking live.
On a cold start it says the first snapshot is still being taken and lists
nothing. If registry files could not be read it says how many and what to run.
And on a healthy host with nothing running, it says there are no live sessions
— which is a different sentence again.

**Why this priority**: Constitution III and IV. A list of sessions is the most
believable thing on the page, so it is the most damaging place for a stale
reading. It is P2 rather than P1 only because the rows must exist first.

**Independent Test**: Drive the page against a payload that is warming, one
that reports a snapshot failure, one with a non-zero unreadable-rows count, and
one with an empty session list, and confirm four distinct sentences and the
correct withholding in each.

**Acceptance Scenarios**:

1. **Given** the feed cannot be read, **When** the roster repaints, **Then** it
   states that the feed is down with the reason and the measured age of the
   sessions it is still showing, and every context percentage and memory figure
   in every row is absent rather than annotated.
2. **Given** a payload reporting that the first snapshot is still being taken,
   **When** the roster repaints, **Then** it says so and lists no rows.
3. **Given** a payload reporting that N registry files could not be read,
   **When** the roster repaints, **Then** it says how many and names
   `ccwatch doctor`.
4. **Given** a trusted payload with no sessions and no snapshot error, **When**
   the roster repaints, **Then** it says there are no live sessions, and that
   sentence never appears at the same time as the feed-down or warming
   sentence.
5. **Given** an untrusted tick followed by a good one, **When** the good
   snapshot arrives, **Then** the roster's statement is cleared and the
   withheld readings return on that same repaint.

---

### User Story 5 - Make the panel the width I need it (Priority: P3)

The engineer works on a laptop. They drag the divider between the roster and
the city to give the list more room to show long branch names, and that width
is still there tomorrow. On a narrow window the panel still shows every row's
status word and the measurement behind it — those are the two things that must
never be the ones truncated away.

**Why this priority**: Real value, but the panel is useful at a fixed default
width, so it is the last thing that must land.

**Independent Test**: Resize the panel, reload, and confirm the width is
restored; render at a narrow viewport and confirm each row still exposes its
status word and measurement as text.

**Acceptance Scenarios**:

1. **Given** the default width, **When** the person drags the divider, **Then**
   the roster and the map both take the new widths and the map's camera keeps
   its current centre rather than refitting.
2. **Given** a resized roster, **When** the page is reloaded, **Then** the
   stored width is restored, clamped to something usable if the window is now
   too small for it.
3. **Given** a viewport too narrow for a side-by-side layout, **When** the page
   renders, **Then** the roster remains usable and every row still exposes its
   status word and its measurement.
4. **Given** the divider, **When** the person operates it from the keyboard,
   **Then** the width can be changed without a pointer.

---

### Edge Cases

- **Selected session absent while the feed is down.** The selection must not be
  reported as "gone" on the strength of an untrusted tick — a feed that cannot
  be read is not evidence that a session exited (Constitution I, IV). The
  gone-sentence is only reachable from a trusted payload.
- **Selected session absent while the snapshot is warming.** Same: nothing has
  been collected, so nothing has been observed to disappear.
- **Selected session returns.** A session whose `sid` reappears in a later
  trusted payload takes its row back and its figure emphasis with it, with no
  further camera move.
- **A stored selection for a session that has never been seen this run.** On
  first load the stored `sid` may not be in the first payload. It is treated
  the same as any absent selection: stated, not silently dropped, and not
  flown to.
- **Local storage unavailable or full** (private mode, quota). Width and
  selection persistence degrade to session-only without taking the panel or the
  map down, matching how plot assignments already behave.
- **A session with no transcript at all** (`quiet` is null) — the row states
  that there is no transcript rather than printing a silence of zero.
- **An `sdk-ts` session.** Its silence measures nothing and must not be
  presented as one; the row carries the word and the note the payload gives it
  and no invented measurement (Constitution VI).
- **A session whose context or memory reading is absent from a trusted
  payload** (statusline past its staleness window, or no process sample). The
  reading is simply not in the row; its absence must not read as `0%` or
  `0 MB`.
- **Two sessions with the same name in different worktrees.** Rows are keyed by
  `sid`, so both appear, distinguished by branch.
- **A payload with far more sessions than fit the panel.** The list scrolls;
  the scroll position and the focused row survive a tick.
- **A figure that is not currently drawn** because the camera's level of detail
  is far. Selecting its row still emphasises the right identity and flies the
  camera to its world position; the roster never depends on a node being
  onscreen.
- **A tick that arrives mid-keyboard-navigation.** Focus stays on the same
  session's row even if that row's index changed because the order changed.

## Requirements *(mandatory)*

### Functional Requirements

**The panel and its rows**

- **FR-001**: `/map` MUST present a docked panel alongside the city containing
  one row per session in the payload's session list.
- **FR-002**: Each row MUST carry, as text: the session's name; its repository
  and branch, or `no repo` for a directory with no git remote; the status
  **word** the payload gives it; and the measurement that justified that word
  (Constitution II).
- **FR-003**: The measurement in FR-002 MUST be the waited time for a session
  blocked on the person, and the transcript silence otherwise, taken from the
  payload's `waited` and `quiet` fields, together with the payload's own note
  for that row.
- **FR-004**: Each row MUST additionally carry, as text, the session's age, its
  pipeline phase and pipeline status when it has one, its context percentage,
  and its memory figure.
- **FR-005**: A session's own status word and its pipeline's phase and status
  MUST be presented as two separate statements, never collapsed into one, for
  the reason already recorded at `bin/ccwatch:938-944`.
- **FR-006**: A row MUST NOT print a measurement the payload did not supply. A
  null silence, a null context reading and a null memory figure are absent from
  the row, never rendered as zero.
- **FR-007**: The panel MUST NOT compute, derive or default any status,
  severity, verdict or note of its own (Constitution V, XI). It reads the
  payload's `token`, `sev`, `psev`, `note`, `quiet`, `waited`, `context`,
  `rss_mb` and `pipeline` fields and formats them.

**Ordering**

- **FR-008**: The roster MUST be ordered needs-you-first: descending by the
  greater of the row's `sev` and `psev`.
- **FR-009**: Rows tied on FR-008 MUST be ordered descending by `waited`, or by
  `quiet` where `waited` is absent, and the ordering MUST be stable — two rows
  tied on every ordering field keep their relative order across ticks.
- **FR-010**: The order produced by FR-008 and FR-009 MUST be the order the
  payload's session list already arrives in, so that the terminal and the
  roster present the same sequence for the same snapshot.
- **FR-011**: No ordering, grouping or severity computed for the roster may
  reach the map. A session changing severity MUST reorder the roster and MUST
  NOT change any district, building, zone or figure coordinate (Constitution
  XIII).

**Accessibility and the map as companion**

- **FR-012**: Every claim a figure draws — its pose, its colour, its halo or
  emphasis, its animation, and the level of its context fill — MUST be
  reachable as text in the corresponding roster row (Constitution VII).
- **FR-013**: The city graphic MUST be presented as a labelled companion to the
  roster rather than as the only carrier of meaning, and MUST NOT be the sole
  route to any claim.
- **FR-014**: Roster rows MUST be focusable, with exactly one row in the tab
  order at a time, and the panel MUST be reachable by tabbing.
- **FR-015**: Within the roster, the down and up arrows MUST move focus between
  rows, `Home` and `End` MUST move focus to the first and last row, and `Enter`
  MUST select the focused row.
- **FR-016**: The panel MUST expose an accessible name identifying it as the
  list of active agents and the number of rows it holds; each row MUST expose
  an accessible name conveying the content required by FR-002, and its selected
  state.
- **FR-017**: Roster keyboard handling MUST NOT capture keys that belong
  elsewhere — the camera's own pan, zoom and fit keys keep working when the
  world has focus, and typing in the reply box never moves focus or the camera.

**Selection**

- **FR-018**: Selecting a row MUST mark that row selected, with at most one row
  selected at a time.
- **FR-019**: Selecting a row MUST emphasise the corresponding figure on the
  map, distinguishably from the figure's status appearance, and MUST clear the
  previous selection's emphasis.
- **FR-020**: Selecting a row MUST centre the camera on the selected figure's
  world position through the camera API entry 003 exposed, animated by default
  and as an immediate jump when the person prefers reduced motion.
- **FR-021**: Selecting a row MUST NOT open the inspector, and a figure click
  MUST continue to open the inspector exactly as it does today.
- **FR-022**: The selection MUST be persisted in the browser's local storage
  and restored on reload, and MUST survive a refresh tick without a further
  camera move.
- **FR-023**: When a trusted payload no longer contains the selected session,
  the roster MUST state that the selected session has gone, in the place the
  selected row occupied, in a sentence distinct from every failure sentence in
  FR-025 — and MUST continue to render the sessions that are present.
- **FR-024**: The statement in FR-023 MUST NOT be produced from an untrusted
  tick: while the feed is down or the snapshot is warming, an absent selected
  session is not evidence that it exited.

**The four failure states, in the roster**

- **FR-025**: The roster MUST state each of these four conditions in its own
  distinct sentence: the feed is down; the first snapshot is still being taken;
  N registry files could not be read; and there are genuinely no live sessions.
- **FR-026**: The unreadable-rows sentence MUST name `ccwatch doctor`, matching
  what the terminal footer already tells the person to run.
- **FR-027**: While the feed is down or the snapshot is warming, the roster MUST
  NOT present its rows as current: it MUST state the condition and, where rows
  are retained, the measured age of the data behind them.
- **FR-028**: While the feed is not fully trusted, every context percentage and
  every memory figure MUST be withheld from every row rather than annotated
  (Constitution III), through the same single gate the map's own withholding
  already uses, so there remains exactly one place to extend the withheld set.
- **FR-029**: The no-live-sessions sentence MUST NOT appear at the same time as
  the feed-down, warming or unreadable-rows sentences, and MUST NOT be produced
  from a payload that also carries a snapshot error.
- **FR-030**: When a good snapshot arrives, the roster's condition statement
  MUST be cleared and the withheld readings restored on that same repaint.

**Width and narrow viewports**

- **FR-031**: The roster's width MUST be adjustable by the person, persisted in
  local storage, and restored on reload — clamped on restore to a width the
  current window can actually accommodate.
- **FR-032**: The width control MUST be operable without a pointer.
- **FR-033**: Changing the roster's width MUST NOT refit or otherwise discard
  the camera's current position.
- **FR-034**: At a narrow viewport the panel MUST remain usable, and every
  row's status word and its measurement MUST remain present as text — these are
  the last two things that may be truncated or hidden.

**What must not change**

- **FR-035**: No change to `bin/ccwatch`'s terminal rendering. `ccwatch once`,
  `ccwatch once | grep HUNG`, `NO_COLOR`, the footer, the gauges and the
  host-pressure line all behave exactly as they do now.
- **FR-036**: No change to the snapshot payload: no new field, no altered
  field, no new status, severity, verdict or badge (Constitution V).
- **FR-037**: No new endpoint. `/api/state` remains the roster's only source,
  read by the poll that already exists.
- **FR-038**: Everything the two previous entries delivered MUST keep working:
  identity-derived positions, incremental reconciliation by key, the peer wires
  in world coordinates, pan, zoom, the three detail levels with hysteresis, the
  persisted viewport, the existing inspector on a figure click with its ask
  panel, conversation, send box and kill bar, the gauges with their staleness
  withholding, the host-pressure line's absence below its threshold, the
  legend, the counts, the document title and the footer.
- **FR-039**: The literal source line
  `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` MUST be preserved unreshaped —
  an existing assertion greps the served map page for it.

**Footprint and delivery constraints**

- **FR-040**: The page MUST remain a static page with inline CSS and JS: no
  build step, no package manifest, no bundler, no runtime dependency and no CDN
  fetch.
- **FR-041**: The roster MUST be rendered event-driven, on a data change, a
  selection, a focus or a resize. No `requestAnimationFrame` loop and no
  additional repainting interval may be introduced; the page keeps exactly one
  interval — the shared visibility-aware scheduler — and the visibility pause
  is untouched.
- **FR-042**: Roster rows MUST be reconciled by `sid` rather than rebuilt
  wholesale, so a focused row, a selected row, a hover, a text selection and
  the panel's scroll position survive a tick. The page's count of `innerHTML`
  assignments MUST NOT increase.
- **FR-043**: Any motion introduced — the camera fly-to, a selection
  transition — MUST be bounded and MUST reduce to an instant result under
  `prefers-reduced-motion`. No new decorative animation.

**Tests and documentation**

- **FR-044**: Every new assertion MUST be hermetic: run against a fabricated
  `~/.claude` under `$WORK` via `CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS`,
  never against live sessions. Anything a test starts MUST be reaped.
- **FR-045**: Every new assertion MUST be mutation-checked — the implementation
  broken in the specific way the assertion describes, the assertion confirmed to
  fail, then restored — and MUST contribute a row to the mutation table in
  `README.md`.
- **FR-046**: `TALLY_FLOOR` in `tests/run.sh` MUST be raised to cover the new
  assertions.
- **FR-047**: Where the host cannot supply what an assertion needs, the
  assertion MUST skip with the reason stated rather than fail.
- **FR-048**: `shellcheck -x -S warning` MUST stay clean for `bin/ccwatch` and
  `tests/run.sh`, and `./tests/run.sh` MUST remain the only test entry point.
  Any shell change MUST use bash 3.2 forms only.
- **FR-049**: `README.md` MUST document why volatile ordering lives in the
  roster and not on the map, naming the re-orientation bug — the per-tick
  severity re-sort that moved a project to the front of the grid and moved
  every other project with it — as the failure that motivated the split.
- **FR-050**: `README.md` MUST document the roster as the map's textual
  representation: what a row states, how it is ordered, how selection and the
  camera fly-to behave, and how the four failure conditions read in it.

### Key Entities

- **Roster row**: the textual representation of one session, identified by its
  `sid`. Holds the session name, repository and branch (or the fact that there
  is none), the status word, the measurement behind it, the age, the pipeline
  phase and status, the context percentage and the memory figure. Every field
  is read from the payload; none is derived. Two of them — context and
  memory — are volatile and are withheld when the feed is not trusted.
- **Roster order**: the sequence of rows, derived only from `sev`, `psev`,
  `waited` and `quiet`. It is the same sequence the payload arrives in and the
  same sequence the terminal prints. It is confined to the panel and never
  reaches a coordinate.
- **Selection**: at most one `sid`, persisted across reloads. It marks a row, it
  emphasises a figure, and it is the reason a camera move happens. It has three
  distinguishable states: present, absent-and-observed-gone (from a trusted
  payload), and unknown (the feed is down or warming).
- **Roster width**: one persisted number, clamped to what the window can
  accommodate, affecting layout only.
- **Feed condition**: the existing four-state reading of the payload — trusted,
  feed down, warming, and the additive unreadable-rows count — which the roster
  now renders alongside the map's own banner, from the same computation rather
  than a second one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a payload where exactly one session is blocked on the person,
  that session is the roster's first row and its row states the word and the
  waited time — so identifying it means reading one row rather than inspecting
  eighteen figures, with no camera movement required.
- **SC-002**: For every session in a fabricated payload, the roster's row text
  contains that session's status word and at least one measurement, for 100% of
  rows.
- **SC-003**: Every distinct figure appearance — each pose, each colour, each
  animation state, and the context fill — has a corresponding word or number in
  its roster row, for 100% of the appearances the page can draw.
- **SC-004**: Every roster row is reachable and every agent selectable using
  only the keyboard, with no pointer input, and the roster and its rows are
  announced with their content and selected state.
- **SC-005**: Reordering the roster across 100 consecutive severity changes
  produces zero coordinate changes on the map.
- **SC-006**: A selection made in one page load is still in effect after a
  reload, and after 20 consecutive refresh ticks, with exactly one camera move
  in total.
- **SC-007**: Each of the four failure conditions produces a distinct sentence,
  and no two of them can be presented simultaneously except the additive
  unreadable-rows count.
- **SC-008**: In every untrusted condition, zero context percentages and zero
  memory figures are present anywhere in the roster.
- **SC-009**: A roster width set by the person is restored on reload, and at a
  360-pixel-wide viewport every row still shows its status word and
  measurement.
- **SC-010**: `ccwatch once`, `ccwatch once | grep HUNG` and `ccwatch --json`
  produce byte-identical output to the pre-change build for the same fixture.
- **SC-011**: The page introduces no animation loop, no additional repainting
  timer, and no additional wholesale replacement of rendered markup — the
  counts the suite already asserts for each are unchanged.
- **SC-012**: With `/map` open and nothing changing, the roster performs zero
  repaints between refresh ticks: every repaint is attributable to a data
  change, a selection, a focus change or a resize.
- **SC-013**: `./tests/run.sh` passes with a raised `TALLY_FLOOR`, every new
  assertion has been shown to fail against its stated mutation, and the
  `README.md` mutation table gained a row for each.

## Assumptions

- **The roster covers session rows, not building badges.** The payload's
  `unfinished` runs and the `deploys` are drawn as badges on buildings, not as
  figures; the roadmap entry specifies "one row per session in the payload" and
  Constitution VII's obligation here is over what a *figure* claims. Their
  existing treatment is unchanged and no roster row is created for them. A
  session that carries a pipeline phase does state that phase in its row, so a
  crashed phase attached to a live session is reachable as text.
- **The panel is a view, not the runtime roster file.** `bin/ccwatch` already
  has a `write_roster` writing `~/.claude/ccwatch/roster` — the record of what
  was live, used by `ccwatch resume`. This entry touches none of it and writes
  nothing to disk; the name collision is unfortunate and is worth a note in
  `README.md` so the two are not confused.
- **The gone-selection statement is pinned where the person will find it.**
  Once a session is absent from the payload it has no `sev` to sort by, so
  "in the row's place" is read as: a tombstone row at the top of the list,
  which is where a needs-you-first list puts anything requiring attention. It
  is dismissible, and dismissing it clears the selection.
- **At a narrow viewport the panel stacks rather than shrinks to nothing.**
  Below a side-by-side breakpoint the roster is presented above the map with a
  bounded height and its rows reflowed onto more than one line, keeping the
  name, status word and measurement. The alternative — a fixed minimum width
  with horizontal truncation — would eventually truncate the two things FR-034
  protects.
- **The camera's fly-to keeps the current zoom** unless the selected figure's
  detail level makes it illegible, in which case it uses the camera API's
  existing level argument to reach the level at which figures carry their
  names. Nothing about the detail-level thresholds or the hysteresis changes.
- **Selection and width are stored as two new local-storage keys**, versioned
  the way the existing plot and viewport records are, and a stored value that
  does not parse is discarded rather than trusted.
- **Opening a session's conversation stays pointer-only in this entry.**
  Reaching the inspector from a roster row, by keyboard as well as pointer, is
  explicitly the next entry's work (`map-agent-modal`, item 6). This entry
  discharges the *reading* half of Constitution VII — every claim reachable as
  text — and leaves the *opening* half to the entry that replaces the
  inspector, rather than building that control twice. The gap is pre-existing
  and is named here so it is not mistaken for delivered.
- **Local storage is the only persistence.** No server-side state, no new file
  under `~/.claude/ccwatch/`, and a throwing or full local storage degrades to
  session-only rather than taking the page down, matching how `plots.js`
  already flips its own `persistence` flag once.
- **The existing feed-condition computation is reused, not duplicated.** The
  roster renders from the same condition object the map's banner already
  derives from the payload and the fetch outcome, so the two can never disagree
  about whether the feed is trusted (Constitution XI applied within the page).
- **Fixtures and README examples stay generic** — `acme/checkout-api`,
  `web-app`, `pricing` — with no real session name, repository slug, feature id
  or cost from a development machine.

## Out of Scope

- The per-agent modal — stats, conversation, chat and kill — and the visible
  `--allow-kill` gate. Those are `map-agent-modal`. Until then the existing
  `#reply` inspector, opened by a figure click, remains what reads and replies.
- Any new endpoint, and any change to `/api/state`, `/api/send`, `/api/kill` or
  `/api/transcript`.
- Any new status, severity, verdict, note or badge, and any change to what a
  collector computes.
- Any change to the terminal renderer, the CLI's flags or its output.
- Any change to the world layout, the coordinate derivation, the detail-level
  thresholds or the persisted viewport beyond the camera move a selection
  causes.
- Any change to the transcript bounding and redaction rules, or to the send
  token and `Origin` checks.
