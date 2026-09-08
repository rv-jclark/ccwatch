# Feature Specification: Map — identity-derived world layout, incremental rendering, four distinct failure states

**Feature Branch**: `002-map-stable-world`

**Created**: 2026-09-08

**Status**: Draft

**Input**: Roadmap `city-map`, entry `map-stable-world` — "Rebuild the drawing model of `web/map.html` (replace the existing /map — do not add a third page) so that the city's geography is derived from identity and never re-flows, and so a tick that fails does not empty the map."

## Overview

`/map` is the view a person leaves open on a second screen and glances at. That
only works if the glance is cheap, and a glance is only cheap if the thing they
are looking for is where it was last time. Today it is not: the map is rebuilt
from scratch every 3 seconds, into an order chosen by severity.

Three specific defects follow from that drawing model, all confirmed against the
current code on 2026-09-08:

1. **The map re-flows on status.** Projects are sorted by their worst
   inhabitant's severity (`web/map.html:740-744`) into a responsive CSS grid
   (`web/map.html:46`). A session going from `busy` to `waiting` moves its
   project to the front, which moves every other project. The comment sitting
   directly above that sort (`web/map.html:710-712`) claims the map "does not
   reorder itself into a different arrangement each time you glance at it" —
   the code does the opposite of what its own comment promises. This is
   Constitution XIII, in the file that most needs it.

2. **A refresh destroys the view.** The whole map is replaced with
   `$("map").innerHTML = …` on every tick (`web/map.html:746`), so a hover, a
   text selection and any per-figure state are discarded every 3 seconds. The
   peer wires are positioned from measured DOM rectangles
   (`web/map.html:385-432`), so they must be re-measured after each of those
   rebuilds — and could not survive a camera transform at all.

3. **A failed tick reads as a healthy, empty city.** `if (s.warming) return`
   (`web/map.html:707`) leaves the previous drawing standing with only a footer
   note. The payload's snapshot `error` — which the table view does surface
   (`web/index.html:339`) — is never read by the map at all, so a collection
   that has been failing for minutes draws the retained rows, retained context
   percentages and retained memory figures as though they were current
   (Constitution III), while a host with genuinely no sessions gets the same
   `No live sessions` line as a broken feed (Constitution IV).

There is a fourth fact that cannot be rendered at all today, because nothing
carries it. `PARSE_FAILED` counts registry files that would not parse
(`bin/ccwatch:188`), and it reaches **nothing** — not the terminal footer that
formats it (`bin/ccwatch:1129-1145`), not `ccwatch doctor` (`bin/ccwatch:3087`),
and no payload. It is incremented inside a pipeline and read from the parent
shell, so every increment is lost to a subshell. Verified with a fabricated
registry containing one malformed file beside one good one: `ccwatch once`
prints `1 live` with no unreadable-file note, `ccwatch --json` has no such key
at all, and `ccwatch doctor` says nothing. So "rows that could not be read"
cannot currently be distinguished from "rows that were not there" by any
consumer, terminal included.

This feature rebuilds the map's drawing model so that geography comes from
identity, updates are incremental, and the four ways the picture can be
untrustworthy read as four different sentences. It replaces `/map`; it does not
add a page. It adds no status, severity, verdict or badge that the payload does
not already carry, and it changes nothing about how status is computed.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The city stays where I learned it (Priority: P1)

An engineer keeps `/map` open on a second monitor all day. They learn the shape
of it: their own repository is the building bottom-left, the noisy shared service
is the tall one in the middle of the other org's district. When something needs
them they want to find it by muscle memory — glance, see the raised arm in the
bottom-left building, act. Today the buildings swap places whenever any session
anywhere changes state, so every glance is a re-read.

**Why this priority**: This is the entry's reason to exist and the reason it is
first in the roadmap — every later map entry (camera, roster, modal) is drawn on
top of a stable world and is meaningless without one. It delivers value alone,
with nothing else in the roadmap built.

**Independent Test**: Fabricate a registry, load the map, note where each
building sits, then change one session's status and refresh. Every building,
zone and figure must be at the same coordinate. Reload the page and it must
still be. Both are observable without any other part of this feature.

**Acceptance Scenarios**:

1. **Given** a map showing several projects, **When** one session changes from
   working to blocked, **Then** no district, building, zone or figure changes
   coordinate, and only appearance changes.
2. **Given** a map showing several projects, **When** the page is reloaded,
   **Then** every district, building, zone and figure is at the coordinate it
   was at before the reload.
3. **Given** a map with existing buildings, **When** a project that has never
   been seen before appears, **Then** it is placed in unoccupied space and
   nothing already placed moves.
4. **Given** a session that exits and later returns under the same identity,
   **When** it reappears, **Then** it reappears at the coordinate it previously
   held.
5. **Given** two sessions in the same repository on different branches,
   **When** the map is drawn, **Then** they are in the same building and in
   different zones of it, each zone labelled with its branch.
6. **Given** a directory with no git remote, **When** the map is drawn, **Then**
   it is in its own district, visibly labelled as having no repository, and it
   is never placed inside a real organisation's district.

---

### User Story 2 - A refresh does not interrupt what I am doing (Priority: P1)

The same engineer clicks a figure to read what it is doing, and starts selecting
a line of its output to paste into a ticket. Three seconds later the refresh
lands. Today that wipes the map underneath, dropping their hover, their
selection and anything they were pointing at.

**Why this priority**: Equal-first with Story 1 because the two are the same
promise — the view holds still — and because the later roadmap entries put a
modal and a roster on this page, both of which the current rebuild would
destroy on every tick. It is independently valuable: the inspector already
exists and is already usable, and this makes it usable *while the map is live*.

**Independent Test**: Open the inspector, start a text selection, hover a
figure, and let at least two refresh cycles pass with the fixture changing
underneath. All three must survive.

**Acceptance Scenarios**:

1. **Given** the inspector is open on a figure, **When** two refresh cycles
   pass, **Then** the inspector stays open on the same session with its
   conversation, ask panel and send box intact.
2. **Given** a text selection inside the page, **When** a refresh lands,
   **Then** the selection is still there.
3. **Given** the pointer is resting on a figure, **When** a refresh lands,
   **Then** the hover state and any tooltip are still there.
4. **Given** a session disappears from the payload, **When** the next refresh
   lands, **Then** its figure is removed and everything else is left alone.
5. **Given** the map is drawn, **When** refreshes land with no change in the
   payload, **Then** nothing on the page is recreated.

---

### User Story 3 - A broken feed says which way it is broken (Priority: P2)

The engineer glances over and the map shows six figures, all idle, no numbers
that alarm. Either the machine is quiet, or the collection has been failing for
four minutes and they are looking at a photograph. Today the map cannot tell
them which, and the numbers inside the figures — context fill, memory — are
drawn from the retained snapshot as if measured now.

**Why this priority**: This is the honesty half of the entry and it is what
Constitution III and IV demand of any live view. It is P2 only because the
stability work is what the rest of the roadmap is blocked on; on its own merits
it is the more dangerous of the two defects, because a map that lies quietly is
worse than one that shuffles.

**Independent Test**: Drive each of the four conditions in turn — server
stopped, snapshot never yet taken, unreadable registry rows present, genuinely
no sessions — and read the four sentences the page shows. They must be four
different sentences, and in the first three the structure must still be drawn
and the volatile numbers must be gone.

**Acceptance Scenarios**:

1. **Given** the map is drawn, **When** the state feed cannot be reached or
   answers with a failure, **Then** the page says the feed is down and what
   went wrong, keeps the districts and buildings drawn, marks the map stale with
   the measured age of the data it is still showing, and shows no context fill,
   no percentage and no memory figure.
2. **Given** the server has started but no snapshot has yet succeeded, **When**
   the map is drawn, **Then** the page says a first snapshot is still being
   taken, and this reads differently from a feed that is down and differently
   from an empty host.
3. **Given** the snapshot reports registry rows that could not be read, **When**
   the map is drawn, **Then** the page states how many rows could not be read
   and points at `ccwatch doctor`, and this reads differently from all three
   other states.
4. **Given** the host genuinely has no live sessions and the snapshot succeeded,
   **When** the map is drawn, **Then** the page says there are no live sessions
   and suggests `ccwatch resume`, and says nothing about staleness or failure.
5. **Given** the payload carries a snapshot error, **When** its session list is
   empty, **Then** the page MUST NOT say there are no live sessions.
6. **Given** a stale or failed state has been shown, **When** a good snapshot
   arrives, **Then** the staleness marking and the withheld numbers return in
   the same tick, with no reload.

---

### User Story 4 - Messages between agents are drawn on the map itself (Priority: P2)

Two sessions are talking to each other across two different repositories. That
crossing line is the thing worth seeing on a map, and it works today — but only
because the map is a flat grid the wires can measure. It must keep working now
that the map is one world.

**Why this priority**: It is an existing capability, and losing it would make
this entry a net regression. It moves in this entry rather than a later one
because introducing a world space without moving the wires breaks a feature
that works today.

**Independent Test**: Fabricate peer traffic in both directions between two
sessions in different projects, plus traffic involving a session that has since
exited, and check the drawn lines and the footer count.

**Acceptance Scenarios**:

1. **Given** peer traffic from A to B and from B to A, **When** the map is
   drawn, **Then** two separate bowed lines are visible, each with an arrowhead
   showing its direction.
2. **Given** an edge carrying more than one message, **When** the map is drawn,
   **Then** a count is shown on that line; **and** an edge carrying exactly one
   message shows no count.
3. **Given** an edge where one end is a session that has exited, **When** the
   map is drawn, **Then** that edge is not drawn, and the footer says how many
   of the total edges were drawn and why the rest were not.
4. **Given** the window is resized, **When** the map redraws, **Then** every
   wire still connects the same two figures.

---

### User Story 5 - The whole city is visible without touching anything (Priority: P3)

Someone opens `/map` for the first time on a laptop. They must see the entire
city, and be able to read which figure is which, without panning, zooming or
learning any controls.

**Why this priority**: The camera proper is a later roadmap entry; this entry
must nevertheless be usable on its own, which means the default view has to fit
and be legible. Without it, the entry ships a world nobody can see.

**Independent Test**: Open the map at a small window size with several
districts present, and confirm the full extent is on screen and figures are
distinguishable. Resize and confirm it refits.

**Acceptance Scenarios**:

1. **Given** any number of districts, **When** the map is drawn, **Then** the
   full extent of the occupied world is within the visible area.
2. **Given** the map is drawn, **When** the window is resized, **Then** the view
   refits to the new size and no coordinate in the world changes.
3. **Given** a district is added or removed, **When** the map redraws, **Then**
   the view refits to the new extent and the positions of everything already
   placed are unchanged.
4. **Given** plots remembered from previous sessions that no longer have any
   occupant, **When** the view is fitted, **Then** those empty plots do not
   enlarge the fitted extent.

---

### Edge Cases

- **A repository with no live session but an unfinished run or a deploy badge.**
  It still has an identity, so it still has a building at its own coordinate,
  and the unfinished run lies in it as today.
- **Two projects whose identities hash to the same plot.** The second one placed
  takes the next plot in a probe order derived from its own identity; the first
  never moves.
- **A project whose remote appears later** (a directory that had no remote, then
  gained one). It is a different identity, so it gets a plot in the real org's
  district; the `no repo` plot it used to occupy is remembered but drawn empty
  and does not enlarge the fitted view.
- **Position storage unavailable, full, or holding entries from an older
  format.** The map must still draw and must still be internally consistent for
  the session; because a plot that silently moves between reloads is exactly the
  "did it move or do I misremember" failure this entry exists to prevent, the
  loss of persistence is stated rather than passed over in silence.
- **The stored set grows without limit** as repositories come and go. It is
  bounded, and what is discarded is what has not been seen for longest — never
  something currently on screen.
- **An unrecognised status token in the payload.** No pose, colour or severity
  is invented for it (Constitution V); it draws as the neutral figure and its
  own token remains readable as text.
- **A session with no branch, or no project name.** It still has a session
  identity and still gets a figure; the missing part is shown as missing, not
  guessed.
- **`prefers-reduced-motion` set.** No figure animates, and every state that
  motion was carrying is still distinguishable without it.
- **A snapshot that fails and then succeeds and then fails again.** Each
  transition is reflected on the next tick, in both directions.
- **The registry is unreadable *and* the host has no sessions.** Both facts are
  stated; the unreadable count is not allowed to be swallowed by the empty-host
  sentence.
- **A single session, a single district.** The fitted view must not zoom one
  figure to fill a 4K screen, nor leave it a few pixels tall.
- **Peer traffic between two sessions in the same building.** The two ends are
  distinct figures at distinct coordinates, so the line is still drawn and
  still bowed.

## Requirements *(mandatory)*

### Functional Requirements

**One world space**

- **FR-001**: `/map` MUST draw its city into a single world space with one
  camera group, replacing the flowing grid; the tool MUST continue to serve
  exactly two pages, and this feature MUST NOT add a third.
- **FR-002**: The world MUST express four nesting levels: organisation as
  district, repository as building, branch as a zone within its building, and
  session as a figure within its zone.
- **FR-003**: The organisation MUST be derived by splitting the repository slug
  already present in the payload; no change to what is collected is required or
  permitted for it.
- **FR-004**: A project directory with no git remote MUST be placed in a
  district of its own, MUST be visibly labelled as having no repository, and
  MUST NEVER be grouped under an organisation (Constitution VI).
- **FR-005**: The world MUST be laid out in whole world units, so that a later
  change of art direction is a change of drawing and not of layout.

**Position from identity only**

- **FR-006**: Every coordinate in the world MUST be a function of identity
  strings alone — organisation, repository slug (or the directory key where
  there is no remote), branch, and session id.
- **FR-007**: No volatile reading MAY influence any coordinate or any spatial
  ordering. Specifically excluded are severity, phase severity, quiet time,
  waited time, status token, context readings, memory figures, cost, and deploy
  state.
- **FR-008**: The severity-ordered arrangement of projects MUST be removed. A
  session changing severity MUST change appearance only.
- **FR-009**: Assignments MUST persist across page loads, so that a layout a
  person has learned survives a reload and a restart of the browser.
- **FR-010**: A newly seen identity MUST be placed in unoccupied space, and
  placing it MUST NOT move anything already placed.
- **FR-011**: An identity that disappears and returns MUST return to the
  coordinate it held.
- **FR-012**: Where two identities compete for the same plot, resolution MUST be
  derived from the identities themselves rather than from the order rows arrive
  in the payload.
- **FR-013**: Persisted assignments MUST be bounded in number, discarding
  longest-unseen entries first and never an entry that is currently drawn.
- **FR-014**: If assignments cannot be persisted or cannot be read back, the map
  MUST still draw and MUST remain self-consistent for the session, and the page
  MUST state that positions will not survive a reload (Constitution IV — this
  failure must not look like an absence).

**Incremental rendering**

- **FR-015**: Each refresh MUST reconcile the drawing against the payload —
  creating, updating and removing individual districts, buildings, zones,
  figures and wires — keyed on the identities in FR-006.
- **FR-016**: No code reached by a refresh MAY replace a container's contents
  wholesale.
- **FR-017**: An open inspector MUST survive a refresh, still bound to the same
  session, with its ask panel, conversation, send box and kill bar intact and
  its content updated in place.
- **FR-018**: A hover, a focus and a text selection MUST survive a refresh.
- **FR-019**: The fitted view MUST survive a refresh, and MUST be recomputed
  only when the set of occupied plots changes or the window is resized.
- **FR-020**: A refresh in which nothing relevant changed MUST leave the drawing
  untouched.

**Peer wires in the world**

- **FR-021**: Message lines MUST be drawn inside the world, computed from world
  coordinates, so that they hold under any transform applied to the camera —
  not from measured screen geometry.
- **FR-022**: Lines MUST remain bowed so that traffic in each direction is a
  separate visible line, and MUST keep an arrowhead indicating direction.
- **FR-023**: A message count MUST be shown on a line only when it carries more
  than one message.
- **FR-024**: A line MUST be drawn only when both of its ends are figures on the
  map.
- **FR-025**: When some edges are not drawn, the footer MUST report how many of
  the total were drawn and state that the remainder involve sessions that have
  exited.

**Four distinct failure renderings**

- **FR-026**: The page MUST render four mutually distinguishable conditions,
  each in its own wording: (a) the feed could not be read; (b) no snapshot has
  yet succeeded; (c) the snapshot reports registry rows that could not be read;
  (d) the snapshot succeeded and there are genuinely no live sessions.
- **FR-027**: In conditions (a), (b) and (c) the districts, buildings and zones
  MUST stay drawn, so a failure cannot present as an empty city.
- **FR-028**: In conditions (a), (b) and (c) the map MUST be marked stale and
  MUST state the measured age of the session data it is still showing, taken
  from the age the payload reports for the snapshot.
- **FR-029**: In conditions (a), (b) and (c) every volatile reading MUST be
  withheld rather than annotated — the context fill drawn inside a figure,
  every percentage, and every memory figure (Constitution III).
- **FR-030**: The early return on a warming payload MUST be removed: a warming
  payload MUST NOT leave a previous drawing standing with only a footnote.
- **FR-031**: An empty session list MUST NOT be rendered as an absence of
  sessions when the payload also reports a snapshot error.
- **FR-032**: When a good snapshot arrives, the staleness marking MUST be
  cleared and the withheld readings restored on that same refresh.

**The unreadable-rows count becomes a fact in the payload**

- **FR-033**: The count of registry files that could not be parsed MUST be
  carried in the snapshot payload, so that `ccwatch --json` and the state feed
  both expose it.
- **FR-034**: The count MUST be the same number in the terminal footer, in
  `ccwatch --json`, in the state feed and in `ccwatch doctor` for the same
  registry — which requires fixing its propagation, since it currently reaches
  none of them.
- **FR-035**: The count MUST be zero only when no file failed to parse; a
  registry containing an unparseable file MUST report a non-zero count.
- **FR-036**: The map MUST render the count from the payload and MUST NOT infer
  it from a short list or any other side effect.
- **FR-037**: No status, severity, verdict or badge MAY be derived in the page.
  Everything the map draws MUST come from a field the payload already carries
  (Constitution XI); the mapping from a payload value to a pose or colour is
  presentation and is permitted, deciding what the value should be is not.

**Static camera, this entry only**

- **FR-038**: The extent of the occupied world MUST be computed and fitted into
  the visible area, once per change of layout and once per resize.
- **FR-039**: Remembered plots with no current occupant MUST NOT enlarge the
  fitted extent.
- **FR-040**: At the fitted scale, each figure MUST be at least as tall as the
  page's body text and MUST be separated from its neighbours by visible space,
  and each building MUST show a readable name, for up to eight districts and
  twenty-five sessions on a 1280x800 viewport.
- **FR-041**: The feature MUST NOT add interactive panning or zooming, semantic
  level-of-detail, or a persisted viewport.

**Everything the page does today keeps working**

- **FR-042**: Clicking a figure MUST open the existing inspector, which MUST
  keep working: the ask panel, the conversation, the send box and the kill bar,
  with their current behaviour and wording.
- **FR-043**: The account-usage gauges MUST keep their current behaviour,
  including withholding a reading past its staleness window and stating how old
  the last one was.
- **FR-044**: The host memory-pressure line MUST keep appearing only at its
  threshold and be absent below it (Constitution XII).
- **FR-045**: The legend, the footer, the live counts and the document title
  MUST keep their current behaviour and wording.
- **FR-046**: Every figure state MUST have a distinct word available as text,
  not colour or shape alone (Constitution VII).
- **FR-047**: The existing send-token source line in the map page MUST be
  preserved verbatim, because an assertion greps the served map page for the
  injected token.
- **FR-048**: Read-only and kill-disabled operation MUST behave exactly as
  today; this feature MUST NOT change any gate, and MUST NOT make a disabled
  capability visible as a control (that belongs to a later entry).

**Event-driven, sprite-ready drawing**

- **FR-049**: Drawing MUST happen only in response to an event — a data change,
  a resize, a pointer or focus interaction. No animation-frame loop and no
  repainting timer MAY be introduced, and the page MUST keep routing everything
  periodic through the single shared scheduler established by the previous
  entry.
- **FR-050**: A figure, a building and a district MUST each be drawn through one
  interchangeable drawing primitive, so that changing the art of any of the
  three touches only that primitive and not the layout.
- **FR-051**: The drawing primitives MUST be prepared for sprite art: pixel art
  must be able to render unsmoothed, and swapping a shape for an image at the
  primitive boundary must not require touching layout, reconciliation or hit
  testing.
- **FR-052**: This feature MUST ship shapes drawn by the page itself. It MUST
  NOT add an image asset, a binary, a font, a fetch from any external origin, or
  any runtime dependency.
- **FR-053**: Motion MUST remain signal-bearing: a working, blocked or suspect
  figure may move, an idle one MUST NOT, and reduced-motion preference MUST
  suppress all of it without losing any distinction.

**Constraints the change inherits**

- **FR-054**: The pages MUST remain static, self-contained files with no build
  step, no package manifest, no bundler and no fetch from an external origin.
- **FR-055**: No new endpoint MAY be added.
- **FR-056**: Any change to the tool script MUST use only the shell forms the
  project already restricts itself to, and MUST leave the linter clean at its
  current severity.

**Tests and documentation**

- **FR-057**: Every new assertion MUST run against a fabricated configuration
  directory with the substituted liveness probe, and MUST NOT read the
  developer's live sessions.
- **FR-058**: The unreadable-rows count MUST be asserted as a server-side
  behaviour — from the tool's own output and from the state feed — not by
  inspecting the page.
- **FR-059**: Every new assertion MUST be mutation-checked against an
  implementation broken in the specific way it describes, and MUST contribute a
  row to the mutation table in the README.
- **FR-060**: The assertion floor MUST be raised to cover the new batch.
- **FR-061**: Where the host cannot supply what an assertion needs, it MUST skip
  with the reason stated rather than fail.
- **FR-062**: The README's map section MUST be rewritten: it currently presents
  the responsive grid as the design. It MUST document the identity-derived
  geography and name the three defects this entry fixes.

### Key Entities

- **District**: One GitHub organisation, or the single district reserved for
  directories with no git remote. Identified by the organisation part of a
  repository slug. Holds buildings.
- **Building**: One repository, or one remote-less directory. Identified by the
  full `owner/name` slug, or by the directory key where there is no remote.
  Holds zones, plus the unfinished runs and deploy badges that belong to that
  repository. Its plot is remembered.
- **Zone**: One branch within a building, identified by its branch name. Holds
  figures. Present so that two worktrees of one repository are distinguishable,
  which is the only thing that tells them apart.
- **Figure**: One live session, identified by its session id. Carries the
  session's appearance — pose, colour, emphasis — from payload fields, plus its
  own text.
- **Plot assignment**: The remembered mapping from an identity string to a
  coordinate. Persisted, bounded, and never rewritten for an identity already
  placed.
- **Wire**: One directed peer edge between two figures, carrying a message
  count. Drawn only when both ends are present.
- **Unreadable-rows count**: How many registry files could not be parsed for the
  snapshot being shown. A new payload fact, sourced where the count is taken.
- **Feed condition**: Which of the four trustworthiness states the page is in,
  determined entirely from payload fields and the outcome of the read.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Across a sequence of refreshes in which sessions change status,
  appear and exit, 100% of districts, buildings, zones and figures that are
  present in consecutive frames occupy identical coordinates in both.
- **SC-002**: After a page reload with the same set of identities, 100% of
  coordinates are unchanged from before the reload.
- **SC-003**: Introducing a new repository changes the coordinate of zero
  previously placed entities.
- **SC-004**: For an unchanged payload, a refresh creates and destroys zero
  drawing elements.
- **SC-005**: An inspector opened on a figure survives at least 10 consecutive
  refreshes still bound to the same session, and a text selection and a hover
  survive at least 2.
- **SC-006**: The four untrustworthy-or-empty conditions produce four texts that
  share no sentence, and each names the specific fact behind it — the read
  failure, the absent first snapshot, the number of unreadable rows, or the
  absence of sessions.
- **SC-007**: In every condition where the data on screen is not current, the
  number of percentages, context fills and memory figures visible is zero, and
  the age stated for the session data equals the true elapsed time since it was
  collected, within the resolution the page displays.
- **SC-008**: A payload carrying a snapshot error and an empty session list
  produces zero occurrences of the empty-host wording.
- **SC-009**: For a registry containing a file that will not parse, the count
  reported by the terminal footer, by `ccwatch --json`, by the state feed and by
  `ccwatch doctor` are all equal and all non-zero — measured against a
  fabricated registry with exactly one such file, which today yields nothing
  anywhere.
- **SC-010**: With peer traffic in both directions between two projects, two
  distinct lines are drawn with correct direction; an edge with one message
  shows no count; an edge with an exited endpoint is not drawn and is accounted
  for in the footer's drawn-of-total figure.
- **SC-011**: With several districts present on a 1280×800 viewport, the entire
  occupied world is within the visible area and every figure is separable from
  its neighbours, with no user interaction.
- **SC-012**: The page performs no work between events: no animation-frame loop
  exists and the page still uses exactly one periodic timer, and the suite fails
  if either changes.
- **SC-013**: Everything the page does today still works: the inspector, the
  gauges with their withholding, the threshold-gated host line, the legend, the
  footer, the counts and the title are unchanged in behaviour and wording, and
  the served page still carries the injected send token.
- **SC-014**: The repository gains no image, binary, font, external reference,
  build step, package manifest or endpoint — checkable by inspection of the
  diff.
- **SC-015**: The full suite passes with the linter clean, with at least five
  new mutation-checked assertions, a matching README mutation-table row for
  each, and the assertion floor raised accordingly.
- **SC-016**: The README's map section no longer describes a responsive grid,
  and names all three defects this entry fixes: the re-flow on status, the
  destroy-on-refresh, and the failure that reads as an absence.

## Assumptions

- **The plot function is hash-then-probe, and the persisted assignment wins.**
  A coordinate is derived from a stable hash of the identity strings; when that
  plot is taken, the next plot in a probe sequence derived from the same
  identity is used. A previously stored assignment is authoritative, which is
  what makes FR-010 and FR-011 hold. A consequence, accepted deliberately: with
  colliding identities the resulting city depends on which was placed first, so
  two browsers that first saw the projects in a different order can show
  different cities. Persistence, not global determinism, is what a person
  actually relies on, and a globally order-independent tie-break would have to
  move an already-placed building — which FR-010 forbids.
- **Stale-state withholding covers the numbers, and the pose stays.** In the
  three untrustworthy states, the readings enumerated in FR-029 are removed and
  the structure and figure states remain, marked stale with their measured age.
  A pose is a state the person needs in order to read the structure at all, and
  Constitution II is satisfied by stating the measurement — the age — beside
  it. If a later reviewer disagrees, the enumeration in FR-029 is the single
  place to extend.
- **Storage for plot assignments is the browser's own local storage**, keyed per
  origin. No server-side persistence is added, so nothing new is written to
  disk, and the runtime state directory is untouched.
- **The unreadable-rows count is exposed as a top-level snapshot field**
  alongside the existing session and unfinished lists, so the state feed carries
  it with no change to the feed's own assembly, and it participates in the
  feed's change validator like any other collected number.
- **The count is a count of files, not of sessions.** A file that will not parse
  costs exactly one from the count, matching what the count already means where
  it is taken.
- **`no repo` remains a single district** shared by all remote-less directories,
  each as its own building, matching how the payload already keys them and how
  the current badge reads. They are grouped with each other, which is not the
  same as being folded into a real organisation.
- **Fitting the view means fitting the world extent to the available area** at a
  uniform scale with the aspect ratio preserved, with a floor on scale so a
  single figure is not blown up to fill the window and a plausible-sized city
  is not shrunk below legibility. Where those two demands conflict — a city too
  large to fit legibly — fitting wins for this entry, and the interactive camera
  that resolves it properly is the next roadmap entry.
- **The payload already carries everything the map draws** apart from the
  unreadable-rows count: the repository slug, branch, session id, status token,
  severities, context, memory, deploys, unfinished runs and peer edges. No other
  collection-side change is needed.
- **Existing assertions that inspect the pages statically continue to apply**,
  including the count of periodic timers and the absence of an animation-frame
  loop; the new drawing model is built to satisfy them rather than to relax
  them.
- **The three later map entries are not started here.** Interactive pan and
  zoom, level-of-detail and persisted viewport, the docked roster, and the
  per-agent modal with a visible kill gate are named as out of scope and are
  deliberately not designed for beyond keeping the world space they will need.

## Out of Scope

- Interactive panning and zooming, semantic level-of-detail, and a persisted
  viewport — roadmap entry `map-camera-lod`.
- The docked, severity-sorted, keyboard-navigable agent roster and camera
  fly-to — roadmap entry `map-roster`.
- Replacing the inspector with a per-agent modal, and making the kill gate
  visible as a disabled control with its reason — roadmap entry
  `map-agent-modal`.
- Any new status, severity, verdict or badge; any change to how status is
  computed; any change to what is collected beyond surfacing the count that is
  already taken.
- Sprite artwork itself. This entry prepares the seam and ships shapes.
