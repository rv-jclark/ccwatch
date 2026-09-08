# Phase 1 — Data Model

**Feature**: `003-map-camera-lod` | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)

Nothing in this feature changes the payload. `/api/state` gains no field, loses
none, and no collector computes anything new (FR-053); `specs/002-map-stable-world/contracts/api-state.md`
remains the operative description of the snapshot. Every entity below is either
in-page state or the one new persisted record.

The fields the camera reads are listed in §6 for the same reason
`002-map-stable-world` listed them: so a later change to a collector can tell at
a glance whether it moved something the map depends on.

---

## 1. `Viewport` — the camera's whole state

Three numbers. There is no fourth: scale is `LADDER[idx]`, and the detail level
is a function of `idx` (§3).

| Field | Type | Meaning | Invariant |
|---|---|---|---|
| `idx` | integer | index into `LADDER` (§2) | `0 ≤ idx < LADDER.length`; never fractional |
| `tx` | number | horizontal translation, **screen pixels** | finite; within the clamp interval of §4 |
| `ty` | number | vertical translation, screen pixels | finite; within the clamp interval of §4 |

Realised in the DOM as exactly one attribute:

```
<g id="camera" transform="translate(TX TY) scale(K)">
```

`K = LADDER[idx]`. Because `#world`'s `viewBox` is fixed to the element's own
client size (`web/map.html:1237-1245`, unchanged), one world unit is one screen
pixel at `idx = 2`, and a world point `w` maps to the screen at `w · K + T`.

**Transitions.** Every one of them produces a whole new `Viewport`, which is then
clamped (§4) and applied by the single writer:

| Cause | Change | Requirement |
|---|---|---|
| drag `pointermove` | `tx`,`ty` += pointer delta | FR-005 |
| wheel / pinch past the accumulator threshold | `idx` ±1, anchored at the pointer | FR-003, FR-006 |
| `+` / `-` / a zoom button | `idx` ±1, anchored at the viewport centre | FR-004, FR-014 |
| arrow key | `tx` or `ty` ± 120 (`Shift`: 480) | FR-013 |
| `0` / the fit button | `fitIndex()` and the centring `tx`,`ty` | FR-012, FR-014, FR-039 |
| resize | `idx` unchanged; `tx`,`ty` re-solved to hold the centre world point | FR-010 |
| tick whose `placed.sig` changed | unchanged, then re-clamped to the new extent | FR-011 |
| `centreOn(wx, wy, …)` | `tx`,`ty` (and optionally `idx`) to put `(wx,wy)` at the centre | FR-042 |
| load with a valid stored record | that record | FR-035 |
| load with no or an invalid record | `fitIndex()` | FR-036, FR-037, FR-038 |

**Not a cause of a change**: a data tick that did not change the occupied set, a
severity change, a new session, a session exiting, a level-of-detail change, the
tab being hidden or shown, the inspector opening or closing (FR-011, FR-044,
FR-046).

---

## 2. `Ladder` — the only reachable scales

```js
CCWATCH_CAMERA.LADDER = [1/4, 1/2, 1, 2, 3, 4, 6, 8];   // index 0 … 7
```

A frozen module constant (D2). Independent of viewport size and world extent
(FR-002). Every entry is a whole number or the reciprocal of one, which is what
lets a future sprite atlas map to whole pixels. `idx` is clamped to
`[0, 7]` (FR-009); a step past either end is a no-op and leaves the
corresponding control present and disabled (FR-017).

---

## 3. `DetailLevel` — `far` | `mid` | `near`

A named function of `idx` with one rung of hysteresis at each boundary (D7).
`levelFor(idx, prev) → "far" | "mid" | "near"`.

| `idx` | `k` | `prev = far` | `prev = mid` | `prev = near` | cold (`prev = null`) |
|---|---|---|---|---|---|
| 0 | ¼ | far | far | far | far |
| 1 | ½ | far | far | far | far |
| 2 | 1 | far | mid | mid | **far** |
| 3 | 2 | mid | mid | mid | mid |
| 4 | 3 | mid | mid | near | mid |
| 5 | 4 | near | near | near | near |
| 6 | 6 | near | near | near | near |
| 7 | 8 | near | near | near | near |

Rising thresholds: mid at `idx ≥ 3`, near at `idx ≥ 5`. Falling: out of mid
below `idx 2`, out of near below `idx 4`. The two direction-dependent bands are
`idx 2` and `idx 4`.

**What each level draws.** The level changes what is rendered and never a
coordinate (FR-025): a district, building, zone or figure occupies the same
world position at all three.

| Drawn | far | mid | near |
|---|---|---|---|
| district outline | ✓ | ✓ | ✓ |
| district **name** (`.dlabel`) | — | ✓ | ✓ |
| district **summary** (`.dsummary`, §5) | ✓ | — | — |
| building outline and label | — | ✓ | ✓ |
| branch zone outline and label | — | ✓ | ✓ |
| per-building `no repo` / pipeline / deploy badges | — | ✓ | ✓ |
| figure art | — | ✓ | ✓ |
| figure name and activity (`.alabel`) | — | — | ✓ |
| peer wires, arrowheads, count bubbles | ✓ | ✓ | ✓ |

Realised as one attribute, `data-lod`, on `#world`, with stylesheet rules keyed
off it (D3). Every node listed above exists in the DOM at every level; the level
decides which are rendered. Wires are drawn at all three because FR-031–FR-034
require them legible across the whole range and say nothing about hiding them.

**Written only by the camera.** `levelFor` is called from `applyView()` alone, so
a data tick cannot change the level (FR-026, FR-030).

---

## 4. `OccupiedExtent` and the clamp interval

`OccupiedExtent` is unchanged and is not ours: `place()` returns it
(`web/plots.js:285-297`) as `{x, y, w, h}` in world units, the bounding box of
every placed plot padded by one district gutter and floored at
`MIN_EXTENT = 408`. The camera reads it and never writes it (FR-048).

Given `k = LADDER[idx]`, a viewport of `vw × vh` CSS pixels and extent `E`, the
permitted translations are the closed intervals (D5):

```
tx ∈ [ min(a, b), max(a, b) ]      a = -E.x · k,   b = vw - (E.x + E.w) · k
ty ∈ [ min(c, d), max(c, d) ]      c = -E.y · k,   d = vh - (E.y + E.h) · k
```

`E.w · k > vw` gives `b < a` and holds the visible rectangle inside the extent;
`E.w · k < vw` gives `a < b` and holds the world inside the viewport. One
formula, both clauses of FR-008, no branch.

**Visible world rectangle** — used by the intersection test in §5 and by nothing
else: `{ x: -tx/k, y: -ty/k, w: vw/k, h: vh/k }`.

---

## 5. `DistrictSummary` — the far-level aggregate

Computed once per tick on the data path, in `buildWorldModel`
(`web/map.html:386-448`), and attached to the existing `districtsByKey[k]` meta
object. Never computed on a camera move (FR-044).

| Field | Type | Source | Rule |
|---|---|---|---|
| `n` | integer | count of session rows placed in the district | the length of a list the page already builds |
| `worst` | string | the `token` of the row with the greatest `[sev, psev]` pair | selection by the CLI's own ordering key (`bin/ccwatch:920`), printed verbatim |
| `unfinished` | string \| null | `${u.phase}/${u.status}`, or `${u.phase}/CRASHED` when `u.crashed`, of one unfinished run in the district, with `+N` appended when there is more than one | the existing per-building badge text (`web/map.html:566`), unchanged |

Rendered at far as `<org> · <n> sessions · <worst>` with ` · <unfinished>`
appended when present.

**Constraints this encodes.**

- The view **selects a maximum** over values the payload supplied and prints the
  selected row's own status word. It does not derive, rank or invent a status,
  severity or verdict, and it introduces no word, badge or colour the payload did
  not carry (FR-027, Constitution V and XI).
- The count sits beside the word, so the aggregate carries its measurement
  (FR-028, Constitution II).
- `unfinished` exists because FR-022 stops drawing that building's badge at far
  and FR-029 forbids a claim disappearing: the fact is carried by the aggregate
  that replaced it (Constitution IV).
- Nothing here is volatile in the sense of Constitution III: no context
  percentage, no memory figure, no cost. Those stay withheld under `VOLATILE`
  exactly as they are today (FR-050), and none of them is eligible to appear in a
  summary.
- `n = 0` cannot occur — a district exists because something was placed in it —
  but a district may hold unfinished runs and no live session, in which case `n`
  is the number of live rows (zero is printed as `0 sessions`) and `unfinished`
  carries the reason the district is on the map at all.

---

## 6. `StoredViewport` — the one new persisted record

**Key**: `localStorage["ccwatch.map.view.v1"]`, per origin, one record, global to
the map. Separate from `ccwatch.map.plots.v1` (FR-035), which keeps its own
version, its own 512-entry bound and its own LRU eviction.

```json
{ "v": 1, "idx": 4, "tx": -312.5, "ty": -88 }
```

Under 60 bytes. Written through an injected setter, coalesced: `applyView()`
stages the record and the `setItem` happens on `pointerup`, on key or button
release, and on `visibilitychange` — never on a `pointermove` (D9).

**`validateView(raw, ladderLength) → Viewport | null`.** Returns `null`, and the
caller fits (FR-037), when any of:

| Rejected because | Example |
|---|---|
| absent | first load in this browser (FR-036) |
| not parseable JSON | a truncated write, a hand-edited value |
| not an object, or an array | `"7"`, `[]` |
| `v !== 1` | a record written by a future ladder or shape |
| `idx` missing, non-integer, or outside `[0, ladderLength)` | `2.5`, `-1`, `99`, `"4"` |
| `tx` or `ty` missing or non-finite | `NaN`, `Infinity`, `null`, `"0"` |

A record that validates is then, in order: clamped to the live extent (§4), and
tested for intersection — if its visible world rectangle (§4) intersects none of
`placed.world.districts`, `.buildings`, `.zones` or `.figures`, it is discarded
for a fit (FR-038). Intersecting a gutter inside the extent but no plot counts
as no intersection, which is the spec's own definition.

Nothing throws on any path. A `getItem` or `setItem` that throws — private mode,
a full origin quota — is caught, flips a module-level
`persistence = "unavailable"` **once**, and is never retried (FR-040); the page
reads that flag and states in `#camnote` that the viewport will not be
remembered. This is the mechanism `plots.js` already uses
(`web/map.html:1172-1194`), reused rather than reinvented.

---

## 7. Page state that is not persisted

| Name | Shape | Reset by | Why it exists |
|---|---|---|---|
| `view` | `Viewport` (§1) | never; always replaced whole | the single source of the transform |
| `level` | `DetailLevel` (§3) | never; recomputed from `levelFor(idx, level)` | the `prev` argument the hysteresis needs |
| `worldExtent` | `OccupiedExtent` (§4) | each tick whose `placed.sig` changed | the clamp's bound; replaces today's `lastFit.extent` |
| `drag` | `{active, startX, startY, startTx, startTy, moved}` | `pointerup`/`pointercancel`/`lostpointercapture` | one-to-one panning and the 4-pixel click/drag distinction (FR-005) |
| `wheelAcc` | number | on each step taken, and on a sign change | the accumulation threshold (FR-006) |
| `pendingSave` | `StoredViewport` \| null | on flush | coalescing the `setItem` (§6) |
| `overflow` | boolean | each fit | the conditional "does not fit" sentence (FR-012) |

`lastRows`, `VOLATILE`, `trust`, the reconciliation indices and the plot store
are all untouched.

---

## 8. The payload fields the camera and the aggregate read

Read-only, and listed so a collector change can be checked against them. All of
them already exist.

| Field | Read by | For |
|---|---|---|
| `sessions[].sev`, `sessions[].psev` | `DistrictSummary.worst` | selecting the worst row by the CLI's own key |
| `sessions[].token` | `DistrictSummary.worst` | the status word, printed verbatim |
| `unfinished[].phase`, `.status`, `.crashed`, `.repo`, `.project` | `DistrictSummary.unfinished` | the badge text FR-029 requires the aggregate to carry |

Everything else the camera needs — the extent, the placed boxes, the figure
centres — comes from `place()`'s return value, which is derived from identity
alone and is not a payload field.

**Explicitly not read by anything on the camera path**: `quiet`, `waited`,
`context`, `rss_mb`, `cost`, `age`, `deploys`, `pipeline`, row order. The camera
must not depend on a volatile reading for the same reason a coordinate must not
(`web/plots.js:12-14`, Constitution XIII).
