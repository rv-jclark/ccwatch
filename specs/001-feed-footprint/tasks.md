---

description: "Task list for Feed — idle-aware refresh, visibility-paused polling, conditional responses"
---

# Tasks: Feed — idle-aware refresh, visibility-paused polling, conditional responses

**Input**: Design documents from `/specs/001-feed-footprint/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/api-state.md, contracts/config.md, quickstart.md

**Tests**: Explicitly requested — FR-035–FR-040 and quickstart.md §1 require hermetic, mutation-checked assertions in `tests/run.sh` for each story, so test tasks are included.

**Organization**: Tasks are grouped by user story (US1/US2/US3, priority order from spec.md). All work lands in four files: `bin/ccwatch` (the `cmd_serve` section, ~line 2608–2955), `web/index.html`, `web/map.html`, `tests/run.sh` (the `serve` section, ~line 726). There is no `src/` tree and no build step (constitution).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Line numbers are anchors as of this writing; re-locate by the quoted symbol if the file has shifted.

---

## Phase 1: Setup

**Purpose**: Add the two new configuration tunables the rest of the feature reads.

- [X] T001 Add `CCWATCH_IDLE_GRACE` (default `15`) and `CCWATCH_SNAPSHOT_TIMEOUT` (default `90`, parsed as float) to `cmd_serve()` in `bin/ccwatch` (~line 2622), read with `${VAR:-default}` in the same style as the function's existing `port`/`open`/`readonly`/`allowkill` locals, and export both into the embedded python program's environment alongside `CCWATCH_SELF`, `CCWATCH_WEB`, `CCWATCH_BIND_PORT`, `CCWATCH_SEND_TOKEN`, `CCWATCH_ALLOW_KILL` (~line 2679-2680)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared state and wiring that every user story's phase depends on.

**⚠️ CRITICAL**: Complete before any user story phase.

- [X] T002 In the embedded python program in `bin/ccwatch`, read `CCWATCH_SNAPSHOT_TIMEOUT` from `os.environ` (default `90`) and use it as the `snapshot` collector's `_to` value in the `for _key, _args, _to, _every, _tf in (...)` tuple (~line 2939-2942), replacing the hard-coded `40`
- [X] T003 Add module-level `LAST_READ = time.monotonic()` and `GRACE = float(os.environ.get("CCWATCH_IDLE_GRACE", "15"))` beside `STATE = {"warming": True}` / `LOCK = threading.Lock()` in `bin/ccwatch` (~line 2707-2708)
- [X] T004 Stamp `global LAST_READ; LAST_READ = time.monotonic()` at the very top of the `/api/state` branch of `do_GET` in `bin/ccwatch` (~line 2906), before the response is built, and nowhere else — not in `/`, `/map`, `/api/transcript`, `/api/send` or `/api/kill` (FR-006)

**Checkpoint**: `LAST_READ`/`GRACE` exist and are stamped correctly; the snapshot timeout is configurable. User story work can begin.

---

## Phase 3: User Story 1 - Leaving the dashboard running costs nothing when nobody is looking (Priority: P1) 🎯 MVP

**Goal**: Collection stops when no client has read `/api/state` for longer than `GRACE`, resumes independently per collector on the next read, and both pages stop polling while hidden.

**Independent Test**: Start the server, open no page, observe no collection after the grace period and no measurable CPU; request `/api/state` once and observe collection resume.

### Implementation for User Story 1

- [X] T005 [US1] Rewrite `refresh_loop` in `bin/ccwatch` (~line 2735-2747) so each collector's closure holds its own `next_due` (initialised to `0.0`), and its loop: computes `now = time.monotonic()`; if `now - LAST_READ > GRACE`, sleeps a short `TICK` (0.25s) and continues **without** advancing `next_due`; else if `now < next_due`, sleeps `TICK` and continues; else runs the collection, publishes under `LOCK`, and sets `next_due = time.monotonic() + every` — per research.md decision 1's pseudocode. A collection already in flight is never interrupted (FR-004 falls out of checking the gate before starting work, not during it).
- [X] T006 [US1] In the `/api/state` branch of `do_GET` in `bin/ccwatch`, derive a per-request `feed` value — `"warming"` if no snapshot has ever succeeded, else `"idle"` if the *previous* `LAST_READ` (captured before T004's stamp overwrites it) was more than `GRACE` ago, else `"collecting"` — and add it to the payload. `feed` is derived per request, never stored (data-model.md's state machine).
- [X] T007 [P] [US1] In `web/index.html`, replace the bare `setInterval(tick, 3000)` (~line 359) with a single visibility-aware scheduler: one `every(ms, fn)` helper holding the one `setInterval` in the file, a `resume()` that returns immediately if `document.hidden`, otherwise calls `fn()` once and (re)starts the interval, wired to `visibilitychange`, and an initial call to `resume()` in place of the current unconditional `tick()` (~line 358) so a page that loads hidden never polls (FR-016, FR-017, FR-019)
- [X] T008 [P] [US1] In `web/map.html`, apply the same visibility-aware scheduler in place of `setInterval(tick, 3000)` (~line 689) and the unconditional `tick()` call (~line 688); guard the `resize` handler (~line 692) with `if (!document.hidden) tick();`; gate the open-conversation timer so `convoTimer = setInterval(loadConvo, 5000)` (~line 561) only runs while the inspector is open **and** the page is visible, clearing it on both `closeReply` (~line 566) and on hide, and restarting it on becoming visible again while the inspector is still open (FR-018)
- [X] T009 [US1] In `tests/run.sh`, in the `serve` section (~line 726 onward), add a mutation-checked assertion: start a server with `CCWATCH_IDLE_GRACE` set low, let it warm up, let the grace period lapse with no reader, assert `ages.snapshot` from a single read has not advanced by anywhere near the elapsed wall time (collection stopped), then read again and assert a following read shows fresh collection resuming and `.feed == "idle"` on that first post-idle read (FR-001, FR-002, SC-001). Mutation-check by reverting the gate to always collect, confirm the assertion fails, restore, and add the mutation row to README's mutation table (FR-036, FR-037).
- [X] T010 [US1] In `tests/run.sh`, add a static assertion guarding FR-020–FR-022: `grep -c requestAnimationFrame web/index.html web/map.html` reports `0` for both files, `grep -c 'setInterval(' web/index.html web/map.html` reports exactly `1` for each, and `grep -c visibilitychange web/index.html web/map.html` reports at least `1` for each. Mutation-check by temporarily adding a second `setInterval(` to one page, confirm the assertion fails, restore, and add the mutation row to README's mutation table.

**Checkpoint**: With T001-T010 done, the feed idles and resumes correctly, and both pages pause while hidden. This is independently testable and deployable as the MVP.

---

## Phase 4: User Story 2 - The dashboard never presents a resumed or cached reading as current (Priority: P2)

**Goal**: `/api/state` carries a strong validator covering every measurement, answers a matching `If-None-Match` with a bodyless `304`, and both pages recompute panel age from absolute `collected_at` instants so a `304` or a resumed collection never shows a stale reading as current.

**Independent Test**: Read the feed after an idle period and confirm the true measured age is reported; re-read with a matching validator and confirm a `304` with no body and no redraw, and that displayed panel ages are still correct.

### Implementation for User Story 2

- [X] T011 [US2] In the `/api/state` branch of `do_GET` in `bin/ccwatch` (~line 2906-2921), add `collected_at: {snapshot, deploys, peers}` to the payload, sourced from the existing `STATE[key + "_at"]` values (epoch seconds via `time.time()`, unchanged in kind) or `null` where a collector has never published
- [X] T012 [US2] In `bin/ccwatch`, compute the payload's `ETag` once per publish (not per request): serialise the payload with `ages`, `stale` and `feed` removed as canonical JSON (`sort_keys=True`, fixed separators), SHA-256 it, take the first 16 hex characters, double-quote it as a strong validator, and cache it under `LOCK` (e.g. `STATE["etag"]`) at the point each collector publishes
- [X] T013 [US2] In the `/api/state` branch of `do_GET` in `bin/ccwatch`, parse the request's `If-None-Match` header (split on `,`, each entry stripped; `*` matches any current payload); on an exact match against the cached `ETag`, call `send_response(304)` with `ETag` and `Cache-Control: no-cache, private` headers and no body (no `Content-Type`, no `Content-Length`); otherwise send `200` with those two headers plus `Content-Type: application/json` and `Content-Length`, replacing the existing `Cache-Control: no-store` (~line 2925) on this endpoint only — `/`, `/map` and `/api/transcript` keep `no-store` unchanged (FR-010, FR-011, FR-014)
- [X] T014 [P] [US2] In `web/index.html`: track the `ETag` of the last body received; on the `/api/state` fetch (~line 321), remove `{cache: "no-store"}` and send `If-None-Match` with the tracked value when present; on a `304` response, skip `res.json()` and the content redraw entirely but still repaint the freshness footer; change the footer's age computation (~line 343-346) to `Date.now()/1000 - collected_at[key]` for `snapshot`/`deploys`/`peers` instead of reading `s.ages` (FR-011, FR-013, FR-015)
- [X] T015 [P] [US2] In `web/map.html`: the same `ETag`/`If-None-Match` tracking and conditional-fetch change on the `/api/state` fetch (~line 609), skipping redraw on `304`, and changing the footer's age computation (~line 675-677) to use `collected_at` instead of `s.ages`
- [X] T016 [US2] In `tests/run.sh`, add a mutation-checked assertion: read `/api/state`, capture its `ETag`, re-read with that value as `If-None-Match` and assert `status=304`/`size_download=0`; re-read with a stale/unparseable validator and assert `200`; and assert the `ETag` is unchanged across two reads with no intervening collection even though their `ages` differ (FR-010, FR-011, FR-012). Mutation-check by including `ages` in the hash input, confirm the assertion fails (no two reads ever share an `ETag`), restore, and add the mutation row to README.
- [X] T017 [US2] In `tests/run.sh`, add an assertion that after a `304`, the true panel age is still derivable from `collected_at` in the previously-held body and is not frozen at the time that body was received (FR-013) — e.g. sleep between two conditional reads and confirm the client-computed age (from the first body's `collected_at`) tracks the sleep

**Checkpoint**: US1 and US2 both work independently; a `304` never hides a stale reading.

---

## Phase 5: User Story 3 - A slow snapshot never reads as a host with no sessions (Priority: P3)

**Goal**: A timed-out or failed snapshot collection is represented distinguishably from a genuinely empty host, the prior successful snapshot is retained with its true growing age, and `warming` means "no snapshot has ever succeeded."

**Independent Test**: Force a snapshot collection to exceed its ceiling and inspect the payload for `snapshot_ok`/`snapshot_error`/`sessions: null`, distinguishable from a genuinely empty host's `snapshot_ok: true`/`sessions: []`.

### Implementation for User Story 3

- [X] T018 [US3] Delete the `snapshot_ok()` transform in `bin/ccwatch` (~line 2749-2753) that fabricates `{"sessions": [], "unfinished": [], "error": …}` on a failed or malformed snapshot result, and remove it from the `_tf` slot of the `snapshot` tuple (~line 2940)
- [X] T019 [US3] Rework the publish step of `refresh_loop` in `bin/ccwatch` (built in T005) for the `snapshot` key specifically: on a successful `run()` result, publish `STATE["snapshot"]`, `STATE["snapshot_at"]`, set `STATE["snapshot_ok"] = True`, `STATE["snapshot_error"] = None`; on a failed/timed-out result, leave `STATE["snapshot"]` and `STATE["snapshot_at"]` untouched (so a retained snapshot's age keeps growing truthfully) and set `STATE["snapshot_ok"] = False`, `STATE["snapshot_error"]` to the failure reason (verbatim from the exception/timeout message) (FR-024, FR-025)
- [X] T020 [US3] In the `/api/state` branch of `do_GET` in `bin/ccwatch`: publish `snapshot_ok` and `snapshot_error` from `STATE`; redefine `warming` as `STATE.get("snapshot_at") is None` (no snapshot has ever *succeeded*) rather than "no publish has happened yet"; when `warming` is true, publish `sessions: null` and `unfinished: null` instead of `[]` (FR-026); mirror a non-null `snapshot_error` into the existing top-level `error` key so `web/index.html`'s footer surfaces it unchanged (FR-027)
- [X] T021 [US3] In `tests/run.sh`, add a mutation-checked assertion: start a server with `CCWATCH_SNAPSHOT_TIMEOUT` forced very low (e.g. `0.001`), read `/api/state`, and assert `snapshot_ok: false`, `snapshot_error` names the timeout, `warming: true`, `sessions: null`; separately assert a healthy server on a fabricated host with no sessions reads `snapshot_ok: true`, `snapshot_error: null`, `sessions: []` — the two payloads distinguishable by inspection alone (FR-024, FR-026, SC-007). Mutation-check by restoring the old `snapshot_ok()` fabrication, confirm the assertion fails, restore the fix, and add the mutation row to README.
- [X] T022 [US3] In `tests/run.sh`, add an assertion that once one snapshot has succeeded, forcing subsequent failures retains the last successful `sessions` list in the payload and lets `ages.snapshot` keep growing rather than resetting to near-zero (FR-025)

**Checkpoint**: All three user stories work independently; the feed footprint, freshness truthfulness and failure-visibility fixes are all in place.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Documentation, the counted-assertion floor, and end-to-end validation.

- [X] T023 [P] Raise `TALLY_FLOOR` in `tests/run.sh` (~line 33) to cover the assertions added in T009, T010, T016, T017, T021, T022 (FR-038)
- [X] T024 [P] Add `CCWATCH_IDLE_GRACE` and `CCWATCH_SNAPSHOT_TIMEOUT` rows to the Configuration table in `README.md` (~line 590-615), each with its default and what it controls, matching the style of the existing rows (FR-029)
- [X] T025 [P] Add the mutation rows from T009, T010, T016, T021 to the mutation-checked table in `README.md` (~line 647-677) (FR-037)
- [X] T026 Add the measured duty-cycle figures to the Performance section of `README.md` (~line 700-716): before/after CPU-over-60s for the three conditions (no client, hidden tab, visible tab), with the live session population noted alongside, using the `times`-based measurement method from research.md and quickstart.md §6 (FR-028, SC-001-SC-003)
- [ ] T027 Run `./tests/run.sh` and confirm `shellcheck -x -S warning` is clean for `bin/ccwatch` and `tests/run.sh`, and the full suite passes (or skips with a stated reason) at or above the raised `TALLY_FLOOR` (SC-011)
- [ ] T028 Manually validate quickstart.md scenarios 3, 5, 7 and 9 end to end: a read is never made to wait (SC-004), the failed-vs-empty snapshot distinction in a browser, both pages' pause/resume-on-visibility behaviour including the two-tabs and loads-hidden edge cases (SC-009), and `ccwatch once`/`ccwatch doctor` output unchanged (FR-033); confirm both pages remain pixel-identical for the same payload (SC-012)

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup (T001's tunables are read by T002/T003). Blocks all user stories.
- **User Stories (Phase 3-5)**: All depend on Foundational. US1, US2 and US3 touch the same functions in `bin/ccwatch` (`refresh_loop`, the `/api/state` branch of `do_GET`) so within `bin/ccwatch` they are easiest to implement in priority order (US1 → US2 → US3) even though each is independently testable once its own tasks land. The two web-page tasks in each story ([P]-marked) are independent of each other and of the other stories' page tasks.
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### User Story Dependencies

- **User Story 1 (P1)**: No dependency on US2/US3. Independently shippable as the MVP.
- **User Story 2 (P2)**: Builds on US1's `refresh_loop` rewrite (T005) and `feed` derivation (T006) for its own payload additions, but is independently testable per its own acceptance scenarios.
- **User Story 3 (P3)**: Builds on US1's `refresh_loop` rewrite (T005) for where the failure-retention logic hooks in, and is independently testable per its own acceptance scenarios.

### Within Each User Story

- `bin/ccwatch` tasks are sequential (same functions, same file).
- The two web-page tasks in US1 (T007, T008) and in US2 (T014, T015) are `[P]` — different files, no dependency between them.
- Test tasks (T009/T010, T016/T017, T021/T022) follow their story's implementation tasks.

### Parallel Opportunities

- T007 and T008 (US1 page changes) in parallel.
- T014 and T015 (US2 page changes) in parallel.
- T023, T024, T025 (Polish: floor, config table, mutation table) in parallel; T026 depends on running the measurement method, so do it after or alongside.

---

## Parallel Example: User Story 1

```bash
# Launch both page-scheduler rewrites together — different files:
Task: "Replace setInterval(tick, 3000) with a visibility-aware scheduler in web/index.html"
Task: "Replace setInterval(tick, 3000) with a visibility-aware scheduler, plus the resize guard and conversation-timer gating, in web/map.html"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001).
2. Complete Phase 2: Foundational (T002-T004) — CRITICAL, blocks all stories.
3. Complete Phase 3: User Story 1 (T005-T010).
4. **STOP and VALIDATE**: run quickstart.md §2, §7, §8 by hand; confirm SC-001, SC-002, SC-009, SC-010.
5. This alone is a shippable, resource-saving improvement with no truthfulness change yet.

### Incremental Delivery

1. Setup + Foundational → attention signal and configurable tunables exist.
2. Add User Story 1 → validate independently → the feed idles and resumes, pages pause when hidden.
3. Add User Story 2 → validate independently → `304`s are honest and freshness survives them.
4. Add User Story 3 → validate independently → a failed snapshot is never mistaken for an empty host.
5. Polish → README figures, mutation table, raised floor, full suite green.

### Parallel Team Strategy

With multiple developers, after Foundational is done: one developer takes the `bin/ccwatch` side of each story in priority order (since they share functions), while a second takes the paired web-page tasks (T007/T008, then T014/T015) as each story's server-side pieces land.
