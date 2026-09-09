# Implementation Plan: Map — per-agent modal with stats, conversation, chat, and a visible kill gate

**Branch**: `005-agent-modal` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/005-agent-modal/spec.md`

## Summary

The four entries before this one built the city, the camera over it and the
docked roster beside it. None of them touched the panel a click on a figure
opens: `#reply`, which predates the rebuild and hides the kill control
entirely when the server did not opt in, is not a modal, is not reachable from
the roster or the keyboard, shows three of the twelve stats the roster row now
carries, says nothing when the feed behind it stops, and writes its
`frees NMB` figure with no staleness gate. This entry replaces it with one
per-agent modal.

Four constructions carry the feature, and each falls out of a requirement
rather than a preference:

- **The rendering decisions move into a fifth static module, `web/modal.js`.**
  FR-050 asks for it and names the precedent. Almost everything this entry can
  get wrong is a *sentence*: SC-001 is one sentence, SC-007 is six, SC-009 is
  five that must be pairwise distinct, and FR-011's "never `0MB`" is a claim
  about every branch that formats a reading. Sentences are cheap to assert
  under `node` and expensive to assert in a browser, so `panel(input) →
  PanelModel` returns the whole rendering as data and `map.html` writes it into
  nodes built once at load (research D1, D2).
- **The surface is a native `<dialog>` opened with `showModal()`.** Four
  modal-behaviour requirements — focus moves in (FR-036), focus is trapped
  (FR-036), the panel is announced as a modal dialog (FR-038), and the content
  behind is not operable by keyboard (FR-039) — are things the platform already
  does and that hand-rolled code would have to keep doing correctly forever. It
  costs no dependency and no build step. FR-039's second clause is *already*
  true structurally and stays so: the map's `keydown` is bound to `#world`
  (`web/map.html:1502`), and the dialog is a `<body>` child outside
  `#stage`/`#wrap` (research D3).
- **The stats are the roster's own `fields` object, not a second formatter.**
  `panel()` is handed `CCWATCH_ROSTER.rowFields(row, {volatile: VOLATILE})`,
  so SC-002's "read identically to that snapshot's roster row" is true by
  construction rather than by vigilance, and the single `VOLATILE` gate keeps
  its property of being the one place to extend. That is also the fix for
  defect 5: the kill confirmation's memory figure reads `fields.mem` instead of
  `row.rss_mb`, so FR-033 falls out of the same gate as every other withheld
  reading (research D2, D9, D10).
- **A disabled capability is a real `disabled` control with its reason beside
  it.** `renderKill`'s early return (`web/map.html:1254`) becomes a `killModel`
  with two states, both of which render; the same for send on a `--read-only`
  server, where `#ifoot` is currently `display:none` (`web/map.html:1302`). The
  attribute suppresses the activation and the handler guards it too — two
  independent reasons no request leaves a disabled control (research D17).

Three defects found while reading the code for this entry are fixed here
because this entry is the first to reach them, and each is recorded rather than
absorbed silently:

1. `renderConvo` states "No transcript yet. Embedded-SDK sessions never write
   one." for *any* empty turn list (`web/map.html:1094`) — asserting something
   about the session that the page did not check. Three conditions, three
   sentences (FR-019, research D15).
2. A transport failure in `doSend`/`doKill` writes the bare exception message
   into the same node, in the same red, as a server refusal
   (`web/map.html:1289`, `:1335`), so a page that could not reach the server
   reads as a server that refused. The transport arms now say what did not
   happen (FR-024, FR-032, research D22).
3. Escape closes the drawer only while the reply input has focus
   (`web/map.html:1340-1343`). The dialog's native `cancel` covers every focus
   position, and the input-level handler is removed rather than left to
   disagree (research D20).

`bin/ccwatch` is **not modified by this feature at all** — `modal.js` is served
by the static fallback (`SimpleHTTPRequestHandler` with `directory=WEB`,
`bin/ccwatch:2900-2901`), exactly as `roster.js` is — which is what makes
FR-035, FR-047 and FR-048 true literally rather than by inspection.

Full reasoning, including what was rejected, is in
[research.md](./research.md) (D1–D22).

## Technical Context

**Language/Version**: ES2019-era browser JavaScript in static pages; bash 3.2
for the suite only; `python3` for the server (untouched); `node` for the module
assertions and therefore optional.

**Primary Dependencies**: none. No build step, no package manifest, no bundler,
no CDN fetch, no image or binary asset (FR-047). The feature is one new static
file, edits to one existing static file, and test and documentation changes.

**Storage**: none. The modal persists nothing and adds no `localStorage` key —
`ccwatch.map.view.v1`, `ccwatch.map.plots.v1`, `ccwatch.map.selection.v1` and
`ccwatch.map.width.v1` are untouched. A modal is not a place you return to; it
is a panel you open on a session (see Out of Scope: no deep links, no modal
history).

**Testing**: `./tests/run.sh` only — `shellcheck -x -S warning`, then the
assertions. A new `modal-module` section runs `web/modal.js` under `node` in
the same harness shape as the existing `plots` (`tests/run.sh:1976`), `camera`
(`:2206`) and `roster-module` (`:2425`) sections, emitting one
`PASS|name|detail` line per check and calling `t_skip` with the reason when
`node` is absent. The source-level page guards (no `id="reply"` remains, the
dialog is opened with `showModal`, the `innerHTML` count, the `setInterval`
count, `drag.moved`'s single consumer, the figures' `tabindex`/`role`, the
roster opener's position outside the listbox, the token header on both writes,
the `SEND_TOKEN` placeholder) join the existing guards in the `serve` section
(`:1464-1551`) beside the ones they must not disturb. The server-side gate
assertions in the `kill` (`:1871`) and `send` (`:637`) sections are unchanged,
because nothing server-side changes. `TALLY_FLOOR` (currently `455`) is raised
by the number of new assertions.

**Target Platform**: macOS host (BSD `stat -f`, `ps -o lstart=`); the pages run
in a current Chromium/WebKit/Gecko browser on `127.0.0.1`. `<dialog>` +
`showModal()` is baseline in all three.

**Project Type**: single-file CLI tool plus the static pages it serves. No
frontend/backend split, no new directory.

**Performance Goals**: the modal renders on a tick, on an open, and on a
kill/send outcome, and at no other time; a render performs no node creation or
removal in the panel other than `reconcile`'s per-stat-line create/remove; the
page keeps exactly one `setInterval` and zero `requestAnimationFrame`
(SC-010), `innerHTML` stays at two assignments, and a hidden tab performs no
periodic work at all (SC-011). The transcript poll stays at 5000 ms against the
state tick's 3000 ms (FR-017).

**Constraints**: no change to `bin/ccwatch`, the payload, the endpoints, the
gates or the terminal output (FR-035, FR-047, FR-048); `const SEND_TOKEN =
"__CCWATCH_SEND_TOKEN__";` byte-identical; every claim the panel draws
reachable as text (principle VII); volatile readings withheld through the one
existing `VOLATILE` gate (principle III); no transcript content and no anchor
on any path out of the page (principle X).

**Scale/Scope**: one new module (~260 lines), ~230 changed lines in
`web/map.html`, one new test section plus ~10 source guards (≈55 new
assertions), one `README.md` section and one mutation-table row per assertion
batch. Twelve stats, five failure renderings, three send outcomes, three kill
outcomes, four openers.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| # | Principle | Gate for this feature | Verdict |
|---|---|---|---|
| I | Never claim on one signal | The feature introduces no verdict. It renders payload verdicts and adds no signal of its own. Where it *gates an action*, the gate has two independent carriers: the `disabled` attribute and a handler guard (D17). | **PASS** |
| II | Print the measurement next to the verdict | The header carries `<word> · <measure>` as one string from `fields`, byte-identical to the roster row's `.rstatus`; the grid states the silence or waited duration explicitly (FR-010, D9). | **PASS** |
| III | A stale reading is withheld, not annotated | `VOLATILE` stays the single gate; `ctx` and `mem` arrive already absent from `rowFields`; the kill figure reads `fields.mem`, fixing the one place that bypassed the gate (FR-012, FR-033, D10). No "(old)" annotation anywhere. | **PASS** |
| IV | A failure must never look like an absence | Both gated controls render disabled with a named reason instead of vanishing (FR-026, FR-028) — the defect this entry is named for. The transcript's three cases become three sentences (FR-019). The transport failure stops reading as a refusal (D22). Feed-down, warming, unreadable-count and gone are four more distinct renderings inside the panel. | **PASS** |
| V | Never invent a status you did not read | `fields.word` is `row.token` verbatim, including a token the module has never seen; `killModel`/`sendModel` have no default arm that manufactures a state (M‑D, K‑K). | **PASS** |
| VI | Say nothing rather than guess | `sdk-ts` is stated as writing no transcript, from `entrypoint`, and nothing in that branch escalates its silence (C‑E). `no repo` is `fields.where`'s own value and is never folded under an organisation. | **PASS** |
| VII | Colour is never the only carrier | Every stat has a `<dt>` label; each feed sentence carries its words as well as its colour; edge direction carries `to`/`from` as well as an arrow; the figures' focus indicator is drawn, not an `outline` that one engine may not paint (D7, E‑H). | **PASS** |
| VIII | Delivery is observed, not assumed | `/api/send`'s three observed outcomes are reported distinctly and unchanged; nothing new claims a delivery (FR-024). | **PASS** |
| IX | Loopback is not a security gate | Both writes keep `X-CCWatch-Token` and the server's `Origin` check; the `SEND_TOKEN` placeholder line is byte-identical; the destructive action keeps its `--allow-kill` opt-in and its two-step confirmation (FR-025, FR-035). Making the *control* visible when the gate is closed does not touch the gate. | **PASS** |
| X | Transcripts are sensitive | The reduction is the server's and is untouched; the page still escapes before formatting and renders a markdown link as text; the modal reads no `peers` `sample` text (FR-015, FR-016, D11). | **PASS** |
| XI | One code path computes status | The modal derives no status, severity, verdict or ordering; it shows one session and orders nothing. `panel()` has no comparator (FR-009, M‑D). | **PASS** |
| XII | Normal conditions are silent | `feedLines` for `trust: "ok"` yields empty strings; a zero unreadable count prints nothing; a session with nothing to ask shows no ask panel at all (F‑C, F‑D, A‑C). | **PASS** |
| XIII | Position is stable; only status moves | No coordinate, ordering or placement input changes. Opening a modal moves nothing in the city; the roster's order and the camera are untouched (FR-046). | **PASS** |

**Additional constraints**: bash 3.2 only in `tests/run.sh` (no `mapfile`, no
`declare -A`, no `${var,,}`); `python3 -c` never on stdin — not reached, since
`bin/ccwatch` is unmodified; `shellcheck -x -S warning` clean; no build step
and no dependency; runtime state untouched. **PASS**.

**Quality gates**: hermetic assertions on a fabricated `CLAUDE_CONFIG_DIR`
with `CCWATCH_FAKE_PS` (FR-051) — the new module assertions need neither, being
`node` over plain objects; `t_skip` with the reason when `node` is absent
(FR-056); mutation-check every new assertion with a `README.md` row (FR-052);
`TALLY_FLOOR` raised (FR-054); nothing left running by a test. **PASS**.

**Post-design re-check (after Phase 1)**: unchanged — all thirteen still PASS.
The design added no endpoint, no timer, no stored record, no status and no
second formatter; the two things it *removes* (a hidden kill control, an
ungated memory figure) are each a principle-IV and principle-III violation
respectively that existed before this entry. No entry in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/005-agent-modal/
├── plan.md              # This file
├── research.md          # Phase 0 — D1–D22, with what was rejected
├── data-model.md        # Phase 1 — Subject, PanelModel, StatLine, the models
├── quickstart.md        # Phase 1 — how to validate it, story by story
├── contracts/
│   ├── modal-js.md      # Phase 1 — web/modal.js's API and its asserted claims
│   └── page-modal.md    # Phase 1 — what changes in web/map.html
├── checklists/
│   └── requirements.md  # from /speckit-specify
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
bin/ccwatch          UNCHANGED. The static fallback already serves web/modal.js
                     (directory=WEB, bin/ccwatch:2900-2901), so this feature
                     adds no route, no endpoint and no server code.

web/
├── map.html         the map view — gains <dialog id="agentmodal"> in place of
│                    #reply, renderModal(), the stats grid, the four openers,
│                    focusable figures, the two gated controls and the modal's
│                    stylesheet block. Loses #reply, renderKill's early return,
│                    #ifoot's display toggle and the input-level Escape.
├── modal.js         NEW. The pure module: panel(), statLines(), edgesFor(),
│                    feedLines(), goneText(), atBottom(), killModel(),
│                    sendModel(), askModel(), convoMessage(), dur().
├── roster.js        UNCHANGED. rowFields/titleText/dur are consumed as they are.
├── camera.js        UNCHANGED.
├── plots.js         UNCHANGED.
├── md.js            UNCHANGED. Still the only path transcript text is formatted by.
└── index.html       UNCHANGED (out of scope).

tests/run.sh         a new `modal-module` section (node, skippable) plus source
                     guards in the existing `serve` section; TALLY_FLOOR raised.

README.md            the modal documented, with why a disabled kill control
                     naming the flag beats an absent one, plus one mutation-
                     table row per new assertion.
```

**Structure Decision**: unchanged from entries 002–004. One CLI script plus the
static pages it serves; the pure logic goes in a `web/*.js` module so the suite
can exercise it under `node`, and the page keeps the DOM and the fetches. No
new directory, no new file outside `web/`.

## Complexity Tracking

> No Constitution Check violations. Nothing to justify.
