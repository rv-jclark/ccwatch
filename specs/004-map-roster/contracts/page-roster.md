# Contract: what `/map` does — the docked roster

**Feature**: `004-map-roster` | **Plan**: [../plan.md](../plan.md) |
**Module**: [roster-js.md](./roster-js.md)

Everything below lives in `web/map.html`. `web/roster.js` owns the arithmetic
and the wording; the page owns the document.

---

## §1 New DOM

Built with `createElement`/`textContent` only — the page's `innerHTML` count
stays at **two** (FR-042, asserted at `tests/run.sh:1389-1397`).

```
<div id="stage">                     flex row (column below the breakpoint)
  <aside id="roster"  role="region" aria-labelledby="rostertitle">
    <h2  id="rostertitle">agents · N</h2>          visible name + count (FR-016)
    <p   id="rosternote">                          storage-unavailable note (P3)
    <div id="rostercond">                          the four sentences (§5)
      <span class="main">  <span class="unreadable">  <span class="emptymsg">
    <div id="rostergone">                          tombstone + dismiss button (§6)
    <div id="rosterlist" role="listbox" aria-labelledby="rostertitle">
      <div class="rrow" role="option" tabindex="-1" aria-selected="false" data-sid=…>
        <span class="rname">      name
        <span class="rwhere">     repo · branch  |  no repo
        <span class="rstatus">    word  ·  measure          ← never truncated
        <span class="rmeta">      age · phase/status · ctx NN% · NNMB
        <span class="rasks">      asks: …
        <span class="rsel">       selected                  ← word, not colour
  <div id="rdivider" role="separator" aria-orientation="vertical" tabindex="0"
       aria-valuenow aria-valuemin aria-valuemax aria-label="Roster width">
  <div id="wrap">  …unchanged: #world, #camctl…
```

`#stage` wraps the **existing** `#wrap` without moving anything inside it, so
`#world`, `#camera`, `#camctl` and the `#reply` inspector keep their structure,
their ids and their listeners (FR-038).

Changed elsewhere:

- `#world`'s `aria-label` gains a companion clause: it names itself a companion
  view of the agent list and keeps the key list verbatim
  (`Arrow keys` must still appear — `tests/run.sh:826` asserts it) (FR-013).
- The legend gains one entry for the selection ring. It is built once, before
  `tick()` is defined, so the existing line-order assertion still holds.

## §2 Stylesheet additions

| Rule | Why |
|---|---|
| `#stage { display:flex; align-items:stretch }` | the dock |
| `#roster { flex:0 0 var(--roster-w, 320px); overflow-y:auto; min-width:0 }` | one custom property is the only width writer (D9) |
| `#rdivider { flex:0 0 6px; cursor:col-resize; touch-action:none }` | `touch-action` for the same reason `#world` has it |
| `#rdivider:focus-visible { outline:2px solid var(--info) }` | the keyboard path is visible (FR-032) |
| `.rrow .rname, .rrow .rwhere { overflow:hidden; text-overflow:ellipsis; white-space:nowrap }` | identity truncates first |
| `.rrow .rstatus { flex:none; white-space:nowrap }` | **the status word and measurement never truncate** (FR-034) |
| `.rrow[aria-selected="true"] { … }` + `.rsel` text | emphasis carries a word, not only a colour (Constitution VII, D17) |
| `.agent.selected .hit { stroke:var(--info); stroke-dasharray:2; … }` | figure emphasis, distinct from every status appearance (FR-019, D17) |
| `@media (max-width:720px) { #stage{flex-direction:column} #roster{flex:0 0 auto; max-height:40vh} #rdivider{display:none} }` | stacking (D11) |

No new keyframes, no new transition and **no new
`@media (prefers-reduced-motion: reduce)` block**. Nothing this feature draws
moves: the selection marker is text and a static ring, and the only motion in
the feature — the camera fly — is decided in the page (D8). This is also a
hard constraint rather than a preference: the existing assertion at
`tests/run.sh:865-870` reads the **first** `prefers-reduced-motion` block in
the file with `awk`, so a new block inserted above the `#camera.eased` one
would break it while changing nothing about behaviour.

## §3 Rendering — `renderRoster(sessions, cond)`

Called from exactly four places (FR-041):

1. `applyFeed()`, **after** `VOLATILE = cond.trust === "ok"`
   (`web/map.html:1681`) and in the same pass, so the roster withholds through
   the one gate (D13, FR-028);
2. the selection change handler;
3. the row focus handler (roving `tabindex` only);
4. the width/viewport change path (§6).

No `setInterval`, no `requestAnimationFrame`, no `ResizeObserver`. The page
keeps exactly one interval — the shared visibility-aware scheduler
(`web/map.html:928-936`) — so `tests/run.sh:809-816` stays green.

Order of work in `renderRoster`:

```
statements(cond)         → #rostercond          (F1–F5)
warming?                 → render no rows at all (FR-025 (b))
keys = keysOf(sessions)
prevFocusSid             = the active row's sid, if any
reconcile(#rosterlist, wanted, "rrow", makeRow, updateRow)   ← identity
applyOrder(reorderPlan(currentKeys, keys))                   ← sequence (D3)
focusTarget(prevFocusSid, keys) → re-focus if the move dropped it (D4)
roving tabindex: exactly one row at 0
#rostertitle.textContent = "agents · " + keys.length
resolveSelection(storedSid, sessions, cond) → mark row / figure / tombstone
```

`makeRow`/`updateRow` split exactly as the map's primitives do
(`web/map.html:556-577`): the row's `<div>`, its `data-sid` and its span
children are created once and written to on every later tick, so a focused
row, a selected row, a hover, a text selection and the panel's scroll offset
all survive a tick (FR-042).

## §4 Keyboard and pointer

| Target | Event | Behaviour |
|---|---|---|
| `#rosterlist` | `keydown` `ArrowDown`/`ArrowUp`/`Home`/`End` | `nextFocus`, `preventDefault` so the panel does not also scroll |
| `#rosterlist` | `keydown` `Enter` | select the focused row (FR-015) |
| `.rrow` | `click` | select that row — **never** open the inspector (FR-021) |
| `.agent` | `click` | unchanged: opens the inspector (`web/map.html:1249-1256`) |
| `#rdivider` | `pointerdown`/`move`/`up` | width drag, `setPointerCapture`, clamped per tick |
| `#rdivider` | `keydown` `ArrowLeft`/`ArrowRight` (`Shift` = coarse), `Home`/`End` | width by keyboard (FR-032) |

**FR-017 by construction**: the camera's `keydown` is bound to `#world`
(`web/map.html:1387`), the roster's to `#rosterlist`, the divider's to
`#rdivider`. None is a descendant of another and none is bound to `document`,
so arrows in the roster never pan, arrows on the map never move roster focus,
and the reply box — guarded already by `EDITABLE_SEL` — is untouched. The one
`document`-level `click` listener that exists keeps its `.agent[data-sid]`
`closest()` test, which no roster node matches.

## §5 The four sentences, in the panel

`#rostercond` renders `statements(cond)` into three persistent child nodes
(`main`, `unreadable`, `emptymsg`), toggled by text content — the same
construction `renderTrust` uses (`web/map.html:1604-1626`), which stays exactly
as it is. The banner above the map and the panel read the *same* `cond` object
(FR-007, Constitution XI inside the page).

While `trust === "warming"` the list renders no rows (FR-025 (b)). While
`trust === "feed_down"` the retained rows stay listed, the sentence states the
reason and their measured age, and every `ctx`/`mem` is absent because
`VOLATILE` is false (FR-027, FR-028).

## §6 Selection, the fly, and the width

```
let selectedSid = loadSelection(getItem)?.sid ?? null;
let lastFlownSid = null;      // D7 — exactly one camera move per selection
```

- `selectRow(sid)` sets `selectedSid`, saves it, re-renders the roster, applies
  the figure emphasis, and flies **iff** `sid !== lastFlownSid`.
- The fly is
  `CCWATCH_MAP_CAMERA.centreOn(cx, cy, {animate: !reducedMotion, idx: flyIdx(CCWATCH_MAP_CAMERA.current().level)})`
  — the first caller of the API entry 003 shipped unused (FR-020).
  `reducedMotion` is read from `matchMedia("(prefers-reduced-motion: reduce)")`
  at the moment of the fly (D8: the CSS reduction alone would leave `.eased` on
  `#camera` forever, because `transition: none` fires no `transitionend`).
- `cx`/`cy` come from `centreBySid`, built inside `drawWorld`'s existing figure
  loop (`web/map.html:1534-1546`) from `plots.js`'s own `cx`/`cy`
  (`web/plots.js:259-261`) (D19). A sid with no placement this tick does not
  fly.
- The figure emphasis is a class on the outer `<g class="agent">`, applied by
  `updateFigure` from a page-level `selectedSid` — **not** inside `.figart`,
  which is rebuilt wholesale each tick (`web/map.html:711-716`).
- A restored selection on load marks the row and emphasises the figure and does
  **not** fly (D7).
- Width: `setWidth(w)` writes `--roster-w` on `#stage`, saves it, and calls
  `reflowWorld()`.

## §7 `reflowWorld()` — one function, three callers

Extracted verbatim from the existing `resize` listener
(`web/map.html:1752-1768`):

```
sync #world's viewBox to its client size
wx, wy = the world point at the centre of the previous size (vpSize)
view = clampPan(centreOn(view, wx, wy, vw, vh), worldExtent, vw, vh)
applyView()
```

Callers: the window `resize` listener (behaviour unchanged), the divider's drag
and keyboard paths, and **once at load** after the panel exists and before the
first tick.

- It never calls `fitView`, so a width change cannot discard the camera
  (FR-033).
- The load-time call also syncs the shipped `viewBox="0 0 408 408"`
  (`web/map.html:276`) to the element's pixel size, which is what
  `contracts/page-camera.md §1` already assumes ("1 world unit == 1 screen px
  at idx 2") and which nothing did before the first window resize (D10).

## §8 Load order

```
<script src="/md.js">      <script src="/plots.js">
<script src="/camera.js">  <script src="/roster.js">     ← new, last of the four
… page script …
  build #stage, #roster, #rdivider, move #wrap into #stage
  selectedSid = loadSelection(...)          (validated, or null)
  width       = clampWidth(loadWidth(...)?.w ?? WIDTH_DEFAULT, innerWidth)
  #rosternote = persistence === "unavailable" ? the note : ""
  reflowWorld()                             ← before the first tick (§7)
  resume() → tick() → applyFeed() → renderRoster()
```

A missing `/roster.js` must not take the page down: the roster render is
guarded by `if (!window.CCWATCH_ROSTER) return;` and the map keeps working —
the same discipline `md.js`'s `isMd` guard follows (`web/map.html:950`). The
suite asserts the guard exists, mirroring the `remove web/md.js from the web
directory` mutation already in the table.

## §9 What must not change

| Invariant | Guarded by |
|---|---|
| exactly one `setInterval`, zero `requestAnimationFrame` | `tests/run.sh:809-816` |
| `innerHTML` assigned exactly twice, the refresh-reachable one being the turn body | `tests/run.sh:1389-1397` |
| `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` byte-identical | `tests/run.sh:1402` (FR-039) |
| `#world` keeps `tabindex="0"` and an `aria-label` naming the keys | `tests/run.sh:822-826` |
| three real `<button>`s in `#camctl` | `tests/run.sh:830-836` |
| every label/badge counter-scales against `--k`; `.bubblescale` unchanged | `tests/run.sh:841-860` |
| `#camera.eased` stays a bounded transition reduced under `prefers-reduced-motion` | `tests/run.sh:865-870` |
| the payload, the endpoints and the terminal output | this feature touches no `bin/ccwatch` line (FR-035–FR-037) |
