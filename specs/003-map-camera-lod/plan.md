# Implementation Plan: Map — pan, zoom, semantic level-of-detail, persisted viewport

**Branch**: `003-map-camera-lod` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/003-map-camera-lod/spec.md`

## Summary

`map-stable-world` gave `/map` a world in world units under one `<g id="camera">`
and one way to look at it: `applyFit()`, which centres the whole occupied extent
and refits on resize. This entry adds the camera over that same world — drag to
pan, discrete zoom steps, keyboard operation, three named detail levels chosen
from the scale with hysteresis, wires and labels that hold their apparent size,
and a viewport that survives a reload — while changing no coordinate, no payload
field, no endpoint and no verdict.

The whole approach falls out of one requirement, FR-044: a camera move may change
only the camera group's transform, the detail-level state and the stored
viewport. That rules out the obvious implementations of both level of detail and
constant-apparent-size, and the research settled on the two constructions that
survive it:

- **One writer, three writes.** Camera state is `{idx, tx, ty}` — an index into a
  frozen ladder `[¼, ½, 1, 2, 3, 4, 6, 8]` and a translation in screen pixels.
  Every input path (drag, wheel, key, button, restore, resize, tick-clamp,
  `centreOn`) computes a new triple and hands it to a single `applyView()`, which
  writes the `transform` on `#camera`, the `--k` custom property and the
  `data-lod` attribute on `#world`, plus the control state and the two text notes
  in page chrome. Storing the *index* makes "only ladder values are reachable"
  (FR-002), "clamped at the ends" (FR-009) and "a stored scale that is not a step
  is discarded" (FR-037) true by construction.
- **Level of detail and apparent size are both declarative.** `data-lod` drives
  stylesheet rules that `display: none` what a level does not draw; `--k` drives
  `calc(Npx / var(--k))` for every label, the wire stroke (and therefore the
  `markerUnits="strokeWidth"` arrowhead, free) and a counter-scaled inner group
  for the count bubble. Nothing on the camera path touches a scene-graph node, so
  a camera move creates, removes and repositions zero nodes (SC-008) and runs no
  JavaScript per frame (FR-045).

The pure arithmetic moves into a new `web/camera.js` — a third static module
beside `md.js` and `plots.js`, for the reason `CLAUDE.md` already gives for
`md.js`: so `tests/run.sh` can run it under `node` and assert on it without a
browser (FR-055). It is served by the existing static fallback in `serve`
(`bin/ccwatch:3041`), so **`bin/ccwatch` is not modified by this feature at
all** — which is what lets FR-053's "the payload MUST NOT change" hold
literally.

Full reasoning, including what was rejected, is in
[research.md](./research.md) (D1–D14).

## Technical Context

**Language/Version**: bash 3.2 (untouched here), ES2019-era browser JavaScript in
static pages, `python3` for the server (untouched), `node` for the arithmetic
assertions and therefore optional

**Primary Dependencies**: none. No build step, no package manifest, no bundler,
no CDN fetch at runtime, no image or binary asset (FR-054). The feature is one
new static file plus edits to one existing static file plus test and doc changes.

**Storage**: `localStorage`, one new versioned record `ccwatch.map.view.v1`
holding `{v, idx, tx, ty}`, separate from the existing `ccwatch.map.plots.v1`
(FR-035). Reached only through injected `getItem`/`setItem` functions so the
suite can exercise it — and a throwing storage — without a browser.

**Testing**: `./tests/run.sh` only — `shellcheck -x -S warning`, then the
assertion suite. A new `camera` section runs `web/camera.js` under `node` in the
same harness shape as the existing `plots` section (`tests/run.sh:1718-1947`),
emitting one `PASS|name|detail` line per check and calling `t_skip` with the
reason when `node` is absent. The served-page guards (zero
`requestAnimationFrame`, exactly one `setInterval`, `innerHTML` twice, the
`SEND_TOKEN` line, the counter-scaling and `data-lod` rules, three real buttons,
`touch-action: none`) live in the existing `serve` section. `TALLY_FLOOR` (now
`244`) is raised by the number of new assertions.

**Target Platform**: macOS host (BSD `stat -f`, `ps -o lstart=`); the pages run
in a current Chromium/WebKit/Gecko browser on `127.0.0.1`.

**Project Type**: single-file CLI tool plus the static pages it serves. No
frontend/backend split, no new directory.

**Performance Goals**: a camera move is one attribute write, one custom-property
write and one `data-lod` write — zero nodes created, removed or repositioned
(SC-008), zero extra `/api/state` requests over ten seconds of continuous
panning and zooming (SC-007), and the polling cadence, visibility pause and
conditional-request behaviour from `feed-footprint` unchanged (FR-046).

**Constraints**: no `requestAnimationFrame` on either page and exactly one
`setInterval` per page (FR-043, asserted at `tests/run.sh:758-770`); `map.html`
assigns `innerHTML` exactly twice (FR-047, asserted at
`tests/run.sh:1288-1296`); `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` stays
byte-identical (FR-052); easing is a single bounded CSS transition that reduces
to an instant jump under `prefers-reduced-motion` (FR-045, SC-012); the four
failure sentences and the gauges stay in page chrome outside the camera group so
they are readable at every zoom (FR-049, SC-010).

**Scale/Scope**: eight ladder rungs; three detail levels with two thresholds
each; one new ~200-line static module; the concrete numbers settled by research
are `WHEEL_THRESHOLD = 100` normalised pixels per step, `PAN_STEP = 120` screen
pixels per arrow press (`480` with `Shift`), `DRAG_SLOP = 4` screen pixels before
a press becomes a pan, and hysteresis bands at `k = 1` (far↔mid) and `k = 3`
(mid↔near) with a downward-resolving cold mapping for restore.

**Unknowns**: none. The spec's Assumptions section closed each open question as a
decision and left exactly three numbers to the plan — the ladder's values, the
detail-level thresholds and the arrow-key step — settled in
[research.md](./research.md) D2, D7 and D6 respectively. No NEEDS CLARIFICATION
remains.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Constitution version 1.0.0. Gates are stated as the question the principle asks
of *this* feature.

| # | Principle | Applies? | Gate and how the design passes |
|---|---|---|---|
| I | Never make a claim on one signal | yes | The far-level district summary is not a new claim: it selects the worst existing row by the CLI's own `sev`/`psev` key and prints that row's own status word. No new verdict, badge, colour or figure state is introduced, so there is nothing to corroborate (FR-027, research D13). **Pass.** |
| II | Print the measurement next to the verdict | yes | Nothing the camera draws is a severity of its own. The two readings the camera *does* introduce — the current scale and the current level — are printed as text in `#camstate` (FR-019). The aggregate prints its count and its word, never a colour alone. **Pass.** |
| III | A stale reading is withheld, not annotated | yes | The camera adds no reading with a staleness window. The gauges keep `VOLATILE` untouched, and nothing volatile enters a district summary — the summary is a count and a status word (FR-050, data-model §8's "explicitly not read" list). **Pass.** |
| IV | A failure must never look like an absence | yes | Three separate obligations, all met: a zoom control that cannot act is rendered **present and disabled with its reason** rather than omitted (FR-017); a `localStorage` that throws states that the viewport will not be remembered (FR-040, `#camnote`); and FR-029's rule that a level may draw less but may not make a claim disappear is why the far-level summary carries the unfinished/crashed pipeline word that far stops drawing as a badge (research D13). The four failure sentences stay four sentences, in chrome, readable at every zoom (FR-049). **Pass.** |
| V | Never invent a status you did not read | yes | The aggregate is a maximum over payload values; there is no default arm that manufactures a word. An unrecognised token is printed verbatim, exactly as the payload supplied it (FR-027). **Pass.** |
| VI | Say nothing rather than guess | yes | The camera escalates nothing, so an `sdk-ts` session's silence is still unmeasured and a `no repo` directory is still its own district. A stored viewport that cannot be trusted is discarded into a fit rather than restored approximately (FR-037, FR-038). **Pass.** |
| VII | Colour is never the only carrier of meaning | yes | This is Story 2's whole reason to exist. The scale and level are text (FR-019); the map surface is focusable with an `aria-label` naming the keys (FR-018); zoom in / zoom out / fit are three real `<button>` elements in the tab order (FR-016); every aggregate carries its status word as text (FR-028); a session needing attention is identifiable at far by a word with no colour perception and no zooming (SC-011). **Pass.** |
| VIII | Delivery is observed, not assumed | n/a | No new action and no new write endpoint. `send` is untouched. |
| IX | Loopback is not a security gate | n/a | No new endpoint, no new write path, no change to the per-run token or the `Origin` check. `/camera.js` is served read-only by the existing static fallback. |
| X | Transcripts are sensitive | yes | Nothing on the camera path reads or moves transcript text. The inspector's redaction rules, and `web/md.js`'s escape-then-format-and-never-link discipline, are untouched; the inspector survives a camera move with its scroll position and half-typed message because the camera writes nothing inside `#reply` (FR-051). **Pass.** |
| XI | One code path computes status | yes | The view lays out, groups and hides; it derives nothing. The aggregate is a *selection* over payload fields, not a computation — it may not rank, derive or invent (FR-027). `/api/state` still invokes the commands the CLI does, and no collector changes (FR-053). **Pass.** |
| XII | Normal conditions are silent | yes | `#camnote` is empty unless one of exactly two things is true: the whole world does not fit even at the smallest rung (FR-012), or `localStorage` refused (FR-040). Neither is a standing line, and there is no "viewport saved" confirmation (research D14). **Pass.** |
| XIII | Position is stable; only status moves | yes | The principle this feature is most exposed to, and the reason level of detail is a visibility switch rather than a different scene: a district, building, zone or figure occupies the same world position at every level and every rung (FR-025, SC-002). A resize preserves the centre world point instead of refitting (FR-010); a tick clamps but never refits (FR-011). Identity-derived placement and the plot store are not touched (FR-048). **Pass.** |

**Additional constraints.** bash 3.2 and BSD `stat`/`ps`: unaffected —
`bin/ccwatch` is not modified. `python3 -c` never on stdin: unaffected.
`shellcheck -x -S warning` clean: the only shell change is the new `camera`
section in `tests/run.sh` (FR-058). No build step and no dependency: satisfied by
one more static file served by the existing fallback (FR-054). Runtime state in
`~/.claude/ccwatch/` is not touched; the viewport is browser-side
`localStorage`, which is where the plot assignments already live.

**Workflow gates.** New assertions are hermetic under `$WORK` via
`CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS`; each is mutation-checked and gains a
row in the `README.md` mutation table; `TALLY_FLOOR` is raised; anything a test
starts is reaped; `node`-dependent checks `t_skip` with the reason rather than
fail (FR-055, FR-056). `README.md` documents what each of the three zoom levels
shows and why the level of detail is semantic rather than a scale factor
(FR-057).

**Initial gate result: PASS.** No violation, no justification required.

**Post-design re-check (after Phase 1): PASS.** The design added three things
worth re-testing against the constitution, and each was checked:

1. The `data-lod` visibility switch (research D3) could have hidden a claim —
   FR-029 and research D13 are the answer, and IV is why the far-level summary
   must carry the pipeline word rather than merely stop drawing the badge.
2. The `--k` counter-scaling (research D4) touches presentation only; no
   `x`/`y` is rewritten, which is what keeps XIII and FR-048 intact. The
   rejected alternative — writing `font-size`/`stroke-width` per node per move —
   would have been a coordinate-adjacent rewrite on the camera path.
3. `window.CCWATCH_MAP_CAMERA` (FR-042, page contract §6) exposes
   `centreOn`/`fit`/`current` and ships **no caller**. It is a camera API, not a
   selection model, so it introduces no state and no verdict for `map-roster` to
   inherit.

## Project Structure

### Documentation (this feature)

```text
specs/003-map-camera-lod/
├── plan.md              # This file (/speckit-plan command output)
├── spec.md              # Feature specification
├── research.md          # Phase 0 output — D1–D14, decision/rationale/rejected
├── data-model.md        # Phase 1 output — Viewport, Ladder, DetailLevel,
│                        #   OccupiedExtent, DistrictSummary, StoredViewport
├── quickstart.md        # Phase 1 output — validation scenarios per user story
├── contracts/           # Phase 1 output
│   ├── camera-js.md     #   the pure web/camera.js module: every function's
│   │                    #   inputs, outputs and asserted claims
│   └── page-camera.md   #   what /map does: the single writer, new DOM,
│                        #   stylesheet rules, events, load order, roster API
├── checklists/
│   └── requirements.md  # spec-quality checklist (from /speckit-specify)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
web/
├── camera.js       NEW — the pure camera arithmetic: LADDER and the four
│                   constants, scaleFor, clampIdx, clampPan, fitIndex, fitView,
│                   zoomTo, panBy, centreOn, levelFor, wheelStep, validateView,
│                   loadView, saveView, visibleWorldRect, intersects. No DOM,
│                   no fetch, no timers; storage injected. Exports
│                   window.CCWATCH_CAMERA with a module.exports tail, mirroring
│                   web/plots.js. Served by the static fallback in `serve`
│                   (bin/ccwatch:3041) — no route, no bin/ccwatch change.
├── map.html        MODIFIED — <script src="/camera.js">; the single applyView()
│                   replacing applyFit(); #world gains tabindex, aria-label and
│                   data-lod; a new #camctl in chrome with three buttons,
│                   #camstate and #camnote; pointer/wheel/key listeners;
│                   stylesheet rules for data-lod and calc(Npx / var(--k));
│                   makeDistrict() gains a .dsummary text node written per tick;
│                   makeWire() gains one .bubblescale nesting level; the resize
│                   handler keeps the centre world point instead of refitting.
├── plots.js        UNCHANGED (FR-048 — placement and the plot store are not
│                   this feature's to decide)
├── md.js           UNCHANGED
└── index.html      UNCHANGED

bin/ccwatch         UNCHANGED (FR-053, FR-054)

tests/run.sh        MODIFIED — a new `camera` section running web/camera.js
                    under node (t_skip with the reason when absent); new static
                    guards in the existing `serve` section; TALLY_FLOOR raised.

README.md           MODIFIED — the three zoom levels and why level of detail is
                    semantic (FR-057), plus one mutation-table row per new
                    assertion (FR-056).
```

**Structure Decision**: the existing layout, plus exactly one new file. `ccwatch`
is a single bash script serving static pages; there is no `src/`, no test
directory beyond `tests/run.sh`, and no build step to add one to. `web/camera.js`
is a third sibling of `md.js` and `plots.js` for the documented reason the second
one exists — the suite can run it under `node` and assert on numbers without a
browser (FR-055) — and because the static fallback already serves everything in
`web/`, adding it costs no route and no change to `bin/ccwatch`. Every DOM
concern stays in `web/map.html`: the module is pure, the page is the only thing
that touches the document.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified

No violations. The Constitution Check passed before Phase 0 and again after
Phase 1 design, and nothing in this feature requires a deviation to be justified.
