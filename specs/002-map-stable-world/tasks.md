---

description: "Task list for 002-map-stable-world"
---

# Tasks: Map — identity-derived world layout, incremental rendering, four distinct failure states

**Input**: Design documents from `/specs/002-map-stable-world/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included. FR-057–FR-061 and the constitution's test discipline require every new assertion to be mutation-checked, hermetic, and to skip with a stated reason where the host cannot supply what it needs. `tests/run.sh` is the only test entry point — there is no separate test framework.

**Organization**: Tasks are grouped by user story per the spec's priorities. Stories 1 and 2 (both P1) share the same foundational geometry/reconciliation machinery and are sequenced together; Story 3 (P2, trust model) is independent of layout; Story 4 (P2, wires) depends on the world space from Story 1; Story 5 (P3, fit) depends on the extent Story 1's geometry produces.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US5 map to the spec's five user stories
- Every task names its exact file path

## Path Conventions

Single-file bash CLI plus two static pages and two static JS modules — no `src/` tree, no build step:

- `bin/ccwatch` — the tool (sections: `collection` ~L180, `the join` ~L598, `rendering` ~L947, `doctor` ~L3051)
- `web/map.html` — the page being rebuilt (currently 800 lines)
- `web/plots.js` — **new**, the pure identity→coordinate module
- `tests/run.sh` — the only test entry point (currently 1788 lines, `TALLY_FLOOR=210`)
- `README.md` — the map section and the mutation table

---

## Phase 1: Setup

**Purpose**: Confirm the fixtures and scaffolding this whole feature is built and tested against exist before any story-specific work starts.

- [X] T001 Confirm `jq`, `python3`, `shellcheck` and (optionally) `node` are available in the dev shell per quickstart.md §0; no code change — a preflight so later `node`-gated tasks aren't debugged against a missing interpreter
- [X] T002 Read `web/map.html:1-800` in full and annotate (in your own working notes, not committed) every call site of `.innerHTML =`, `getBoundingClientRect()`, and the `#map` grid, so Phase 2/3 tasks touch exactly the lines research.md and the contracts name

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The pure geometry module and the `parse_failed` propagation are consumed by every user story phase below. Nothing in Phase 3+ can be implemented, let alone tested, until this phase is complete.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### `web/plots.js` — the identity→coordinate module (contracts/plots-js.md)

- [X] T003 [P] Create `web/plots.js` exporting `window.CCWATCH_PLOTS` with a CommonJS tail for `node` (same pattern as `web/md.js`), and define `CCWATCH_PLOTS.UNITS` with the exact figure/zone/building/district world-unit budget from research.md D5 and contracts/plots-js.md §1
- [X] T004 [P] [Depends: T003] Implement `assign(level, key, opts) → slot` in `web/plots.js`: hash-then-probe placement (`h1(key) mod C`, then `(i + h2(key)) mod C` with `h2` odd and coprime to `C`), a persisted assignment always wins and is never recomputed, and district capacity doubles (never shrinks) when a new district cannot be placed — satisfying guarantees A1–A6 in contracts/plots-js.md §2
- [X] T005 [Depends: T004] Implement annex-plot overflow in `web/plots.js`: when a parent's capacity is exhausted, the identity claims `<key>#2`, `<key>#3`, … in the grandparent's space via the same `assign` rule, labelled with the same name, per research.md D2
- [X] T006 [P] [Depends: T003] Implement `load(get)` and `save(set, liveKeys)` in `web/plots.js`: versioned payload (`v: 1`) discarded wholesale if the version differs (S1), storage calls injected so throwing storage sets `persistence = "unavailable"` once without retrying every frame (S2), 512-entry cap evicting longest-unseen first while never evicting a key in `liveKeys` (S3, S4), and `slot` left unchanged for every already-stored key on save (S5) — contracts/plots-js.md §4
- [X] T007 [Depends: T004, T005, T006] Implement `place(model) → { world, extent, sig }` in `web/plots.js`: builds every district/building/zone/figure coordinate from the identity tree using `assign`, computes `extent` as the bounding box of plots with a **current occupant** grown by one district gutter and clamped to a minimum of `408 × 408` (P3, P4), and returns a stable `sig` string over the occupied plot set (P5) — contracts/plots-js.md §3
- [X] T008 [P] [Depends: T007] Implement `fit(extent, vw, vh) → { k, tx, ty }` in `web/plots.js`: uniform scale `k = min(vw/W, vh/H)` clamped to a maximum of `3.0`, extent centred in the available area, and the function reads only its three arguments — no state, no storage (F1–F4) — contracts/plots-js.md §3b

### `bin/ccwatch` — `parse_failed` propagation (research.md D6, contracts/api-state.md)

- [X] T009 [P] Change `collect_sessions` in `bin/ccwatch` (`collection` section, ~L180-215) to return `{"rows": [...], "parse_failed": N}` instead of a bare array; replace the pipeline-based slow path with a loop that accumulates rows into a shell variable in the function's own shell so the `parse_failed` increment is not lost to a subshell
- [X] T010 [Depends: T009] Update `snapshot()` in `bin/ccwatch` (`the join` section, ~L598-618) to destructure `collect_sessions`'s new `{rows, parse_failed}` shape and add a top-level `parse_failed` field to the snapshot JSON it builds
- [X] T011 [Depends: T009] Update `cmd_doctor` in `bin/ccwatch` (`doctor` section, ~L3086-3087) to destructure the new `collect_sessions` return shape and read `parse_failed` from it directly, printing `N registry file(s) would not parse (a session mid-write does this; persistent means trouble)` when `N > 0`
- [X] T012 [Depends: T009] Update the peer-name lookup call site in `cmd_convo` (`transcript`/`kill` section area, ~L1515) to read `.rows[]` from `collect_sessions`'s new object shape instead of iterating a bare array
- [X] T013 [Depends: T010] Update the terminal footer in `bin/ccwatch` (`rendering` section, ~L1129-1145) to read `.parse_failed` from the snapshot it is already given instead of `--argjson pf "$PARSE_FAILED"`, printing `· N unreadable registry file(s) — run: ccwatch doctor` only when `N > 0` (Constitution XII — absent below the threshold, never `0`)
- [X] T014 Run `shellcheck -x -S warning bin/ccwatch` and fix any new warnings introduced by T009–T013 before proceeding — FR-056 requires the linter stay clean at unchanged severity

### Test scaffolding for the foundational phase

- [X] T015 [P] [Depends: T003–T008] Add a new `plots` section to `tests/run.sh`, gated on `node` being present (skip with the reason stated when absent, matching the existing `markdown` section's pattern at `tests/run.sh:1661-1775`), that loads `web/plots.js` via `require()`
- [X] T016 [Depends: T015] Add assertions in the `plots` section for `assign` guarantees A1–A6: same key returns same slot on repeat calls; a key present in injected storage returns its stored slot without hashing; assigning a new key never changes an existing key's slot; a collision's probe step derives from the key, not call order; only `level`/`key`/`opts.seen` influence the result; an annex key (`<key>#2`) is itself persisted
- [X] T017 [Depends: T015] Add assertions in the `plots` section for `place` guarantees P1–P7: coordinates are integers; two trees differing only in `sev`/`psev`/`token`/`quiet`/`waited`/`context`/`rss_mb`/`cost`/`age`/`pipeline`/`deploys`/row-order return identical coordinates; extent is the occupied bbox plus one gutter clamped to a 408×408 floor; a remembered-but-unoccupied plot contributes nothing to extent; `sig` changes only when the occupied set changes; figure `cx`/`cy` are usable centres; a `no repo` building lands in the reserved district
- [X] T018 [Depends: T015] Add assertions in the `plots` section for `fit` guarantees F1–F4 and for `load`/`save` guarantees S1–S5, including the mutation-table row's specific breakages: re-hashing a stored key, a call-counter probe step, ordering by `sev`, counting empty remembered plots in the extent, dropping the `liveKeys` eviction guard, removing the version check, and dropping the max-scale clamp — one assertion per row in contracts/plots-js.md §5, mutation-checked per FR-059
- [X] T019 [P] [Depends: T009–T013] Add `parse_failed` assertions in the `ccwatch` and `doctor` sections of `tests/run.sh` using the fabricated registry from quickstart.md §2 (one good session, one file truncated mid-write): `./bin/ccwatch --json | jq .parse_failed` equals `1`, the footer includes the unreadable-file note, `ccwatch doctor` reports it, and deleting the bad file drops all of them to `0` with **no** note printed (Constitution XII) — mutation-checked against reverting T009/T010/T011/T013 individually
- [X] T020 [Depends: T019] Add a `parse_failed` assertion in the `serve` section of `tests/run.sh` confirming `curl -s .../api/state | jq .parse_failed` matches the same fabricated registry's `--json` value (G1, FR-034, SC-009) — this is the fourth of the four consumers and must equal the other three
- [X] T021 [Depends: T015–T020] Raise `TALLY_FLOOR` in `tests/run.sh` (currently `38: TALLY_FLOOR=210`) to cover the assertions added in this phase

**Checkpoint**: `web/plots.js` exists and is fully tested under `node`; `parse_failed` reaches all four consumers identically; the linter is clean. User story implementation can now begin.

---

## Phase 3: User Story 1 — The city stays where I learned it (Priority: P1) 🎯 MVP

**Goal**: Replace the CSS grid and severity sort in `web/map.html` with the SVG world/camera group from research.md D1, driven entirely by `web/plots.js`, so no coordinate ever moves except on first placement.

**Independent Test**: Fabricate a registry, load the map, note where each building sits, change one session's status and refresh — every building, zone and figure must be at the same coordinate; reload the page and it must still be.

### Implementation for User Story 1

- [X] T022 [US1] In `web/map.html`, remove the `#map` CSS grid (`web/map.html:46` and its responsive rules) and the severity sort (`web/map.html:740-744`) together with the comment above it that claims the opposite of what the code does (`web/map.html:710-712`)
- [X] T023 [US1] [Depends: T022] Add `<svg id="world">` containing `<g id="camera">` to `web/map.html`, and add `<script src="/plots.js">` before the page's own script so `CCWATCH_PLOTS` is available
- [X] T024 [US1] [Depends: T023] Build the in-page identity tree (District/Building/Zone/Figure per data-model.md §3) from each payload tick in `web/map.html`, keyed exactly as data-model.md §2 specifies (`d|<org>`, `b|<org>|<slug>`, `z|<slug>|<branch>`, `f|<slug>|<branch>|<sid>`), deriving `org` from `row.repo.split("/")[0]` with `no repo` as fallback, and the building key from `row.repo` or `dir:<row.cwd>` when there is no remote
- [X] T025 [US1] [Depends: T024] Call `CCWATCH_PLOTS.place(tree)` each tick in `web/map.html` to obtain world coordinates for every district/building/zone/figure, and wire `CCWATCH_PLOTS.load`/`.save` to `localStorage["ccwatch.map.plots.v1"]` with the injected-function signature contracts/plots-js.md §4 requires
- [X] T026 [US1] Implement the `drawDistrict` primitive in `web/map.html`: one `<g>` per district with a `<rect class="hit">`, a `<title>`, a readable org label (or the `no repo` badge and tooltip, verbatim per contracts/page-render.md §3), positioned by the transform `place()` returns
- [X] T027 [US1] [P] Implement the `drawBuilding` primitive in `web/map.html`: one `<g>` per building with a `<rect class="hit">`, a `<title>`, a readable repository/directory name, and slots for the unfinished-run and deploy badges it already carries today
- [X] T028 [US1] [P] Implement zone drawing in `web/map.html`: each zone labelled with its branch name (or `?` when missing, shown as missing per spec Edge Cases), one per building, distinguishing two worktrees of the same repository
- [X] T029 [US1] [Depends: T026, T027, T028] Implement the `drawFigure` primitive in `web/map.html`: one `<g>` per session with a `<rect class="hit">`, a `<title>`, carrying pose/colour/emphasis from payload fields exactly as the current `agentCard()`/figure rendering does, but deriving nothing about position from any payload field
- [X] T030 [US1] [Depends: T029] Handle the "no live session but an unfinished run or a deploy badge" edge case: a building with zero figures still gets a plot and still draws its unfinished/deploy badges (spec Edge Cases)
- [X] T031 [US1] Add a `no repo` reserved district in the identity tree construction that never receives an org-derived key, so it is provably distinct from every real organisation's district (FR-004, Constitution VI, P7)

**Checkpoint**: Districts, buildings, zones and figures draw from identity alone and hold their coordinates across a status change and a reload. User Story 1 is independently testable per quickstart.md §4.

---

## Phase 4: User Story 2 — A refresh does not interrupt what I am doing (Priority: P1)

**Goal**: Replace every `innerHTML =` refresh path in `web/map.html` with keyed reconciliation, so an open inspector, a hover, a focus and a text selection all survive a tick.

**Independent Test**: Open the inspector, start a text selection, hover a figure, and let at least two refresh cycles pass with the fixture changing underneath — all three must survive.

### Implementation for User Story 2

- [X] T032 [US2] [Depends: T029] Implement one `reconcile(parentEl, wanted, key, make, update)` helper in `web/map.html` per research.md D4: `wanted` is a map from identity key to model, `make(key)` creates and indexes the element, `update(el, model)` writes attributes/text, and any element whose key is absent from `wanted` is removed
- [X] T033 [US2] [Depends: T032] Wire `drawDistrict`/`drawBuilding`/`drawFigure` (T026, T027, T029) through `reconcile()` so the world tree is created/updated/removed by key instead of rebuilt (FR-015)
- [X] T034 [US2] [P] [Depends: T032] Reconcile `#counts` in `web/map.html` in place instead of `innerHTML =`
- [X] T035 [US2] [P] [Depends: T032] Reconcile `#gauges` in `web/map.html` in place, preserving its existing staleness-window behaviour (FR-043)
- [X] T036 [US2] [P] [Depends: T032] Reconcile `#foot` in `web/map.html` in place, preserving its existing wording (FR-045)
- [X] T037 [US2] [P] [Depends: T032] Reconcile `#hostwarn` in `web/map.html` in place, preserving its threshold-gated appearance (FR-044, Constitution XII)
- [X] T038 [US2] [P] [Depends: T032] Reconcile `#ask` and `#killbar` in `web/map.html` in place, preserving current behaviour and wording (FR-042)
- [X] T039 [US2] [Depends: T032] Reconcile the inspector's `#convo` turn list in `web/map.html`, keyed on `at|kind|<n>` (the turn's `.timestamp` plus a disambiguator for same-instant duplicates), removing the scroll-position save/restore at `web/map.html:511` since reconciliation makes it unnecessary
- [X] T040 [US2] [Depends: T039] Keep exactly one `innerHTML` write in `web/map.html`: a turn's **body**, filled from `CCWATCH_MD.render(...)` — the container is reconciled, the body is not (V2, Constitution X)
- [X] T041 [US2] Confirm `#legend` in `web/map.html` is built once at load and never touched again (already satisfies FR-020 for the common case; verify no refresh path re-renders it)

**Checkpoint**: No refresh-reachable code path in `web/map.html` assigns `innerHTML` except the one turn-body write. Inspector state, hover, focus and selection all survive refreshes per quickstart.md §5.

---

## Phase 5: User Story 3 — A broken feed says which way it is broken (Priority: P2)

**Goal**: Implement the four mutually distinguishable trust renderings and withhold volatile readings when the feed is not `ok`, per data-model.md §5 and contracts/page-render.md §1.

**Independent Test**: Drive each of the four conditions (server stopped, snapshot never taken, unreadable registry rows, genuinely no sessions) and read the four sentences — they must be four different sentences, and in the first three the structure must stay drawn with volatile numbers gone.

### Implementation for User Story 3

- [X] T042 [US3] In `web/map.html`, remove the early return `if (s.warming) return` (`web/map.html:707`) so a warming payload never leaves the previous drawing standing with only a footnote (FR-030, R8)
- [X] T043 [US3] [Depends: T042] Compute a `FeedCondition` object each tick in `web/map.html` per data-model.md §5: `trust ∈ {ok, feed_down, warming}` derived from the fetch outcome/`res.ok`/`snapshot_ok`/`warming`; `reason` as the thrown message, HTTP status, or `snapshot_error`; `dataAge` as `now - collected_at.snapshot` recomputed every repaint (`null` while `warming`); `unreadable` as `payload.parse_failed` (independent of `trust`, `null` prints nothing); `empty` as `trust === "ok" && !error && sessions.length === 0`
- [X] T044 [US3] [Depends: T043] Render sentence (a) in `web/map.html`: `the feed is down: <reason> — is \`ccwatch serve\` still running? showing session data from <age> ago`, triggered when `trust === "feed_down"`
- [X] T045 [US3] [Depends: T043] Render sentence (b) in `web/map.html`: `taking the first snapshot — no session data has been collected yet`, triggered when `trust === "warming"`, with no age stated (recorded Complexity Tracking deviation from FR-028's literal text)
- [X] T046 [US3] [Depends: T043] Render sentence (c) in `web/map.html`: `<N> registry file(s) could not be read — run: ccwatch doctor`, triggered when `unreadable > 0`, additive and coexisting with any other condition, rendered from the payload field and never inferred (FR-036)
- [X] T047 [US3] [Depends: T043] Keep sentence (d) verbatim in `web/map.html`: `No live sessions. After a reboot, run ccwatch resume.` (`web/map.html:748`), gated on `trust === "ok" && !error && sessions.length === 0`, and confirm it is never printed when `error`/`snapshot_error` is present regardless of `sessions` (FR-031, SC-008, R6)
- [X] T048 [US3] [Depends: T044, T045, T046] In conditions (a), (b) and (c), keep districts/buildings/zones drawn (FR-027) and mark the map stale with the measured age computed in T043 (FR-028, R3)
- [X] T049 [US3] [Depends: T043] Define the single `VOLATILE` enumeration in `web/map.html` covering: the context-fill rect inside a figure, `ctx NN%` and `NN MB` in a figure's title text, every gauge percentage, and the host memory-pressure percentages — and withhold every one of them when `trust !== "ok"` while leaving pose/colour/structure/status-word/age untouched (FR-029, Constitution III, R4)
- [X] T050 [US3] [Depends: T044, T045, T046, T049] Confirm transitions are computed fresh each tick and never latched: a good snapshot arriving after a stale/failed state clears the marking and restores every withheld reading on that same tick with no reload (FR-032, R7)

**Checkpoint**: The four sentences render distinctly, share no wording, and the volatile-withholding set is enumerated in one place. User Story 3 is independently testable per quickstart.md §6.

---

## Phase 6: User Story 4 — Messages between agents are drawn on the map itself (Priority: P2)

**Goal**: Move the peer-wire drawing into world space, computed from `place()`'s figure centres rather than measured screen geometry, so wires survive the camera transform introduced in User Story 1.

**Independent Test**: Fabricate peer traffic in both directions between two sessions in different projects, plus traffic involving an exited session, and check the drawn lines and the footer count.

### Implementation for User Story 4

- [X] T051 [US4] [Depends: T025, T033] Remove the `getBoundingClientRect()`-based wire measurement in `web/map.html` (`web/map.html:385-432`) and replace it with wires drawn as children of `<g id="camera">`, using the `cx`/`cy` figure centres `place()` returns (P6, FR-021, V6)
- [X] T052 [US4] [Depends: T051] Resolve each `peers.edges[]` entry (`from`, `to` as session names) to a row, then a `sid`, then a figure key, then a world centre, in `web/map.html` — matching `peers_graph`'s naming (`bin/ccwatch:2604-2608`)
- [X] T053 [US4] [Depends: T052] Draw each direction of traffic as a separate bowed line with an arrowhead indicating direction in `web/map.html` (FR-022, V7); a count label appears only when an edge carries more than one message (FR-023)
- [X] T054 [US4] [Depends: T052] Skip drawing an edge in `web/map.html` when either end does not resolve to a figure currently on the map (FR-024), and keep the footer's existing verbatim wording (`web/map.html:690-693`) reporting how many of the total edges were drawn and that the remainder involve exited sessions (FR-025, V8)
- [X] T055 [US4] [Depends: T053] Reconcile wires through the same `reconcile()` helper (T032) rather than any wholesale replacement, keyed on the edge's identity

**Checkpoint**: Wires are drawn in world coordinates and hold under any camera transform. User Story 4 is independently testable per quickstart.md §7 (peer-traffic rows).

---

## Phase 7: User Story 5 — The whole city is visible without touching anything (Priority: P3)

**Goal**: Wire `fit()` into the resize/layout-change path so the occupied world is always on screen without panning or zooming, per research.md D5 and D9.

**Independent Test**: Open the map at a small window size with several districts present and confirm the full extent is on screen and figures are distinguishable; resize and confirm it refits.

### Implementation for User Story 5

- [X] T056 [US5] [Depends: T025] Call `CCWATCH_PLOTS.fit(extent, vw, vh)` in `web/map.html` and write the resulting `translate(tx ty) scale(k)` transform onto `<g id="camera">`, recomputing only when `place()`'s `sig` changes or on `resize` (FR-019, FR-038)
- [X] T057 [US5] [Depends: T056] Change the `resize` listener in `web/map.html` (`web/map.html:797`) to call the fit alone instead of `tick()` — no refetch on resize (research.md D9, FR-049)
- [X] T058 [US5] [Depends: T056] Confirm remembered-but-empty plots never enlarge the fitted extent (FR-039, already guaranteed by T007/P4, but verify the call site passes only occupied plots)
- [X] T059 [US5] Confirm no interactive panning, zooming, level-of-detail or persisted viewport is added anywhere in `web/map.html` (FR-041 — this entry's explicit non-goal)

**Checkpoint**: The whole occupied city fits the viewport with no interaction, and a resize refits without moving any world coordinate. User Story 5 is independently testable per quickstart.md §7.

---

## Phase 8: Cross-cutting drawing invariants (spans User Stories 1–5)

**Purpose**: Requirements that apply across all the drawing primitives rather than to one story's user-facing behaviour — implement once the primitives from Phases 3–6 exist.

- [X] T060 [P] Give `drawDistrict`/`drawBuilding`/`drawFigure` (T026, T027, T029) a shared shape so each owns all its own art and nothing else, with a `<rect class="hit">` independent of the art so a later sprite swap touches only the primitive (FR-050, FR-051, V9)
- [X] T061 [P] Confirm every figure state has a distinct word available as text in its `<title>` and in the legend, not colour or shape alone (FR-046, Constitution VII, V13)
- [X] T062 [P] Handle an unrecognised status token in `web/map.html`: draw the neutral figure, invent no pose/colour/severity, and keep the token itself readable as text (Constitution V, V14)
- [X] T063 [P] Handle a session with no branch or no project name in `web/map.html`: still draw a figure, show the missing part as missing rather than guessed (Constitution VI, V15)
- [X] T064 [P] Implement motion rules in `web/map.html`: working/blocked/suspect figures may move, idle figures never do, and `prefers-reduced-motion: reduce` suppresses all motion while keeping every state distinguishable without it (FR-053, V12)
- [X] T065 Confirm `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` remains byte-identical in `web/map.html` after the rewrite (FR-047, V16)
- [X] T066 Confirm read-only and kill-disabled behaviour in `web/map.html` is unchanged: no gate is touched, and no disabled capability becomes a visible control (FR-048, V17)
- [X] T067 Confirm no animation-frame loop exists anywhere in the rewritten `web/map.html` and exactly one `setInterval` remains, routed through the shared visibility-aware scheduler from `001-feed-footprint` (FR-049, SC-012, V11)

---

## Phase 9: Test coverage for the page-level contracts (page-render.md, spans US1–US5)

**Purpose**: Static, mutation-checkable guards for what the automated suite *can* check about the rewritten page, plus the scripted manual validation for what it cannot (research.md's recorded coverage limit).

- [X] T068 [P] Add static page-guard assertions to the `serve` section of `tests/run.sh`: no `.innerHTML =` appears on any refresh-reachable container in the served `map.html` except the one turn-body write (V1, V2) — grep-based, mutation-checked against reintroducing a wholesale `innerHTML =`
- [X] T069 [P] [Depends: T068] Add an assertion confirming exactly one `setInterval` and zero `requestAnimationFrame` occurrences in the served `map.html`, extending the existing check at `tests/run.sh:739-746` to the rewritten page (V11, SC-012)
- [X] T070 [P] Add an assertion confirming the served `map.html` still contains `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` byte-identical and that the substituted token appears when served with a real run (V16, FR-047)
- [X] T071 [Depends: T015–T021] Raise `TALLY_FLOOR` in `tests/run.sh` a second time to include T068–T070, folding it into the single final value (do not raise it twice in the diff — confirm T021's raise already accounted for these, or combine)
- [X] T072 Walk quickstart.md §4–§7 by hand against a locally served map (`./bin/ccwatch serve --port 18800 --open` with the fabricated fixture) and record the outcome of each scripted step — this is the coverage the suite cannot assert automatically (SC-001, SC-002, SC-004, SC-005, SC-011 as rendered-over-time claims) — recorded in `specs/002-map-stable-world/t072-walkthrough.md`; confirmed by hand in a real browser: coordinate stability across a status change and a reload (§4), inspector/selection survival across refreshes (§5), and the feed-down sentence withholding every volatile number and recovering without a reload (§6); noted two doc/impl gaps (quickstart's `[data-key]` selector doesn't match the DOM, and figures have no `tabindex` so the "tab to a figure" step can't be driven) for follow-up, not fixed in this pass

---

## Phase 10: Polish & Cross-Cutting Concerns

**Purpose**: Documentation and diff hygiene that close out the feature once every story and its tests pass.

- [X] T073 [P] Rewrite the map section of `README.md`: remove every description of the responsive grid as the design, document the identity-derived geography (districts/buildings/zones/figures, hash-then-probe, persisted assignment), and name the three defects this entry fixes — the re-flow on status, the destroy-on-refresh, and the failure that reads as an absence (FR-062, SC-016)
- [x] T074 [P] [Depends: T016, T017, T018, T019, T020, T068, T069, T070] Add one row per new assertion to the mutation table in `README.md` (FR-059, SC-015) — at minimum the seven rows enumerated in contracts/plots-js.md §5, plus one each for the `parse_failed` assertions (T019, T020) and the page guards (T068–T070)
- [x] T075 Run `git diff --stat main...HEAD` and `git diff main...HEAD -- . | grep -nE 'https?://|\.png|\.jpg|\.woff|package\.json|node_modules'` per quickstart.md §8 — expect no image, binary, font, external reference, build step, package manifest or endpoint; confirm the touched-file set matches `bin/ccwatch`, `web/map.html`, `web/plots.js`, `tests/run.sh`, `README.md`, `specs/`
- [x] T076 Run `grep -n 'responsive grid' README.md` and confirm no match (SC-016)
- [x] T077 Run `./tests/run.sh` in full: expect `shellcheck -x -S warning` clean, zero failures, the tally at or above the raised `TALLY_FLOOR`, and the new `plots` section present (skipping with its stated reason only where `node` is genuinely absent)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup. **BLOCKS every user story** — `web/plots.js` and `parse_failed` propagation are consumed by Phases 3–7.
- **User Story 1 (Phase 3)**: Depends on Foundational. Establishes the world SVG, camera group and drawing primitives that Phases 4, 6 and 7 build on.
- **User Story 2 (Phase 4)**: Depends on Foundational **and** on the primitives from Phase 3 (reconciliation wraps them).
- **User Story 3 (Phase 5)**: Depends on Foundational only. Independent of Phases 3/4/6/7 — the trust model touches different code (the fetch/warming branch) and can proceed in parallel with them once Phase 2 is done.
- **User Story 4 (Phase 6)**: Depends on Phase 3 (needs `place()`'s figure centres and the world SVG) and Phase 4 (wires reconcile through the same helper).
- **User Story 5 (Phase 7)**: Depends on Phase 3 (needs the occupied-plot tree and `place()`'s extent).
- **Cross-cutting drawing invariants (Phase 8)**: Depends on the primitives existing (Phase 3) — can run alongside Phases 4–7.
- **Page-level test coverage (Phase 9)**: Depends on Phases 3–8 being substantially in place, since its assertions target the rewritten page's static shape.
- **Polish (Phase 10)**: Depends on all prior phases.

### User Story Dependencies

- **US1** — no dependency on other stories; it is the foundation the rest of the page's stability rests on.
- **US2** — builds directly on US1's primitives (reconciliation wraps what US1 draws); not independently meaningful without it, though FR-016/FR-017/FR-018 are its own distinct guarantee.
- **US3** — independent of US1/US2/US4/US5; touches the trust/fetch layer, not layout.
- **US4** — depends on US1 (world coordinates) and US2 (the reconcile helper); regresses today's working peer-wire feature if skipped.
- **US5** — depends on US1 (the occupied-plot tree feeding `fit()`).

### Within Each Phase

- Tests are written alongside (not strictly before) implementation here, because `web/plots.js` guarantees are specified in contracts/plots-js.md ahead of code — but the mutation-check step (breaking the implementation, confirming the assertion fails, restoring it) happens after both exist.
- Models/geometry (Phase 2) before primitives (Phase 3) before reconciliation (Phase 4) before dependent stories (6, 7).

### Parallel Opportunities

- T003, T006, T009 can start in parallel (different files: `web/plots.js` constants/persistence vs. `bin/ccwatch`).
- T026, T027, T028 (district/building/zone primitives) can be built in parallel once T024/T025 land.
- T034–T038 (reconciling `#counts`/`#gauges`/`#foot`/`#hostwarn`/`#ask`+`#killbar`) are independent containers and can proceed in parallel once T032 (the `reconcile()` helper) exists.
- Phase 5 (User Story 3) can proceed in parallel with Phases 3/4/6/7 once Phase 2 is done, since it touches the trust/fetch branch rather than the drawing primitives.
- T060–T064 (cross-cutting invariants) can be split across contributors once the primitives exist.
- T068, T069, T070 (page guards) are independent assertions and can be written in parallel.

---

## Parallel Example: Foundational Phase

```bash
# Launch independent Phase 2 workstreams together:
Task: "Create web/plots.js with CCWATCH_PLOTS.UNITS constants (T003)"
Task: "Implement load(get)/save(set, liveKeys) persistence in web/plots.js (T006)"
Task: "Change collect_sessions in bin/ccwatch to return {rows, parse_failed} (T009)"
```

## Parallel Example: User Story 1 primitives

```bash
Task: "Implement drawDistrict primitive in web/map.html (T026)"
Task: "Implement drawBuilding primitive in web/map.html (T027)"
Task: "Implement zone drawing in web/map.html (T028)"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1 (Setup) and Phase 2 (Foundational — `web/plots.js` fully tested, `parse_failed` propagated).
2. Complete Phase 3 (User Story 1): the world SVG, camera group, and identity-derived coordinates.
3. **STOP and VALIDATE** against quickstart.md §4: coordinates hold across a status change and a reload.
4. This alone fixes the roadmap's stated reason to exist — the re-flow defect — even before reconciliation, trust rendering, wires or fitting are touched.

### Incremental Delivery

1. Setup + Foundational → the pure geometry and the fourth `parse_failed` consumer exist and are tested.
2. Add User Story 1 → validate independently (stable coordinates) → this is the MVP.
3. Add User Story 2 → validate independently (refresh no longer destroys state) → the two P1 stories are both satisfied.
4. Add User Story 3 → validate independently (four honest sentences) → the honesty half of the entry lands.
5. Add User Story 4 → validate independently (wires survive the world/camera transform) → regression risk from Phase 3 is closed.
6. Add User Story 5 → validate independently (fit-without-panning) → the entry is feature-complete.
7. Cross-cutting invariants, test coverage and polish close out the diff.

### Parallel Team Strategy

With multiple contributors, after Foundational (Phase 2) completes:

- One contributor: User Story 1 (Phase 3), then User Story 2 (Phase 4) on top of it.
- A second contributor: User Story 3 (Phase 5) — independent of the drawing primitives.
- Once Phase 3 lands: a third contributor picks up User Story 4 (Phase 6) and User Story 5 (Phase 7) in sequence, since both depend on it.
