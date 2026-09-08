# Contract — `web/camera.js`, the pure camera-arithmetic module

**Feature**: `003-map-camera-lod` | **Loaded by**: `web/map.html` via `<script src="/camera.js">` | **Tested by**: `tests/run.sh`, `camera` section, under `node`

A third static module beside `web/md.js` and `web/plots.js`, and new for the
reason `CLAUDE.md` already gives for `md.js`: so `tests/run.sh` can run it under
`node` and assert on its output without a browser (FR-055). It is served by the
static fallback in `serve` (`bin/ccwatch:3041`) exactly as the other two are, so
it needs no route and `bin/ccwatch` is not touched at all.

**Pure.** No DOM, no `fetch`, no timers, no globals other than its own export.
`localStorage` is reached only through the functions the caller passes to
`loadView`/`saveView` (§8), which is how the suite exercises persistence — and a
throwing storage — without a browser.

Exported as `window.CCWATCH_CAMERA`, with a `module.exports` tail for `node`.

Screen quantities are CSS pixels. World quantities are the world units
`web/plots.js` authors. `viewBox` is fixed to the SVG's client size, so one world
unit is one screen pixel at `k = 1`, and a world point `w` is on screen at
`w · k + t`.

---

## 1. Constants

```js
CCWATCH_CAMERA.LADDER = [0.25, 0.5, 1, 2, 3, 4, 6, 8];   // frozen, index 0…7
CCWATCH_CAMERA.WHEEL_THRESHOLD = 100;   // normalised wheel pixels per step
CCWATCH_CAMERA.PAN_STEP  = 120;         // screen px per arrow press
CCWATCH_CAMERA.PAN_STEP_BIG = 480;      // with Shift
CCWATCH_CAMERA.DRAG_SLOP = 4;           // screen px before a press becomes a pan
CCWATCH_CAMERA.STORAGE_VERSION = 1;
```

Every ladder entry is a whole number or the reciprocal of one (FR-002). The
ladder does not depend on viewport size or world extent, and no function in this
module may extend it. `PAN_STEP` is in screen pixels so an arrow press moves the
same apparent distance at every scale.

---

## 2. `scaleFor(idx) → number` and `clampIdx(idx) → integer`

`scaleFor` is `LADDER[clampIdx(idx)]`. `clampIdx` floors to an integer and
clamps to `[0, LADDER.length - 1]` (FR-009). A step past either end returns the
end, so the caller can compare the returned index with the one it asked for to
decide whether a control is disabled (FR-017).

Guarantees:

- `clampIdx(-3) === 0`, `clampIdx(99) === 7`, `clampIdx(2.7) === 2`.
- `scaleFor` never returns a value that is not in `LADDER`.

---

## 3. `clampPan(view, extent, vw, vh) → Viewport`

Returns a new `{idx, tx, ty}` with `tx` and `ty` clamped to the intervals in
[data-model.md §4](../data-model.md). `idx` is returned unchanged.

Guarantees (FR-008):

- With `extent.w · k > vw`, the returned visible rectangle lies inside the
  extent on that axis: `-tx/k ≥ extent.x` and `(-tx + vw)/k ≤ extent.x + extent.w`.
- With `extent.w · k < vw`, the extent lies inside the viewport on that axis:
  `extent.x · k + tx ≥ 0` and `(extent.x + extent.w) · k + tx ≤ vw`.
- Idempotent: `clampPan(clampPan(v, …), …)` equals `clampPan(v, …)`.
- A non-finite `tx`/`ty` returns the centred value for that axis rather than
  propagating `NaN`.
- `vw` or `vh` of `0` — the element not laid out yet — returns `view` unchanged.

---

## 4. `fitIndex(extent, vw, vh) → { idx, overflow }`

The largest `idx` with `extent.w · LADDER[idx] ≤ vw` **and**
`extent.h · LADDER[idx] ≤ vh`. When no rung qualifies, `{ idx: 0, overflow: true }`.
`overflow` is `false` otherwise (FR-012).

`overflow` is returned as data, not as a sentence: the wording lives in the page
and is rendered only while `overflow` is true (Constitution XII).

---

## 5. `fitView(extent, vw, vh) → { idx, tx, ty, overflow }`

`fitIndex` followed by the centring translation:

```
tx = (vw - extent.w · k) / 2 - extent.x · k
ty = (vh - extent.h · k) / 2 - extent.y · k
```

which is `plots.js`'s existing `fit()` arithmetic (`web/plots.js:305-313`) with
the scale supplied by the ladder instead of computed. The result is passed
through `clampPan`, which is a no-op when the extent fits and is what keeps the
overflow case inside the extent.

Guarantees: FR-012, FR-036, FR-039. `fitView` is the single answer to "no stored
viewport", "an invalid stored viewport", `0`, and the fit button.

---

## 6. `zoomTo(view, idx, ax, ay) → Viewport`

One anchored zoom. `idx` is the requested index (clamped by §2); `ax`,`ay` is the
anchor in **screen** pixels relative to the SVG's top-left — the pointer for a
wheel or pinch (FR-003), the viewport centre for a key or a button (FR-004).

```
w  = (ax - view.tx) / scaleFor(view.idx)      // the world point under the anchor
k2 = scaleFor(clampIdx(idx))
tx = ax - w · k2                              // …still under the anchor
```

and likewise for `y`. The caller clamps afterwards.

Guarantees:

- **SC-004 as arithmetic**: the world point under the anchor before the call is
  under the anchor after it, to within floating-point error — the assertion
  checks `|w·k2 + tx - ax| < 1`.
- A request outside the ladder returns the end rung with the anchor still
  preserved, so a clamped zoom does not shift the view.
- `zoomTo(v, v.idx, …)` returns a view equal to `v`.

---

## 7. `panBy(view, dx, dy) → Viewport`, `centreOn(view, wx, wy, vw, vh, idx?) → Viewport`

`panBy` adds screen-pixel deltas to `tx`,`ty` — the drag path and the arrow-key
path share it (FR-005, FR-013). The caller clamps.

`centreOn` returns the view that puts world point `(wx, wy)` at the centre of a
`vw × vh` viewport, optionally at a different rung:

```
k  = scaleFor(idx == null ? view.idx : idx)
tx = vw/2 - wx · k
ty = vh/2 - wy · k
```

This is the arithmetic behind the page-level API FR-042 exposes for `map-roster`;
the animation and the `prefers-reduced-motion` behaviour are the page's
(see [page-camera.md §6](./page-camera.md)). It is also what the resize path uses
in reverse: read the centre world point from the old `{tx, ty, vw, vh}`, then
`centreOn` it in the new one (FR-010).

---

## 8. `levelFor(idx, prev) → "far" | "mid" | "near"`

The hysteretic detail level, pure in its two arguments. Thresholds and the full
table are in [data-model.md §3](../data-model.md):

- rise into `mid` at `idx ≥ 3`, into `near` at `idx ≥ 5`;
- fall out of `mid` below `idx 2`, out of `near` below `idx 4`;
- `prev == null` uses the cold mapping, which resolves both bands downward —
  which is what makes FR-041 hold on a restore.

Guarantees:

- **FR-026**: `levelFor(3, "far") === "mid"` and `levelFor(2, "mid") === "mid"`,
  so stepping in and back out does not flip the level twice.
- **SC-003**: calling `levelFor(idx, prev)` repeatedly with the same `idx`
  returns `prev` unchanged — a tick at a boundary changes nothing, and the page
  makes that structural by calling it only from the camera path.
- Never returns anything but the three names, for any integer input.

---

## 9. `wheelStep(acc, event) → { acc, step }`

Accumulates one wheel event and reports whether a rung was crossed. `event` is
read for `deltaY` and `deltaMode` only; nothing else, and no DOM method is
called on it.

- `deltaMode 0` (pixels) counts as given; `1` (lines) × 16; `2` (pages) × the
  `pageHeight` the caller passes.
- A sign change resets the accumulator before adding, so reversing a gesture
  responds immediately rather than having to unwind.
- `|acc| ≥ WHEEL_THRESHOLD` returns `step = -1` (zoom in, on the negative-delta
  convention) or `+1`, and `acc = 0`.
- Otherwise `step = 0` and the accumulated value is returned.

Guarantees FR-006: a single one-pixel event returns `step = 0` and cannot change
the scale; a stream of 20 five-pixel deltas takes exactly one step.

---

## 10. `validateView(raw, ladderLength) → Viewport | null` and the storage pair

```js
CCWATCH_CAMERA.loadView(getItem)          // getItem() → string | null, may throw
CCWATCH_CAMERA.saveView(setItem, view)    // setItem(string), may throw
CCWATCH_CAMERA.persistence                // "ok" | "unavailable"  (getter)
```

`validateView` implements the rejection table in
[data-model.md §6](../data-model.md) and returns `null` for every invalid shape —
absent, unparseable, wrong `v`, non-integer or out-of-range `idx`, non-finite
`tx`/`ty` (FR-037). It never throws for any input, including `undefined`, a
number, an array, and a string of a megabyte.

`loadView` calls `getItem` inside a `try`, passes the result through
`validateView`, and returns `null` on either failure. `saveView` serialises
`{v: STORAGE_VERSION, idx, tx, ty}` and calls `setItem` inside a `try`.

The **first** throw from either flips `persistence` to `"unavailable"` and it is
never reset and never retried in a loop (FR-040) — the same mechanism
`plots.js` already has, so the page has one idiom for "storage stopped working".
The page reads `persistence` to decide whether to state that the viewport will
not be remembered.

`validateView` deliberately does **not** know about the extent: the intersection
test (FR-038) needs the placed plots, which belong to `plots.js`'s return value,
so the page performs it (see [page-camera.md §5](./page-camera.md)) using
`visibleWorldRect` below.

---

## 11. `visibleWorldRect(view, vw, vh) → {x, y, w, h}` and `intersects(a, b) → boolean`

`visibleWorldRect` is `{x: -tx/k, y: -ty/k, w: vw/k, h: vh/k}`.
`intersects` is a plain half-open box overlap, `false` on any non-finite input.
Together they are the FR-038 test, and they are pure so the suite can assert the
"stored viewport far outside the world" case without a browser.

---

## 12. Exports, and what the suite asserts

```js
CCWATCH_CAMERA = {
  LADDER, WHEEL_THRESHOLD, PAN_STEP, PAN_STEP_BIG, DRAG_SLOP, STORAGE_VERSION,
  scaleFor, clampIdx, clampPan, fitIndex, fitView, zoomTo, panBy, centreOn,
  levelFor, wheelStep, validateView, loadView, saveView, visibleWorldRect,
  intersects,
  get persistence() { … },
}
```

The `camera` section of `tests/run.sh` runs this file under `node` in the same
harness shape as the `plots` section (`tests/run.sh:1722-1942`): a generated
`camera-check.js`, one `PASS|name|detail` line per check, `t_skip` with the
reason when `node` is absent (FR-055, and `node` stays optional). Each check is
mutation-tested and carries a row in the `README.md` mutation table (FR-056).

Every assertion is a claim about numbers from inputs alone — no browser, no
server, no fabricated `~/.claude` needed for this section. The claims that *do*
need a page or a server (the served pages' static guards) live in the existing
`serve` section, and the claims that need a human live in
[quickstart.md](../quickstart.md).
