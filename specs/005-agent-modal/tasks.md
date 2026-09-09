---

description: "Task list for the per-agent modal replacing #reply"
---

# Tasks: Map — per-agent modal with stats, conversation, chat, and a visible kill gate

**Input**: Design documents from `/specs/005-agent-modal/`
**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/modal-js.md](./contracts/modal-js.md), [contracts/page-modal.md](./contracts/page-modal.md), [quickstart.md](./quickstart.md)

**Tests**: FR-051–FR-056 require every new assertion to be hermetic, mutation-checked, and to raise `TALLY_FLOOR`. Test tasks are therefore included throughout, not optional.

**Organization**: Tasks are grouped by user story so each can be implemented and verified independently. `web/modal.js` is a pure module (no DOM, no fetch, no timers, no `localStorage`, no `require`, no global read — D2) and is the file most tasks touch first; `web/map.html` is the only file that touches the document, and `bin/ccwatch` is touched by no task in this list (FR-035, FR-047, FR-048).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files or independent regions, no dependency on an incomplete task)
- **[Story]**: US1–US6, mapping to the spec's priority-ordered user stories
- File paths are exact

## Path Conventions

Single-file CLI tool serving static pages — no `src/`, no build step:

- `web/modal.js` — NEW pure module (this feature's only new file)
- `web/map.html` — MODIFIED (the only page touched; `#reply` is replaced by `<dialog id="agentmodal">`)
- `tests/run.sh` — MODIFIED (new `modal-module` section; new guards in the `serve` section; raised `TALLY_FLOOR`)
- `README.md` — MODIFIED (the modal documented, the disabled-kill-control rationale stated, plus one mutation-table row per new assertion)
- `bin/ccwatch` — **UNCHANGED** by this feature (FR-035, FR-047, FR-048). No task in this list touches it.

---

## Phase 1: Setup

**Purpose**: Bring the new module into existence in the shape the suite and the page both expect, before any behaviour is built.

- [X] T001 Create `web/modal.js` as a fifth static module mirroring `web/roster.js`'s IIFE shape: `(function (root) { "use strict"; ... root.CCWATCH_MODAL = api; if (typeof module !== "undefined" && module.exports) module.exports = api; })(typeof globalThis !== "undefined" ? globalThis : this);` with an empty `api = {}` for now, per contract `modal-js.md` header
- [X] T002 [P] Add a `<script src="/modal.js">` tag to `web/map.html` immediately after the existing `<script src="/roster.js">` tag, per contract `page-modal.md` §8 load order
- [X] T003 [P] Add a new `modal-module` section to `tests/run.sh`, run under `node` in the same harness shape as the existing `plots`, `camera` and `roster-module` sections, `t_skip`-ing with the reason when `node` is absent (FR-056); seed it with one assertion that `require("./web/modal.js")` succeeds and exports an object

**Checkpoint**: `web/modal.js` exists, is loaded by the page, and is exercised by the suite — every later task adds to something already wired end to end.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The frozen constants, the dialog's DOM skeleton, the render call site, and the openers' shared plumbing every user story's stats, kill gate, conversation, and modal behaviour build on top of.

**⚠️ CRITICAL**: No user story task can be verified until this phase is complete.

- [X] T004 Add the two frozen constants to `web/modal.js` per contract `modal-js.md` §1 — `FOLLOW_EPS` (`8`), `TRANSCRIPT_N` (`40`) — and export both
- [X] T005 [P] Add `dur(s)` to `web/modal.js`, duplicated (not imported, D2) from `web/roster.js`'s formatter and the page's own, matching the four bands and units (D‑A); yield `"-"` for `null` (D‑B); export it
- [X] T006 In `web/map.html`, replace `#reply` (`web/map.html:320-333`) with `<dialog id="agentmodal" aria-labelledby="ilead iname">` containing `#ihead` (`#ilead`, `#iname`, `#istatus`, `#iclose`), `#ifeed` (`.main`, `.unreadable` spans), `#igone`, `<dl id="istats">`, `#ask`, `#convo`, `#killbar`, `#ifoot` (`#replyText`, `#replySend`, `#sendwhy`), `#replyOut`, per contract `page-modal.md` §1 — built with `createElement`/`textContent` only, keeping the existing `#ask`/`#convo`/`#killbar`/`#ifoot`/`#replyText`/`#replySend`/`#replyOut` ids and their `askEls`/`killEls` builders (D4); confirm no `id="reply"` remains anywhere on the page (FR-001)
- [X] T007 In `web/map.html`, add the stylesheet additions from contract `page-modal.md` §2: `dialog#agentmodal` sizing (`max-width: min(760px, 92vw)`, `max-height: 88vh`, flex column) and `::backdrop`; `#istats` as a two-column label/value grid; `#ifeed .main.down`/`.main.warming` and `#igone` colours; `#killbar { display: flex }` always (no `display:none`/`.on` toggle) while `#killconfirm` keeps its `display:none`+`.on`; `#ifoot` never assigned `style.display`; the `@media (max-width: 720px)` rule at `CCWATCH_ROSTER.STACK_BREAKPOINT`'s value; `.agent:focus-visible .focusring { display: block }`; no transition or animation on the dialog, its backdrop or the focus ring (D19)
- [X] T008 In `web/map.html`, implement `renderModal()` per contract `page-modal.md` §3: guarded by `if (!subject) return;`, reads `row = lastRows[subject.sid] ?? null`, computes `fields`, calls `CCWATCH_MODAL.panel({...})`, and writes `#iname`/`#istatus`/`#ifeed`/`#igone`/`#istats` (via `reconcile()` keyed on `StatLine.key`) — writing into existing nodes only, never creating/removing/replacing panel structure (FR-040); stub the `#ask`/`#killbar`/`#ifoot` writes for later phases
- [X] T009 In `web/map.html`, implement `openModal(sid, name, kind)` and `closeModal()` per contract `page-modal.md` §4: `openModal` sets `subject`/`opener`, clears `#replyText`/`#replyOut`/`#killout`, removes `#killconfirm`'s `.on`, calls `renderModal()`, calls `#agentmodal.showModal()`, and focuses `#replyText` or `#iclose`; `closeModal` clears `subject`, calls `#agentmodal.close()`, and restores focus by identity (D5): live row for `opener.sid` → live figure for `opener.sid` → `#rosterlist` if it has rows → `#world`
- [X] T010 In `web/map.html`, call `renderModal()` from `applyFeed()` on every tick (in addition to `openModal`), so the panel stays current without being rebuilt (FR-014, FR-040)
- [X] T011 [P] In `web/map.html`, add a `#rosteropen` `<button>` to the roster header, outside `#rosterlist`, per contract `page-modal.md` §5 — labelled `open <name>` for the currently focused row and `disabled` with "no agents to open" when there are none — as the shared plumbing US1's and US5's openers both write to

**Checkpoint**: The dialog exists in the DOM, is styled, opens and closes, and renders on every tick — user story work can now proceed.

---

## Phase 3: User Story 1 - Open one agent and see everything the snapshot says about it (Priority: P1) 🎯 MVP

**Goal**: Every one of the twelve stats named in FR-008 appears in the modal, verbatim from the payload, reading identically to the roster row for the same snapshot, staying current as ticks arrive without being rebuilt around the reader.

**Independent Test**: Open the modal for a fixture session whose row carries a measurement, an age, a context percentage, a memory figure, a pipeline phase and a peer edge, and assert each one appears with the same text the roster row and the figure's hover reading give it.

### Implementation for User Story 1

- [X] T012 [P] [US1] Implement `statLines(fields, row, opts) → StatLine[]` in `web/modal.js` per data-model §4 and contract `modal-js.md` §4 — fixed order `silence, age, ctx, mem, pipeline, where, sid, edge:*`; `waited` wins over `quiet` for the `silence` line, absent when both are null; every absent `fields` key yields no line, never `0`/`0%`/`0MB`/`-`/`null`; `where` reads `"no repo"` verbatim from `fields.where`; `sid` line is `row.sid` verbatim; each `key` unique (S‑A…S‑I); export it
- [X] T013 [P] [US1] Implement `edgesFor(name, edges, names) → PeerEdgeLine[]` in `web/modal.js` per data-model §5 and contract `modal-js.md` §5 — kept when `e.from === name || e.to === name`, matched by name; `dir` from `from`/`to`; `count` verbatim, no re-aggregation; `unknown: true` when the far end is not in `names`; a self-edge yields one line; `edges: []`/`null`/absent `peers` yield `[]`; neither `last` nor `sample` reachable in the output; rendered text carries `to`/`from` as a word as well as the arrow (E‑A…E‑H); export it
- [X] T014 [P] [US1] Implement `panel(input) → PanelModel` in `web/modal.js` per data-model §4 and contract `modal-js.md` §3 — composes `statLines`, `edgesFor` (via `names`/`edges`), the header (`header.name` from `subject.name` verbatim, never `row.name`; `header.status` as `"<word> · <measure>"`/`"<word>"`/`null`, byte-identical to the roster row's `.rstatus` join); with `row: null`, `stats` contains exactly the `sid` line and both write controls are `disabled` (M‑A…M‑F); pure — no mutation of its argument; export it (feed/gone/ask/kill/send composed by later phases' tasks into the same function)
- [X] T015 [US1] In `web/map.html`, complete `renderModal()`'s `#istats` write from `m.stats` via `reconcile()`, building one `<dt>`/`<dd>` wrapper per `StatLine` keyed on `StatLine.key`, so a line appearing or disappearing does not rebuild the others (contract `page-modal.md` §3)
- [X] T016 [US1] In `web/map.html`, wire the figure opener (pointer): the existing document `click` handler on `.agent[data-sid]` (`web/map.html:1345-1352`) calls `openModal(sid, name, "figure")` unchanged otherwise, so `drag.moved` is still consumed in exactly one place (FR-005, D8)
- [X] T017 [US1] In `web/map.html`, wire the roster opener (pointer and keyboard): `#rosteropen` (from T011) calls `openModal` for the focused row's `sid`/`name`; `dblclick` on a `.rrow` is added as a shortcut to the same call; neither changes the row's existing single-click selection behaviour (FR-004, D6)
- [X] T018 [US1] Add module assertions for `statLines` (S‑A…S‑I) to the `modal-module` section of `tests/run.sh`, including the FR-011 spot-check from `quickstart.md` §2 (a row with neither `waited` nor `quiet` and no `ctx`/`mem`/`age` yields exactly `where`/`sid`, no `0`/`0%`/`0MB`/`-`/`null`), each mutation-checked
- [X] T019 [P] [US1] Add module assertions for `edgesFor` (E‑A…E‑H) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [X] T020 [P] [US1] Add module assertions for `panel` (M‑A…M‑F) to the `modal-module` section of `tests/run.sh`, including a spot-check that `header.status` for a given `fields` is byte-identical to the roster row's `.rstatus` join (M‑C), mutation-checked
- [x] T021 [US1] Add a static guard to the `serve` section of `tests/run.sh` confirming `updateFigure` writes `aria-label` from the same `titleBits(row)` the `<title>` uses (research D6, contract `page-modal.md` §5), mutation-checked
- [X] T022 [US1] Add a "why the modal is handed `rowFields`'s output instead of formatting a stat twice" section to `README.md` (D2), and document the disabled-kill-control rationale FR-055 asks for; add one mutation-table row for each assertion added in T018–T021

**Checkpoint**: Opening the modal from a figure or a roster row shows all twelve stats, reading identically to the roster row, staying current on ticks — User Story 1 is independently demonstrable.

---

## Phase 4: User Story 2 - See that killing is possible, and why it is not available (Priority: P1)

**Goal**: The kill control is always present. Disabled, it names `--allow-kill`. Enabled, it keeps its two-step confirmation, names the memory it would free from the same volatile gate as every other reading, and warns on a running pipeline phase or a mid-turn session.

**Independent Test**: Render the modal against a payload with `can_kill: false` and assert a disabled kill control naming `--allow-kill` is present; render it against `can_kill: true` and assert the control is enabled and no unconditional kill request can be issued from the disabled state.

### Implementation for User Story 2

- [X] T023 [P] [US2] Implement `killModel(input) → KillModel` in `web/modal.js` per data-model §8 and contract `modal-js.md` §8 — `canKill: false` yields `state: "disabled"`, a reason naming `ccwatch serve --allow-kill`, and `confirmOpen: false` even when the caller passed `confirmOpen: true` (K‑A, K‑B); `canKill: true` with a row yields `state: "ready"` and a `confirm` object with `resume` exactly `"claude --resume <sid>"` (K‑C, K‑G); `frees` is `fields.mem` verbatim when volatile and present, `"an unknown amount"` when volatile and absent, and `null` with a `freesNote` when not volatile (K‑D…K‑F); `pipeline.status === "running"` sets `confirm.phase` and the paid-model-call sentence (K‑H); `token === "busy"` sets `confirm.busy` (K‑I); `row: null` yields `state: "disabled"` with a reason distinct from K‑A's (K‑J); no `state` outside `"ready"`/`"disabled"` (K‑K); export it and compose it into `panel()`
- [X] T024 [US2] In `web/map.html`, replace `renderKill`'s early return (`web/map.html:1254`) with a render that always writes `#killbar`: `#killstart.disabled = (m.kill.state !== "ready")`, `#killwhy ← m.kill.reason ?? ""`, and the confirmation step's fields (`confirm.name`, `confirm.frees`/`freesNote`, `confirm.resume`, `confirm.phase`, `confirm.busy`) written from `m.kill.confirm` (contract `page-modal.md` §3, §7)
- [X] T025 [US2] In `web/map.html`, add the independent handler guard to `doKill()`: return early unless `CAN_KILL` and a row is present, so the `disabled` attribute and the handler are two independent reasons no request is issued (FR-029, D17)
- [X] T026 [US2] In `web/map.html`, in `doKill()`'s `catch` arm, prefix the exception with "the kill request did not complete: " (`web/map.html:1335`, D22), so a transport failure reads distinctly from a refusal (FR-032) and from a success
- [X] T027 [US2] In `web/map.html`, remove `#killconfirm`'s `.on` class whenever `m.kill.confirmOpen` is false on a render, closing an open confirmation the instant `can_kill` flips false (FR-034, D18)
- [X] T028 [US2] Add module assertions for `killModel` (K‑A…K‑K) to the `modal-module` section of `tests/run.sh`, including the quickstart §2 spot-checks (ungated must still render a control naming the flag; withheld-is-not-unmeasured across the three `volatile`/`mem` inputs), each mutation-checked
- [X] T029 [US2] Add a static guard to the `serve` section of `tests/run.sh` confirming `#killbar` carries no `display:none` rule (FR-028) and that `#killstart`'s `disabled` attribute and `doKill()`'s guard are both present (D17), mutation-checked
- [X] T030 [US2] Add a section to `README.md` documenting the two-step kill confirmation's phase/busy warnings and the transport-failure wording, alongside FR-055's disabled-control rationale; add one mutation-table row for each assertion added in T028–T029

**Checkpoint**: The kill control is present in both states, the disabled state issues nothing, the enabled state keeps its confirmation and warnings, and a transport failure no longer reads as a refusal — User Story 2 is independently demonstrable.

---

## Phase 5: User Story 3 - Read what it is doing, without the transcript leaving the machine's own rules (Priority: P1)

**Goal**: The conversation keeps its existing reduction exactly, follows new turns only when already at the bottom, states three distinct sentences for the empty/failed cases, and polls on its own slower cadence that stops when the tab is hidden.

**Independent Test**: Open the modal against a fixture transcript containing a long assistant message, a tool use with an argument, and a large tool result; assert the text is truncated, the tool use shows its name and a short argument summary, the result shows its size and no part of its content, and the poll cadence while open is slower than the map's tick.

### Implementation for User Story 3

- [X] T031 [P] [US3] Implement `atBottom({scrollTop, scrollHeight, clientHeight}) → boolean` in `web/modal.js` per contract `modal-js.md` §7 with `FOLLOW_EPS = 8` — exactly at the bottom is true; within `FOLLOW_EPS` is true; one 12px line above is false; a box shorter than its viewport is true; non-finite or missing measurements return true rather than throwing (B‑A…B‑E); export it
- [X] T032 [P] [US3] Implement `convoMessage({row, ok, reason, turnCount}) → {message, isError}` in `web/modal.js` per data-model §11 and contract `modal-js.md` §11 — `row.entrypoint === "sdk-ts"` yields the embedded-SDK sentence regardless of `turnCount`; `ok: true, turnCount: 0` on a non-`sdk-ts` row yields a distinct "no turns yet" sentence; `ok: false` yields the reason verbatim with `isError: true`; `ok: true, turnCount > 0` yields `message: null`; no branch escalates the session's silence to a hang (C‑A…C‑E); export it
- [X] T033 [US3] In `web/map.html`, sample `CCWATCH_MODAL.atBottom(#convo)` in `renderConvo` **before** reconciling and, when true, set `scrollTop = scrollHeight` **after** (FR-018, D14)
- [X] T034 [US3] In `web/map.html`, replace the single empty-conversation string (`web/map.html:1094`) with `CCWATCH_MODAL.convoMessage(...)`'s result, driven by `row.entrypoint`, the transcript fetch's own `ok`/reason, and the turn count (FR-019, D15)
- [X] T035 [US3] In `web/map.html`, remove the `#replyText`-level `Escape` handler (`web/map.html:1340-1343`, D20) — the dialog's native `cancel` now covers every focus position
- [X] T036 [US3] Confirm the conversation's poll (`loadConvo`, `every("convo", 5000, loadConvo)`, `web/map.html:1023-1033`) is unchanged in cadence and still keyed to the same shared scheduler slot that stops with the rest of the page's periodic work when the tab is hidden (`resume()` unchanged), and reads `TRANSCRIPT_N` for its `n=40` parameter (FR-017, SC-011, D16)
- [X] T037 Add module assertions for `atBottom` (B‑A…B‑E) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [X] T038 [P] [US3] Add module assertions for `convoMessage` (C‑A…C‑E) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [X] T039 [US3] Add a static guard to the `serve` section of `tests/run.sh` confirming `setInterval` still occurs exactly once and `requestAnimationFrame` zero times in `web/map.html` (SC-010), and that the `.what` `innerHTML` write is still `CCWATCH_MD.render`'s escape-first render (FR-016), mutation-checked
- [X] T040 [US3] Add a section to `README.md` documenting the three transcript sentences and the follow-at-bottom behaviour; add one mutation-table row for each assertion added in T037–T039

**Checkpoint**: The conversation reduces exactly as before, follows the reader only when they are at the bottom, states three distinct sentences for its failure cases, and its own polling stops with the rest of the page — User Story 3 is independently demonstrable.

---

## Phase 6: User Story 4 - Answer the one that is blocked, and be told what actually happened (Priority: P1)

**Goal**: A recorded question keeps the most prominent place with its options whole; a waiting session with no question gets distinct wording; sending reports one of three distinct outcomes; a `--read-only` server shows the send control present and disabled.

**Independent Test**: Open the modal for a waiting fixture session with a recorded question and assert the question, its options and both statements are present; then for a waiting session with no recorded question and assert the distinct dialog wording; then exercise the send path for each of the three outcomes.

### Implementation for User Story 4

- [X] T041 [P] [US4] Implement `askModel(row) → AskModel` in `web/modal.js` per data-model §7 and contract `modal-js.md` §10 — a row with `questions` yields `kind: "questions"`, the questions and options untruncated, and a `how` containing "queued behind it" / "does not answer it" (A‑A); no `questions` and `sev === 4` yields `kind: "dialog"` with a distinct `how` (A‑B); neither yields `kind: "none"` and no sentences at all (A‑C); `row: null` yields `kind: "none"` (A‑D); a 4KB question and a fifteen-option question are returned whole (A‑E); export it and compose it into `panel()`
- [X] T042 [P] [US4] Implement `sendModel(input) → SendModel` in `web/modal.js` per data-model §9 and contract `modal-js.md` §9 — `canSend: false` yields `state: "disabled"` and a reason naming `--read-only` (N‑A); `canSend: true` with a row yields `state: "ready"`, `reason: null` (N‑B); `row: null` yields `state: "disabled"` with a reason distinct from N‑A's (N‑C); export it and compose it into `panel()`
- [X] T043 [US4] In `web/map.html`, wire `#ask`'s render from `m.ask` (`askEls`, existing builder, D4): the question(s) and options above `#convo` (FR-020), the `how` statement, or nothing at all when `kind === "none"` (FR-023)
- [X] T044 [US4] In `web/map.html`, replace `$("ifoot").style.display = CAN_SEND ? "flex" : "none"` (`web/map.html:1302`) with a render from `m.send`: `#replyText.disabled = #replySend.disabled = (m.send.state !== "ready")`, `#sendwhy ← m.send.reason ?? ""` — `#ifoot` never assigned `style.display` (FR-026, contract `page-modal.md` §2, §7)
- [X] T045 [US4] In `web/map.html`, add the independent handler guard to `doSend()`: return early unless `CAN_SEND` and a row is present (FR-027, D17)
- [X] T046 [US4] In `web/map.html`, in `doSend()`'s `catch` arm, prefix the exception with "the send request did not complete: " (`web/map.html:1289`, D22), distinct from a refusal and a delivered/queued outcome (FR-024)
- [X] T047 [US4] Add module assertions for `askModel` (A‑A…A‑E) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [X] T048 [P] [US4] Add module assertions for `sendModel` (N‑A…N‑C) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [X] T049 [US4] Add a static guard to the `serve` section of `tests/run.sh` confirming both `doSend` and `doKill`'s `fetch` calls still carry `X-CCWatch-Token` (2 occurrences), the `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` line is byte-identical, and `#ifoot` is never assigned `style.display` in `web/map.html` (FR-025, FR-026), mutation-checked
- [X] T050 [US4] Add a section to `README.md` documenting the ask panel's two wordings and the three send outcomes including the transport-failure wording; add one mutation-table row for each assertion added in T047–T049

**Checkpoint**: The pending-ask panel shows the right wording for both waiting shapes and none at all otherwise, sending reports one of three distinct outcomes, and a read-only server shows the send control present and disabled — User Story 4 is independently demonstrable.

---

## Phase 7: User Story 5 - Operate it as a modal, without losing work to a tick (Priority: P2)

**Goal**: The modal opens by keyboard from a figure or a roster row with focus moving in and trapped; Escape closes it and returns focus to the opener; a half-typed message, scroll position, and an open confirmation survive ticks; replacing the subject discards the previous session's in-progress state wholly.

**Independent Test**: Open the modal from a roster row by keyboard, assert focus is inside it and cannot leave by Tab, assert Escape closes it and returns focus to the row; drive several ticks with a message half-typed and a confirmation open, and assert both survive.

### Implementation for User Story 5

- [x] T051 [US5] In `web/map.html`, make each `<g class="agent">` focusable per contract `page-modal.md` §5: `tabindex="0"`, `role="button"`, `aria-haspopup="dialog"`, and an `aria-label` of `"agent <name>: " + titleBits(row)` written in `updateFigure`; `Enter`/`Space` calls `openModal(sid, name, "figure")` (FR-002)
- [x] T052 [US5] In `web/map.html`, add the `<rect class="focusring">` to each `.agent` group and the `.agent:focus-visible .focusring { display: block }` rule (already added in T007) referencing it, so the drawn indicator survives every tick the way the selected-figure emphasis does (D7)
- [x] T053 [US5] In `web/map.html`, add the `o` key to the existing `#rosterlist` `keydown` handler, opening the modal for `focusedSid`; add `aria-keyshortcuts="o"` to `#rosterlist` and update `#rosternote` to state both roster paths in words (click selects and flies; `o` or a double click opens) (FR-003)
- [X] T054 [US5] In `web/map.html`, ensure `openModal` resets every per-subject field (message text, outcome text, confirmation step) when called for a second session while one is open, so nothing from the previous subject appears under the new one (FR-006)
- [X] T055 [US5] In `web/map.html`, remove `Enter`'s implicit submit risk by confirming the dialog has no `<form method="dialog">` (already true from T006) and that `Enter` in `#replyText` calls `doSend` and nothing else (D20)
- [ ] T056 [US5] Add a static guard to the `serve` section of `tests/run.sh` confirming `web/map.html` contains no `<form method="dialog">` inside `#agentmodal`, that `showModal()` occurs exactly once, and that each `.agent` group carries `tabindex` and `role="button"` (FR-036, FR-038, D3), mutation-checked
- [ ] T057 [US5] Add a static guard to the `serve` section of `tests/run.sh` confirming `#rosteropen` is created outside `#rosterlist` (research D6: `role="option"` has presentational children) and that `#rosterlist` carries `aria-keyshortcuts`, mutation-checked
- [x] T058 [US5] Add a section to `README.md` documenting the four openers (figure/pointer, figure/keyboard, roster/keyboard, roster/pointer) and why a per-row button inside the listbox was rejected (research D6); add one mutation-table row for each assertion added in T056–T057

**Checkpoint**: The modal is fully keyboard-operable from both openers, Tab stays trapped, Escape returns focus correctly, and in-progress state survives ticks and subject changes — User Story 5 is independently demonstrable.

---

## Phase 8: User Story 6 - Know when what the modal shows cannot be believed (Priority: P2)

**Goal**: The modal restates the page's own feed condition — feed down with reason and age, warming with neither, an additive unreadable count — and states a vanished session distinctly from all of those, retaining identity fields throughout.

**Independent Test**: Open the modal, then make `/api/state` fail; assert the modal states the feed is down with the reason and the measured age, that the volatile readings are withheld, and that the identity fields remain.

### Implementation for User Story 6

- [x] T059 [P] [US6] Implement `feedLines(cond) → {main, mainKind, unreadable}` in `web/modal.js` per data-model §6 and contract `modal-js.md` §6 — `feed_down` yields `mainKind: "down"`, the reason verbatim, and the age via `dur()` (F‑A); `warming` yields `mainKind: "warming"`, no age, no reading (F‑B); `ok` yields `main: ""`, `mainKind: ""` (F‑C, principle XII); `unreadable` is a separate string, never a substring of `main`, empty for `0`/`null`/`undefined` (F‑D), and produced additively even under `feed_down` (F‑E); no branch prints `0s`/`0`/`null`/`undefined` for an absent `dataAge`/`reason`/`unreadable` (F‑H); export it and compose it into `panel()`
- [x] T060 [P] [US6] Implement `goneText(name, sid) → string` in `web/modal.js` per data-model §6 and contract `modal-js.md` §6 — names the session, states it left the machine's session list, includes `claude --resume <sid>`, and shares no leading clause with any `feedLines` string (F‑F); export it and compose it into `panel()`
- [x] T061 [US6] Add the pairwise-distinctness assertion (F‑G, SC-009) to the `modal-module` section of `tests/run.sh`: the three `feedLines` `main` values, the additive `unreadable` string, and `goneText` are five pairwise-distinct, non-empty-filtered strings — the quickstart §2 spot-check, mutation-checked
- [x] T062 [US6] In `web/map.html`, wire `#ifeed` from `m.feed` (`.main` text and `mainKind` class, `.unreadable` text — separate nodes, never joined) and `#igone` from `m.gone` (toggling `.on`), per contract `page-modal.md` §3; ensure `panel()` only produces a non-null `m.gone` when `row === null` **and** `cond.trust === "ok"` (D13), and that stats other than `sid` are dropped when `row === null` (M‑E)
- [x] T063 [US6] In `web/map.html`, confirm `renderModal()` reads the same `cond`/`lastCond` object `computeFeedCondition`/`renderTrust` already compute (`web/map.html:1677-1692`) rather than deriving a second one (Constitution XI, FR-048)
- [x] T064 [US6] Add module assertions for `feedLines` (F‑A…F‑E, F‑H) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [x] T065 [P] [US6] Add module assertions for `goneText` (F‑F) and for `panel`'s `row: null` behaviour (M‑E) to the `modal-module` section of `tests/run.sh`, mutation-checked
- [ ] T066 [US6] Add a static guard to the `serve` section of `tests/run.sh` confirming `renderModal`'s `cond` argument is the same variable `renderTrust`/`applyFeed` compute (no second `computeFeedCondition` call site introduced), mutation-checked
- [x] T067 [US6] Add a section to `README.md` documenting the five pairwise-distinct renderings (three feed states, the additive unreadable count, and the vanished-session tombstone); add one mutation-table row for each assertion added in T061, T064–T066

**Checkpoint**: All five failure-adjacent renderings — feed down, warming, ok (silent), the additive unreadable count, and gone — read as pairwise-distinct sentences, and identity fields survive every one of them — User Story 6 is independently demonstrable.

---

## Phase 9: Polish & Cross-Cutting Concerns

**Purpose**: Close out the invariants that span every story, and the documentation and count checks FR-046–FR-056 require of the feature as a whole.

- [ ] T068 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming `web/map.html`'s `innerHTML` assignment count is still exactly 2 (the once-built legend and the escape-first turn body, FR-049), mutation-checked
- [ ] T069 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming the `if (drag.moved)` check remains consumed in exactly one place (FR-005, D8), mutation-checked
- [ ] T070 [P] Add a static guard to the `serve` section of `tests/run.sh` confirming the script load order is `src="/roster.js"` immediately before `src="/modal.js"` (contract `page-modal.md` §8, D2), mutation-checked
- [x] T071 [P] Add the export-surface spot-check from `quickstart.md` §1 as an assertion in the `modal-module` section: `Object.keys(require("./web/modal.js")).sort()` matches exactly contract `modal-js.md` §13's list — in particular no `sort`, `severity`, `statusOf` or `rowFields` — mutation-checked
- [x] T072 Verify FR-046's no-regression list by hand against the pre-feature build: identity-derived figure positions, the camera and its level-of-detail behaviour, the persisted viewport, the roster's order/selection/width, and the four feed conditions above the map all still behave unchanged
- [x] T073 Raise `TALLY_FLOOR` in `tests/run.sh` (currently `455`) by the exact number of assertions added across T003, T018–T021, T028–T029, T037–T039, T047–T049, T056–T057, T061, T064–T066, and T068–T071 (FR-054)
- [x] T074 Run `shellcheck -x -S warning` against `bin/ccwatch` and `tests/run.sh` and resolve any new warnings introduced by this feature's shell changes, using a narrow `# shellcheck disable=` with a stated reason only where unavoidable (FR-056)
- [x] T075 Run `./tests/run.sh` end to end and confirm: the tally is at or above the raised `TALLY_FLOOR`; `git diff --stat main -- bin/ccwatch` is empty (FR-035); `./bin/ccwatch once` and `./bin/ccwatch doctor` are unchanged from the pre-feature build for one fabricated fixture (SC-010)
- [ ] T076 Perform the manual browser validation pass in `quickstart.md` §4 for all six stories (US1–US6 checklists), including the reduced-motion pass and the narrow-viewport pass

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — can start immediately.
- **Foundational (Phase 2)**: Depends on Setup (`web/modal.js` and its script tag must exist before the page can call into it) — **BLOCKS** all user stories.
- **User Story 1 (Phase 3)**: Depends on Foundational. No dependency on any other story.
- **User Story 2 (Phase 4)**: Depends on Foundational and on US1's `panel()`/`renderModal()` plumbing (T014/T015) existing to compose into.
- **User Story 3 (Phase 5)**: Depends on Foundational only; independent of US1/US2 behaviourally, though it shares `renderModal()`'s call site.
- **User Story 4 (Phase 6)**: Depends on Foundational and on US1's `panel()` (T014) to compose `askModel`/`sendModel` into.
- **User Story 5 (Phase 7)**: Depends on Foundational (the dialog, `openModal`/`closeModal`) and on US1's roster/figure opener wiring (T016/T017) to extend with keyboard paths.
- **User Story 6 (Phase 8)**: Depends on Foundational and on US1's `panel()` (T014) to compose `feedLines`/`goneText` into.
- **Polish (Phase 9)**: Depends on all six stories being complete.

### Within Each User Story

- Pure `web/modal.js` functions (marked `[P]`) can be implemented in parallel with each other, since each is a self-contained export with no shared mutable state.
- `web/map.html` wiring tasks depend on the `web/modal.js` functions they call, and are not marked `[P]` against each other within a story where one wiring task's DOM is read by the next.
- Test tasks depend on the implementation they assert against, and are mutation-checked only after the implementation lands.
- README tasks are last in each story, once that story's assertions exist to be counted in the mutation table.

### Parallel Opportunities

- All Setup tasks marked `[P]` (T002, T003) can run in parallel once T001 exists.
- Foundational tasks T004/T005 (`[P]`) can run in parallel; T006–T011 touch the same file (`web/map.html`) and are sequenced.
- Within US1: T012, T013, T014 (`[P]`) are independent `web/modal.js` exports and can be built in parallel; T015–T017 depend on them.
- Within US2: T023 (`[P]`) is the sole independent unit; T024–T027 wire it into the page.
- Within US3: T031, T032 (`[P]`) are independent `web/modal.js` exports; T033–T036 depend on them.
- Within US4: T041, T042 (`[P]`) are independent `web/modal.js` exports; T043–T046 depend on them.
- Within US5: T051–T055 all touch `web/map.html`'s opener/focus plumbing and are sequenced.
- Within US6: T059, T060 (`[P]`) are independent `web/modal.js` exports; T062–T063 depend on them.
- Different user story phases (US1–US6) touch overlapping regions of `web/map.html`'s `renderModal`, so — despite being logically independent — they are safest implemented in priority order rather than by literally parallel developers, unless coordinated by function/region ownership.

---

## Parallel Example: User Story 1

```bash
# Launch the independent web/modal.js exports for User Story 1 together:
Task: "Implement statLines(fields, row, opts) in web/modal.js"
Task: "Implement edgesFor(name, edges, names) in web/modal.js"
Task: "Implement panel(input) in web/modal.js"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (blocks everything).
3. Complete Phase 3: User Story 1.
4. **STOP and VALIDATE**: fabricate a session carrying all twelve stats, open its modal from a figure and from a roster row, and confirm every value reads identically to the roster row's text and the figure's hover reading (SC-002).
5. This alone discharges the reason the modal replaces `#reply` (spec Overview, defect 3) even with the kill control still hidden, the send control still unstyled for read-only, and no keyboard opener yet.

### Incremental Delivery

1. Setup + Foundational → the dialog exists and opens/closes without wiring wrong.
2. Add User Story 1 → all twelve stats, verbatim and current → validate independently (MVP).
3. Add User Story 2 → the visible, disabled-with-reason kill control → validate independently (completes the named defect).
4. Add User Story 3 → the conversation's three sentences and follow-at-bottom → validate independently.
5. Add User Story 4 → the ask panel and the three send outcomes → validate independently (completes the P1 set).
6. Add User Story 5 → full keyboard operation and tick-survival → validate independently.
7. Add User Story 6 → the five pairwise-distinct failure renderings → validate independently.
8. Polish → raise `TALLY_FLOOR`, run `shellcheck`, confirm the `bin/ccwatch` diff stays empty, run the full manual pass.

### Parallel Team Strategy

With multiple developers, after Foundational is done: one developer takes US1 (the blocker every other story composes into via `panel()`), and once US1's `panel()` shape lands, a second developer starts US2 while a third starts US4 — both are independent compositions into the same function. US3 and US5 can proceed in parallel with US1 once Foundational is done, since neither depends on `panel()`'s stat/kill/send composition. US6 queues behind US1 for the same reason as US2/US4.

---

## Notes

- `[P]` tasks touch different exports or different files with no dependency on an incomplete task.
- `[Story]` labels map every user-story-phase task to its story for traceability back to the spec's acceptance scenarios.
- `web/modal.js` never derives a status, severity or verdict, and exports nothing named `sort`, `severity`, `statusOf` or `rowFields` (contract `modal-js.md` §13) — verify the export list after each story's tasks with `node -e 'const M=require("./web/modal.js"); console.log(Object.keys(M).sort().join(" "))'`.
- Every assertion added by a test task must be mutation-checked before being marked complete: break the implementation in the way the assertion describes, confirm the assertion fails, restore it, and add the mutation-table row in `README.md` in the same story's documentation task.
- `bin/ccwatch` is touched by no task in this list; `git diff --stat main -- bin/ccwatch` staying empty is the acceptance check in T075, not an aspiration.
- Stop at any checkpoint to validate that story independently before continuing — each is designed to be demonstrable on its own against a fabricated `~/.claude`.
