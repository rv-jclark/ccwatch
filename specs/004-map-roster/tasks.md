---

description: "Task list for the docked agent roster panel"
---

# Tasks: Map — docked agent roster, severity-sorted, keyboard navigable, camera fly-to

**Input**: Design documents from `/specs/004-map-roster/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/roster-js.md](./contracts/roster-js.md), [contracts/page-roster.md](./contracts/page-roster.md), [quickstart.md](./quickstart.md)

**Tests**: The spec (FR-044, FR-045, FR-046, FR-047) requires every new assertion to be hermetic, mutation-checked, and to raise `TALLY_FLOOR`. Test tasks are therefore included throughout, not optional.

**Organization**: Tasks are grouped by user story so each can be implemented and verified independently. `web/roster.js` is a pure module (no DOM, no fetch, no timers, no `localStorage` reference) and is the file most tasks touch first; `web/map.html` is the only file that touches the document.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files or independent regions, no dependency on an incomplete task)
- **[Story]**: US1–US5, mapping to the spec's priority-ordered user stories
- File paths are exact

## Path Conventions

Single-file CLI tool serving static pages — no `src/`, no build step:

- `web/roster.js` — NEW pure module (this feature's only new file)
- `web/map.html` — MODIFIED (the only page touched)
- `tests/run.sh` — MODIFIED (new `roster-module` section; new guards in the `serve` section; new ordering assertions in the `ccwatch` section; raised `TALLY_FLOOR`)
- `README.md` — MODIFIED (the two documentation sections FR-049/FR-050 ask for, plus one mutation-table row per new assertion)
- `bin/ccwatch` — **UNCHANGED** by this feature (FR-035–FR-037, FR-040). No task in this list touches it.

---

## Phase 1: Setup

**Purpose**: Bring the new module into existence in the shape the suite and the page both expect, before any behaviour is built.

- [X] T001 Create `web/roster.js` as a fourth static module mirroring `web/camera.js`'s IIFE shape: `(function (root) { "use strict"; ... root.CCWATCH_ROSTER = api; if (typeof module !== "undefined" && module.exports) module.exports = api; })(typeof globalThis !== "undefined" ? globalThis : this);` with an empty `api = {}` for now
- [X] T002 [P] Add a `<script src="/roster.js">` tag to `web/map.html` immediately after the existing `<script src="/camera.js">` tag, per contract `page-roster.md` §8 load order
- [X] T003 [P] Add a new `roster-module` section to `tests/run.sh`, run under `node` in the same harness shape as the existing `plots` (around `tests/run.sh:1818`) and `camera` (around `tests/run.sh:2048`) sections, `t_skip`-ing with the reason when `node` is absent (FR-047); seed it with one assertion that `require("./web/roster.js")` succeeds and exports an object

**Checkpoint**: `web/roster.js` exists, is loaded by the page, and is exercised by the suite — every later task adds to something already wired end to end.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The shared constants, DOM skeleton, and render call sites every user story's rows, keyboard handling, selection, condition sentences, and width control build on top of.

**⚠️ CRITICAL**: No user story task can be verified until this phase is complete.

- [X] T004 Add the nine frozen constants to `web/roster.js` per contract `roster-js.md` §1 — `STORAGE_VERSION`, `WIDTH_DEFAULT`, `WIDTH_MIN`, `WIDTH_MAX_PX`, `WIDTH_MAX_FRAC`, `WIDTH_STEP`, `WIDTH_STEP_BIG`, `STACK_BREAKPOINT`, `NEAR_IDX`, `ASK_CHARS` — and export all of them
- [X] T005 [P] Add `dur(seconds)` to `web/roster.js`, copied from the page's existing formatter (`web/map.html:308-310`: `s`/`m`/`h`/`d`), and export it, so the page can delegate to one duration formatter (contract `roster-js.md` §2)
- [X] T006 In `web/map.html`, build the new DOM with `createElement`/`textContent` only (the `innerHTML` count must stay at two, FR-042): wrap the existing `#wrap` in a new `#stage` flex container without moving anything inside `#wrap`, and add `<aside id="roster" role="region" aria-labelledby="rostertitle">` containing `#rostertitle`, `#rosternote`, `#rostercond` (with child `main`/`unreadable`/`emptymsg` spans), `#rostergone`, and `<div id="rosterlist" role="listbox" aria-labelledby="rostertitle">`, per contract `page-roster.md` §1
- [X] T007 In `web/map.html`, add `<div id="rdivider" role="separator" aria-orientation="vertical" tabindex="0" aria-valuenow aria-valuemin aria-valuemax aria-label="Roster width">` between `#roster` and `#wrap` inside `#stage`, per contract `page-roster.md` §1
- [X] T008 Add the stylesheet rules from contract `page-roster.md` §2 to `web/map.html` — `#stage` flex row, `#roster` sized by `--roster-w` custom property, `#rdivider` sizing and `:focus-visible` outline, `.rrow .rname`/`.rrow .rwhere` ellipsis truncation, `.rrow .rstatus` `flex:none; white-space:nowrap` (the untruncatable pair, FR-034), `.rrow[aria-selected="true"]` + `.rsel` text emphasis, `.agent.selected .hit` figure emphasis, and the `@media (max-width:720px)` stacking rule — placing all of it **after** the existing `#camera.eased` `prefers-reduced-motion` block so the file's first such block stays the one `tests/run.sh:865-870` reads
- [X] T009 In `web/map.html`, add a `renderRoster(sessions, cond)` stub guarded by `if (!window.CCWATCH_ROSTER) return;` and call it from exactly the four sites contract `page-roster.md` §3 names: inside `applyFeed()` immediately **after** the existing `VOLATILE = cond.trust === "ok";` line (`web/map.html:1681`), from the selection-change handler, from the row-focus handler, and from the width/viewport-change path — no `setInterval`, `requestAnimationFrame`, or `ResizeObserver` introduced
- [X] T010 Extract `reflowWorld()` verbatim from the existing `resize` listener in `web/map.html` (`web/map.html:1752-1768`) into its own function; call it from the `resize` listener (behaviour unchanged) and once more at load, after `#stage`/`#roster`/`#rdivider` exist and before the first `tick()`, per contract `page-roster.md` §7 and §8
- [X] T011 [P] Update `#world`'s `aria-label` in `web/map.html` to add a clause naming it a companion view of the agent list, while keeping the existing "Arrow keys" text verbatim (`tests/run.sh:826` asserts it), per FR-013

**Checkpoint**: The panel exists in the DOM, is styled, is wired into the render loop and the load sequence, and the map still renders exactly as before — user story work can now proceed.

---

## Phase 3: User Story 1 - See what needs me, in order, without scanning the city (Priority: P1) 🎯 MVP

**Goal**: One row per session, in the payload's own needs-you-first order, each row carrying its name, repo/branch, status word, and the measurement behind it as text.

**Independent Test**: Fabricate a registry with sessions at several distinct severities — one `waiting`, one `needs_input` pipeline, one `HUNG?`, one `busy`, one `idle` — open `/map`, and confirm the roster's row order runs highest-severity first and each row's text contains its status word and the measurement behind it.

### Implementation for User Story 1

- [X] T012 [P] [US1] Implement `rowFields(row, opts)` in `web/roster.js` per data-model §1 and contract `roster-js.md` §2 — `sid`, `name`, `where` (`"<repo> · <branch>"` or exactly `"no repo"`), `word` (`row.token` verbatim), `measure` (data-model §2's table), `age`, `pipeline` (`"<phase>/CRASHED"` or `"<phase>/<status>"`, a key separate from `word`), `asks` (bounded to `ASK_CHARS`), `ctx`, `mem` — with every absent reading an **absent key**, never `0`, `"0%"`, `"0MB"` or `null` (R1–R5, R‑A…R‑K); export it
- [X] T013 [P] [US1] Implement `titleText(row, volatile)` in `web/roster.js` per contract `roster-js.md` §3 — joins `rowFields`'s output with `" · "` in the order word, `ASKS:`, measure, pipeline, age, ctx, mem (T‑A, T‑B); export it
- [X] T014 [US1] In `web/map.html`, delegate `titleBits()` to `CCWATCH_ROSTER.titleText` so the figure's hover text and the roster row can never state different things (FR-012)
- [X] T015 [P] [US1] Implement `keysOf(sessions)` in `web/roster.js` per contract `roster-js.md` §4 — `sessions.map(r => r.sid)` in arrival order, dropping any row with no `sid`; export it
- [X] T016 [P] [US1] Implement `reorderPlan(currentKeys, wantedKeys)` in `web/roster.js` per contract `roster-js.md` §4 — the minimal `[{key, before}]` move list (O‑A…O‑E); export it
- [X] T017 [US1] In `web/map.html`, implement the row primitive split into `makeRow`/`updateRow` (mirroring `web/map.html:556-577`'s split): `makeRow(sid)` creates the `.rrow` `<div>` with `data-sid` and its `rname`/`rwhere`/`rstatus`/`rmeta`/`rasks`/`rsel` child spans once; `updateRow(el, row, fields)` writes text into those children from `rowFields`'s output on every later tick
- [X] T018 [US1] In `web/map.html`, complete `renderRoster` per contract `page-roster.md` §3's order of work: compute `keys = keysOf(sessions)`, reconcile `#rosterlist` by `sid` using the existing `reconcile()` primitive with `makeRow`/`updateRow`, apply `reorderPlan(currentKeys, keys)` as `insertBefore` moves on already-attached nodes, and set `#rostertitle.textContent = "agents · " + keys.length`
- [X] T019 [US1] Add module assertions for `rowFields` (R‑A…R‑K) to the `roster-module` section of `tests/run.sh`, each mutation-checked (break the specific claim, confirm the assertion fails, restore) — include the FR-006 spot-check from `quickstart.md` §2 (a row with `repo/branch/quiet/waited/context/rss_mb` all `null` yields no `ctx`, no `mem`, no `0`/`0%`/`0MB` anywhere)
- [X] T020 [US1] Add module assertions for `titleText` (T‑A, T‑B) to the `roster-module` section of `tests/run.sh`, mutation-checked
- [X] T021 [US1] Add module assertions for `keysOf` and `reorderPlan` (O‑A…O‑E) to the `roster-module` section of `tests/run.sh`, mutation-checked
- [X] T022 [US1] Add the FR-008–FR-010 ordering assertions to the existing `ccwatch` section of `tests/run.sh`, against `ccwatch --json` on a fabricated `~/.claude` under `$WORK` via `CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS`: (1) sessions at severities 4, 3, 2, 1, 0 sort descending by `max(sev, psev)`; (2) two rows tied on that value, one with a larger `waited` and one with a larger `quiet` where `waited` is absent, sort by the tie-break; (3) a `needs_input` pipeline on an `idle` session sorts with the `waiting` rows via `psev` while its own `token` stays `idle`; (4) two rows tied on every ordering field produce the same order across two consecutive `ccwatch --json` runs — each mutation-checked
- [X] T023 [US1] Add a static guard to the `serve` section of `tests/run.sh` confirming `innerHTML` is still assigned exactly twice in `web/map.html` (FR-042), mutation-checked
- [X] T024 [US1] Add a "why volatile ordering lives in the roster, not the map" section to `README.md`, naming the re-orientation bug (the per-tick severity re-sort that moved a project to the front of the grid and moved every other project with it) as the failure that motivated the split (FR-049); add one mutation-table row for each assertion added in T019–T023

**Checkpoint**: The roster shows one row per session, correctly ordered and correctly worded, independent of keyboard, selection, failure states, or width — User Story 1 is independently demonstrable.

---

## Phase 4: User Story 2 - Read and operate the city without a mouse or without sight (Priority: P1)

**Goal**: The roster is reachable by tabbing, announced as a list of active agents with a count, navigable by arrow/`Home`/`End`, and every claim a figure draws is reachable as the text User Story 1 already produces.

**Independent Test**: With a fabricated registry, confirm every distinct figure appearance has a corresponding word in its roster row; confirm the roster's rows are focusable and that arrow, `Home`, `End`, and `Enter` move and activate the focused row; confirm the list and its rows carry accessible names and a selected state.

### Implementation for User Story 2

- [X] T025 [P] [US2] Implement `nextFocus(keys, currentSid, key)` and `focusTarget(prevSid, wantedKeys)` in `web/roster.js` per contract `roster-js.md` §4 (K‑A…K‑E, D4); export both
- [X] T026 [US2] In `web/map.html`, bind a `keydown` listener to `#rosterlist` (never `document`) handling `ArrowDown`/`ArrowUp`/`Home`/`End` via `nextFocus` with `preventDefault` (so the panel does not also scroll) and `Enter` to select the focused row (FR-015)
- [X] T027 [US2] In `web/map.html`, implement roving `tabindex`: exactly one `.rrow` has `tabindex="0"` at a time (the rest `-1`), moved by `nextFocus`'s result, and restored **by `sid`** via `focusTarget` after a tick reorders rows (FR-014, D4)
- [X] T028 [US2] In `web/map.html`, set `role="listbox"` on `#rosterlist`, `role="option"`/`tabindex`/`aria-selected` on the `.rrow` template, and `aria-labelledby` wiring for `#roster` and `#rosterlist`, so the panel and each row expose the accessible names FR-016 asks for
- [X] T029 [US2] In `web/map.html`, add one legend entry for the selection ring, built once before `tick()` is defined so the existing legend line-order assertion still holds (research D17)
- [X] T030 [US2] Add module assertions for `nextFocus`/`focusTarget` (K‑A…K‑E) to the `roster-module` section of `tests/run.sh`, mutation-checked
- [X] T031 [US2] Add static guards to the `serve` section of `tests/run.sh`: `#rosterlist` has `role="listbox"`; the `.rrow` template has `role="option"` and a `tabindex`; the roster's `keydown` listener is bound to `#rosterlist`, not `document` (FR-017); `#world`'s `aria-label` still contains `Arrow keys` **and** now names itself a companion view (FR-013) — each mutation-checked
- [X] T032 [US2] Add a section to `README.md` documenting the roster's keyboard operation (arrow/`Home`/`End`/`Enter`) and its accessible names, alongside the FR-050 row-content documentation; add one mutation-table row for each assertion added in T030–T031

**Checkpoint**: Every row from User Story 1 is now reachable and operable without a pointer, and the map is announced as a companion rather than the sole carrier of meaning.

---

## Phase 5: User Story 3 - Select an agent and have the city take me there (Priority: P2)

**Goal**: Selecting a row marks it selected, emphasises the matching figure, flies the camera to it, persists across reload, and states plainly when the selected session is gone.

**Independent Test**: With a fabricated registry, select a row and confirm the row carries a selected state, the matching figure carries an emphasis, and the camera's reported centre has moved to that figure's world position; reload and confirm the same row is still selected; then serve a payload with that session removed and confirm the roster states that the selected session is gone.

### Implementation for User Story 3

- [X] T033 [P] [US3] Implement `resolveSelection(storedSid, sessions, cond)` in `web/roster.js` per contract `roster-js.md` §5 and data-model §4 — returns `{state, sid}` with `state ∈ {none, present, gone, unknown}` (S‑A…S‑G); export it
- [X] T034 [P] [US3] Implement `flyIdx(level)` in `web/roster.js` per contract `roster-js.md` §5 (S‑H, S‑I); export it
- [X] T035 [P] [US3] Implement `validateSelection(raw)`, `loadSelection(getItem)`, `saveSelection(setItem, sid)` in `web/roster.js` per contract `roster-js.md` §7 — accepting a string or already-parsed object, rejecting an unparseable value, a wrong `v`, or a `sid` that is not session-id-shaped (P‑A…P‑C, P‑I), sharing the one-way `persistence` getter with width storage (P‑F…P‑H); export all four plus `persistence`
- [X] T036 [US3] Implement `goneText(sid, name)` in `web/roster.js` per contract `roster-js.md` §8 and data-model §6 — a sentence sharing no leading clause with any string `statements()` can produce (C‑J); export it
- [X] T037 [US3] In `web/map.html`, wire `#rostergone` as the tombstone: rendered from `resolveSelection`'s `gone` state using `goneText`, pinned above `#rosterlist`, with a real `<button>` that dismisses it and clears the stored selection, while the remaining rows keep rendering (data-model §6, FR-023)
- [X] T038 [US3] In `web/map.html`, implement `selectRow(sid)`: sets `selectedSid`, calls `saveSelection`, re-renders the roster, applies the `.selected` class to the matching figure's outer `<g class="agent">` (not inside `.figart`, which is rebuilt wholesale each tick), and flies **iff** `sid !== lastFlownSid` (contract `page-roster.md` §6)
- [X] T039 [US3] In `web/map.html`, build `centreBySid` inside `drawWorld`'s existing figure loop (`web/map.html:1534-1546`) from `plots.js`'s own `cx`/`cy` (`web/plots.js:259-261`) (research D19)
- [X] T040 [US3] In `web/map.html`, wire the fly call: `CCWATCH_MAP_CAMERA.centreOn(cx, cy, {animate: !reducedMotion, idx: flyIdx(CCWATCH_MAP_CAMERA.current().level)})`, reading `matchMedia("(prefers-reduced-motion: reduce)")` at the moment of the fly rather than relying on the stylesheet (research D8, FR-020)
- [X] T041 [US3] In `web/map.html`, bind a `click` handler on `.rrow` that calls `selectRow` and never opens the inspector (FR-021), leaving the existing `.agent` click handler (`web/map.html:1249-1256`) untouched
- [X] T042 [US3] In `web/map.html`, at load, set `selectedSid = loadSelection(getItem)?.sid ?? null` (validated), mark the matching row and figure once the first trusted payload arrives, and do **not** fly on that initial mark (contract `page-roster.md` §6/§8, research D7)
- [X] T043 [US3] Add module assertions for `resolveSelection` (S‑A…S‑G), `flyIdx` (S‑H, S‑I), and selection storage (P‑A…P‑C, P‑F…P‑I) to the `roster-module` section of `tests/run.sh`, mutation-checked
- [X] T044 [US3] Add a module assertion for `goneText` (C‑J) to the `roster-module` section of `tests/run.sh`, mutation-checked
- [X] T045 [US3] Add a static guard to the `serve` section of `tests/run.sh` confirming `.agent.selected .hit` is a distinct rule from every status-appearance rule and is applied on the outer `.agent` group rather than inside `.figart`, mutation-checked
- [X] T046 [US3] Add a section to `README.md` describing selection persistence, the tombstone sentence, and the camera fly-to as the first caller of `CCWATCH_MAP_CAMERA` (which entry 003 shipped with no caller); add one mutation-table row for each assertion added in T043–T045

**Checkpoint**: Selecting a row emphasises the right figure, flies the camera exactly once, survives reloads and ticks, and states clearly when the selection is gone.

---

## Phase 6: User Story 4 - Know when the list cannot be believed (Priority: P2)

**Goal**: The roster states each of the four failure conditions (feed down, warming, N unreadable registry files, genuinely no live sessions) in its own distinct sentence, and withholds `ctx`/`mem` through the map's existing single trust gate whenever the feed is not fully trusted.

**Independent Test**: Drive the page against a payload that is warming, one that reports a snapshot failure, one with a non-zero unreadable-rows count, and one with an empty session list, and confirm four distinct sentences and the correct withholding in each.

### Implementation for User Story 4

- [X] T047 [P] [US4] Implement `statements(cond)` in `web/roster.js` per contract `roster-js.md` §8 and data-model §5 — returns `{main, mainKind, unreadable, empty}` with the `empty` exclusion enforced inside the function regardless of what the caller passed (C‑A…C‑I); export it
- [X] T048 [US4] In `web/map.html`, render `statements(cond)` into `#rostercond`'s three persistent child nodes (`main`, `unreadable`, `emptymsg`), toggled by text content the same way `renderTrust` already does (`web/map.html:1604-1626`), reading the **same** `cond` object the map's own banner derives (contract `page-roster.md` §5, Constitution XI)
- [X] T049 [US4] In `web/map.html`, make `renderRoster` render **no rows at all** while `trust === "warming"`, and while `trust === "feed_down"` keep the retained rows listed with their measured age stated alongside the down sentence (FR-025(b), FR-027)
- [X] T050 [US4] Confirm (and adjust if needed) that the `renderRoster` call site added in T009 sits immediately after the `VOLATILE = cond.trust === "ok";` line, so `ctx`/`mem` are withheld through that one gate and no second one (FR-028, D13)
- [X] T051 [US4] Add module assertions for `statements` (C‑A…C‑I) to the `roster-module` section of `tests/run.sh`, including the FR-029/SC-007 spot-check from `quickstart.md` §2 (`empty: true` produces a sentence only when `trust: "ok"`), mutation-checked
- [X] T052 [US4] Add a static guard to the `serve` section of `tests/run.sh` confirming the `renderRoster(` call inside `applyFeed` sits after the `VOLATILE =` line, mutation-checked
- [X] T053 [US4] Add a section to `README.md` describing how the four failure conditions read in the roster, alongside the FR-050 documentation from earlier phases; add one mutation-table row for each assertion added in T051–T052

**Checkpoint**: All four failure states, and the healthy state, read as four distinct, mutually exclusive sentences, with volatile readings withheld exactly when the map's own banner would withhold them.

---

## Phase 7: User Story 5 - Make the panel the width I need it (Priority: P3)

**Goal**: The roster's width is adjustable by drag or by keyboard, persisted across reloads, clamped to what the current window can accommodate, and the panel stacks above the map below a breakpoint without truncating the status word or the measurement.

**Independent Test**: Resize the panel, reload, and confirm the width is restored; render at a narrow viewport and confirm each row still exposes its status word and measurement as text.

### Implementation for User Story 5

- [X] T054 [P] [US5] Implement `clampWidth(w, windowWidth)` in `web/roster.js` per contract `roster-js.md` §6 (W‑A…W‑F); export it
- [X] T055 [P] [US5] Implement `stacked(windowWidth)` in `web/roster.js` per contract `roster-js.md` §6 (`windowWidth < STACK_BREAKPOINT`); export it
- [X] T056 [P] [US5] Implement `validateWidth(raw)`, `loadWidth(getItem)`, `saveWidth(setItem, w)` in `web/roster.js` per contract `roster-js.md` §7 (P‑D, sharing the `persistence` flag with T035's selection storage); export all three
- [X] T057 [US5] In `web/map.html`, implement `setWidth(w)`: writes the `--roster-w` custom property on `#stage`, calls `saveWidth`, and calls `reflowWorld()` — never `fitView` (contract `page-roster.md` §6, FR-033)
- [X] T058 [US5] In `web/map.html`, implement `#rdivider` pointer drag: `pointerdown`/`pointermove`/`pointerup` with `setPointerCapture`, calling `setWidth(clampWidth(...))` per movement tick
- [X] T059 [US5] In `web/map.html`, implement `#rdivider` keyboard control: `ArrowLeft`/`ArrowRight` by `WIDTH_STEP` (`Shift` = `WIDTH_STEP_BIG`), `Home`/`End` to the clamped extremes, updating `aria-valuenow`/`aria-valuemin`/`aria-valuemax` (FR-032)
- [X] T060 [US5] In `web/map.html`, below `STACK_BREAKPOINT` skip applying the stored width and hide `#rdivider`, matching the `@media (max-width:720px)` rule added in T008 (data-model §7 W4)
- [X] T061 [US5] In `web/map.html`, at load, compute `width = clampWidth(loadWidth(getItem)?.w ?? WIDTH_DEFAULT, innerWidth)` and apply it before the first `tick()` (contract `page-roster.md` §8)
- [X] T062 [US5] Add module assertions for `clampWidth`, `stacked`, and width storage (W‑A…W‑F, plus P‑D for width) to the `roster-module` section of `tests/run.sh`, including the `clampWidth(500, 900) === 405` fraction-bound spot-check, mutation-checked
- [X] T063 [US5] Add a static guard to the `serve` section of `tests/run.sh` confirming `#rdivider` has `role="separator"`, `tabindex="0"`, and the three `aria-value*` attributes, mutation-checked
- [X] T064 [US5] Add a section to `README.md` documenting the roster's width control and its persistence, alongside the FR-050 documentation; add one mutation-table row for each assertion added in T062–T063

**Checkpoint**: The roster's width is fully adjustable, persisted, clamped, keyboard-operable, and the panel stacks correctly at narrow viewports without truncating the two protected fields.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Close out the invariants that span every story, and the two documentation notes that belong to the feature as a whole rather than to one story.

- [X] T065 [P] Add a note to `README.md` clarifying that this panel is not `~/.claude/ccwatch/roster.json` (the `write_roster` record `ccwatch resume` uses), and that this feature reads and writes neither (data-model §9, spec Assumptions)
- [X] T066 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming no `@media (prefers-reduced-motion: reduce)` block precedes the existing `#camera.eased` one in `web/map.html`, mutation-checked
- [X] T067 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming exactly one `setInterval` and zero `requestAnimationFrame` remain in `web/map.html` (FR-041), mutation-checked
- [X] T068 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` remains byte-identical in `web/map.html` (FR-039), mutation-checked
- [X] T069 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming `if (!window.CCWATCH_ROSTER) return;` guards the roster render path in `web/map.html`, mutation-checked (remove `web/roster.js` from the served directory; confirm the map keeps working and the guard's assertion fails without it, then restore)
- [X] T070 Raise `TALLY_FLOOR` in `tests/run.sh` (currently `345`) by the exact number of assertions added across T003, T019–T023, T030–T031, T043–T045, T051–T052, T062–T063, and T066–T069 (FR-046)
- [X] T071 Run `shellcheck -x -S warning` against `bin/ccwatch` and `tests/run.sh` and resolve any new warnings introduced by this feature's shell changes, using a narrow `# shellcheck disable=` with a stated reason only where unavoidable (FR-048)
- [X] T072 Run `./tests/run.sh` end to end and confirm: the tally is at or above the raised `TALLY_FLOOR`; `ccwatch once`, `ccwatch once | grep HUNG`, `NO_COLOR=1 ccwatch once`, `ccwatch doctor`, and `ccwatch --json | jq 'keys'` are unchanged from the pre-feature build for one fabricated fixture (SC-010); and `git diff --stat main -- bin/ccwatch` is empty
- [x] T073 Perform the manual browser validation pass in `quickstart.md` §5 for all five stories (US1–US5 checklists), including the VoiceOver pass for US2 and the reduced-motion pass for US3

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup (`web/roster.js` and its script tag must exist before the page can guard on `window.CCWATCH_ROSTER`) — **BLOCKS** all user stories.
- **User Story 1 (Phase 3)**: Depends on Foundational. No dependency on any other story.
- **User Story 2 (Phase 4)**: Depends on Foundational **and** on User Story 1's rows existing to navigate (T017/T018) and its accessible-name text (T012) to announce — sequenced after US1, though both are P1.
- **User Story 3 (Phase 5)**: Depends on Foundational and on US1's rows (to select) and US2's `.rrow` click/focus wiring being present.
- **User Story 4 (Phase 6)**: Depends on Foundational only; independent of US2 and US3, though sequenced after them here because both are P2 and US4 completes the P1/P2 set.
- **User Story 5 (Phase 7)**: Depends on Foundational only (`#rdivider`, `#stage`, `reflowWorld`); independent of every other story's behaviour.
- **Polish (Phase 8)**: Depends on all five stories being complete.

### Within Each User Story

- Pure `web/roster.js` functions (marked `[P]`) can be implemented in parallel with each other, since each is a self-contained export with no shared mutable state.
- `web/map.html` wiring tasks depend on the `web/roster.js` functions they call, and are not marked `[P]` against each other within a story where one wiring task's DOM is read by the next.
- Test tasks depend on the implementation they assert against, and are mutation-checked only after the implementation lands.
- README tasks are last in each story, once that story's assertions exist to be counted in the mutation table.

### Parallel Opportunities

- All Setup tasks marked `[P]` (T002, T003) can run in parallel once T001 exists.
- Foundational tasks T004/T005 (`[P]`) can run in parallel; T006–T011 touch the same file (`web/map.html`) and are sequenced.
- Within US1: T012, T013, T015, T016 (`[P]`) are independent `web/roster.js` exports and can be built in parallel; T014/T017/T018 depend on them.
- Within US2: T025 (`[P]`) is independent; T026–T029 depend on it and on each other's DOM state.
- Within US3: T033, T034, T035 (`[P]`) are independent `web/roster.js` exports; T036–T042 depend on them.
- Within US4: T047 (`[P]`) is the sole independent unit; everything else wires it into the page.
- Within US5: T054, T055, T056 (`[P]`) are independent `web/roster.js` exports; T057–T061 depend on them.
- Different user story phases (US1–US5) touch overlapping regions of `web/map.html`'s `renderRoster`, so — despite being logically independent — they are safest implemented in priority order rather than by literally parallel developers, unless coordinated by function/region ownership.

---

## Parallel Example: User Story 1

```bash
# Launch the independent web/roster.js exports for User Story 1 together:
Task: "Implement rowFields(row, opts) in web/roster.js"
Task: "Implement titleText(row, volatile) in web/roster.js"
Task: "Implement keysOf(sessions) in web/roster.js"
Task: "Implement reorderPlan(currentKeys, wantedKeys) in web/roster.js"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (blocks everything).
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: fabricate a registry at several severities, confirm the roster orders needs-you-first and every row carries its status word and measurement, confirm no figure's coordinate changed across 100 severity changes (SC-005).
5. This alone discharges the entry's stated reason to exist (spec Overview) even with no keyboard support, no selection, and no failure-state handling yet.

### Incremental Delivery

1. Setup + Foundational → the panel exists and renders nothing wrong.
2. Add User Story 1 → ordered, worded rows → validate independently (MVP).
3. Add User Story 2 → keyboard and accessible names → validate independently (completes the P1 pair).
4. Add User Story 3 → selection, figure emphasis, camera fly-to, the tombstone → validate independently.
5. Add User Story 4 → the four failure sentences and volatile withholding → validate independently.
6. Add User Story 5 → adjustable, persisted, clamped width → validate independently.
7. Polish → raise `TALLY_FLOOR`, run `shellcheck`, confirm SC-010's byte-identical outputs, run the full manual pass.

### Parallel Team Strategy

With multiple developers, after Foundational is done: one developer takes US1 (the only true blocker for US2/US3), a second starts US4 in parallel (independent of US1–US3 behaviourally, though sharing `renderRoster`'s call site), and a third starts US5 (fully independent — different DOM region, different `web/roster.js` functions). US2 and US3 queue behind US1 since they read its rows and its click/focus wiring.

---

## Notes

- `[P]` tasks touch different exports or different files with no dependency on an incomplete task.
- `[Story]` labels map every user-story-phase task to its story for traceability back to the spec's acceptance scenarios.
- `web/roster.js` never sorts, never derives a status, and exports nothing named `sort`, `severity`, `statusOf`, or `render` (contract `roster-js.md` §9) — verify the export list after each story's tasks with `node -e 'const R=require("./web/roster.js"); console.log(Object.keys(R).sort().join(" "))'`.
- Every assertion added by a test task must be mutation-checked before being marked complete: break the implementation in the way the assertion describes, confirm the assertion fails, restore it, and add the mutation-table row in `README.md` in the same story's documentation task.
- `bin/ccwatch` is touched by no task in this list; `git diff --stat main -- bin/ccwatch` staying empty is the acceptance check in T072, not an aspiration.
- Stop at any checkpoint to validate that story independently before continuing — each is designed to be demonstrable on its own against a fabricated `~/.claude`.
