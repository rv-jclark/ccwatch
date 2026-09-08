# Implementation Plan: Map — identity-derived world layout, incremental rendering, four distinct failure states

**Branch**: `002-map-stable-world` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/002-map-stable-world/spec.md`

## Summary

`/map` is rebuilt from scratch every 3 seconds into an order chosen by severity,
so a session going from `busy` to `waiting` moves its project to the front and
moves every other project with it — under a comment claiming the opposite
(`web/map.html:710-712`). Replace that drawing model: one SVG world with a
camera group, every coordinate a function of identity alone, persisted across
reloads, updated by keyed reconciliation instead of `innerHTML`. Then make the
page honest about a bad feed: four mutually distinguishable sentences, the
volatile numbers withheld rather than annotated, and the unreadable-rows count
finally carried in the payload so the map can render it and the terminal can
stop formatting a number it never receives.

The change lands in five files:

| File | What changes |
|---|---|
| `web/plots.js` | **new**. The pure identity→coordinate module: rasters, hash-then-probe, persistence, extent and fit. Separate so the suite can run it under `node`, exactly as `web/md.js` is |
| `web/map.html` | the world SVG and camera group, three drawing primitives, keyed reconciliation everywhere, the four trust renderings, wires in world space |
| `bin/ccwatch` | `collect_sessions` returns its `parse_failed` count with the rows it describes; `snapshot()` carries it; the footer and `doctor` read it from there |
| `tests/run.sh` | a new `plots` section under `node`, `parse_failed` assertions across four consumers, page guards; `TALLY_FLOOR` raised |
| `README.md` | the map section rewritten — it currently presents the responsive grid as the design — plus one mutation-table row per new assertion |

Five design decisions carry the feature, each argued with its rejected
alternatives in [research.md](./research.md):

1. **One inline SVG, one explicit camera group** (D1). Wires become children of
   the same group as the figures, so they are computed from world coordinates
   and `getBoundingClientRect` disappears from the drawing path. SVG keeps hit
   testing, focus, `<title>` text and selectability, which canvas would cost.
2. **Plots come from a per-parent raster with fixed columns and hash-then-probe
   placement, overflowing into an annex plot** (D2). A persisted assignment
   always wins and is never recomputed — that single fact is what makes FR-010
   and FR-011 hold. Capacity per parent is what keeps the world compact, and
   compactness is what makes the legibility floor achievable.
3. **Reconciliation by one keyed helper, and nothing replaced wholesale** (D4).
   `innerHTML =` leaves the refresh path entirely, including the header, the
   footer and the inspector's conversation. The one surviving write is a single
   turn *body* from `CCWATCH_MD.render(...)`, because that is the
   escape-first-then-tag path Constitution X requires.
4. **`PARSE_FAILED` propagates by changing what `collect_sessions` returns**
   (D6). It is currently incremented inside a pipeline and read across two
   further command substitutions, so it is structurally always `0` in all four
   consumers. Returning the count *with the data it describes* removes every
   subshell boundary at once, and the footer reading `.parse_failed` from the
   snapshot gives FR-034 one source rather than four agreeing by convention.
5. **Trust is a state plus an independent count, not a four-way enum** (D7).
   `trust ∈ {ok, feed_down, warming}` alongside `unreadable = parse_failed`,
   because the spec's own edge case requires an unreadable registry *and* an
   empty host to both be stated — which a precedence-ordered enum swallows.

## Technical Context

**Language/Version**: bash 3.2 (macOS system bash) for `bin/ccwatch`; vanilla
ES2020 browser JS with no framework in `web/map.html` and `web/plots.js`; SVG 1.1
with CSS animations for the drawing; `node` (any current version) only as the
optional test runner for `web/plots.js` and `web/md.js`.

**Primary Dependencies**: none new. Existing: `python3`, `jq`, `ps`, `stat`,
`git`, optional `gh`; `curl`, `shellcheck` and optional `node` for the suite. No
package manifest, no bundler, no CDN fetch, no image, binary or font — FR-052,
FR-054 and the constitution forbid all of them.

**Storage**: `localStorage["ccwatch.map.plots.v1"]`, per origin, ≤512 entries
(~20KB against a 5MB budget). Nothing new is written to disk;
`~/.claude/ccwatch/` is untouched and no server-side persistence is added.

**Testing**: `./tests/run.sh` only — `shellcheck -x -S warning`, then the
assertions. Hermetic: fabricated `~/.claude` under `$WORK` via
`CLAUDE_CONFIG_DIR`, liveness probe substituted via `CCWATCH_FAKE_PS`, real
loopback servers on a probed free port, all reaped on exit. The new `plots`
section runs `web/plots.js` under `node` and skips with the reason stated where
`node` is absent.

**Target Platform**: macOS (Darwin) only; loopback HTTP on `127.0.0.1`; Chrome
and Safari as the page runtimes.

**Project Type**: single-file bash CLI (3346 lines) plus two static pages and two
static JS modules served by an embedded python3 `ThreadingTCPServer`. No `src/`
tree, no build step.

**Performance Goals**: SC-004 — zero elements created or destroyed for an
unchanged payload, which the `304` path makes the common case. SC-012 — no
animation-frame loop and exactly one `setInterval` per page, unchanged from
`001-feed-footprint`. A resize costs one transform write instead of today's
full refetch and re-measure (D9). Reconciliation is O(entities), ~40 figures
worst case.

**Constraints**: every coordinate a function of identity strings only (FR-006),
with `sev`, `psev`, `token`, `quiet`, `waited`, `context`, `rss_mb`, `cost`,
`age`, `deploys` and payload row order explicitly excluded (FR-007); no third
page, no new endpoint (FR-001, FR-055); bash 3.2 forms only and
`shellcheck -x -S warning` clean at unchanged severity (FR-056); no status,
severity, verdict or badge derived in the page (FR-037, Constitution XI); the
send-token placeholder line byte-identical (FR-047); read-only and
kill-disabled gates untouched (FR-048); the three later map entries not started
(FR-041, spec Out of Scope).

**Scale/Scope**: FR-040's stated target is 8 districts and 25 sessions on a
1280×800 viewport; the world-unit budget in [research.md](./research.md) D5 puts
a figure at 22.0px there against 13px body text, degrading to 15.8px at twelve
districts. Touched surfaces: `web/map.html` (~800 lines today, most of the JS
half rewritten), `web/plots.js` (~250 new lines), `bin/ccwatch` `collection`,
`the join`, `rendering` and `doctor` sections (~40 lines), `tests/run.sh` (~200
new lines), `README.md` (map section, mutation table).

No **NEEDS CLARIFICATION** remains. The spec's Assumptions section fixed every
open value — hash-then-probe with the persisted assignment authoritative,
browser local storage, `no repo` as one shared district, a count of files not
sessions, `parse_failed` as a top-level snapshot field, fit-with-a-floor — and
[research.md](./research.md) settles the mechanisms those values left open.

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1. Both passes
below; the second changed nothing.*

| Principle | Bearing on this feature | Verdict |
|---|---|---|
| I. Never claim on one signal | No new verdict, badge, colour, animation or figure state. `KIND` (`web/map.html:267-279`) keeps its exact mapping; corroboration logic is untouched | PASS (N/A) |
| II. Print the measurement next to the verdict | The stale marking always carries the measured age of the data still shown (FR-028), and a figure's `<title>` keeps the quiet time and waited time that justify its pose | PASS |
| III. Stale reading withheld, not annotated | The feature **repairs** a live violation: retained context percentages and memory figures are currently drawn as though measured now. `VOLATILE` is one enumeration, applied at draw time from `trust` rather than latched, so FR-032's restore is one assignment. The gauges' own staleness window is untouched (FR-043) | PASS (repairs) |
| IV. Failure must never look like an absence | **Three** repairs. Four distinct renderings replace one `No live sessions` line (FR-026); the unreadable count stops being lost to a subshell and starts reaching all four consumers (FR-033); `parse_failed` absent means unknown and prints nothing, never `0`. Storage that stops persisting is stated, not silently absorbed (FR-014) | PASS (repairs) |
| V. Never invent a status you did not read | An unrecognised token draws as the neutral figure with its own token readable as text (V14). No default arm manufactures a pose, colour or severity. `null` `parse_failed` is not read as `0` | PASS |
| VI. Say nothing rather than guess | A remote-less directory gets its own district, labelled `no repo`, never folded under an organisation (FR-004). A missing branch or project name is shown as missing (V15). An `sdk-ts` session's silence is still never escalated — no classification changes here | PASS |
| VII. Colour is never the only carrier | The whole point of the graphical rewrite risking this one. Every figure state has a distinct word in its `<title>` and in the legend (FR-046); the primitives carry `role`/`<title>` rather than relying on shape; `NO_COLOR` is a terminal concern and is untouched | PASS |
| VIII. Delivery is observed | `send` and `kill` paths untouched; the inspector's send box keeps its current behaviour and wording (FR-042) | PASS (N/A) |
| IX. Loopback is not a security gate | No endpoint added, no gate changed, no `Cache-Control` changed. The token placeholder line stays byte-identical because `bin/ccwatch:2842` substitutes on that exact string and an assertion greps the served page for the result (FR-047, FR-048) | PASS |
| X. Transcripts are sensitive | The inspector's conversation moves to keyed reconciliation, and the one surviving `innerHTML` write is a turn body from `CCWATCH_MD.render(...)` — escape first, then tag, still no anchor, still no sanitise-afterwards path. `convo`'s bounding and reduction are untouched, and `/api/transcript` keeps `no-store` | PASS |
| XI. One code path computes status | `parse_failed` is produced where the count is already taken and read by four consumers from one field, rather than recounted anywhere. The page gains geometry and formatting only: mapping a payload value to a pose or colour is presentation; deciding the value is not, and nothing here does (FR-037) | PASS |
| XII. Normal conditions are silent | The unreadable-rows line appears only when the count is above zero, in the footer, in `doctor` and on the map. The host-pressure line keeps its threshold (FR-044). No new always-on line | PASS |
| XIII. Position is stable; only status moves | The feature exists for this principle. The severity sort (`web/map.html:740-744`) is deleted; FR-007's exclusion list is the operative statement; the volatile ordering that is genuinely useful stays in the table view, which is expected to be ordered — and the roster that will re-add an explicit ordered list is a later entry | PASS (repairs) |
| bash 3.2 / BSD `stat`, `ps` / `python3 -c` | The bash change is a `for` loop, a string accumulator and `jq` calls — no `mapfile`, no `declare -A`, no case-modification expansion, nothing passed on stdin. `serve`'s embedded python is not touched at all | PASS |
| No build step, no dependencies | One new static JS file served by the existing static fallback, which is what `web/md.js` already is and for the same reason `CLAUDE.md` gives. No manifest, bundler, image, binary, font or external fetch | PASS |
| Test discipline | Hermetic fixtures; ≥7 mutation-checked assertions with a README row each; `TALLY_FLOOR` raised; servers reaped; the `plots` section and every timing-dependent assertion `t_skip` with a stated reason. The browser-only claims are scripted in `quickstart.md` with an expected outcome each, and the plan says plainly which claims the suite cannot make | PASS with a recorded limit |

**Gate result: pass.** Three principle *repairs*, one recorded coverage limit and
two recorded readings, all in Complexity Tracking. Nothing here is a violation
taken as a trade-off.

## Project Structure

### Documentation (this feature)

```text
specs/002-map-stable-world/
├── plan.md               # This file
├── research.md           # Phase 0 — nine decisions, each with what was rejected
├── data-model.md         # Phase 1 — the payload field, the in-page models, the persisted record
├── quickstart.md         # Phase 1 — how to validate, automated and by hand
├── contracts/
│   ├── api-state.md      # the snapshot payload: `parse_failed`, and the fields the map pins
│   ├── plots-js.md       # web/plots.js: the identity→coordinate module and its guarantees
│   └── page-render.md    # what /map renders: the four sentences, and the rendering invariants
├── checklists/
│   └── requirements.md   # written by /speckit-specify
└── tasks.md              # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
bin/ccwatch          # the whole tool. Four sections change, ~40 lines total:
                     #   collection  (~line 180)  collect_sessions returns
                     #                            {rows, parse_failed}; the slow
                     #                            path stops being a pipeline
                     #   the join    (~line 614)  snapshot() splits it and adds
                     #                            top-level parse_failed
                     #   rendering   (~line 1129) the footer reads .parse_failed
                     #                            from the snapshot, not $PARSE_FAILED
                     #   doctor      (~line 3086) reads the field it collects
                     # serve is NOT touched: it shells out to `ccwatch --json`
                     # and build_canonical copies snapshot keys wholesale, so the
                     # field reaches /api/state and the ETag on its own.
web/plots.js         # NEW. Pure: rasters and the world-unit budget, assign(),
                     # place(), fit(), load()/save() with injected storage.
                     # No DOM, no fetch, no timers. Served by the static
                     # fallback in `serve`, so it needs no route — the same
                     # arrangement as web/md.js.
web/map.html         # the world <svg> + <g id="camera">, drawDistrict /
                     # drawBuilding / drawFigure primitives, the reconcile()
                     # helper and its four keyed levels, wires in world space,
                     # the trust model and the four renderings, in-place updates
                     # for #counts/#gauges/#foot/#hostwarn/#ask/#killbar/#convo,
                     # #legend built once, resize refits without refetching.
web/index.html       # UNCHANGED. The table view is where volatile ordering
                     # belongs and it is not in scope.
tests/run.sh         # new `plots` section (node-gated); parse_failed assertions
                     # in the ccwatch, doctor and serve sections; page guards in
                     # the serve section; TALLY_FLOOR raised.
README.md            # the map section rewritten (it presents the responsive
                     # grid as the design), plus one mutation-table row per new
                     # assertion.
```

**Structure Decision**: the repository has no `src/` tree and no build step, and
the constitution forbids introducing either. The layout above is the existing
one; the only new file outside `specs/` is `web/plots.js`, and it is new for the
reason `CLAUDE.md` already gives for `web/md.js` — "a separate file rather than
inline script so that `tests/run.sh` can run it under node and assert on the
HTML". Work is grouped by these five files rather than by layer, because
`bin/ccwatch` is one script organised into banner-commented sections and the map
is one page.

## Complexity Tracking

> Recorded because each is something a reviewer should be able to audit, not
> because a gate failed.

| Item | Why accepted | Alternative rejected because |
|---|---|---|
| **A second static JS file**, `web/plots.js`, so the pages are no longer strictly self-contained | It is what makes SC-001, SC-002, SC-003, FR-007, FR-013 and FR-039 mutation-checkable rather than eyeballed. `web/md.js` is the standing precedent, blessed in `CLAUDE.md` for exactly this reason, and the file is not an image, binary, font, external fetch or runtime dependency (FR-052), needs no build step (FR-054) and needs no route (FR-055) | Keeping the geometry inline in `map.html` leaves six success criteria assertable only by eye, and would put rows in the mutation table that nothing can check — which the constitution calls worse than no assertion. A headless browser is forbidden outright |
| **The suite cannot assert the browser-observable claims.** SC-001/002/005 and FR-017/018 are about a rendered page over time | The pure half is extracted into `plots.js` and asserted for real; the DOM half gets static structural guards (no `innerHTML` on the reconciled containers, one `setInterval`, no `requestAnimationFrame`) plus scripted manual validation in `quickstart.md` §4–§7 with a `diff`-able coordinate dump and a `MutationObserver` check. The limit is stated here rather than papered over | A grep can prove `sev` does not appear inside a layout function; it cannot prove two frames agree on a coordinate. Claiming otherwise would make the mutation table dishonest |
| **Reading of FR-028 for condition (b).** FR-028 requires (a), (b) and (c) to state the measured age of the session data still shown; in (b) there is none | `warming` means no snapshot has ever *succeeded*, so there is provably no retained data to age. The sentence states that instead — the honest form of the same obligation. Recorded because it is a deviation from FR-028's literal text | Printing an age of `0` or `null` in (b) would be a number on screen that measures nothing, which is Constitution III in the other direction |
| **Annex plots.** An organisation with more than 6 repositories (or a repository with more than 2 branches, or a branch with more than 3 sessions) claims a second plot of its own level, labelled the same | It is the only overflow rule that keeps every level's pitch fixed, and a fixed pitch is what makes FR-010 and SC-003 arithmetic rather than a hope. Capacity covers FR-040's stated target with room: 8 × 6 × 2 × 3 = 288 figure slots against 25 sessions | Sizing a district to the buildings it currently holds moves every district below it the first time an org gains a repository. Growing the row pitch to the tallest district moves everything. Both are direct FR-010 violations |
| **Order-dependence of a colliding city**, accepted by the spec's own Assumptions: two browsers that first saw the same projects in a different order can show different cities | A globally order-independent tie-break would have to move an already-placed building, which FR-010 forbids. Persistence, not global determinism, is what a person relies on | Re-hashing on collision to a canonical winner is order-independent and moves buildings, which is the failure this entry exists to prevent |
| **`collect_sessions` changes its return shape** from an array to `{rows, parse_failed}`, touching three call sites | It removes both subshell boundaries at once and makes the count travel with the data it describes. A side-channel file survives the subshells and adds a stale-read window, a cleanup obligation and a collision between two concurrent `ccwatch` processes — for a number whose only purpose is to be trustworthy | Inferring the count as `n - length(rows)` is already rejected by the code's own comment (`bin/ccwatch:210-213`): it is wrong for a pretty-printed file. Computing it in `serve` would be two code paths for one number (Constitution XI) |
