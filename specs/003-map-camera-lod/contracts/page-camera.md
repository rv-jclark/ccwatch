# Contract — what `/map` does with the camera

**Feature**: `003-map-camera-lod` | **Page**: `web/map.html` | **Module**: [camera-js.md](./camera-js.md)

The page's side of the camera: the DOM it adds, the attributes it writes, the
events it listens for, the stylesheet rules that make level of detail and
constant apparent size work, and the API it exposes for `map-roster`. Everything
here is a claim a reviewer can check against the served page; the ones the suite
checks statically are marked **[asserted]**.

`specs/002-map-stable-world/contracts/page-render.md` stays in force. Nothing
below removes a rendering it describes.

---

## 1. The single writer

```js
function applyView() { … }
```

Called by every camera path and by nothing else. It performs exactly these
writes, in this order, and no others:

| Write | Target | Requirement |
|---|---|---|
| `transform="translate(TX TY) scale(K)"` | `#camera` | FR-001 |
| `--k: K` | `#world` (inline style) | FR-031–FR-033 |
| `data-lod="far\|mid\|near"` | `#world` | FR-021–FR-024 |
| `disabled`, `title` | the three `#camctl` buttons | FR-017 |
| text | `#camstate`, `#camnote` | FR-012, FR-019, FR-040 |
| staged record | `pendingSave` (no `setItem` here) | FR-035 |

**It creates no node, removes no node and writes no attribute on any district,
building, zone, figure, badge or wire** (FR-044, SC-008). It reads no payload
field. It calls no reconciliation. It does not fetch.

`drawWorld()` keeps its `placed.sig` guard; where it called `applyFit(extent)` it
now updates `worldExtent` and calls `applyView()` — which re-clamps the current
view against the new bounds without refitting (FR-011).

---

## 2. New DOM

```html
<svg id="world" viewBox="0 0 408 408" tabindex="0" data-lod="mid"
     aria-label="City map. Drag to pan. Arrow keys pan, plus and minus zoom,
                 zero fits the whole world.">
```

**[asserted]** `#world` carries `tabindex="0"` and a non-empty `aria-label`
naming the keys (FR-018).

```html
<div id="camctl">
  <button id="zout" type="button">zoom out</button>
  <button id="zin"  type="button">zoom in</button>
  <button id="zfit" type="button">fit</button>
  <span id="camstate" aria-live="polite">zoom 2× · mid</span>
  <span id="camnote"></span>
</div>
```

**[asserted]** three real `<button>` elements with accessible names, built with
DOM APIs — no `innerHTML`, so `map.html` still assigns it exactly twice
(FR-047). `#camctl` sits in `#wrap` after `#world`, in page chrome and outside
the camera group, which is why it is unaffected by the transform and by
`data-lod` (FR-016, FR-019).

Each district gains one text node in `makeDistrict()`:

```html
<text class="dsummary" x="3" y="18"></text>
```

written every tick from `DistrictSummary` ([data-model.md §5](../data-model.md)),
rendered only at far (FR-022).

The count bubble in `makeWire()` gains one level of nesting so its position can
stay a data-written attribute while its size is CSS-driven (FR-032):

```html
<g class="bubble" transform="translate(LX LY)">
  <g class="bubblescale">
    <circle cx="0" cy="0"/><text y="3"/>
  </g>
</g>
```

---

## 3. Stylesheet rules

**[asserted]** each of the following is present in the served page.

Level of detail — one attribute, four rules (FR-022–FR-025):

```css
#world[data-lod="far"] .building,
#world[data-lod="far"] .zone,
#world[data-lod="far"] .agent      { display: none; }
#world[data-lod="far"] .dlabel     { display: none; }
#world:not([data-lod="far"]) .dsummary { display: none; }
#world[data-lod="mid"] .alabel     { display: none; }
```

Constant apparent size — one custom property (FR-031–FR-033):

```css
.dlabel   { font-size: calc(7px   / var(--k, 1)); }
.blabel   { font-size: calc(5px   / var(--k, 1)); }
.zlabel   { font-size: calc(4px   / var(--k, 1)); }
.dsummary { font-size: calc(6px   / var(--k, 1)); }
.alabel   { font-size: calc(3.6px / var(--k, 1)); }
.norepo-badge, .wreck-badge, .deploy-badge { font-size: calc(4px / var(--k, 1)); }
.wire path { stroke-width: calc(var(--wire-w, 1) * 1px / var(--k, 1)); }
.wire text { font-size: 9px; }            /* inside .bubblescale — already counter-scaled */
.bubblescale { transform: scale(calc(1 / var(--k, 1))); transform-origin: 0 0; }
```

The `var(--k, 1)` fallback matters: before the first `applyView()` the page
renders at scale 1 rather than collapsing to zero-height text.

The arrowhead needs no rule. The existing marker
(`web/map.html:231-233`) uses the default `markerUnits="strokeWidth"`, so it
follows the counter-scaled stroke width exactly (FR-031).

Interaction and easing:

```css
#world { touch-action: none; }                    /* FR-007 on touch */
#world:focus-visible { outline: 2px solid var(--info); outline-offset: 2px; }
#camera.eased { transition: transform 180ms ease-out; }
@media (prefers-reduced-motion: reduce) { #camera.eased { transition: none; } }
```

**[asserted]** `touch-action: none` on the map surface, and the reduced-motion
media query guarding the only transition (FR-045, SC-012).

The existing per-level stroke widths (`.district .hit { stroke-width: 1 }` and
friends) are left in world units on purpose: an outline that thickens as you
zoom out is the correct reading of a district boundary, and FR-031 names the
wires, not the outlines.

---

## 4. Events

| Event | Target | Options | Behaviour |
|---|---|---|---|
| `pointerdown` | `#world` | — | primary button only; `setPointerCapture`; records the start point and `{tx,ty}`; focuses `#world` |
| `pointermove` | `#world` | — | while dragging: `panBy` + `clampPan` + `applyView()`; sets `drag.moved` past `DRAG_SLOP` |
| `pointerup`, `pointercancel`, `lostpointercapture` | `#world` | — | ends the drag; flushes `pendingSave` |
| `click` | `document` (existing handler) | — | returns early and clears the flag when `drag.moved` — so a pan never opens an inspector (FR-005) |
| `wheel` | `#world` | `{passive: false}` | always `preventDefault()`; `wheelStep`; a step is `zoomTo` anchored at the pointer (FR-003, FR-006, FR-007) |
| `keydown` | `#world` | — | arrows, `+`/`=`, `-`/`_`, `0`; inert when the target or `document.activeElement` matches `input, textarea, select, [contenteditable]` or reports `isContentEditable` (FR-013–FR-015) |
| `click` | each `#camctl` button | — | one ladder step anchored at the viewport centre, or a fit (FR-004, FR-039) |
| `resize` | `window` | — | **no refit**: holds the centre world point, re-clamps (FR-010) |
| `visibilitychange` | `document` (existing) | — | unchanged cadence behaviour; flushes `pendingSave` (FR-046) |
| `transitionend` | `#camera` | — | removes the `eased` class |

No `requestAnimationFrame` anywhere, and no new `setInterval`: the page keeps
exactly one, the shared visibility-aware scheduler (`web/map.html:841-847`).
**[asserted]** by the existing footprint assertions, unmodified
(`tests/run.sh:759-767`, FR-043, SC-009).

A camera event never calls `tick()`, never issues a `fetch`, and never touches
the polling timer (FR-046, SC-007).

---

## 5. Load order

1. `place()` runs on the first tick and produces `worldExtent` and the placed
   boxes — unchanged.
2. `loadView(getItem)` → `validateView`. `null` ⇒ `fitView` (FR-036, FR-037).
3. A record that validated is clamped, then intersection-tested against
   `placed.world.districts`/`.buildings`/`.zones`/`.figures` using
   `visibleWorldRect` and `intersects`. No intersection ⇒ `fitView` (FR-038).
4. `level = levelFor(view.idx, null)` — the cold mapping, so the restored level
   follows from the restored scale (FR-041).
5. `applyView()`.

The camera is therefore never applied before there is an extent to clamp
against, which is what stops a first paint from landing outside the world.

---

## 6. The API `map-roster` will call (FR-042)

```js
window.CCWATCH_MAP_CAMERA = {
  centreOn(wx, wy, opts),   // opts: {idx, animate}
  fit(),
  current(),                // → {idx, scale, level, tx, ty}
}
```

`centreOn` computes the view with `CCWATCH_CAMERA.centreOn`, clamps it, and
applies it. With `animate: true` it adds the `eased` class first, which the
`prefers-reduced-motion` rule reduces to an instant jump — no JS branch and no
per-frame work (FR-045).

This entry ships the API and **no caller**: no roster panel, no selection model,
no fly-to-on-select (the spec's Out of Scope). `current()` exists so the roster
can read the level without duplicating the thresholds.

---

## 7. What must still be true afterwards

| Claim | Where it is checked |
|---|---|
| `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` byte-identical | existing assertion, `tests/run.sh` serve section (FR-052) |
| `innerHTML` assigned exactly twice in `map.html` | existing assertion `tests/run.sh:1287-1289` (FR-047) |
| zero `requestAnimationFrame`, exactly one `setInterval`, both pages | existing assertion `tests/run.sh:759-767` (FR-043, SC-009) |
| the four failure sentences, still four, still with the geography drawn, readable at every zoom | they live in `#trust` in page chrome, outside the camera group and outside `data-lod` (FR-049, SC-010) |
| volatile readings still withheld, not annotated | `VOLATILE` untouched; nothing volatile enters a summary (FR-050) |
| gauges, host-pressure line, legend, counts, footer, title unchanged | not on the camera path (FR-051) |
| the inspector survives a camera move with its scroll position and half-typed message | `#reply` is chrome; the camera writes nothing inside it (FR-051) |
| identity-derived positions, the plot store, keyed reconciliation unchanged | `web/plots.js` is not modified by this feature (FR-048) |
| no payload change, no `bin/ccwatch` change | `/camera.js` is served by the existing static fallback (FR-053, FR-054) |
