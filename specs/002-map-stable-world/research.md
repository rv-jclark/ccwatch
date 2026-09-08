# Phase 0 — Research: identity-derived world layout, incremental rendering, four failure states

**Feature**: `002-map-stable-world` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

Every decision below was taken against the code as it stands on 2026-09-08 and
names what was rejected. The spec's Assumptions section had already fixed the
open *values* (hash-then-probe, persisted assignment wins, browser local
storage, `no repo` as one district, fit-with-a-floor); what remained open was
*mechanism*, and that is what this document settles.

There are no **NEEDS CLARIFICATION** markers left in the Technical Context.

---

## D1. The drawing surface is one inline SVG with an explicit camera group

**Decision**: replace the `#map` CSS grid (`web/map.html:46`) with a single
inline `<svg id="world">` containing one `<g id="camera">`. Everything the map
draws — districts, buildings, zones, figures **and the peer wires** — is a child
of that group, in world units. The camera group carries a
`transform="translate(tx ty) scale(k)"` computed in JS.

**Rationale**:

- FR-021 requires wires computed from world coordinates rather than measured
  screen geometry. Sharing one coordinate space with the figures is what makes
  that true by construction: today `wires()` (`web/map.html:385-432`) calls
  `getBoundingClientRect()` on every `.agent` and on `#wrap`, which is why it
  has to be re-run after every rebuild and could not survive a transform.
- Constitution VII and FR-046 require a textual equivalent of every claim the
  view draws. SVG elements are real DOM nodes: they take `<title>`, they take
  `tabindex`, they hit-test for the existing click delegation
  (`web/map.html:667-672`), and their text is selectable. FR-017/FR-018 need
  exactly that.
- FR-051 requires the sprite seam. `image-rendering: pixelated` on an SVG
  `<image>` is the one-line swap; the primitive's own `<rect class="hit">`
  keeps hit testing independent of the art.
- FR-005 (whole world units) falls out for free: authored coordinates are
  integers in the `viewBox` space and the camera does the scaling.

**Alternatives rejected**:

- **`<canvas>`**: no DOM nodes, so no hit testing without a second geometry
  model, no `<title>`, no focus, no text selection, no screen reader. It fails
  FR-017, FR-018, FR-046 and Constitution VII at once, and it would force an
  animation-frame loop, which FR-049 and the existing assertion at
  `tests/run.sh:740` both forbid.
- **HTML `<div>`s at absolute positions**: workable for the figures, but the
  wires then have to be an overlay in a second coordinate space — the exact
  arrangement that FR-021 exists to remove — or an SVG sized to the same world,
  which is just this decision with an extra tree.
- **`viewBox` alone, no camera group** (`preserveAspectRatio="xMidYMid meet"`
  does the uniform fit): fewer lines, but the scale clamp of D5 has to be
  expressed as an extent fudge rather than as a scale, and the next roadmap
  entry (`map-camera-lod`) has to introduce the group anyway. FR-001 asks for
  "one camera group" in as many words.

---

## D2. Plots come from a per-parent raster: fixed columns, hash-then-probe, capacity overflow into an annex plot

**Decision**: four nested address spaces, each a raster with a **fixed column
count and a fixed row pitch**, so a slot index maps to a coordinate by pure
arithmetic that never changes:

| Level | Parent | Columns | Capacity | Key hashed |
|---|---|---|---|---|
| district | the world | 4 | 8, doubling | `org` (or the literal `no repo`) |
| building | a district plot | 3 | 6 | `owner/name` slug, or `dir:<cwd>` |
| zone | a building plot | 1 | 2 | branch name (or the literal `?`) |
| figure | a zone slot | 3 | 3 | session id |

Placement of a *new* identity: `i = h1(key) mod C`; while slot `i` is taken,
`i = (i + h2(key)) mod C` with `h2` forced odd and coprime to `C` (both powers
of two), for at most `C` steps. A **persisted assignment always wins and is
never recomputed** — that is the single fact that makes FR-010 and FR-011 hold.

When every slot of a parent is occupied, the identity claims an **annex plot**:
the same level, keyed `<key>#2`, `<key>#3`, … placed by the same rule in the
grandparent's space and labelled with the same name. Nothing already placed
moves.

The district capacity `C` starts at 8 and doubles when a new district cannot be
placed. Doubling is safe precisely because existing districts are read back
from storage rather than re-derived, so changing the modulus cannot move them.
`i → (i mod 4, floor(i / 4))` means growth adds rows of four and the world
grows downward.

**Rationale**:

- The spec already chose hash-then-probe and already accepted its consequence
  ("with colliding identities the resulting city depends on which was placed
  first"). FR-012 is met because the probe *step* comes from the identity, not
  from the payload's row order.
- Fixed columns and a fixed pitch are what make SC-003 checkable arithmetic
  rather than a claim: a new building's coordinate is a function of its own
  slot index only.
- A capacity per parent is what keeps the world **compact**, and compactness is
  what makes FR-040 achievable — see D5 for the measured scale. A large sparse
  address space would be equally stable and illegible.
- 8 districts × 6 buildings × 2 zones × 3 figures = 288 figure slots, against
  FR-040's stated target of 8 districts and 25 sessions.

**Alternatives rejected**:

- **One global building lattice with org-seeded clustering, districts drawn as
  hulls around their members.** No capacity ceiling and no annexes, but a
  district's drawn boundary then grows into its neighbours as buildings appear,
  and a district's coordinate stops being well defined — SC-001 asks for a
  district's coordinate to be identical between frames.
- **A district box sized to the buildings it currently holds.** The natural
  thing to want, and it moves every district below it the first time an org
  gains a repository. Direct FR-010 / SC-003 violation.
- **Sequential assignment in first-seen order** (lowest free slot). Maximally
  compact and perfectly stable once persisted, but the first placement is then a
  function of arrival order, which FR-006 forbids in as many words.
- **Growing the row pitch to the tallest district.** Keeps one box per district
  and no annexes, at the cost of moving every district whenever any district
  grows. Same violation as above.

---

## D3. Storage is `localStorage`, versioned, bounded at 512 entries, LRU by last-seen

**Decision**: one key, `ccwatch.map.plots.v1`, holding
`{v: 1, entries: {<scope>|<key>: {slot, seen}}}` where `seen` is an epoch
second. On load, a payload whose `v` is not `1` is discarded wholesale rather
than migrated. On save, if the entry count exceeds **512**, drop the
longest-unseen entries first, skipping any identity drawn in the current frame.
Every write is inside `try/catch`; the first failure flips an in-memory flag
that the page renders as a sentence (FR-014) and does not retry-spam.

**Rationale**:

- The spec fixed the medium ("the browser's own local storage, keyed per
  origin"). Nothing new is written to disk and `~/.claude/ccwatch/` is
  untouched.
- 512 entries at ~40 bytes each is ~20KB, two orders below the 5MB per-origin
  budget, so eviction is a correctness guard for FR-013 rather than a space
  guard.
- FR-013's "never an entry that is currently drawn" is why eviction takes the
  live key set as an argument instead of reading it from a global.
- FR-014 is Constitution IV applied to the page's own storage: a layout that
  silently stops persisting is exactly the "did it move or do I misremember"
  failure this entry exists to prevent, so the loss is stated.

**Alternatives rejected**:

- **`sessionStorage`**: dies with the tab, which is FR-009's whole point.
- **Server-side persistence under `~/.claude/ccwatch/`**: adds a write path, a
  file format and a route, for a preference that is per-browser by nature.
- **Migrating an older format**: there is no older format to migrate. Writing a
  migration for a hypothetical one is code no fixture can exercise.

---

## D4. Reconciliation is keyed by identity, one primitive per level, and nothing is replaced wholesale

**Decision**: one `reconcile(parentEl, wanted, key, make, update)` helper drives
every level. `wanted` is a map from identity key to model object; `make(key)`
creates the `<g>` and stashes it in a per-level index; `update(el, model)`
writes attributes and text. Elements whose key is absent from `wanted` are
removed. Three interchangeable primitives — `drawDistrict`, `drawBuilding`,
`drawFigure` — own **all** the art and nothing else (FR-050), each rendering
into a `<g>` whose transform is set by the layout, with a `<rect class="hit">`
for hit testing and a `<title>` for the text equivalent.

The same rule applies **outside** the world, because FR-016 says "no code
reached by a refresh": `#counts`, `#gauges`, `#foot`, `#hostwarn`, `#ask`,
`#killbar` and the inspector's `#convo` all lose their `innerHTML =`
assignments. `#legend` is built once at load and never touched again, which
also satisfies FR-020 for the commonest case.

`#convo` turns are keyed on `at|kind|<n>` where `at` is the turn's
`.timestamp` (present in the payload — `bin/ccwatch:1468`) and `<n>`
disambiguates the rare same-instant duplicate. A turn's **body** keeps its
single `innerHTML` write from `CCWATCH_MD.render(...)`, because that is the
escape-first-then-tag path Constitution X requires and `web/md.js` returns a
string; the container is reconciled, the body is not.

**Rationale**:

- FR-015 asks for create/update/remove keyed on the FR-006 identities. One
  helper means one place where that is true, rather than four hand-rolled loops
  that will diverge.
- FR-020 / SC-004 ("an unchanged payload creates and destroys zero elements")
  is a property of the helper, not of each call site.
- FR-017's "ask panel, conversation, send box and kill bar intact and its
  content updated in place" is only satisfiable if `renderConvo`
  (`web/map.html:502-519`) stops assigning `box.innerHTML`. The existing
  scroll-position preservation at `web/map.html:511` becomes unnecessary rather
  than merely careful.

**Alternatives rejected**:

- **A tiny virtual DOM / diffing layer**: more code than the four keyed lists
  it would serve, and FR-054 forbids a dependency.
- **`innerHTML` plus save/restore of selection, hover and scroll**: this is what
  `web/map.html:511` already does for scroll alone, and it cannot restore focus
  ring state, a partial text selection across nodes, or a `:hover` that the
  pointer is no longer moving over. FR-018 asks for survival, not restoration.
- **Reconciling only the world and leaving the header/footer on `innerHTML`**:
  cheaper, and it fails FR-016 literally. It would also keep a real bug: a
  selection made in the footer's edge-count sentence dies every 3 seconds.

---

## D5. Fitting: bbox of occupied plots, one gutter of padding, min extent 2×2 district plots, max scale 3.0

**Decision**: the extent is the bounding box of the plots that have a **current
occupant** (FR-039), grown by one district gutter, then clamped to a minimum of
`408 × 408` world units. `k = min(vw / W, vh / H)`, clamped to a maximum of
`3.0`. The transform centres the extent in the available area. Recomputed only
when the occupied-plot signature changes or on `resize` (FR-019, FR-038).

The world-unit budget, chosen so the arithmetic below lands:

```
figure       8 w × 14 h     slot pitch 12 × 18
zone        42 w × 28 h     slot pitch 46 × 32   (3 figure slots in one row)
building    54 w × 78 h     slot pitch 60 × 84   (2 zone slots stacked, 10 for the name band)
district   192 w × 192 h    slot pitch 204 × 204 (3 × 2 building slots, 12 for the label band)
```

Measured consequence at FR-040's stated target — 8 districts on a 1280×800
viewport, of which the world area is about 1280 × 690 after the header, legend
and footer:

| Quantity | World units | On screen at k = 1.57 |
|---|---|---|
| occupied extent (8 districts, 4 × 2 plots) | 816 × 408 | fits, height-bound |
| figure height | 14 | **22.0 px** (body text is 13 px) |
| figure width / gap between figures | 8 / 4 | 12.6 px / 6.3 px |
| building width | 54 | 84.7 px |
| building name at font-size 8 | 8 | 12.5 px |

A twelve-district world (three rows) drops `k` to 1.13 and the figure to
15.8 px, still above body text. A single district unclamped would reach k = 3.38
on this viewport and k = 10 on a 3840×2160 screen — a 140 px figure — which is
what the 3.0 clamp exists to stop.

**Rationale**: FR-038 asks for the occupied extent; FR-039 excludes remembered
empties; FR-040 sets a legibility floor and the spec's Assumptions set a scale
ceiling ("a floor on scale so a single figure is not blown up"). Clamping the
*extent* from below and the *scale* from above expresses both without either
one being able to violate the other. Where the two genuinely conflict — a city
too large to fit legibly — fitting wins, per the spec, and `map-camera-lod` is
the entry that resolves it.

**Alternatives rejected**:

- **Fit the whole lattice rather than the occupied bbox.** Stable under
  occupancy change, so no refit is ever needed — and it wastes three quarters of
  the screen the moment the district capacity doubles, and FR-039 forbids
  counting remembered empties.
- **A lower clamp on scale (never shrink below legible).** Rejected by the
  spec's own Assumptions: it would mean the world overflows the viewport with
  no way to reach the rest, since FR-041 forbids panning in this entry.

---

## D6. `PARSE_FAILED` propagates by changing what `collect_sessions` returns, and the footer reads the snapshot

**Decision**:

1. `collect_sessions` prints an **object** — `{"rows": [...], "parse_failed": N}`
   — instead of a bare array. Its slow path stops being a pipeline: the per-file
   loop accumulates rows into a shell variable in the function's own shell, so
   the increment survives.
2. `snapshot()` splits that object and adds a top-level `parse_failed` to the
   snapshot JSON.
3. The terminal footer stops taking `--argjson pf "$PARSE_FAILED"`
   (`bin/ccwatch:1130`) and reads `.parse_failed` from the snapshot it is
   already given.
4. `cmd_doctor` (`bin/ccwatch:3086-3087`) reads the field from the object it
   already collects.
5. `serve` needs **no change at all**: it shells out to `ccwatch --json`
   (`bin/ccwatch:3034`) and `build_canonical` copies the snapshot's keys
   wholesale (`body = dict(snap)`, `bin/ccwatch:2800`), so `parse_failed`
   reaches `/api/state` and enters the ETag hash automatically — which is the
   spec's assumption that the count "participates in the feed's change
   validator like any other collected number".

**Rationale — why the current code cannot work at all**: `PARSE_FAILED` is
incremented inside `{ for f in …; done; } | jq -s '.'`, and a pipeline stage is
a subshell. Even with that fixed, every caller reads it across a *second*
subshell: `sessions=$(collect_sessions)` at `bin/ccwatch:618` and `:3086`, and
`once) render "$(snapshot)"` at `bin/ccwatch:3322`. So the footer's `$pf` is
structurally always `0`, which matches the spec's verification: a fabricated
registry with one malformed file yields nothing in the footer, nothing in
`--json`, nothing in `doctor`. Returning the count *with the data it describes*
removes both subshell boundaries at once, and making the footer read the
snapshot gives FR-034's "same number everywhere" one source instead of four
agreeing by convention.

**Alternatives rejected**:

- **A side-channel file** (`$TMPDIR/ccwatch-parsefail-$$`). Survives the
  subshells, and introduces a stale-read window, a cleanup obligation and a
  collision between two concurrent `ccwatch` processes — for a number whose
  whole purpose is to be trustworthy.
- **Inferring the count as `n - length(rows)`.** Already rejected in the code's
  own comment (`bin/ccwatch:210-213`): it is wrong for a pretty-printed file,
  which the fast path splits across lines and drops entirely.
- **Leaving `--json` alone and computing the count in `serve`.** Two code paths
  for one number, which is Constitution XI.

---

## D7. Trust is a state plus an independent count, not a four-way enum

**Decision**: the page holds `trust ∈ {ok, feed_down, warming}` and, separately,
`unreadable = payload.parse_failed`. The four FR-026 renderings are:

| Condition | Determined by | Wording carrier |
|---|---|---|
| (a) feed could not be read | the `fetch` threw, or `res.ok` is false, or `snapshot_ok === false` | `#trust` banner: the feed is down, the reason, and the age of the data still shown |
| (b) no snapshot yet | `warming === true` | `#trust` banner: a first snapshot is still being taken |
| (c) rows would not parse | `parse_failed > 0` | `#unreadable` line: how many, and `ccwatch doctor` |
| (d) genuinely no sessions | `trust === "ok"` and no `error` and `sessions.length === 0` | `#empty` line: no live sessions, and `ccwatch resume` |

(c) is **additive** and can coexist with any of the others, which is what the
spec's edge case "the registry is unreadable *and* the host has no sessions"
requires. (d) is gated on `trust === "ok"` and on the absence of `error`, which
is FR-031 and SC-008. `parse_failed` absent or `null` (which is what `warming`
produces, since there is no snapshot to take it from) means *unknown* and prints
nothing — never `0`, which would be a claim.

Withholding under `trust !== "ok"` (FR-029, Constitution III) is enumerated in
exactly one place, `VOLATILE`, listing the context fill rect, every `%` and
every MB figure, in the figure primitive, the `<title>` text, the counts line
and the footer. Pose, colour and structure stay, per the spec's second
assumption. Age comes from `collected_at.snapshot` recomputed against `now` —
the mechanism `001-feed-footprint` introduced precisely so an age cannot freeze.

**Rationale**: a single enum cannot express (c)-with-(d), and the spec demands
both facts be stated. Splitting the trust *state* from the additive *count*
also means FR-032 is one assignment: a good snapshot sets `trust = "ok"`, and
the withheld readings come back on the same tick because they are read from
`trust` at draw time rather than latched.

**Alternative rejected**: a precedence-ordered single enum. Smaller, and it
swallows the unreadable count behind the empty-host sentence — the exact
Constitution IV failure the spec calls out.

---

## D8. The pure geometry lives in `web/plots.js`, tested under `node`

**Decision**: the identity → slot → coordinate function, the persistence and
eviction, and the extent/scale fit go into a new static file `web/plots.js`,
exporting on `window.CCWATCH_PLOTS` and with a CommonJS tail for `node`, exactly
as `web/md.js` does. `web/map.html` loads it with `<script src="/plots.js">`;
the static fallback in `serve` already serves the `web/` directory, so no route
is added (FR-055).

**Rationale**: the browser-observable requirements — coordinates identical
across frames (SC-001), unchanged across reload (SC-002), zero movement when a
project appears (SC-003), no volatile field influencing a coordinate (FR-007),
bounded storage that never evicts a live entry (FR-013), an extent that ignores
remembered empties (FR-039) — are all properties of *pure functions*, and the
suite has no browser and may not acquire one (FR-052, FR-054). `web/md.js` is
the standing precedent: `CLAUDE.md` says it is a separate file "so that
`tests/run.sh` can run it under node and assert on the HTML". This is the same
trade for the same reason, and it makes five of the spec's success criteria
mutation-checkable instead of manual.

A second static file is not an image, a binary, a font, an external fetch or a
runtime dependency (FR-052), it needs no build step (FR-054), and the `node`
gate skips with a stated reason where `node` is absent (FR-061), as the
`markdown` section already does.

**Alternatives rejected**:

- **Keep the geometry inline in `map.html`.** Then SC-001 through SC-003 can
  only be asserted by eye, and the mutation table gets rows nothing can check.
- **Add a headless browser.** Forbidden by FR-052/FR-054 and by the
  constitution's no-dependencies rule.
- **Assert the geometry by grepping the page.** A grep can prove `sev` does not
  appear inside a function body; it cannot prove two frames agree on a
  coordinate. That is the difference between a guard and a test.

---

## D9. Resize refits; it does not refetch

**Decision**: the `resize` listener (`web/map.html:797`) stops calling `tick()`
and calls the fit alone. The single `setInterval` scheduler
(`web/map.html:475-485`) is untouched, and no new timer or animation frame is
introduced.

**Rationale**: today the wires are measured from screen geometry, so a resize
*had* to re-run the whole tick to re-measure them; D1 removes that reason. FR-049
wants drawing driven by events, FR-038 wants the fit recomputed once per resize,
and the existing assertions at `tests/run.sh:739-746` — one `setInterval`, no
`requestAnimationFrame`, a `visibilitychange` listener — keep passing unchanged.
A resize also stops costing a network round trip and a full snapshot read, which
is the same duty-cycle argument `001-feed-footprint` made.
