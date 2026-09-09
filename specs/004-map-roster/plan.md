# Implementation Plan: Map — docked agent roster, severity-sorted, keyboard navigable, camera fly-to

**Branch**: `004-map-roster-panel` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/004-map-roster/spec.md`

## Summary

Entry 002 deleted the map's per-tick severity sort because it moved every
project whenever one session changed state, and entry 003 built a camera over
the world it left behind but shipped no caller for it. This entry adds the thing
both of them were missing: a docked panel beside the city holding one row per
session, in the payload's own needs-you-first order, carrying as text every
claim a figure currently makes only in SVG, navigable by keyboard, and — when a
row is selected — emphasising its figure and flying the camera to it.

Three constructions carry the whole feature, and each one falls out of a
requirement rather than a preference:

- **The roster does not sort.** FR-010 requires the panel's sequence to be the
  payload's sequence so the terminal and the map cannot disagree, and the
  payload is already sorted `-max(sev, psev)` then `-(waited // quiet // 0)` at
  `bin/ccwatch:953`. So the page renders `s.sessions` in arrival order and
  contains no comparator at all — FR-008 and FR-009 are then asserted where
  they are computed, against `ccwatch --json`, which is a stronger test than
  asserting a second copy of the rule in the page (research D2). FR-011 follows:
  a severity change reorders the list because the payload reordered, and no
  ordering value can reach a coordinate because none is handed to `plots.js`.
- **Identity and sequence are reconciled separately.** The existing
  `reconcile()` primitive keeps create/update/remove by `sid`; a second pass
  applies the order with `insertBefore` on already-attached nodes, from a pure
  `reorderPlan(current, wanted)`. That is what keeps a focused row, a selected
  row, a hover, a text selection and the panel's scroll offset alive across a
  tick (FR-042) while making the sequence explicit — and it is why focus is
  restored **by `sid`**, since a move is a remove-and-insert and some engines
  drop focus through it (research D3, D4).
- **One formatter, two renderings.** `rowFields(row, {volatile})` produces the
  row's parts with absent readings *absent from the object*, and `map.html`'s
  `titleBits()` becomes a join over the same function. The figure's hover text
  and the roster row therefore cannot state different things about one session,
  which is what FR-012 asks for and what two formatters would satisfy only on
  the day they were written (research D12).

The pure arithmetic, wording and storage validation go in a new
`web/roster.js`, a fourth static module beside `md.js`, `plots.js` and
`camera.js`, for the reason `CLAUDE.md` gives for the second one: the suite can
`require()` it under `node` and assert on behaviour without a browser. The
static fallback in `serve` already serves everything under `web/`
(`directory=WEB`, `bin/ccwatch:2901`), so **`bin/ccwatch` is not modified by
this feature at all** — which is what makes FR-035, FR-036 and FR-037 true
literally rather than by inspection.

Two things found while reading the code for this entry are fixed here because
this entry is the first to reach them, and both are recorded rather than
absorbed silently:

1. `#camera.eased` reduces to `transition: none` under
   `prefers-reduced-motion`, and with no transition there is no
   `transitionend`, so the class that the listener removes would never be
   removed. It has never mattered because entry 003 shipped no caller. The fly
   therefore decides reduced motion in the page and passes `animate: false`,
   rather than relying on the stylesheet (research D8).
2. `#world` ships `viewBox="0 0 408 408"` and nothing syncs it to the element's
   pixel size until the first window resize, so the camera's screen-pixel
   arithmetic and the SVG user space disagreed on the first paint. Inserting the
   panel changes `#world`'s width anyway, so this feature must reflow once at
   load — and that reflow syncs the viewBox, making "1 world unit == 1 screen px
   at rung 2" true from the first frame as `contracts/page-camera.md §1` already
   claims (research D10).

Full reasoning, including what was rejected, is in
[research.md](./research.md) (D1–D21).

## Technical Context

**Language/Version**: ES2019-era browser JavaScript in static pages; bash 3.2
for the suite only; `python3` for the server (untouched); `node` for the module
assertions and therefore optional.

**Primary Dependencies**: none. No build step, no package manifest, no bundler,
no CDN fetch, no image or binary asset (FR-040). The feature is one new static
file, edits to one existing static file, and test and documentation changes.

**Storage**: `localStorage`, two new versioned records —
`ccwatch.map.selection.v1` holding `{v, sid}` and `ccwatch.map.roster.v1`
holding `{v, w}` — independent of `ccwatch.map.view.v1` and
`ccwatch.map.plots.v1`. Reached only through injected `getItem`/`setItem`, so
the suite can drive persistence, and a throwing storage, without a browser; the
first throw flips a one-way `persistence` flag and the panel *states* that the
selection and width will not be remembered (Constitution IV).

**Testing**: `./tests/run.sh` only — `shellcheck -x -S warning`, then the
assertions. A new `roster-module` section runs `web/roster.js` under `node` in
the same harness shape as the existing `plots` (`tests/run.sh:1818`) and
`camera` (`tests/run.sh:2048`) sections, emitting one `PASS|name|detail` line
per check and calling `t_skip` with the reason when `node` is absent. The
source-level page guards (listbox and option roles, the separator's ARIA, the
un-truncatable status line, the roster's listener target, the `VOLATILE`
line-order, the `CCWATCH_ROSTER` guard) join the existing `serve` section beside
the `innerHTML`, `setInterval` and `SEND_TOKEN` guards they must not disturb.
The FR-008–FR-010 ordering assertions go in the `ccwatch` section, against
`ccwatch --json` on a fabricated home. `TALLY_FLOOR` (currently `345`) is raised
by the number of new assertions.

**Target Platform**: macOS host (BSD `stat -f`, `ps -o lstart=`); the pages run
in a current Chromium/WebKit/Gecko browser on `127.0.0.1`.

**Project Type**: single-file CLI tool plus the static pages it serves. No
frontend/backend split, no new directory.

**Performance Goals**: the roster renders on a data change, a selection, a focus
change or a resize and at no other time (FR-041, SC-012); an unchanged order
produces zero DOM moves (`reorderPlan` → `[]`, SC-011); a selection produces
exactly one camera move however many ticks and reloads follow it (SC-006); the
page keeps exactly one `setInterval` and zero `requestAnimationFrame`, and
`innerHTML` stays at two assignments.

**Constraints**: no change to `bin/ccwatch`, the payload, the endpoints or the
terminal output (FR-035–FR-037, SC-010); `const SEND_TOKEN =
"__CCWATCH_SEND_TOKEN__";` byte-identical (FR-039); every claim reachable as
text (FR-012, Constitution VII); `ctx` and `mem` withheld through the one
existing `VOLATILE` gate (FR-028, Constitution III); the four failure sentences
distinct and mutually exclusive except the additive unreadable count (FR-025,
FR-029); no new `@media (prefers-reduced-motion: reduce)` block above the
existing `#camera.eased` one, because the shipped assertion reads the first such
block in the file.

**Scale/Scope**: one new ~300-line pure module; one new panel, one divider and
one row primitive in `map.html`; eighteen-plus rows is the size the spec's
scenarios describe. The numbers this plan settles are `WIDTH_DEFAULT = 320`,
`WIDTH_MIN = 220`, `WIDTH_MAX = min(560, 45% of the window)`,
`WIDTH_STEP/BIG = 16/64`, `STACK_BREAKPOINT = 720`, `NEAR_IDX = 5` and
`ASK_CHARS = 100`, each justified in [research.md](./research.md).

**Unknowns**: none. The spec's Assumptions section closed every open question as
a decision and left the numbers above to the plan, which research settled. No
NEEDS CLARIFICATION remains.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version 1.0.0. Each gate is stated as the question the principle
asks of *this* feature.

| # | Principle | Applies? | Gate and how the design passes |
|---|---|---|---|
| I | Never make a claim on one signal | yes | The roster introduces no verdict. Every word in a row is `row.token`, `row.note`, `row.pipeline.status` or a duration the payload supplied; the corroboration that licensed them happened in the collector and is unchanged. The one new *state* — a selection — is not a claim about a session, and its `gone` reading requires a **trusted** payload before it will say a session exited (FR-024, data-model §4 S2). **Pass.** |
| II | Print the measurement next to the verdict | yes | FR-002/FR-003 are the principle restated: every row carries the status word and the measurement that justified it, in the terminal's own wording (`bin/ccwatch:1092-1097`), and those two are the fields that may never be truncated at any width (FR-034, page contract §2). **Pass.** |
| III | A stale reading is withheld, not annotated | yes | `ctx` and `mem` are the whole volatile set and are *absent* from the row — not annotated, not `0%` — whenever `VOLATILE` is false, through the same single gate the map already uses (FR-028, research D13). The panel states the condition and the measured age of the rows it is still showing; the stable structure stays, the volatile numbers go (FR-027). **Pass.** |
| IV | A failure must never look like an absence | yes | Four obligations, all met: the four conditions read as four distinct sentences with the exclusion enforced in the formatter (FR-025, FR-029, contract §8 C‑F); a selected session that has *gone* is stated in its own sentence, distinct from all four (FR-023, C‑J); an unavailable `localStorage` is stated rather than silently degrading (data-model §8 P3); and `no repo` remains its own value rather than an empty repository (R‑B). **Pass.** |
| V | Never invent a status you did not read | yes | `word` is `row.token` verbatim, including a token the module has never seen (R‑A); there is no default arm anywhere in `roster.js` that manufactures a word, no `sev`→word mapping, and no export named `severity` or `statusOf` (contract §9). **Pass.** |
| VI | Say nothing rather than guess | yes | An `sdk-ts` row carries its note and no derived duration (R‑I); a `quiet == null` row states the payload's note and never a zero silence (R‑D); a directory with no remote reads `no repo` and is not folded into a repository (R‑B); an absent selection under an untrusted feed is `unknown` and says nothing at all (S‑C, S‑D). **Pass.** |
| VII | Colour is never the only carrier of meaning | yes | This is the entry's reason to exist. Every pose, colour, animation and fill level has a word or a number in its row (FR-012, SC-003); the map graphic is relabelled a companion view (FR-013); rows are focusable with one in the tab order and arrow/`Home`/`End`/`Enter` operation (FR-014, FR-015); the panel and each row expose accessible names from their visible text, plus a selected state (FR-016); the selection emphasis carries the word `selected`, not only a ring (research D17). `NO_COLOR` is a terminal concern and is untouched. **Pass.** |
| VIII | Delivery is observed, not assumed | n/a | No new action and no new write endpoint. `send` and `kill` are untouched; selecting a row performs no side effect outside the browser. |
| IX | Loopback is not a security gate | n/a | No new endpoint and no new write path. `/roster.js` is served read-only by the existing static fallback; the per-run token and the `Origin` check are untouched, and `SEND_TOKEN`'s literal line is preserved (FR-039). |
| X | Transcripts are sensitive | yes | Nothing on the roster path reads a transcript. The only transcript-derived text a row shows is the pending question the payload already carries and the ask panel already displays, bounded to 100 characters and written with `textContent`, never markup and never a link (research D21). The inspector's redaction rules and `md.js`'s escape-then-format discipline are untouched. **Pass.** |
| XI | One code path computes status | yes | The panel lays out, groups, orders and emphasises; it derives nothing. The order *is* the payload's order (D2); the condition is the object `computeFeedCondition` already produces, rendered a second time in the roster's own wording rather than recomputed (D14); `rowFields` is a formatter over payload fields with no branch that produces a value the payload did not supply. `/api/state` still invokes the commands the CLI does, and no collector changes. **Pass.** |
| XII | Normal conditions are silent | yes | `#rostercond` is empty unless one of the four conditions holds; `#rosternote` is empty unless `localStorage` refused; there is no "feed healthy", no "selection saved" and no standing row count banner beyond the list's own accessible name. **Pass.** |
| XIII | Position is stable; only status moves | yes | The principle the feature is most exposed to, and the reason the ordering is confined to the panel: a list is expected to be ordered, a spatial arrangement is expected to be remembered. The order reaches the DOM sequence of `#rosterlist`'s children and nothing else (FR-011, data-model §3 O3); nothing derived from `sev`, `psev`, `waited` or `quiet` is handed to `plots.js`, whose identity-only input rule (`web/map.html:428-431`) is untouched; a selection changes a figure's *emphasis*, never its coordinate; and a width change re-centres rather than refits, so the camera keeps the position the viewer chose (FR-033). **Pass.** |

**Additional constraints.** bash 3.2 and BSD `stat`/`ps`: unaffected —
`bin/ccwatch` is not modified, and the only shell change is the new section in
`tests/run.sh`, written in 3.2 forms. `python3 -c` never on stdin: unaffected.
`shellcheck -x -S warning` clean for both files: the new test section is the
only shell added (FR-048). No build step and no dependency: satisfied by one
more static file served by the existing fallback (FR-040). Runtime state under
`~/.claude/ccwatch/` is untouched — the selection and the width live in the
browser, where the viewport and the plot assignments already live, and
`~/.claude/ccwatch/roster.json` (the `resume` record that shares this feature's
name) is neither read nor written (data-model §9).

**Workflow gates.** New assertions are hermetic under `$WORK` via
`CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS`, never against live sessions
(FR-044); each is mutation-checked and gains a row in the `README.md` mutation
table (FR-045); `TALLY_FLOOR` is raised (FR-046); the `node`-dependent section
`t_skip`s with its reason rather than failing (FR-047); anything a test starts
is reaped by the existing `cleanup_suite` trap. `README.md` gains the two
sections FR-049 and FR-050 ask for — why volatile ordering lives in the roster
and not on the map, naming the re-orientation bug, and what a row states, how it
is ordered, how selection and the fly behave, and how the four conditions read —
plus the note that the panel is not `~/.claude/ccwatch/roster.json`. Fixtures
and examples stay generic (`acme/checkout-api`, `web-app`, `pricing`).

**Initial gate result: PASS.** No violation, no justification required.

**Post-design re-check (after Phase 1): PASS.** Phase 1 added five things worth
re-testing against the constitution, and each was checked:

1. **The DOM ordering pass** (research D3) is the one place a volatile value
   reaches the document. It reaches `#rosterlist`'s child order and nothing
   else; XIII is why it is a separate pass from `reconcile()` rather than a mode
   inside it, since three of `reconcile()`'s callers must never acquire an
   order. Re-checked against XIII: **pass**.
2. **The selection state machine** (data-model §4) introduces a state that
   outlives a row. `gone` is reachable only from a trusted payload, which is I
   and IV together; `unknown` renders nothing, which is VI. Re-checked:
   **pass**.
3. **`statements()` enforcing its own exclusion** (D14, C‑F) could have been
   read as a second computation of the feed's trust. It is not: it derives no
   status, reads the same `cond` object the banner reads, and only refuses to
   *print* the empty sentence when trust is not `ok`. Re-checked against XI:
   **pass**.
4. **The figure emphasis** is a new visual state, so I and VII apply: it is not
   a severity and corroborates nothing, and its textual equivalent is the word
   `selected` in the row. It is drawn on the outer `.agent` group rather than
   inside `.figart` precisely so a tick cannot destroy it (D17). Re-checked:
   **pass**.
5. **The load-time reflow** (D10) changes the map's initial apparent scale. It
   moves no world coordinate and refits nothing — it makes the screen-pixel
   arithmetic agree with the SVG user space, which is what the camera's contract
   already assumed. Re-checked against XIII and FR-038: **pass**, and recorded
   in the Summary rather than absorbed silently.

## Project Structure

### Documentation (this feature)

```text
specs/004-map-roster/
├── plan.md              # This file (/speckit-plan command output)
├── spec.md              # Feature specification
├── research.md          # Phase 0 output — D1–D21, decision/rationale/rejected,
│                        #   plus the eight numbers this plan settles
├── data-model.md        # Phase 1 output — RosterRow, the measurement, RosterOrder,
│                        #   Selection, FeedCondition, Tombstone, RosterWidth,
│                        #   the stored records, and what the roster does not read
├── quickstart.md        # Phase 1 output — the acceptance gate, the node checks,
│                        #   the static guards, and the per-story manual pass
├── contracts/           # Phase 1 output
│   ├── roster-js.md     #   the pure web/roster.js module: every function's
│   │                    #   inputs, outputs and asserted claims (R‑, O‑, K‑,
│   │                    #   S‑, W‑, P‑, C‑, T‑)
│   └── page-roster.md   #   what /map does: the new DOM, the stylesheet rules,
│                        #   the render call sites, the keyboard/pointer map,
│                        #   reflowWorld, the load order, and what must not change
├── checklists/
│   └── requirements.md  # spec-quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
web/
├── roster.js       NEW — the pure roster module: the nine constants, rowFields,
│                   titleText, dur, keysOf, reorderPlan, focusTarget, nextFocus,
│                   resolveSelection, flyIdx, clampWidth, stacked, and the two
│                   records' validate/load/save with an injected storage and a
│                   one-way `persistence` flag. No DOM, no fetch, no timers, no
│                   sort and no status. Exports window.CCWATCH_ROSTER with a
│                   module.exports tail, mirroring plots.js and camera.js.
│                   Served by the static fallback in `serve` — no route, and no
│                   bin/ccwatch change.
├── map.html        MODIFIED — <script src="/roster.js">; a #stage flex row
│                   wrapping the existing #wrap; #roster with its title, note,
│                   condition block, tombstone and #rosterlist listbox; the
│                   makeRow/updateRow primitive and the applyOrder pass;
│                   #rdivider as a role="separator" widget; renderRoster()
│                   called from applyFeed after VOLATILE is set, plus on
│                   selection, focus and width change; titleBits() delegated to
│                   CCWATCH_ROSTER.titleText; updateFigure() applying the
│                   .selected class from the page's selectedSid; centreBySid
│                   built inside drawWorld's existing figure loop; reflowWorld()
│                   extracted from the resize listener and called once at load;
│                   the stylesheet rules in contracts/page-roster.md §2; #world's
│                   aria-label gaining its companion clause.
├── camera.js       UNCHANGED — the fly goes through the CCWATCH_MAP_CAMERA
│                   facade entry 003 exposed for exactly this caller.
├── plots.js        UNCHANGED (FR-011 — no ordering value may reach placement)
├── md.js           UNCHANGED
└── index.html      UNCHANGED (FR-035 — the table view already has the order)

bin/ccwatch         UNCHANGED (FR-035, FR-036, FR-037, FR-040, SC-010)

tests/run.sh        MODIFIED — a new `roster-module` section running
                    web/roster.js under node (t_skip with the reason when
                    absent); new source-level page guards in the existing
                    `serve` section; the FR-008–FR-010 ordering assertions in
                    the existing `ccwatch` section; TALLY_FLOOR raised.

README.md           MODIFIED — why volatile ordering lives in the roster and not
                    on the map, naming the re-orientation bug (FR-049); what a
                    row states, how it is ordered, how selection and the camera
                    fly-to behave, and how the four conditions read in it
                    (FR-050); the note that this panel is not
                    ~/.claude/ccwatch/roster.json; one mutation-table row per
                    new assertion (FR-045).
```

**Structure Decision**: the existing layout, plus exactly one new file.
`ccwatch` is a single bash script serving static pages; there is no `src/`, no
test directory beyond `tests/run.sh`, and no build step to add one to.
`web/roster.js` is a fourth sibling of `md.js`, `plots.js` and `camera.js` for
the documented reason the second one exists — the suite can run it under `node`
and assert on behaviour without a browser (FR-044) — and because the static
fallback already serves everything in `web/`, adding it costs no route and no
change to `bin/ccwatch`. Every DOM concern stays in `web/map.html`: the module
is pure, the page is the only thing that touches the document.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified

No violations. The Constitution Check passed before Phase 0 and again after
Phase 1 design, and nothing in this feature requires a deviation to be
justified.

One thing the spec names as a gap and this plan does **not** close, recorded
here so it is not mistaken for delivered: opening a session's conversation
remains pointer-only. Reaching the inspector from a roster row by keyboard is
`map-agent-modal`'s work, because that entry replaces the inspector and
building the control twice would mean deleting one of them. This entry
discharges the *reading* half of Constitution VII — every claim reachable as
text — and leaves the *opening* half to the entry that owns the control (spec
Assumptions).
