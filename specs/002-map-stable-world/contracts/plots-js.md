# Contract — `web/plots.js`, the identity→coordinate module

**Feature**: `002-map-stable-world` | **Loaded by**: `web/map.html` via `<script src="/plots.js">` | **Tested by**: `tests/run.sh`, `plots` section, under `node`

A second static file for the same reason `web/md.js` is one: so the suite can
run it under `node` and assert on its output. `CLAUDE.md` states that reason for
`md.js`; this is the same trade. It is served by the static fallback in `serve`
and needs no route of its own (FR-055).

**Pure.** No DOM, no `fetch`, no timers, no globals other than its own export.
Storage is reached only through the two functions in §4, which the caller may
substitute — that is how the suite exercises persistence without a browser.

Exported as `window.CCWATCH_PLOTS`, with a `module.exports` tail for `node`.

---

## 1. Constants — the world-unit budget

Whole world units (FR-005), so a change of art direction is a change of drawing
and not of layout.

```js
CCWATCH_PLOTS.UNITS = {
  figure:   { w:  8, h: 14, pitchX: 12, pitchY: 18, cols: 3, cap: 3 },
  zone:     { w: 42, h: 28, pitchX: 46, pitchY: 32, cols: 1, cap: 2 },
  building: { w: 54, h: 78, pitchX: 60, pitchY: 84, cols: 3, cap: 6 },
  district: { w:192, h:192, pitchX:204, pitchY:204, cols: 4, cap: 8 },
}
```

`cols` is fixed forever: `slot → (slot % cols, floor(slot / cols))`. `cap` is
the number of slots a parent offers before an identity claims an annex plot.
The district `cap` doubles when a new district cannot be placed; every other
`cap` is fixed and overflows to an annex (see [research.md](../research.md) D2).

---

## 2. `assign(level, key, opts) → slot`

```js
assign("district", "d|acme", { seen: 1757280000 }) // → 3
```

| Guarantee | Requirement |
|---|---|
| **A1** Same key, same slot, every call, for the life of the map instance | FR-006 |
| **A2** A key present in storage returns its stored slot without hashing | FR-009, FR-011 |
| **A3** Assigning a new key never changes any existing key's slot | FR-010, SC-003 |
| **A4** A collision resolves by probing with a step derived from the *key*, not from call order | FR-012 |
| **A5** No argument other than `level`, `key` and the parent scope can influence the result. `opts` carries `seen` and nothing else | FR-007 |
| **A6** An annex key (`<key>#2`) is itself assigned by A1–A5, so it persists too | FR-006 |

`key` is the scoped key from [data-model.md](../data-model.md) §2. `level`
selects the raster from `UNITS`.

---

## 3. `place(model) → { world, extent, sig }`

Takes the district/building/zone/figure tree built from the payload and returns
every coordinate plus the fitted extent.

```js
const { world, extent, sig } = CCWATCH_PLOTS.place(tree)
world.figures["f|acme/checkout-api|main|aaaa…"] // → { x, y, cx, cy, w, h }
```

| Guarantee | Requirement |
|---|---|
| **P1** Every returned coordinate is an integer in world units | FR-005 |
| **P2** Two calls with trees that differ only in `sev`, `psev`, `token`, `quiet`, `waited`, `context`, `rss_mb`, `cost`, `age`, `pipeline`, `deploys` or row order return **identical** coordinates | FR-007, FR-008, SC-001 |
| **P3** `extent` is the bounding box of plots with a current occupant, grown by one district gutter, clamped to a minimum of `408 × 408` units | FR-038, FR-039 |
| **P4** A remembered assignment with no occupant in this tree contributes nothing to `extent` | FR-039, spec Edge Cases |
| **P5** `sig` is a stable string over the occupied plot set, so the caller can refit only when it changes | FR-019 |
| **P6** `cx`/`cy` are the figure centres the wires are drawn between, in the same world units | FR-021 |
| **P7** A `no repo` building is placed in the reserved `no repo` district and never in an org's district | FR-004, Constitution VI |

## 3b. `fit(extent, vw, vh) → { k, tx, ty }`

| Guarantee | Requirement |
|---|---|
| **F1** `k = min(vw / W, vh / H)`, uniform, aspect ratio preserved | spec Assumptions |
| **F2** `k` is clamped to a maximum of `3.0`, so one figure is not blown up to fill a large screen | spec Assumptions, FR-040 |
| **F3** The extent is centred in the available area | SC-011 |
| **F4** `fit` reads only its three arguments — it holds no state and does not touch storage | FR-019 |

The transform the caller writes onto the camera group is
`translate(tx ty) scale(k)`.

---

## 4. Persistence — `load(get)` and `save(set, liveKeys)`

The two storage calls are injected so the suite can drive them without a
browser, and so a throwing storage cannot take the map down.

```js
CCWATCH_PLOTS.load(() => localStorage.getItem(KEY))
CCWATCH_PLOTS.save(v => localStorage.setItem(KEY, v), liveKeys)
CCWATCH_PLOTS.persistence   // "ok" | "unavailable"
```

| Guarantee | Requirement |
|---|---|
| **S1** `load` of a payload whose `v !== 1` discards it wholly and starts empty | spec Edge Cases |
| **S2** `load` or `save` throwing sets `persistence = "unavailable"` and is not retried on every frame; assignment continues from memory and stays self-consistent for the session | FR-014 |
| **S3** `save` caps `entries` at **512**, discarding longest-unseen (`seen` ascending) first | FR-013 |
| **S4** `save` never discards a key in `liveKeys`, even if it is the longest-unseen | FR-013 |
| **S5** `save` writes `slot` unchanged for every key already stored | FR-010, FR-011, SC-002 |

`persistence === "unavailable"` is what the page turns into the FR-014 sentence.

---

## 5. Mutation checks this contract makes possible

Each row is an assertion in the new `plots` section of `tests/run.sh`, and each
gets a row in the README mutation table (FR-059).

| Mutation | Assertion that must fail |
|---|---|
| let `assign` re-hash a key that is already in storage | A2 — the reload case (SC-002) |
| make the probe step a call counter instead of `h2(key)` | A4 (FR-012) |
| let `place` read `sev` when ordering buildings within a district | P2 (FR-008, SC-001) |
| include remembered-but-empty plots in the extent | P4 (FR-039) |
| drop the `liveKeys` guard from eviction | S4 (FR-013) |
| remove the version check from `load` | S1 |
| drop the max-scale clamp from `fit` | F2 |

Where `node` is absent the whole section skips with the reason stated, as the
`markdown` section already does (FR-061, Constitution's test discipline).
