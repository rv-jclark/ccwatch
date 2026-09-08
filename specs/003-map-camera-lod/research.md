# Phase 0 — Research: a camera over the stable world, semantic level of detail, a persisted viewport

**Feature**: `003-map-camera-lod` | **Spec**: [spec.md](./spec.md)

Every decision below is stated as *decision → rationale → what was rejected and
why*. The spec left three things explicitly to the plan — the ladder's values,
the detail-level thresholds, and the arrow-key step — and they are settled in
D2, D7 and D6. Nothing here is a NEEDS CLARIFICATION: the spec's Assumptions
section closed each open question as a decision, and the plan's job was to pick
concrete numbers inside those decisions.

The hard constraint that shaped almost all of it: **FR-044 says a camera move
changes only the camera group's transform, the detail-level state and the stored
viewport.** That one sentence rules out the obvious implementation of level of
detail (build a different scene per level) and the obvious implementation of
constant-apparent-size (rewrite `stroke-width` and `font-size` per node per
move). D3 and D4 are the answers that survive it.

---

## D1. The camera is a ladder index plus a pan, written by exactly one function

**Decision.** The camera's whole state is `{idx, tx, ty}` — an index into the
fixed ladder (D2) and a translation in screen pixels. Scale is never stored; it
is `LADDER[idx]`. Exactly one function, `applyView()`, writes the transform
attribute on `#camera`, the `--k` custom property (D4) and the `data-lod`
attribute (D3). Every input path — drag, wheel, key, button, restore, resize,
tick-clamp, `centreOn` — computes a new `{idx, tx, ty}`, hands it to
`applyView()`, and touches the DOM nowhere else.

**Rationale.** FR-001 wants one transform and FR-044 wants a camera move to have
one write path; a single writer is how that becomes checkable rather than
aspirational. Storing the *index* rather than the scale makes FR-002 (only
ladder values are reachable), FR-009 (clamped at the ends) and FR-037 ("a scale
that is not a valid ladder step is discarded") true by construction instead of
by validation at each call site. It also makes FR-026's hysteresis a function of
two small integers, which is trivially assertable (FR-055).

**Rejected.** *Storing the scale as a float and snapping on use* — every call
site then has to remember to snap, and a stored `1.9999999` restores to a scale
that is not on the ladder, which is exactly FR-037's failure. *Driving the SVG's
own `viewBox` instead of the group transform* — the existing code already
rejected that (`web/map.html:1232-1236`) because a `viewBox` cannot express the
scale clamp, and it would additionally break the 1-world-unit-equals-1-pixel
convention that makes `--k` meaningful in D4. *A transform on the `<svg>`
element* — puts the page's layout box under the transform and would scale the
whole map region, not its contents.

---

## D2. The ladder is `¼, ½, 1, 2, 3, 4, 6, 8` — eight rungs, absolute, integer-friendly

**Decision.** `LADDER = [1/4, 1/2, 1, 2, 3, 4, 6, 8]`, adopted verbatim from the
spec's own example. Index 0..7. One world unit is one screen pixel at index 2
(`k = 1`), matching the existing `viewBox`-equals-client-size convention. The
ladder is a compile-time constant: it does not depend on the viewport, the world
extent, or the fit scale.

**Rationale.** Every rung is a whole number or the reciprocal of a whole number,
which is FR-002's sprite-crispness requirement. The span reaches both ends of
the legibility problem the spec measured: at `k = 8` the 3.6-unit figure label
(`web/map.html:75`) is 28.8 screen pixels and the 4-unit zone label is 32, so
"read the session's name and what it is doing" is satisfiable; at `k = ¼` a
world of about 6,600 units — roughly 32 districts at the 204-unit district pitch
(`web/plots.js:22`) — fits a 1,650-pixel window, so "back off far enough to see"
is satisfiable for any host that will realistically be running Claude Code
sessions. Today's `MAX_SCALE = 3.0` (`web/plots.js:28`) becomes rung 4 of 8
rather than a ceiling.

**Note on the spec's wording.** The spec's assumption says "roughly an eightfold
range" and then gives an example spanning ¼→8, which is 32-fold. The example is
what the legibility arithmetic above requires, so the example is what the plan
adopts; "eightfold" is read as naming the ladder's top rung. This is recorded
rather than silently resolved because it is the one place the plan's numbers
exceed a number the spec printed.

**Rejected.** *Steps relative to the fit scale* — the spec rejects this itself
and gives the reason: fit-relative steps are not integer-friendly, which defeats
the only reason for having steps. *A geometric ladder (`×1.5` or `×√2` per rung)*
— smoother, but `1.5`, `2.25`, `3.375` are exactly the non-integer scales
FR-002 forbids, and a 16-rung ladder makes the hysteresis bands in D7 span
scales a person cannot distinguish. *Continuous zoom with snapping on release* —
FR-002 forbids continuous zoom outright, and it would reintroduce per-frame work
during the gesture.

---

## D3. Level of detail is a CSS visibility switch keyed off one attribute — not a re-render

**Decision.** `applyView()` sets `data-lod="far|mid|near"` on the `#world`
element. Stylesheet rules keyed on that attribute decide what is rendered:

| Rule | Effect |
|---|---|
| `#world[data-lod="far"] .building, … .zone, … .agent { display: none }` | buildings, branch zones, figures and every badge inside them stop being rendered at **far** (FR-022) |
| `#world:not([data-lod="far"]) .dsummary { display: none }` | the district's count-and-status summary is rendered only at **far** (FR-022) |
| `#world[data-lod="far"] .dlabel { display: none }` | the district's name gives way to its summary at far; it returns at mid (FR-022 → FR-023's "the district summary is replaced by the district's name" read in reverse) |
| `#world[data-lod="mid"] .alabel { display: none }` | per-figure name and activity text appear only at **near** (FR-023, FR-024) |

Every node exists in the DOM at every level, written each tick by the existing
reconciliation. A camera move creates nothing, removes nothing and repositions
nothing; it flips one attribute.

**Rationale.** This is the only construction found that satisfies FR-022–FR-024
and FR-044 at the same time. Building a different scene per level would create
and destroy nodes on a camera move, which FR-044 and SC-008 forbid in terms
("creates, removes and repositions zero scene-graph nodes"). It also answers the
spec's second complaint honestly: `display: none` takes the sub-pixel zone
labels and badges out of layout and paint entirely, so at far they are not
drawn — the DOM node's existence costs a retained object, not a rendered glyph.
And because the switch is CSS, the level survives a tick without being
recomputed, which is what FR-026's "a tick arriving at the boundary must not
change the level at all" needs: `tick()` never touches `data-lod`.

The district summary text node is created by `makeDistrict()` alongside the
existing `.dlabel` and written on every tick from the payload, whether or not
the current level shows it. That keeps the aggregate on the *data* path (it
changes when sessions change) and off the *camera* path (it does not change when
the view moves), which is the split FR-044 draws.

**Rejected.** *Three sibling groups, one per level, with the inactive two
detached* — a camera move then adds and removes hundreds of nodes, failing
FR-044/SC-008, and the detached subtrees go stale between ticks. *`visibility:
hidden`* — keeps the hidden nodes in layout, so the cost the spec complains
about stays. *Removing the far-level nodes from `wanted` in the reconciliation
call* — makes the drawn set a function of the camera, which means a camera move
runs a reconciliation pass: FR-044's "no reconciliation pass runs" forbids it
exactly. *Deciding per node in JS on each move* — per-node JS per camera event,
against the spirit of FR-045 and unnecessary when one attribute does it.

---

## D4. Constant apparent size is one CSS custom property, `--k`, and `calc(Npx / var(--k))`

**Decision.** `applyView()` sets `--k` to the current scale on `#world`
(`world.style.setProperty("--k", k)`). Everything that must hold a constant
apparent size is authored in the stylesheet as a screen-pixel quantity divided
by that number:

```css
.dlabel  { font-size: calc(7px  / var(--k)); }   /* was font-size: 7  */
.blabel  { font-size: calc(5px  / var(--k)); }
.zlabel  { font-size: calc(4px  / var(--k)); }
.alabel  { font-size: calc(3.6px / var(--k)); }
.wire path { stroke-width: calc(var(--wire-w, 1) * 1px / var(--k)); }
```

Per-wire data (`--wire-w`, the existing `min(3.2, 0.7 + log2(1+count)·0.7)`) is
written once per wire per **tick** by `updateWire()`, never by the camera. The
arrowhead needs no work at all: the existing marker (`web/map.html:231-233`)
uses the default `markerUnits="strokeWidth"`, so once the stroke width is
counter-scaled the marker follows it exactly (FR-031). The message-count bubble
gets one extra nesting: `<g class="bubble" transform="translate(lx ly)">` written
from data, wrapping `<g class="bubblescale">` carrying
`transform: scale(calc(1 / var(--k))); transform-origin: 0 0;` in CSS, with the
circle at `cx=0, cy=0` and its text at `y=3`. The bubble's *position* stays a
data-written attribute on the outer group (so it stays attached to the same point
on the line, FR-032) and its *size* is CSS-driven (so it holds its apparent
size).

**Rationale.** One property write on one element, inherited by the whole subtree
including the `<defs>` marker, satisfies FR-031, FR-032 and FR-033 without the
camera path touching a single scene-graph node — which is what FR-044 demands. It
is declarative, so there is no per-frame JS (FR-045), and it is the same trick
the existing code already relies on for colour (`var(--bad)` etc.), so it adds
no new concept to the page.

**Rejected.** *`vector-effect="non-scaling-stroke"`* — solves the line and
nothing else: the arrowhead is sized from the user-space stroke width, which
`non-scaling-stroke` does not change, so the arrowhead would still shrink and
FR-031 names the arrowhead explicitly. *Writing `font-size`/`stroke-width`
attributes per node on each camera move* — the direct reading of FR-044's "only
the camera group's transform … change" forbids it, and it is O(nodes) work per
wheel event. *A counter-scaled `<g>` wrapper around every label* — one wrapper
node per label, and text drawn inside a scaled group inherits a scaled
coordinate system, so every `x`/`y` in the primitives would have to change: a
coordinate rewrite, which FR-025 and FR-048 forbid. *CSS geometry properties
(`r: calc(8px / var(--k))`) for the bubble* — would be the tidiest form, but
`r`-as-CSS is the least-supported piece of SVG 2 in circulation and the nested-`g`
form costs one node per wire and works everywhere.

---

## D5. Pan clamping is one interval, `[min(a,b), max(a,b)]`, for both cases

**Decision.** For the x axis, with `k = LADDER[idx]` and the occupied extent `E`:

```
a = -E.x · k                        (world's left edge at the viewport's left)
b = vw - (E.x + E.w) · k            (world's right edge at the viewport's right)
tx ∈ [ min(a, b), max(a, b) ]
```

and the same for `ty` with `E.y`, `E.h`, `vh`. No branch on whether the world is
larger than the viewport.

**Rationale.** When `E.w · k > vw` the world is wider than the window and
`b < a`, so the interval is `[b, a]`: the visible rectangle is held inside the
extent. When `E.w · k < vw` the world is narrower and `a < b`, so the interval is
`[a, b]`: the world is held fully inside the viewport. Those are precisely
FR-008's two clauses, and they fall out of the same two endpoints without a
conditional — which matters because a branch here is a branch that has to be
mutation-tested twice and can be got backwards once. The degenerate case
`E.w · k == vw` collapses to a single permitted value, which is correct.

**Rejected.** *Clamping the visible rectangle's centre to the extent* — lets a
corner of the city leave the screen, and "the city can never be lost off-screen"
(FR-008) is the requirement. *Allowing a margin of empty ground around the
extent* — pleasant to drag against, but it means a person can pan onto ground
with nothing on it, which is the state FR-038 goes out of its way to prevent on
restore; permitting it interactively while forbidding it on reload would be
incoherent. *Clamping only on pointer-up* — the view leaves the bounds during the
drag and snaps back, which reads as a bug.

---

## D6. Input is event-driven with no loop: a wheel accumulator, a drag threshold, and a 120-pixel key step

**Decision.**

- **Drag.** `pointerdown` on `#world` with the primary button captures the
  pointer (`setPointerCapture`), records the start point and the current
  `{tx, ty}`. `pointermove` sets `tx/ty` from the pointer delta and calls
  `applyView()`. `pointerup`/`pointercancel`/`lostpointercapture` all end the
  drag. Movement beyond **4 CSS pixels** (Manhattan distance) marks the gesture
  as a pan and sets a `dragMoved` flag; the existing document-level `click`
  handler (`web/map.html:1163-1169`) returns early when that flag is set and
  clears it (FR-005). Below the threshold nothing is suppressed, so a press and
  release on a figure is still a click.
- **Wheel.** One listener on `#world` with `{passive: false}`, always
  `preventDefault()` (FR-007, and it is also what stops a `ctrl`+wheel pinch from
  zooming the browser). Deltas are normalised for `deltaMode` (lines × 16,
  pages × the viewport height) and accumulated; the accumulator crosses
  **±100 normalised pixels** to take exactly one ladder step, then resets to
  zero, and reverses immediately on a sign change (FR-006). A one-pixel event
  therefore cannot change the scale at all, and one trackpad flick takes one or
  two steps rather than crossing the ladder.
- **Keys.** Arrow keys pan **120 CSS pixels** per press (`Shift` → 480);
  `+`/`=` and `-`/`_` take one ladder step anchored at the viewport centre;
  `0` fits. The handler returns immediately when the event's target — or
  `document.activeElement` — matches `input, textarea, select, [contenteditable]`
  or reports `isContentEditable` (FR-015), which is what keeps the inspector's
  reply box typable.
- **Touch.** `touch-action: none` on `#world`, so a one-finger drag pans rather
  than scrolling the page.

**Rationale.** 120 pixels is about a tenth of a typical window and one district
plot at `k = ½`, so an arrow press moves a useful amount at every scale while
staying the same *apparent* movement — which the spec's assumption asks for. The
4-pixel drag threshold is the conventional slop for distinguishing a click from
a drag and is small enough that a deliberate click never crosses it. The 100-unit
wheel threshold is a little under one notch of a classic mouse wheel (which
reports 100–120 per notch on the platforms this runs on), so a mouse wheel gives
one step per notch and a trackpad's stream of 1–10 pixel deltas needs a real
gesture to move a rung.

On FR-045, which says a camera move "MUST NOT run JavaScript per frame": the
prohibition is read as forbidding self-perpetuating loops (`requestAnimationFrame`,
a repainting `setInterval`) and JS-driven easing. A handler that writes one
attribute in response to one input event is the opposite of a loop — it stops
when the input stops, and it is the only way a pointer drag can track a pointer
at all. FR-043 states the checkable form of the constraint (zero
`requestAnimationFrame`, exactly one `setInterval`) and this design keeps both
literally true.

**Rejected.** *Coalescing pointer moves into a `requestAnimationFrame`* — the
standard smoothness trick, and flatly forbidden by FR-043 and the existing
assertion at `tests/run.sh:759-763`. *A `pointermove` listener on `document`
instead of pointer capture* — capture is what makes "the pointer leaves the
window mid-drag" end cleanly, which is an edge case the spec calls out. *Zooming
on `wheel` without `preventDefault`* — the page scrolls behind the map, failing
FR-007. *Using `keydown` on `document` without the editable-target guard* — the
reply box stops working, which is FR-015's whole subject.

---

## D7. The detail level is a Schmitt trigger on the ladder index, with a cold mapping for restore

**Decision.** Two thresholds per level, in ladder indices, with the rising
threshold one rung above the falling one:

| Level | Rise into it at | Fall out of it below | Band where the level is direction-dependent |
|---|---|---|---|
| **far** | — (bottom) | — | |
| **mid** | `idx ≥ 3` (`k ≥ 2`) | `idx < 2` (`k < 1`) | `idx = 2` (`k = 1`) |
| **near** | `idx ≥ 5` (`k ≥ 4`) | `idx < 4` (`k < 3`) | `idx = 4` (`k = 3`) |

So `k ≤ ½` is always far, `k = 2` is always mid, `k ≥ 4` is always near, and the
two single-rung bands at `k = 1` and `k = 3` hold whichever level the camera
arrived with. `levelFor(idx, prev)` is a pure function of those two values.

For a restore, a resize or any other event with no meaningful previous level,
`levelFor(idx, null)` uses the **cold** mapping — the bands resolve *downward*:
`idx ≤ 2 → far`, `idx = 3, 4 → mid`, `idx ≥ 5 → near`. FR-041 is then satisfied
by construction: the restored level is a function of the restored scale alone.

**Rationale.** FR-026 requires the entering step to be strictly above the
leaving step, which on a discrete ladder means the two thresholds must be at
least two rungs apart — otherwise they name the same boundary and there is no
hysteresis, only a shared edge. One rung of overlap is the minimum that gives
real hysteresis and the maximum that keeps a level from persisting into scales
it cannot be read at; two rungs of overlap would leave mid detail on screen at
`k = ½`, which is the illegibility the feature exists to fix. The chosen
thresholds sit inside the spec's own sketch ("far below scale 1, mid around 1–2,
near at 3 and above"): far below 1 ✓, mid at 1–2 ✓, near retained at 3 and
always at 4 and above — the one deviation being that near is *entered* at 4
rather than 3, which is the price of the band and is recorded here.

Because `levelFor` is called only from `applyView()`, and `applyView()` is called
only from camera paths, SC-003 holds without extra machinery: one camera event
crosses at most one threshold, and a tick calls nothing.

**Rejected.** *A single threshold per boundary* — no hysteresis at all; the spec
calls this out as the failure to avoid. *Hysteresis in continuous scale (enter at
1.0, leave at 0.9)* — meaningless on a discrete ladder where nothing between two
rungs is reachable. *Hysteresis in time (a dwell timer)* — needs a timer, and
FR-030 says the level changes on the camera event that crossed the boundary,
never on a timer. *Deriving the level from the number of visible sessions rather
than the scale* — makes the level a function of volatile data, so a tick could
change it: FR-026 forbids exactly that.

---

## D8. The pure arithmetic lives in a new `web/camera.js`, tested under `node`

**Decision.** A third static module beside `web/md.js` and `web/plots.js`,
exporting `window.CCWATCH_CAMERA` with a `module.exports` tail. It holds the
ladder, `fitIndex`, `centreOn`, `zoomTo`, `clampPan`, `panBy`, `levelFor`,
`wheelStep`, and the viewport record's `loadView`/`saveView`/`validateView` with
injected storage functions. It is pure: no DOM, no `fetch`, no timers, no
globals but its own export. `web/map.html` keeps every DOM concern — listeners,
the transform write, `--k`, `data-lod`, the controls — and calls into the module
for every number.

**Rationale.** FR-055 requires the camera's decisions to be assertable without a
browser, and `CLAUDE.md` already states the reason a second file exists ("so
that `tests/run.sh` can run it under node and assert on the HTML"); this is the
same trade a third time. It is served by the static fallback in `serve`
(`bin/ccwatch:3041`, `super().do_GET()` over `web/`), exactly as `md.js` and
`plots.js` are, so it needs no route and no change to `bin/ccwatch` at all —
which is what lets FR-053 hold literally.

**Rejected.** *Adding the camera to `web/plots.js`* — `plots.js` is documented
and asserted as the module that may not read a volatile field
(`web/plots.js:12-14`); the camera reads none either, but it *is* a different
concern with a different persisted record, and merging them would put fit-step
selection next to identity hashing in one 500-line file. *Inline in
`map.html`* — the arithmetic then needs a browser to test, and FR-055 exists to
forbid that. *A fourth file for the persisted record* — the record is three
numbers; splitting it from the functions that validate it would spread one
contract over two files.

---

## D9. The viewport is its own versioned `localStorage` record, validated against the live extent

**Decision.** Key `ccwatch.map.view.v1`, separate from
`ccwatch.map.plots.v1` (FR-035). Shape:

```json
{ "v": 1, "idx": 4, "tx": -312.5, "ty": -88 }
```

Written on a debounce-free but *coalesced* basis: `applyView()` records the
pending record and the actual `setItem` happens on `pointerup`, on key/button
release, and on `visibilitychange` — not on every `pointermove`. Read once at
load through an injected getter, and put through `validateView()`, which
discards the record — silently, and in favour of a fit — when it is absent,
unparseable, of a different `v`, missing a field, has a non-finite `tx`/`ty`, or
has an `idx` that is not an integer in `[0, LADDER.length)` (FR-037). A record
that survives validation is then clamped (D5) and tested for intersection: if
the visible world rectangle intersects none of the placed district, building,
zone or figure boxes, it is dropped for a fit (FR-038). Every `localStorage`
call is wrapped, and the first throw flips a `persistence` flag to
`"unavailable"` once — never retried, never in a loop — which the page states as
text (FR-040).

**Rationale.** Separate record because the plot assignments and the viewport
have different lifetimes and different invalidation reasons: a change of ladder
must invalidate the viewport and must *not* invalidate the plots, and a bounded
LRU eviction of 512 plot entries must not be able to evict the viewport.
Coalescing the write is what keeps a drag from issuing hundreds of
`setItem` calls; the pending-record-plus-flush shape means a crash mid-drag
loses at most the current gesture. Validating against the *live* extent rather
than trusting a stored extent is the spec's own instruction ("validated against
the current placements before it is used") and is why FR-038's failure — opening
on empty ground — cannot happen.

`persistence` is modelled on the identical mechanism `plots.js` already has
(`web/map.html:1172-1176`), so the page has one idiom for "storage stopped
working", not two.

**Rejected.** *Storing the scale instead of the index* — see D1. *Storing the
centre world point instead of `tx/ty`* — equivalent information, but the restore
then depends on the viewport size at save time, so a reload in a resized window
lands somewhere the person did not leave; `tx/ty` plus the clamp is
window-size-independent in the only way that matters. *Storing the extent
alongside, and refitting when it changed* — a refit on any extent change is
FR-011's forbidden behaviour, and the intersection test answers the real
question (is there anything to look at) without it. *`sessionStorage`* — the map
is a thing left open for days through restarts; per-tab storage would forget on
every window close, which is the complaint Story 3 opens with.

---

## D10. A resize keeps the centre world point; a tick clamps but never refits

**Decision.** The existing `resize` listener (`web/map.html:1432-1436`) stops
calling `applyFit`. It instead reads the world point currently at the centre of
the viewport *before* the new size is applied, updates the `viewBox` to the new
client size, then solves for the `{tx, ty}` that puts that same world point at
the centre of the new viewport, and clamps (FR-010). The scale is untouched. The
tick path keeps its `placed.sig` guard, and when the signature changes it no
longer refits: it re-reads the extent and re-applies the *current* view through
the clamp, so a view that has fallen outside a shrunken extent is pulled back in
and a view that is still inside one does not move at all (FR-011).

**Rationale.** Both requirements are the same principle — the view is the
person's, and the only reason to touch it is that it has become impossible.
Keeping the centre point is what makes a resize feel like the window changed
rather than the map. Reusing the clamp for the tick path means the
extent-shrinks case is handled by code that is already mutation-tested for the
pan case, and there is no second notion of "in bounds".

The first paint is the one case that *does* fit: no stored viewport, or a stored
one that failed validation, produces `fitIndex(extent, vw, vh)` (FR-036).

**Rejected.** *Keeping the top-left world point instead of the centre* — the
content a person is looking at is in the middle of the window, and anchoring the
corner slides it off. *Refitting on resize (today's behaviour)* — correct while
there was no viewport to lose, and exactly wrong now; the spec's third
consequence says so. *Refitting when the extent shrinks* — moves the view the
person chose, forbidden by FR-011.

---

## D11. Fit picks the largest rung that shows the whole extent, and says so when none does

**Decision.** `fitIndex(extent, vw, vh)` returns `{idx, overflow}`: the largest
`idx` with `extent.w · LADDER[idx] ≤ vw` **and** `extent.h · LADDER[idx] ≤ vh`;
when no rung qualifies it returns `idx = 0` with `overflow: true`. The camera
then centres the extent at that rung. `overflow` drives a single sentence in the
page chrome — "the whole world does not fit at this zoom" — which is rendered
only while it is true (FR-012, Constitution XII).

**Rationale.** Fit has to land on a rung because the ladder is absolute (D2), and
the largest qualifying rung is the one that shows the extent as large as it can
be shown. Returning the overflow as data rather than as a rendered string keeps
the decision in the testable module (FR-055) and the wording in the page.

**Rejected.** *Fitting to a computed scale and adding it to the ladder* — the
ladder stops being fixed and integer-friendly, failing FR-002. *Silently
accepting that the extent is clipped* — a failure looking like an absence
(Constitution IV): the person sees a city with an edge and no way to know
whether there is more. *A standing "zoom: fit" line that says whether it fits* —
a line that appears on every refresh to say things are fine (Constitution XII).

---

## D12. Easing is a bounded CSS transition applied by a class, for fit and the `centreOn` API only

**Decision.** `#camera.eased { transition: transform 180ms ease-out; }` with
`@media (prefers-reduced-motion: reduce) { #camera.eased { transition: none } }`.
The class is added for the two moves where a person can lose their place — the
fit reset (`0` and the fit button) and `centreOn(..., {animate: true})` (FR-042)
— and removed immediately afterwards on `transitionend`. Drags, wheel steps, key
pans and key zooms jump.

**Rationale.** A declarative transition of a bounded duration that ends is
exactly what FR-045 permits, and the reduced-motion media query reduces it to an
instant jump without a JS branch. Not easing the pointer paths is not a
compromise: an eased drag lags the pointer, and an eased wheel step lags a
trackpad's stream of steps. The spec's own assumption records that no easing at
all would satisfy every requirement, so this is the smaller of two acceptable
designs, not a stretch of one.

**Rejected.** *Easing every camera move* — the drag lag above. *A JS easing loop*
— per-frame JS, forbidden by FR-045 and by FR-043's zero-`requestAnimationFrame`
assertion. *`transition` permanently on `#camera`* — every camera move eases,
same lag, and a tick-driven clamp would animate too.

---

## D13. The far-level aggregate selects a maximum over payload fields and prints the selected row's own words

**Decision.** For each district the page computes, on the **data** path (once per
tick, in `buildWorldModel`), a summary object:

```
{ n, worst, unfinished }
   n           the number of session rows in the district
   worst       the `token` string of the row with the greatest [sev, psev] pair
   unfinished  the existing badge text of one unfinished run in the district —
               `${u.phase}/${u.status}`, or `${u.phase}/CRASHED` when crashed —
               plus `+N` when there is more than one
```

Rendered at far into `.dsummary` as, for example,
`acme · 8 sessions · waiting · plan/CRASHED`. The ordering key `[sev, psev] | max`
is lifted verbatim from the terminal's own sort (`bin/ccwatch:920`). The status
word is the selected row's `token`, printed as it arrived. No new word, badge,
severity or colour is introduced, and the view ranks nothing it was not given.

**Rationale.** FR-027 permits a maximum over values the payload supplied and
forbids deriving a status; selecting a row by a key the CLI already sorts on, and
then printing that row's own status word, is a selection. Reusing the CLI's key
rather than inventing one is also Constitution XI in practice: if the terminal
and the map disagree about which session is worst, there is no way to tell which
is lying. FR-028 is met by the word being a word — `ccwatch once | grep HUNG`'s
graphical equivalent — and FR-029 by the `unfinished` field, which is the one
fact FR-022 stops drawing at far and therefore the one fact the aggregate has to
carry. `n` beside the word is Constitution II: the measurement next to the
verdict.

The summary is computed on the data path, not the camera path, so a camera move
does not recompute it (FR-044) and a level change cannot alter it.

**Rejected.** *Showing the worst `sev` as a number or a colour* — colour alone
fails Constitution VII and a bare severity integer is not a word anyone reads.
*Computing a district-level severity of its own (e.g. "district degraded")* — a
new verdict, forbidden by FR-027 and Constitution V. *Dropping the unfinished
badge at far without carrying it* — a claim disappearing, forbidden by FR-029
and Constitution IV. *Aggregating counts server-side into the payload* — a
payload change, forbidden by FR-053, and unnecessary: the count is a length of a
list the page already has.

---

## D14. The controls and the two conditional notes live in page chrome, outside the camera group

**Decision.** A new `<div id="camctl">` in the page chrome, immediately after
`#world` inside `#wrap`, holding three real `<button>` elements (zoom out, zoom
in, fit), a `<span id="camstate">` reading e.g. `zoom 3× · near`, and a
`<span id="camnote">` used for the two conditional sentences (`overflow` from
D11, and the "the viewport will not be remembered" text from D9). `#world` gains
`tabindex="0"` and an `aria-label` naming it and stating the keys. `#camstate`
carries `aria-live="polite"` so a zoom announces. The buttons are built once with
DOM APIs — no `innerHTML`, keeping the count at exactly two (FR-047) — and their
`disabled` state and `title`/`aria-description` are written by `applyView()`:
present and disabled with a reason at the ends of the ladder, never removed
(FR-017).

**Rationale.** FR-016, FR-018 and FR-019 want real, focusable, named controls and
a textual statement of scale and level; putting them in chrome rather than in the
SVG means they are unaffected by the camera transform and by `data-lod`, which is
also why the four failure sentences and the gauges already live there (the spec's
own assumption records this). `#camstate` is an always-present line, which is
worth stating against Constitution XII: XII forbids a line that says *things are
fine*; a readout of the camera's own state is the textual equivalent of the
picture that VII requires, and it carries information that changes. The two
sentences in `#camnote` are the ones that follow XII strictly — absent unless
true.

**Rejected.** *Drawing the controls into the SVG* — they would scale, move and
disappear with the level of detail. *A keyboard-only camera with no buttons* —
FR-016 requires the buttons. *Hiding the zoom-in button at maximum zoom* — the
absence reads as "not built"; FR-017 and Constitution IV require present and
disabled with the reason.

---

## What the suite can and cannot assert

**Can, headlessly, under `node`** (FR-055): the ladder's values and clamping;
`fitIndex` including the overflow case; `clampPan` in both the larger- and
smaller-than-viewport directions; pointer-anchored `zoomTo` (the anchored world
point is preserved to within a pixel — SC-004 becomes an arithmetic assertion);
`levelFor` in both directions across both bands and its cold mapping;
`wheelStep`'s accumulation and reset; `validateView` against each of the five
invalid shapes; the viewport record's round trip through injected storage.

**Can, statically, over the served pages**: zero `requestAnimationFrame` and
exactly one `setInterval` on both pages (the existing assertion, unmodified);
`innerHTML` still assigned exactly twice in `map.html`; the `SEND_TOKEN` line
byte-identical; `/camera.js` served and non-empty; the counter-scaling
`calc(… / var(--k))` present for each of the four label classes and the wire;
the `data-lod` rules present for each of the three levels; three real `<button>`
elements with accessible names; `touch-action: none` on the map surface.

**Cannot, without a browser**: that a rendered glyph's on-screen size is
constant; that a pointer drag pans one-to-one; that `display: none` actually
stops paint; that a focus ring is visible; that a screen reader announces the
level. Those are `quickstart.md`'s manual scenarios, each with a stated expected
outcome — the same recorded limit `002-map-stable-world` carried, and for the
same reason.
