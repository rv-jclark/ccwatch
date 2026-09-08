---

description: "Task list for 003-map-camera-lod"
---

# Tasks: Map — pan, zoom, semantic level-of-detail, persisted viewport

**Input**: Design documents from `/specs/003-map-camera-lod/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. FR-055–FR-056 and the constitution's test discipline require every new
assertion to be hermetic, mutation-checked, and to skip with a stated reason where the host
cannot supply what it needs (`node`). `tests/run.sh` is the only test entry point.

**Organization**: Tasks are grouped by user story per the spec's priorities. Stories 1 and 2
(both P1) share the pointer/keyboard input machinery built in Foundational; Story 3 (P2,
persistence) reuses Foundational's `centreOn`/`clampPan` for resize and adds its own storage
functions; Story 4 (P2, constant apparent size) is a pure CSS/DOM change independent of input
handling; Story 5 (P3, footprint) is mostly a verification pass over the design's own
constraints.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US5 map to the spec's five user stories
- Every task names its exact file path

## Path Conventions

Single-file bash CLI plus two static pages and now three static JS modules — no `src/` tree,
no build step:

- `web/camera.js` — **new**, the pure camera-arithmetic module (contracts/camera-js.md)
- `web/map.html` — the page gaining the camera (contracts/page-camera.md); `bin/ccwatch` is
  **not** modified by this feature (FR-053, FR-054)
- `tests/run.sh` — the only test entry point, gaining a new `camera` section
- `README.md` — the zoom-level documentation and the mutation table

---

## Phase 1: Setup

**Purpose**: Scaffolding every later task builds into — the new module, the page's reference
to it, and the test harness shape — before any story-specific arithmetic or DOM work starts.

- [X] T001 [P] Create `web/camera.js` exporting an empty `window.CCWATCH_CAMERA` object with a
      `module.exports` tail for `node`, mirroring `web/plots.js`'s existing pattern
- [X] T002 [P] Add `<script src="/camera.js"></script>` to `web/map.html`, loaded before the
      script that will call into it
- [X] T003 [P] Add a `camera` section scaffold to `tests/run.sh`: a `node` availability check
      with `t_skip` stating the reason when absent, generation of a `camera-check.js` harness
      file, and parsing of its `PASS|name|detail` output lines — in the same shape as the
      existing `plots` section (`tests/run.sh:1718-1947`)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The ladder, the pure per-move arithmetic, the single writer `applyView()`, and
the new page chrome are consumed by every user story below. Nothing in Phase 3+ can be
implemented, let alone tested, until this phase is complete.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### `web/camera.js` — shared arithmetic (contracts/camera-js.md §1–8)

- [X] T004 [Depends: T001] Implement the frozen constants `LADDER`, `WHEEL_THRESHOLD`,
      `PAN_STEP`, `PAN_STEP_BIG`, `DRAG_SLOP`, `STORAGE_VERSION` in `web/camera.js`
      (contracts/camera-js.md §1)
- [X] T005 [Depends: T004] Implement `scaleFor(idx)` and `clampIdx(idx)` in `web/camera.js`,
      clamping to `[0, LADDER.length - 1]` and flooring non-integer input
      (contracts/camera-js.md §2)
- [X] T006 [Depends: T005] Implement `panBy(view, dx, dy)` in `web/camera.js`, adding
      screen-pixel deltas to `tx`/`ty` with no clamping of its own (contracts/camera-js.md §7)
- [X] T007 [Depends: T005] Implement `clampPan(view, extent, vw, vh)` in `web/camera.js` as the
      single `[min(a,b), max(a,b)]` interval per axis from data-model.md §4, idempotent, and
      returning the centred value on a non-finite `tx`/`ty` (contracts/camera-js.md §3)
- [X] T008 [Depends: T005] Implement `centreOn(view, wx, wy, vw, vh, idx?)` in `web/camera.js`
      (contracts/camera-js.md §7)
- [X] T009 [Depends: T005] Implement `zoomTo(view, idx, ax, ay)` in `web/camera.js`, solving the
      anchored zoom so the world point under `(ax, ay)` stays under it to within a pixel
      (contracts/camera-js.md §6)
- [X] T010 [Depends: T007] Implement `fitIndex(extent, vw, vh)` and `fitView(extent, vw, vh)` in
      `web/camera.js`, returning `{idx, overflow}` and the centred `{idx, tx, ty, overflow}`
      respectively, passed through `clampPan` (contracts/camera-js.md §4–5)
- [X] T011 [Depends: T004] Implement `levelFor(idx, prev)` in `web/camera.js` with the two
      hysteresis bands at `idx 2` and `idx 4` and the downward-resolving cold mapping for
      `prev === null` (contracts/camera-js.md §8, data-model.md §3)
- [X] T012 [Depends: T010, T011] Add mutation-tested assertions to the `tests/run.sh` `camera`
      section for `scaleFor`, `clampIdx`, `panBy`, `clampPan` (both the larger- and
      smaller-than-viewport directions), `centreOn`, `fitIndex`/`fitView` (including the
      overflow case), and `levelFor` (both bands, both directions, and the cold mapping), with
      one row per assertion added to the mutation table in `README.md`

### `web/map.html` — the single writer and new chrome (contracts/page-camera.md §1–2)

- [X] T013 [P] [Depends: T002] Add the new DOM to `web/map.html`: a `<div id="camctl">`
      built with DOM APIs (no `innerHTML`) holding `<button id="zout">`, `<button id="zin">`,
      `<button id="zfit">`, `<span id="camstate" aria-live="polite">`, and
      `<span id="camnote">`, placed in `#wrap` immediately after `#world`
- [X] T014 [Depends: T013] Add `tabindex="0"`, an `aria-label` naming the keys, and an initial
      `data-lod` attribute to `#world` in `web/map.html`
- [X] T015 [Depends: T009, T010, T011, T014] Implement `applyView()` in `web/map.html` as the
      single function that performs exactly the writes in contracts/page-camera.md §1 —
      `transform` on `#camera`, `--k` on `#world`, `data-lod` on `#world`, `disabled`/`title` on
      the three `#camctl` buttons, text into `#camstate`/`#camnote`, and staging `pendingSave`
      with no `setItem` call — and nothing else
- [X] T016 [Depends: T015] Introduce `worldExtent` and `level` page state in `web/map.html`, and
      change `drawWorld()`'s existing `applyFit(extent)` call site (`web/map.html:1237-1245`
      today) to update `worldExtent` and call `applyView()` instead

**Checkpoint**: The ladder, every shared arithmetic function, and the single writer all exist
and are exercised by the test harness. User story implementation can now begin.

---

## Phase 3: User Story 1 — Get close enough to read, back off far enough to see (Priority: P1) 🎯 MVP

**Goal**: Pointer-driven pan and zoom over the stable world, with the three named detail levels
switching what is drawn as the scale crosses a threshold.

**Independent Test**: Fabricate a registry with sessions across several organisations, open
`/map`, and confirm: at the far level each district shows a session count and a status word;
zooming in twice replaces that with buildings and their branch zones; zooming in again shows
figures with names and activity; dragging moves the view and buildings keep their relative
positions throughout.

### Tests for User Story 1

- [X] T017 [US1] Add mutation-tested assertions for `wheelStep`'s accumulation, its
      threshold-crossing step, and its immediate reset on a sign change to the `tests/run.sh`
      `camera` section, with a row per assertion in the `README.md` mutation table
- [X] T018 [US1] Add a mutation-tested assertion reproducing SC-004 — `zoomTo`'s anchored world
      point stays within one pixel of the anchor after the step — to the `tests/run.sh` `camera`
      section, with a mutation-table row in `README.md`

### Implementation for User Story 1

- [X] T019 [US1] [Depends: T017] Implement `wheelStep(acc, event)` in `web/camera.js`, reading
      only `deltaY`/`deltaMode`, normalising lines and pages, and never calling a DOM method on
      the event (contracts/camera-js.md §9)
- [X] T020 [US1] [Depends: T016] Wire `pointerdown`/`pointermove`/`pointerup`/`pointercancel`/
      `lostpointercapture` drag handlers on `#world` in `web/map.html`: `setPointerCapture` on
      the primary button, `panBy` + `clampPan` + `applyView` on move, and a `drag.moved` flag set
      past `DRAG_SLOP` (contracts/page-camera.md §4)
- [X] T021 [US1] [Depends: T020] Update the existing document-level `click` handler in
      `web/map.html` (`web/map.html:1163-1169` today) to return early and clear `drag.moved`
      when it is set, so a pan never opens a figure's inspector
- [X] T022 [US1] [Depends: T019, T020] Wire a `{passive: false}` `wheel` listener on `#world` in
      `web/map.html`: always `preventDefault()`, accumulate via `wheelStep`, and on a step call
      `zoomTo` anchored at the pointer, then `clampPan` and `applyView`
- [X] T023 [US1] Add `touch-action: none` to `#world` in `web/map.html`'s stylesheet, so a
      one-finger drag pans rather than scrolling the page
- [X] T024 [US1] [Depends: T016] Compute `DistrictSummary` — `{n, worst, unfinished}` per
      data-model.md §5 — once per tick in `buildWorldModel` in `web/map.html`, and attach it to
      the existing `districtsByKey[k]` meta object
- [X] T025 [US1] [Depends: T024] Add a `.dsummary` text node to `makeDistrict()` in
      `web/map.html`, written every tick from `DistrictSummary`
- [X] T026 [US1] [Depends: T015] Add the `data-lod` stylesheet rules to `web/map.html`: hide
      `.building`/`.zone`/`.agent`/`.dlabel` at `far`, hide `.dsummary` everywhere except `far`,
      and hide `.alabel` everywhere except `near` (contracts/page-camera.md §3)

**Checkpoint**: Pointer pan and zoom work, the three detail levels switch correctly, and User
Story 1 is independently testable end to end.

---

## Phase 4: User Story 2 — Navigate the city without a mouse (Priority: P1)

**Goal**: Every camera action reachable and announced without a pointer: arrow keys, `+`/`-`/`0`,
and three real, focusable, named buttons.

**Independent Test**: With the pointer unused, tab to the zoom controls and operate them; press
the arrow keys, `+`, `-` and `0` and confirm each moves the camera as described; confirm the same
keys typed into the reply box do not move the camera.

### Tests for User Story 2

- [X] T027 [US2] Add an assertion that `#world` carries `tabindex="0"` and a non-empty
      `aria-label` naming the keys to the `tests/run.sh` `serve` section
- [X] T028 [US2] Add an assertion that `#camctl` contains three real `<button>` elements, each
      with an accessible name, to the `tests/run.sh` `serve` section

### Implementation for User Story 2

- [X] T029 [US2] [Depends: T016] Wire a `keydown` handler on `#world` in `web/map.html` for
      arrow keys — `panBy` by `PAN_STEP` screen pixels, `PAN_STEP_BIG` with `Shift` — followed by
      `clampPan` and `applyView`
- [X] T030 [US2] [Depends: T029, T010, T009] Extend the same `keydown` handler for `+`/`=` and
      `-`/`_` (one ladder step via `zoomTo` anchored at the viewport centre) and `0`
      (`fitView`), each followed by `applyView`
- [X] T031 [US2] [Depends: T029] Add the editable-target guard to the `keydown` handler in
      `web/map.html` — return immediately when the event's target or `document.activeElement`
      matches `input, textarea, select, [contenteditable]` or reports `isContentEditable`
      (FR-015)
- [X] T032 [US2] [Depends: T013, T009, T010] Wire `click` handlers on `#zout`/`#zin` (one ladder
      step via `zoomTo` anchored at the viewport centre) and `#zfit` (`fitView`) in
      `web/map.html`, each followed by `applyView`
- [X] T033 [US2] [Depends: T015] Write `disabled` and a `title`/`aria-description` reason onto
      `#zout`/`#zin` at the ladder's ends inside `applyView()` in `web/map.html`, so the control
      that cannot act is present and disabled rather than removed
- [X] T034 [US2] Add the `#world:focus-visible` outline stylesheet rule to `web/map.html`
- [X] T035 [US2] [Depends: T015] Write `"zoom Nx · level"` into `#camstate` inside `applyView()`
      in `web/map.html`

**Checkpoint**: Every camera action from Story 1 is now also reachable by keyboard and by a
real, named button, with disabled ends and a live text readout.

---

## Phase 5: User Story 3 — The view I left is the view I come back to (Priority: P2)

**Goal**: The pan and scale survive a reload, a resize, and a data tick, and a stored viewport
that no longer makes sense falls back to fit rather than opening on empty ground.

**Independent Test**: Zoom and pan, reload, confirm the same view. Clear the stored viewport,
reload, confirm the whole world. Store a viewport far outside the current world, reload, confirm
the whole world and not empty ground.

### Tests for User Story 3

- [X] T036 [US3] Add mutation-tested assertions for `validateView` against each entry in the
      rejection table in data-model.md §6 — absent, unparseable, non-object/array, wrong `v`,
      non-integer or out-of-range `idx`, non-finite `tx`/`ty` — to the `tests/run.sh` `camera`
      section, with a mutation-table row per case in `README.md`
- [X] T037 [US3] Add mutation-tested assertions for `loadView`/`saveView` round-tripping through
      injected storage functions, and for a throwing storage flipping `persistence` to
      `"unavailable"` exactly once and never retrying, to the `tests/run.sh` `camera` section
- [X] T038 [US3] Add mutation-tested assertions for `visibleWorldRect` and `intersects`,
      including a stored viewport whose rectangle is far outside the world, to the
      `tests/run.sh` `camera` section

### Implementation for User Story 3

- [X] T039 [US3] [Depends: T036] Implement `validateView(raw, ladderLength)` in `web/camera.js`
      per the rejection table in data-model.md §6, never throwing (contracts/camera-js.md §10)
- [X] T040 [US3] [Depends: T039] Implement `loadView(getItem)`/`saveView(setItem, view)` and the
      `persistence` getter (`"ok" | "unavailable"`) in `web/camera.js`
      (contracts/camera-js.md §10)
- [X] T041 [US3] Implement `visibleWorldRect(view, vw, vh)` and `intersects(a, b)` in
      `web/camera.js` (contracts/camera-js.md §11)
- [X] T042 [US3] [Depends: T040, T041, T010, T011] Wire the load order in `web/map.html`
      (contracts/page-camera.md §5): `place()` → `loadView` → `validateView` → (`null` or a
      non-intersecting result falls back to `fitView`) → `levelFor(idx, null)` → `applyView()`
- [X] T043 [US3] [Depends: T042] Stage `pendingSave` in `applyView()` and flush it via
      `saveView` on `pointerup`, on key/button release, and on `visibilitychange` — never on
      `pointermove` — in `web/map.html`
- [X] T044 [US3] [Depends: T040] State "the viewport will not be remembered" in `#camnote` when
      `persistence === "unavailable"`, in `web/map.html`
- [X] T045 [US3] [Depends: T008, T042] Replace the existing `resize` listener
      (`web/map.html:1432-1436` today) with a centre-preserving resize in `web/map.html`: read
      the world point at the centre of the viewport before the new size is applied, update the
      `viewBox`, `centreOn` that same point in the new viewport, clamp, and `applyView` — no
      refit
- [X] T046 [US3] [Depends: T016] Replace `drawWorld()`'s tick-time refit in `web/map.html` with a
      re-clamp-only of the current view against the new extent when `placed.sig` changes, so a
      view that has fallen outside a shrunken extent is pulled back in and an unaffected view
      does not move
- [X] T047 [US3] [Depends: T010, T015] State "the whole world does not fit at this zoom" in
      `#camnote` only while `fitIndex`/`fitView` report `overflow: true`, in `web/map.html`
- [X] T048 [US3] [Depends: T008, T045] Expose `window.CCWATCH_MAP_CAMERA = {centreOn, fit,
      current}` in `web/map.html` (FR-042); `centreOn(wx, wy, {animate: true})` adds the `eased`
      class before applying

**Checkpoint**: The viewport survives a reload, a resize, and a shrinking extent, and never
opens on empty ground.

---

## Phase 6: User Story 4 — Wires and text stay the size they should be (Priority: P2)

**Goal**: Every label, the wire stroke, its arrowhead, and the message-count bubble hold a
constant apparent size across the whole zoom range.

**Independent Test**: With a fabricated peer log producing an edge with `count > 1`, step the
camera across the full zoom range and confirm the wire's apparent thickness, its arrowhead and
its count bubble hold their size on screen, and the label text stays the same apparent size.

### Tests for User Story 4

- [X] T049 [US4] Add an assertion that `.dlabel`/`.blabel`/`.zlabel`/`.dsummary`/`.alabel` and
      the badge classes, plus `.wire path`, use `calc(Npx / var(--k, 1))` to the `tests/run.sh`
      `serve` section
- [X] T050 [US4] Add an assertion that `.bubblescale` carries
      `transform: scale(calc(1 / var(--k, 1)))` to the `tests/run.sh` `serve` section

### Implementation for User Story 4

- [X] T051 [US4] [Depends: T015] Write the `--k` custom property onto `#world` inside
      `applyView()` in `web/map.html`
- [X] T052 [US4] [Depends: T051] Add `calc(Npx / var(--k, 1))` `font-size` rules for `.dlabel`,
      `.blabel`, `.zlabel`, `.dsummary`, `.alabel`, `.norepo-badge`, `.wreck-badge`, and
      `.deploy-badge` to `web/map.html`'s stylesheet
- [X] T053 [US4] [Depends: T051] Add the `calc(var(--wire-w, 1) * 1px / var(--k, 1))`
      `stroke-width` rule for `.wire path` to `web/map.html`'s stylesheet
- [X] T054 [US4] [Depends: T051] Add one `.bubblescale` nesting level around the count bubble's
      circle and text in `makeWire()` in `web/map.html`, keeping the bubble's position a
      data-written attribute on the outer `.bubble` group and moving its size to
      `.bubblescale`'s CSS `transform`

**Checkpoint**: Every label and every wire element holds its apparent size at every rung of the
ladder.

---

## Phase 7: User Story 5 — A camera move costs nothing (Priority: P3)

**Goal**: Panning and zooming reintroduces none of the cost `feed-footprint` removed: no
animation loop, no per-frame JavaScript, no re-render, and no change to polling.

**Independent Test**: Assert the served pages still contain zero `requestAnimationFrame` and
exactly one `setInterval`, and that the camera's write path touches only the camera group's
transform. Confirm holding an arrow key or spinning the wheel does not change the number of
`/api/state` requests.

### Tests for User Story 5

- [X] T055 [US5] Add an assertion that `#camera.eased` sets a bounded `transition` on `transform`
      and that the rule reduces to `none` under `prefers-reduced-motion: reduce` to the
      `tests/run.sh` `serve` section

### Implementation for User Story 5

- [X] T056 [US5] Add the `#camera.eased { transition: transform 180ms ease-out; }` rule and its
      `prefers-reduced-motion` override to `web/map.html`'s stylesheet
- [X] T057 [US5] [Depends: T048, T056] Add a `transitionend` listener on `#camera` in
      `web/map.html` that removes the `eased` class
- [X] T058 [US5] [Depends: T020, T022, T029, T030, T032, T045, T046] Audit every camera event
      handler added in this feature and confirm none calls `tick()`, issues a `fetch`, or
      touches the polling `setInterval` — fix any that do

**Checkpoint**: The existing footprint assertions (`tests/run.sh:759-767`, zero
`requestAnimationFrame`, exactly one `setInterval`) still pass unmodified, and a camera move is
confirmed to touch nothing beyond the camera group's transform, `--k`, and `data-lod`.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, suite bookkeeping, and the end-to-end pass across everything that
cannot be asserted without a browser.

- [X] T059 [P] Document, in `README.md`, what each of the three zoom levels (`far`, `mid`,
      `near`) shows and why level of detail is semantic rather than a scale factor — that the
      levels change what is drawn and never a coordinate, and that discrete steps give the
      levels an unambiguous boundary (FR-057)
- [X] T060 [Depends: T012, T017, T018, T027, T028, T036, T037, T038, T049, T050, T055] Raise
      `TALLY_FLOOR` in `tests/run.sh` by the number of new assertions added across the `camera`
      and `serve` sections
- [X] T061 [Depends: T060] Run `shellcheck -x -S warning bin/ccwatch tests/run.sh` and fix any
      finding with a narrow `# shellcheck disable=` and a reason, never a loosened severity
- [ ] T062 [Depends: T061] Run `./tests/run.sh` end to end and confirm zero failures, the new
      `camera` section present (or skipped with its reason on a host without `node`), and the
      tally at or above the raised `TALLY_FLOOR`
- [ ] T063 [Depends: T062] Work through quickstart.md §2–§10 by hand in a browser against a
      fabricated `~/.claude`, and confirm every expected outcome for SC-001 through SC-013

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories
- **User Stories (Phase 3–7)**: All depend on Foundational completion
  - US1 and US2 (both P1) can proceed in parallel once Foundational is done — they touch
    different event listeners and different stylesheet rules, though both edit `web/map.html`
  - US3 (P2) needs Foundational's `centreOn`/`clampPan`/`fitIndex`/`fitView`/`levelFor` but not
    US1 or US2's event wiring, so it can proceed alongside them
  - US4 (P2) is CSS/DOM-only and independent of US1–US3's event handling
  - US5 (P3) audits handlers added by US1–US3, so its audit task (T058) is sequenced after them
- **Polish (Phase 8)**: Depends on every story whose assertions it tallies

### User Story Dependencies

- **User Story 1 (P1)**: Depends only on Foundational
- **User Story 2 (P1)**: Depends only on Foundational; independently testable from US1 (a
  keyboard-only pass never touches the drag/wheel code US1 adds)
- **User Story 3 (P2)**: Depends only on Foundational
- **User Story 4 (P2)**: Depends only on Foundational (specifically `applyView()`'s `--k` write
  point, T015)
- **User Story 5 (P3)**: Depends on Foundational and on the handlers added by US1–US3 (its audit
  task reads their code)

### Within Each User Story

- Tests are written first and are expected to fail until the paired implementation task lands
- Pure `web/camera.js` arithmetic before the `web/map.html` wiring that calls it
- Event wiring before the stylesheet rules that key off the state it writes

### Parallel Opportunities

- All Setup tasks (T001–T003) run in parallel — three different files
- Foundational's `README.md`/`tests/run.sh` assertion task (T012) can proceed alongside the
  `web/map.html` chrome tasks (T013–T016) — different files
- Once Foundational is complete, US1, US2, US3 and US4 can be staffed in parallel; US5's audit
  is the one story that must wait
- Within Polish, the README documentation task (T059) is independent of the suite-bookkeeping
  tasks (T060–T063)

---

## Parallel Example: Setup

```bash
# Launch all three Setup tasks together — different files, no dependencies:
Task: "Create web/camera.js exporting an empty window.CCWATCH_CAMERA object"
Task: "Add <script src=\"/camera.js\"></script> to web/map.html"
Task: "Add a camera section scaffold to tests/run.sh"
```

## Parallel Example: After Foundational

```bash
# Once Phase 2 is complete, these can proceed on separate branches:
Task: "User Story 1 — pointer drag and wheel zoom, data-lod CSS switch"
Task: "User Story 2 — keyboard handlers, button wiring, focus-visible"
Task: "User Story 3 — validateView/loadView/saveView, resize, load order"
Task: "User Story 4 — --k custom property, counter-scaling CSS"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup
2. Complete Phase 2: Foundational (CRITICAL — blocks all stories)
3. Complete Phase 3: User Story 1
4. **STOP and VALIDATE**: pan, zoom, and the three detail levels work end to end against a
   fabricated multi-organisation registry
5. Demo if ready — note that Story 2 (keyboard) is equal-priority P1 and a real regression in
   reach if shipped without it, so treat "MVP" here as a checkpoint, not a shippable state

### Incremental Delivery

1. Setup + Foundational → the ladder, the arithmetic, and the single writer exist
2. Add User Story 1 → pointer pan/zoom/LOD works → validate independently
3. Add User Story 2 → keyboard parity → validate independently → **this pair is the real MVP**
4. Add User Story 3 → the view survives a reload → validate independently
5. Add User Story 4 → wires and labels hold their size at every rung → validate independently
6. Add User Story 5 → confirm the footprint budget held throughout → validate independently
7. Phase 8 → document, raise `TALLY_FLOOR`, run the full suite, walk the manual quickstart

### Parallel Team Strategy

With multiple developers, once Foundational is done:

- Developer A: User Story 1 (pointer input, LOD switch)
- Developer B: User Story 2 (keyboard input, buttons, a11y)
- Developer C: User Story 3 (persistence, resize, tick-clamp)
- Developer D: User Story 4 (constant apparent size)

All four touch `web/map.html`, so coordinate on the event-listener and stylesheet regions each
task names to avoid merge conflicts; `web/camera.js` additions are per-function and rarely
collide. User Story 5's audit (T058) is a single developer's pass once A–C land.

## Notes

- `[P]` tasks = different files, no dependencies
- `[Story]` label maps task to specific user story for traceability
- Nearly every implementation task in this feature touches `web/map.html` or `web/camera.js`;
  where two tasks share a file, they are sequenced (via `[Depends: ...]`) rather than marked
  `[P]`, even within the same story
- Verify each new assertion fails against a deliberately broken implementation before trusting
  it, and add its row to the `README.md` mutation table in the same commit as the assertion
- Commit after each task or logical group, per `CLAUDE.md`'s commit discipline — one
  reason-to-change per commit, implementation and its assertion and its `README.md` row together
- Stop at any checkpoint to validate a story independently
- Avoid: vague tasks, same-file conflicts, cross-story dependencies that break independence
