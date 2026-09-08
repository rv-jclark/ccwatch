# Feature Specification: Map — pan, zoom, semantic level-of-detail, persisted viewport

**Feature Branch**: `003-map-camera-lod`

**Created**: 2026-09-08

**Status**: Draft

**Input**: Roadmap `city-map`, entry `map-camera-lod` — "Turn the static fitted view from `map-stable-world` into a navigable camera over the same world space."

## Overview

`map-stable-world` gave `/map` a world: one `<svg id="world">` holding one
`<g id="camera">`, every district, building, branch zone, figure and peer wire
authored inside it in world units by `web/plots.js`, and coordinates derived
from identity so nothing moves when status does. What it deliberately did not
give it is a camera. `applyFit()` (`web/map.html:1237-1245`) runs once per
layout change and on resize: it sets the SVG's `viewBox` to the element's own
pixel size and writes a single `translate(…) scale(…)` onto the camera group
that centres the whole occupied extent. There is no other way to move.

Three consequences, all confirmed against the current code on 2026-09-08:

1. **The whole city is the only view there is.** A figure is 8 × 14 world units
   (`web/plots.js:19`) and its name label is drawn at that size; a branch zone
   label is `font-size:4px` and a building label `5px`
   (`web/map.html:63-65`). Fit clamps the scale at `MAX_SCALE = 3.0`
   (`web/plots.js:28,307`), and with more than a couple of districts the fitted
   scale is well below that, so the text that names a session, its branch and
   its activity is drawn at a size chosen for the extent rather than for
   reading. There is no way to get closer to one building, and no way to back
   off to a coarser summary when there are more sessions than fit legibly.

2. **Everything is drawn at every scale, whether it can be read or not.** The
   renderer emits one node per district, building, zone, figure, badge and wire
   on every tick regardless of how small they land. At a fitted scale the
   zone labels, the `phase/status` wreck badges and the deploy badges are
   sub-pixel; they still cost DOM and still overprint each other. Conversely
   there is no summary of a district — a person looking at a fitted city with
   eighteen sessions cannot see "this district has 8 sessions and one of them
   is waiting on you" without reading eighteen figures.

3. **A resize is the only camera event, and it discards nothing because there
   is nothing to discard.** `addEventListener("resize", …)`
   (`web/map.html:1432-1436`) refits the same extent. Once there is a position
   to hold, a refit is exactly the wrong response: it would throw away where
   the person was looking every time the window changed.

Two more facts constrain how this is built, and both are load-bearing. The peer
wires draw a fixed `stroke-width` between `0.7` and `3.2` world units and a
count bubble at `r: 8` with `font-size: 9` (`web/map.html:648-683`) — at a far
scale those become hairlines and unreadable dots, and at a near scale the
bubble becomes a saucer larger than the building it sits beside. And the
footprint rules from `feed-footprint` are asserted: `tests/run.sh:759-767`
requires **zero** `requestAnimationFrame` and **exactly one** `setInterval` in
each of `web/index.html` and `web/map.html`, and `tests/run.sh:1288-1296`
requires `map.html` to assign `innerHTML` exactly twice. A camera built as a
render loop would break all three.

This feature adds the camera: pan, zoom in discrete steps, keyboard operation,
three semantic levels of detail chosen from the scale with hysteresis, and a
viewport that survives a reload. It changes no coordinate, no payload field, no
endpoint, and no status or severity. It draws less at a distance and more up
close — but a building sits in exactly the same place at every zoom.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Get close enough to read, back off far enough to see (Priority: P1)

An engineer has eighteen sessions across four organisations on screen. They want
to back off to a view where each district says how many sessions it holds and
the worst thing happening inside it, spot the one district that has something
waiting, then zoom into that district until they can read the session's name,
its branch and what it is doing — and then pan one building over to check its
neighbour. Today the only view is the fitted one, at whatever scale eighteen
sessions imply.

**Why this priority**: It is the entry's reason to exist. Without it the map is
a picture whose legibility depends on how many sessions happen to exist, and the
roadmap's own goal — an *interactive, pannable and zoomable* city — is unmet.
It delivers value on its own with no other entry built.

**Independent Test**: Fabricate a registry with sessions across several
organisations, open `/map`, and confirm: at the far level each district shows a
session count and a status word; zooming in twice replaces that with buildings
and their branch zones; zooming in again shows figures with names and activity;
dragging moves the view and the buildings keep their relative positions
throughout. Every step is checkable against a fabricated `~/.claude` with no
live session involved.

**Acceptance Scenarios**:

1. **Given** a fitted city of four districts, **When** the person zooms out one
   step past the fit scale, **Then** each district is labelled with the number
   of sessions it contains and the status word of the worst one, and no branch
   zone label or badge is drawn.
2. **Given** the far view, **When** the person zooms in on a district, **Then**
   buildings appear with their branch zones and the district summary is
   replaced by the district's name — and every building is at the same world
   position it occupied at the far level.
3. **Given** the mid view, **When** the person zooms in again, **Then** figures
   carry their session name and current activity as text.
4. **Given** any zoom level, **When** the person drags the map surface, **Then**
   the view pans with the pointer and no figure inspector opens as a result of
   the drag.
5. **Given** a zoom action anchored under the pointer, **When** the scale
   changes, **Then** the world point that was under the pointer is still under
   the pointer.

---

### User Story 2 - Navigate the city without a mouse (Priority: P1)

A person using a keyboard, or a screen-reader user, must be able to reach every
part of the city and every zoom level. Arrow keys pan, `+` and `-` zoom, `0`
returns to the whole world, and the zoom controls are real buttons they can tab
to and hear announced. A trackpad pinch is a convenience, not the path.

**Why this priority**: Constitution VII — a graphical view must carry an
equivalent textual and operable representation of what it draws. A camera that
can only be driven by a pointer makes the parts of the city it hides
unreachable, which is worse than the static fitted view it replaces. Equal
priority to Story 1 because shipping Story 1 without it is a regression in
reach.

**Independent Test**: With the pointer unused, tab to the zoom controls and
operate them; then press the arrow keys, `+`, `-` and `0` and confirm each moves
the camera as described. Confirm the same keys typed into the reply box do not
move the camera.

**Acceptance Scenarios**:

1. **Given** the page loaded, **When** the person tabs forward, **Then** they
   reach the map surface and the zoom-in, zoom-out and fit controls, each with
   an accessible name that says what it does and what the current zoom is.
2. **Given** focus on the map surface, **When** an arrow key is pressed,
   **Then** the camera pans a fixed amount in that direction, clamped at the
   world bounds.
3. **Given** focus on the map surface, **When** `+` or `-` is pressed, **Then**
   the scale moves exactly one step, anchored at the centre of the viewport.
4. **Given** any camera position, **When** `0` is pressed, **Then** the whole
   world is visible again.
5. **Given** the caret in the reply box or any other editable field, **When**
   `-`, `0` or an arrow key is typed, **Then** the character is typed and the
   camera does not move.
6. **Given** the camera at the maximum zoom step, **When** the person looks at
   the zoom-in control, **Then** it is present and visibly disabled rather than
   absent, and says why.

---

### User Story 3 - The view I left is the view I come back to (Priority: P2)

The map is a thing left open on a second monitor for days, through reloads,
restarts of `ccwatch serve` and window resizes. Having zoomed into the district
that matters, a person should find that view again after a reload rather than
being thrown back to the whole city — and should never be dropped onto empty
ground because the city they had zoomed into is no longer there.

**Why this priority**: It is the same argument as the identity-derived layout in
the previous entry (Constitution XIII) applied to the camera: a view a person
navigates must hold still. It is P2 rather than P1 because the camera is useful
before it is remembered.

**Independent Test**: Zoom and pan, reload, confirm the same view. Clear the
stored viewport, reload, confirm the whole world. Store a viewport far outside
the current world, reload, confirm the whole world and not empty ground.

**Acceptance Scenarios**:

1. **Given** a panned and zoomed view, **When** the page is reloaded, **Then**
   the same scale and the same world point are shown, and the detail level
   matches that scale.
2. **Given** a browser that has never shown the map, **When** the page loads,
   **Then** the whole world is fitted, exactly as the previous entry did.
3. **Given** a stored viewport whose visible rectangle no longer intersects any
   placed district, building, zone or figure, **When** the page loads, **Then**
   the whole world is fitted instead.
4. **Given** a stored viewport that is corrupt, from an older storage version,
   or has a scale that is not a valid step, **When** the page loads, **Then**
   the whole world is fitted and nothing throws.
5. **Given** a browser where `localStorage` throws or is full, **When** the
   person pans and zooms, **Then** the camera works normally for the session and
   the page says the viewport will not be remembered.
6. **Given** a camera zoomed into one district, **When** the window is resized,
   **Then** the scale is unchanged and the world point at the centre of the
   viewport is still at the centre — no refit.
7. **Given** a camera zoomed into one district, **When** a tick adds a new
   repository elsewhere in the world, **Then** the camera does not move.

---

### User Story 4 - Wires and text stay the size they should be (Priority: P2)

The peer wires, their arrowheads and their message-count bubbles, and every
label on the map, must be as readable at the far level as at the near one. A
line that becomes a hairline is a message the person does not see; a count
bubble that becomes a saucer is a message that covers the city.

**Why this priority**: The wires are a feature that works today and the camera
is what would break them, so this is not an enhancement but the cost of the
camera. P2 because the wires are only drawn when peer traffic exists.

**Independent Test**: With a fabricated peer log producing an edge with
`count > 1`, step the camera across the full zoom range and confirm the wire's
apparent thickness, its arrowhead and its count bubble hold their size on
screen, and the label text stays the same apparent size.

**Acceptance Scenarios**:

1. **Given** an edge between two sessions, **When** the camera moves from the
   minimum step to the maximum step, **Then** the line's apparent thickness on
   screen does not change and the arrowhead stays the same apparent size.
2. **Given** an edge with `count > 1`, **When** the camera scale changes,
   **Then** the count bubble and its number keep the same apparent size and stay
   attached to the same point on the line.
3. **Given** any label drawn at the current detail level, **When** the camera
   scale changes within that level, **Then** the label's apparent size on screen
   does not change.

---

### User Story 5 - A camera move costs nothing (Priority: P3)

The map is left open all day and `feed-footprint` exists so that it bills for
nothing when nothing is happening. Panning and zooming must not reintroduce the
cost that entry removed: no animation loop, no per-frame JavaScript, no
re-render of the city to move the view, and no change to the polling cadence or
the pause when the tab is hidden.

**Why this priority**: It is a constraint on how Stories 1–4 are built rather
than a behaviour a person asks for, and the existing assertions already guard
part of it. P3 because it is invisible when satisfied — which is the point.

**Independent Test**: Assert the served pages still contain zero
`requestAnimationFrame` and exactly one `setInterval`, and that the camera's
write path touches only the camera group's transform. Confirm holding an arrow
key or spinning the wheel does not change the number of `/api/state` requests.

**Acceptance Scenarios**:

1. **Given** the camera being panned and zoomed continuously for several
   seconds, **When** the polling is observed, **Then** the request cadence is
   unchanged and no extra snapshot is fetched.
2. **Given** a camera move, **When** the DOM is observed, **Then** no district,
   building, zone, figure or wire node is created, removed or given a new
   coordinate — only the camera group's transform and the detail-level state
   change.
3. **Given** `prefers-reduced-motion: reduce`, **When** a camera move that would
   otherwise ease is made, **Then** the view jumps to the destination
   immediately.
4. **Given** the tab hidden, **When** it is brought back, **Then** the camera is
   where it was left and the visibility-pause behaviour is unchanged.

---

### Edge Cases

- **The world is bigger than the smallest zoom step allows.** With many
  districts on a small window, even the minimum step may not fit the whole
  extent. Fit uses the minimum step and the page says the whole world does not
  fit at this zoom — said only when it is true (Constitution XII), never as a
  standing line.
- **The world is smaller than the viewport.** Fit must not zoom past the
  maximum step, and pan clamping must keep a small world on screen rather than
  letting it be pushed into a corner and off the edge.
- **A trackpad emits dozens of small wheel deltas per gesture.** One flick must
  not cross the whole zoom ladder; deltas accumulate to a threshold before one
  step is taken.
- **A pinch gesture arrives as `ctrl`+wheel.** It moves the same ladder by the
  same steps and never zooms the browser's own page.
- **A drag that starts on a figure.** Past a small movement threshold it is a
  pan, and it must not open that figure's inspector when the pointer is
  released. Below the threshold it is still a click.
- **The pointer leaves the window mid-drag, or a button is released outside
  it.** The drag ends; the camera does not keep following the pointer.
- **A wheel event over the map.** The page behind must not scroll.
- **The occupied extent shrinks** because a district's last session exited,
  leaving the current view outside the new bounds. The camera is clamped back
  into bounds; it is not refitted, because a refit would move the view the
  person chose.
- **A detail-level boundary reached repeatedly.** Stepping up then down across a
  boundary must not flip the level twice for one step, and a tick arriving at
  the boundary must not change the level at all.
- **A zoom step while the inspector is open.** The inspector stays open, keeps
  its scroll position and any half-typed message.
- **The feed is down, warming, has unreadable rows, or found nothing** while the
  camera is zoomed into one building. All four sentences stay readable at that
  zoom, and the volatile readings stay withheld.
- **The stored viewport was written by a different world.** Stored plots and
  stored viewport are separate records; a viewport restored against a world
  whose extent has changed is validated against the current placements before
  it is used.
- **`localStorage` throws** (private mode, full origin quota). The camera works,
  the failure is stated, and nothing is retried in a loop.
- **Zero sessions.** The camera still pans and zooms over an empty world at a
  usable scale, and `0` still fits.

## Requirements *(mandatory)*

### Functional Requirements

#### The camera and the one transform

- **FR-001**: The camera MUST be expressed solely as a translate-and-scale on
  the single existing camera group. No pan or zoom may rewrite a world
  coordinate on any district, building, zone, figure, badge or wire.
- **FR-002**: Zoom MUST move between the entries of a fixed, discrete ladder of
  scale values. Continuous zoom is not permitted. The ladder's values MUST be
  integer-friendly (whole numbers, or reciprocals of whole numbers) so that a
  future sprite atlas maps pixels to whole pixels, and MUST be the same values
  regardless of viewport size or world extent.
- **FR-003**: A wheel or pinch zoom MUST be anchored at the pointer: the world
  point under the pointer before the step is under the pointer after it, to
  within a pixel.
- **FR-004**: A zoom driven by a control or a key MUST be anchored at the centre
  of the viewport.
- **FR-005**: Dragging with the primary pointer button on the map surface MUST
  pan the view one-to-one with the pointer. A drag that exceeds a small movement
  threshold MUST NOT be delivered as a click to whatever was under the pointer
  when it started; a press and release below the threshold MUST still be a
  click. A pointer release, cancel or exit outside the window MUST end the drag.
- **FR-006**: Wheel deltas MUST accumulate to a threshold before one ladder step
  is taken, so a single trackpad gesture cannot cross the whole ladder, and a
  one-pixel event cannot change the scale at all.
- **FR-007**: A wheel or pinch gesture over the map MUST NOT scroll the page or
  zoom the browser's own view.
- **FR-008**: Pan MUST be clamped to the world bounds. When the world at the
  current scale is larger than the viewport, the visible rectangle MUST stay
  within the occupied extent; when it is smaller, the world MUST remain fully
  visible. The city can never be lost off-screen.
- **FR-009**: Zoom MUST be clamped to the ends of the ladder.
- **FR-010**: A resize MUST preserve the current scale and keep the world point
  at the centre of the viewport at the centre of the resized viewport,
  re-applying pan clamping. A resize MUST NOT refit, MUST NOT refetch and MUST
  NOT move any coordinate.
- **FR-011**: A data tick MUST NOT move the camera. When the occupied extent
  changes such that the current view falls outside the new bounds, the camera
  MUST be clamped back into bounds rather than refitted.
- **FR-012**: "Fit" MUST select the largest ladder step at which the whole
  occupied extent is visible, and centre it. When even the smallest step cannot
  show the whole extent, fit MUST use the smallest step and the page MUST say
  that the whole world does not fit at this zoom — a statement present only when
  true.

#### Operable without a mouse

- **FR-013**: Arrow keys MUST pan the camera by a fixed amount per press,
  subject to the same clamping as a drag.
- **FR-014**: `+` and `-` MUST each move the scale exactly one ladder step, and
  `0` MUST fit the whole world.
- **FR-015**: Camera keys MUST be inert while focus is in a text input,
  textarea, or any other editable field, so typing into the reply box is never
  intercepted.
- **FR-016**: Zoom in, zoom out and fit MUST each be a real focusable button
  with an accessible name that states the action, reachable in the tab order and
  with a visible focus indicator.
- **FR-017**: When the camera is at either end of the ladder, the control that
  cannot act MUST be rendered present and disabled with the reason available as
  text, never omitted (Constitution IV).
- **FR-018**: The map surface MUST be focusable and carry an accessible name and
  a statement of how to drive it with the keyboard.
- **FR-019**: The current scale and the current detail level MUST be available as
  text, not implied by the picture alone.
- **FR-020**: A trackpad pinch MAY be supported, and if supported MUST use the
  same ladder and clamping. It MUST NOT be the only way to reach any scale.

#### Zoom is semantic, not merely scale

- **FR-021**: There MUST be exactly three named detail levels — **far**, **mid**
  and **near** — and the name of the current one MUST be available as text.
- **FR-022**: At **far**, districts MUST be drawn with the number of sessions
  they contain and the status word of the worst status inside them. Building
  and zone outlines, figure detail, per-session labels and the per-building
  pipeline and deploy badges are not drawn at this level.
- **FR-023**: At **mid**, buildings MUST be drawn with their branch zones and
  their labels. Per-figure names and activity text are not required at this
  level.
- **FR-024**: At **near**, individual figures MUST be drawn with their session
  name and their current activity as text.
- **FR-025**: A change of detail level MUST NOT change any coordinate. A
  district, building, zone or figure occupies the same world position at every
  level; level of detail changes only what is drawn and how much of it.
- **FR-026**: The detail level MUST be a function of the camera scale with
  hysteresis: the step at which a level is entered while zooming in MUST be
  higher than the step at which it is left while zooming out, so that one step,
  one wheel event or one tick at a boundary cannot flip the level back and
  forth.
- **FR-027**: The session count and the worst status shown at **far** MUST be
  read from the payload's existing `sev` and `psev` values and the status word
  the payload already carries. The view selects a maximum over values the
  payload supplied; it MUST NOT derive, rank or invent a status, severity or
  verdict of its own (Constitution XI), and MUST NOT introduce a status word,
  severity or badge the payload does not already carry.
- **FR-028**: Every aggregate the camera draws MUST carry its distinguishing
  status word as text, not colour alone (Constitution VII). Aggregation MUST NOT
  be able to hide a severity: a session needing attention MUST be visible as a
  word at the far level without zooming in.
- **FR-029**: A fact that a lower detail level stops drawing MUST be carried by
  the aggregate that replaces it, or MUST keep being drawn. Specifically, a
  building marked as holding an unfinished or crashed pipeline (FR-022 stops
  drawing that building's badges at **far**) MUST still be discoverable at the
  far level as a word on the district that contains it. A level of detail may
  draw less; it may not make a claim disappear (Constitution IV).
- **FR-030**: A detail-level change MUST happen once per boundary crossing, on
  the camera event that crossed it — never on a timer and never per frame.

#### Legible under transform

- **FR-031**: Peer wire stroke widths and arrowheads MUST hold a constant
  apparent size on screen across the whole zoom range: neither a hairline at the
  smallest step nor a slab at the largest.
- **FR-032**: The message-count bubble and its number MUST hold a constant
  apparent size across the zoom range and stay attached to the same point on the
  line, keeping the existing rule that it appears only when `count > 1`.
- **FR-033**: Every text label drawn at the current detail level MUST hold a
  constant apparent size as the scale changes within that level.
- **FR-034**: The existing wire behaviours MUST be preserved unchanged: bowed
  paths so A→B and B→A are two lines, the arrowhead, edges drawn only when both
  ends are on the map, and the footer note reporting `drawn/total`.

#### Persisting the viewport

- **FR-035**: The pan and the scale MUST be persisted in `localStorage` under a
  versioned record, separate from the stored plot assignments, and restored on
  load.
- **FR-036**: The first load in a browser with no stored viewport MUST fit the
  whole world.
- **FR-037**: A stored viewport MUST be validated before use. A record that is
  absent, unparseable, of a different version, or whose scale is not a valid
  ladder step or whose pan is not a finite number MUST be discarded and replaced
  by a fit, without throwing.
- **FR-038**: A restored viewport whose visible world rectangle does not
  intersect any placed district, building, zone or figure MUST fall back to fit
  rather than open on empty ground.
- **FR-039**: A visible control MUST reset the camera to fit, and MUST be
  reachable by keyboard as well as pointer.
- **FR-040**: A `localStorage` that throws or is full MUST NOT break the camera.
  The camera works for the session, the fact that the viewport will not be
  remembered is stated as text, and nothing retries in a loop.
- **FR-041**: The restored detail level MUST follow from the restored scale, so
  a reload cannot show a scale at one level with the detail of another.

#### A camera API for the roster, without the roster

- **FR-042**: A documented way to centre the camera on a given world point MUST
  be exposed for the `map-roster` entry to call, with an optional bounded
  animation and an instant jump under `prefers-reduced-motion`. This entry MUST
  NOT build the roster panel, a selection model, or fly-to-on-select behaviour.

#### Footprint

- **FR-043**: The camera MUST NOT introduce a `requestAnimationFrame` loop or a
  repainting `setInterval`. Both pages MUST continue to contain zero
  `requestAnimationFrame` and exactly one `setInterval`.
- **FR-044**: A camera move MUST NOT re-render the scene graph: no node is
  created, removed or repositioned, no payload is re-read, and no reconciliation
  pass runs. Only the camera group's transform, the detail-level state and the
  stored viewport change.
- **FR-045**: A camera move MUST NOT run JavaScript per frame. Any easing MUST
  be a bounded declarative transition that ends, and MUST reduce to an instant
  jump under `prefers-reduced-motion`.
- **FR-046**: The camera MUST NOT change the polling cadence, the
  visibility-driven pause, the conditional-request behaviour or the transcript
  inspector's cadence established by `feed-footprint`.
- **FR-047**: No code on the camera path may assign `innerHTML`; `map.html`
  MUST continue to assign it exactly twice — the once-built legend and the
  markdown turn body.

#### Nothing that worked stops working

- **FR-048**: Identity-derived positions, the stored plot assignments,
  deterministic placement of newly appearing repositories, and incremental
  diffing by `sid` and by building/zone key MUST all be unchanged.
- **FR-049**: The four distinct failure renderings — feed down, snapshot
  warming, registry rows that could not be read, and a genuine absence of
  sessions — MUST remain four different sentences, MUST keep the geography
  drawn, and MUST be readable at whatever zoom the person left the camera at,
  including the most zoomed-in step.
- **FR-050**: Volatile readings MUST remain withheld rather than annotated while
  the feed is not fully trusted (Constitution III), including any reading newly
  drawn at the far level.
- **FR-051**: The transcript inspector, the gauges with their staleness
  withholding, the host-pressure line at its threshold, the legend, the counts,
  the footer and the document title MUST keep their current behaviour and
  wording. The inspector MUST survive a camera move with its scroll position and
  any in-progress message intact.
- **FR-052**: The literal source line `const SEND_TOKEN =
  "__CCWATCH_SEND_TOKEN__";` MUST remain byte-identical, because an existing
  assertion greps the served map page for it.
- **FR-053**: The payload MUST NOT change: no new field, no new endpoint, no
  change to what any collector computes, and no new status, severity or verdict.
  Nothing in the terminal renderer changes.
- **FR-054**: The page MUST remain a static page with inline CSS and JS served as
  it is now: no build step, no dependency to install, no package manifest, no
  CDN fetch at runtime, and no image or binary asset added to the repository.

#### Tests and documentation

- **FR-055**: The camera's decisions MUST be assertable without a browser: the
  ladder and its clamping, fit-step selection, pan clamping, pointer-anchored
  zoom, detail-level selection with hysteresis, and stored-viewport validation
  MUST each be determinable from inputs alone, in the manner `web/plots.js`
  already is. Where the assertion needs a tool the host may not have, it MUST
  skip with the reason stated rather than fail.
- **FR-056**: Every new assertion MUST be hermetic — run against a fabricated
  `~/.claude` under `$WORK` via `CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS`,
  never against live sessions — MUST be mutation-checked (break the
  implementation in the specific way the assertion describes, confirm the
  assertion fails, restore), and MUST add a row to the mutation table in
  `README.md`. `TALLY_FLOOR` MUST be raised. Anything a test starts MUST be
  reaped.
- **FR-057**: `README.md` MUST document what each of the three zoom levels shows
  and why level of detail is semantic rather than a scale factor — that the
  levels change what is drawn and never a coordinate, and that discrete steps
  are what give the levels an unambiguous boundary.
- **FR-058**: `shellcheck -x -S warning` MUST stay clean for `bin/ccwatch` and
  `tests/run.sh`, bash 3.2 forms only, and `./tests/run.sh` MUST remain the only
  test entry point.

### Key Entities

- **Viewport**: what the person is looking at — a scale drawn from the zoom
  ladder and a pan offset, together determining which world rectangle is on
  screen. Persisted, validated on restore, clamped to the world bounds.
- **Zoom ladder**: the fixed, ordered list of permitted scale values. Integer-
  friendly, independent of viewport and world size, and the only scales the
  camera can hold.
- **Detail level**: one of `far`, `mid`, `near` — a named function of the scale,
  with a two-threshold (hysteretic) boundary between neighbours. Determines
  what is drawn, never where.
- **Occupied extent**: the world rectangle covering every placed district,
  building, zone and figure, already computed by the layout. The target of fit
  and the bound for pan clamping.
- **District summary**: at the far level, a session count and the worst status
  word inside a district, both selected from values the payload already carries.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a fitted city of at least four organisations, a person can
  reach a view where one named session's activity is readable in three or fewer
  actions, using only the keyboard.
- **SC-002**: Every building's world position is identical at all three detail
  levels and at every ladder step — verifiable by comparing positions before and
  after a zoom, with zero coordinates changed.
- **SC-003**: Repeatedly stepping the zoom up and down across a detail-level
  boundary changes the level at most once per step, and a data refresh arriving
  while the camera sits exactly at a boundary changes it not at all.
- **SC-004**: A pointer-anchored zoom keeps the world point under the pointer
  within one pixel of the pointer.
- **SC-005**: After a reload, the restored view shows the same scale and the
  same centre world point as before; a first-ever load and any invalid or
  non-intersecting stored viewport show the whole world instead — in every case
  the page shows content, never empty ground.
- **SC-006**: A wire's apparent thickness, its arrowhead and its count bubble
  vary by no more than a pixel of apparent size across the whole zoom ladder,
  and every drawn label's apparent size is constant within a level.
- **SC-007**: Panning and zooming continuously for ten seconds issues no
  additional snapshot requests and leaves the polling cadence unchanged.
- **SC-008**: A camera move creates, removes and repositions zero scene-graph
  nodes.
- **SC-009**: The existing footprint assertions pass unmodified — no
  animation-frame loop on either page, exactly one interval timer per page, and
  exactly two wholesale markup assignments in the map page.
- **SC-010**: Each of the four ways the picture can be untrustworthy is readable
  as its own sentence at the most zoomed-in step as well as at the most zoomed-
  out one, with the geography still drawn.
- **SC-011**: At the far level, a session whose status needs attention is
  identifiable by a word, with no colour perception and no zooming required.
- **SC-012**: With `prefers-reduced-motion: reduce` set, no camera move animates.
- **SC-013**: The whole suite passes with the new assertions counted, every one
  of them shown to fail against a deliberately broken implementation and
  recorded as a row in the mutation table.

## Assumptions

Reasonable defaults chosen where the roadmap entry did not specify. Each is a
decision this spec makes, not an open question.

- **This entry depends on `map-stable-world` (`002-map-stable-world`) being
  merged**, and on nothing else in the roadmap. It assumes what that entry
  delivered and is asserted to deliver: the single camera group, the world-unit
  coordinates and occupied extent produced from identity, the plot store, the
  incremental reconciliation, the world-coordinate peer wires, and the four
  distinct failure renderings. It also assumes `feed-footprint`'s polling,
  visibility pause and conditional responses, which it must leave untouched.

- **The zoom ladder** is a small, fixed set of integer-friendly scales spanning
  roughly an eightfold range — reciprocals of whole numbers below 1 and whole
  numbers at and above it (for example ¼, ½, 1, 2, 3, 4, 6, 8). One world unit
  equals one screen pixel at scale 1, matching the existing `viewBox` convention
  (`web/map.html:1237-1245`). The exact values belong to the plan; the ladder
  being fixed, discrete and integer-friendly is the requirement.
- **The ladder is absolute, not relative to fit.** Anchoring the steps to the
  fit scale would make them non-integer and defeat the sprite-crispness reason
  for having steps at all, so fit snaps to a step rather than the steps being
  derived from fit. The consequence — a world too large for the smallest step —
  is handled by FR-012.
- **The detail-level boundaries** sit on ladder steps, with the entering step
  above the leaving step at each boundary. Roughly: far below scale 1, mid
  around 1–2, near at 3 and above. The concrete steps belong to the plan; the
  hysteresis is the requirement.
- **The arrow-key pan step** is a fixed number of screen pixels per press, so
  the movement feels the same at every scale, with a modifier for a larger jump
  left to the plan.
- **"Does not intersect any content"** (FR-038) means the visible world
  rectangle intersects no placed district, building, zone or figure box.
  Intersecting a gutter inside the extent but no plot counts as not
  intersecting.
- **Any camera easing** is a single bounded transition of at most a couple of
  hundred milliseconds, driven declaratively, and is absent entirely under
  `prefers-reduced-motion`. No easing at all is an acceptable implementation of
  every requirement here.
- **The stored viewport is per-origin and global to the map**, not per-world and
  not per-session, matching how the plot assignments are already stored. Its
  record is versioned so a later change of ladder or storage shape invalidates
  it into a fit rather than restoring nonsense.
- **The far level draws districts only** — buildings, zones, figures and badges
  are not drawn there. This is what makes the level semantic rather than a scale
  factor, and FR-028 is what keeps it honest: nothing a person needs to know is
  hidden by the aggregation, because the aggregate states the worst status word
  it contains.
- **The four failure sentences and the gauges live outside the camera group** in
  page chrome, which is why they are already readable at any zoom; this entry
  keeps them there rather than drawing them into the world.
- **`node` remains optional.** Assertions over camera arithmetic that need it
  skip with the reason stated when it is absent, exactly as the existing
  markdown and plots sections do.

## Out of Scope

Explicitly deferred, with the entry that owns each:

- **The docked agent roster**, its severity ordering, its keyboard navigation,
  its selection state and fly-to-on-select — `map-roster`. This entry exposes
  the centre-on-world-point API that entry will call (FR-042) and builds no
  panel.
- **The per-agent modal** — stats, conversation, chat, focus trapping — and
  making the `--allow-kill` gate visible as a disabled button — `map-agent-
  modal`. The existing `#reply` inspector remains what opens on a figure click.
- **Any payload change**: no new field, no new endpoint, no change to what a
  collector computes, no new status, severity or verdict.
- **Any change to the identity-to-coordinate derivation or the plot storage**
  established by `map-stable-world`. The camera reads the extent and the
  placements; it does not decide them.
- **Sprite art, an atlas, or any image asset.** The discrete integer-friendly
  ladder exists so a future atlas can be crisp; this entry adds no asset.
- **Any change to the terminal renderer, `doctor`, `send`, `kill`, the transcript
  redaction rules, the per-run send token or the `Origin` check.**
