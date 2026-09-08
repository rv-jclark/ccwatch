# Quickstart — validating `003-map-camera-lod`

**Feature**: `003-map-camera-lod` | **Date**: 2026-09-08

How to prove the camera works, end to end. Three kinds of claim, three kinds of
check:

- **Arithmetic**, under `node`: the ladder, fit-step selection, pan clamping,
  pointer-anchored zoom, hysteresis, the wheel accumulator, stored-viewport
  validation. `./tests/run.sh`, the new `camera` section.
- **Static, over the served pages**: the footprint guards, the counter-scaling
  rules, the `data-lod` rules, the three buttons, the untouched token line.
  `./tests/run.sh`, the `serve` section.
- **By hand, in a browser**: everything that is about a *rendered* page under a
  *transform* over *time* — an on-screen glyph size, a drag tracking a pointer,
  a reload landing where you left it. There is no headless browser and FR-054
  forbids adding one, so each is scripted below with an expected outcome.

Nothing here reads live sessions. Every step drives a fabricated
`CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS` substituting the liveness probe
(FR-056).

---

## 0. Prerequisites

```bash
jq --version          # required
node --version        # optional; without it the camera, plots and markdown sections skip
shellcheck --version  # optional; without it the lint section skips
curl --version        # optional; without it the serve section skips
```

Run everything from the worktree root. In a restricted sandbox roughly 13
assertions fail with empty output because `mktemp` is denied — that is the
sandbox, not a regression. Re-run with the sandbox off before believing a
failure.

---

## 1. The suite

```bash
./tests/run.sh
```

Expected: shellcheck clean at `-S warning`, zero failures, the tally at or above
the raised `TALLY_FLOOR`, and a new `camera` section. On a host without `node`
the `camera`, `plots` and `markdown` sections skip with their reason stated and
the tally still clears the floor (FR-055, SC-013).

The existing footprint assertions must pass **unmodified** — if a task had to
touch `tests/run.sh:759-767` to make the suite green, the camera was built with a
render loop and SC-009 has failed.

---

## 2. The arithmetic, by hand (FR-002–FR-012, FR-026, FR-037, SC-003, SC-004)

Every claim below is what the `camera` section asserts; this is how to reproduce
one at the prompt while working on it.

```bash
node -e '
const C = require("./web/camera.js");
const E = {x: 0, y: 0, w: 1600, h: 900};       // a four-district world
console.log("ladder      ", C.LADDER.join(" "));
console.log("fit 1400x800", JSON.stringify(C.fitIndex(E, 1400, 800)));
console.log("fit 200x200 ", JSON.stringify(C.fitIndex(E, 200, 200)));   // overflow
let v = C.fitView(E, 1400, 800);
console.log("levels      ",
  [C.levelFor(2, "far"), C.levelFor(3, "far"), C.levelFor(2, "mid"), C.levelFor(2, null)].join(" "));
const before = (500 - v.tx) / C.scaleFor(v.idx);
const z = C.zoomTo(v, v.idx + 1, 500, 300);
console.log("anchored    ", Math.abs(before * C.scaleFor(z.idx) + z.tx - 500) < 1);
console.log("bad records ",
  [null, "{", "[]", JSON.stringify({v:9,idx:1,tx:0,ty:0}),
   JSON.stringify({v:1,idx:2.5,tx:0,ty:0}), JSON.stringify({v:1,idx:1,tx:NaN,ty:0})]
    .map(r => C.validateView(r, C.LADDER.length) === null).join(" "));
'
```

| Line | Expected | Requirement |
|---|---|---|
| `ladder` | `0.25 0.5 1 2 3 4 6 8` — every entry a whole number or a reciprocal of one | FR-002 |
| `fit 1400x800` | `{"idx":2,"overflow":false}` — the largest rung where 1600×900 fits | FR-012 |
| `fit 200x200` | `{"idx":0,"overflow":true}` — smallest rung, and the page will say so | FR-012 |
| `levels` | `far mid mid far` — the band at `k=1` holds, and cold resolves down | FR-026, FR-041 |
| `anchored` | `true` — the world point under the pointer stayed within a pixel | FR-003, SC-004 |
| `bad records` | `true true true true true true` — six invalid shapes, six fits | FR-037 |

---

## 3. Serve the map against a fabricated city

The fixture wants enough districts that the far level has something to
aggregate, one district holding a session that needs attention, one unfinished
pipeline, and peer traffic — Stories 1, 4 and part of 2 in one page. The registry
shape is the one `specs/002-map-stable-world/quickstart.md` §2 and §3 build; reuse
it and add districts until `./bin/ccwatch --json | jq '[.sessions[].repo] | unique | length'`
reports at least four organisations and one session's `token` is `waiting`.

```bash
./bin/ccwatch serve --port 18800 --open   # CLAUDE_CONFIG_DIR/CCWATCH_FAKE_PS still exported
```

Open `http://127.0.0.1:18800/map`. Reap with
`pkill -f 'ccwatch serve --port 18800'` when finished.

Before touching anything, in the browser console:

```js
CCWATCH_MAP_CAMERA.current()   // → {idx, scale, level, tx, ty}
```

Expected: a first-ever load reports the fitted rung and a `level` that matches
it by the cold mapping (FR-036, FR-041).

---

## 4. Story 1 — close enough to read, far enough to see (FR-021–FR-025, SC-001, SC-002, SC-011)

| Do | Expect |
|---|---|
| Zoom out to `k = ½` or below | each district shows its name, a session count and a status word; no building outline, no branch zone, no figure, no badge is drawn (FR-022) |
| Read the district holding the `waiting` session | the word `waiting` is on the district summary — no colour perception and no zooming needed (FR-028, SC-011) |
| Read the district holding the unfinished pipeline | its `phase/status` — the same text the building badge carries at mid — is on the summary (FR-029) |
| Note a building's screen position, then zoom in two rungs and out again | the building is at the same world position; only what is drawn changed (FR-025, SC-002) |
| Zoom to `k = 2` | buildings and branch zones with their labels; the district summary is gone and the district name is back (FR-023) |
| Zoom to `k = 4` | figures carry their session name and activity as text (FR-024) |
| Drag anywhere | the view follows the pointer one-to-one and no inspector opens (FR-005) |
| Press and release on a figure without moving | the inspector opens — the click still works (FR-005) |
| Wheel over a building | the world point under the pointer stays under the pointer (FR-003) |
| One trackpad flick | one or two rungs, never the whole ladder (FR-006) |
| Wheel over the map with the page scrollable | the page does not scroll; a `ctrl`+wheel pinch does not zoom the browser (FR-007) |
| Drag the city towards a corner as hard as you can | it cannot be pushed off screen; at a rung where the world is smaller than the window it stays wholly visible (FR-008) |

**In the console**, for SC-008, before and after a zoom step:

```js
document.querySelectorAll("#camera *").length
```

Expected: identical. A camera move creates, removes and repositions zero
scene-graph nodes (FR-044, SC-008).

---

## 5. Story 2 — without a mouse (FR-013–FR-020, SC-001)

Put the mouse down.

| Do | Expect |
|---|---|
| `Tab` from the top of the page | the map surface takes focus with a visible focus ring, then the zoom-out, zoom-in and fit buttons, each announced by what it does (FR-016, FR-018) |
| Arrow keys with the map focused | the camera pans a fixed apparent amount, clamped at the world bounds (FR-013) |
| `Shift`+arrow | a larger jump (FR-013) |
| `+` then `-` | exactly one rung each, anchored at the viewport centre; `#camstate` reads the new scale and level (FR-014, FR-004, FR-019) |
| `0` | the whole world, fitted (FR-014) |
| `+` until it stops | the zoom-in button is **present and disabled**, and says why — not absent (FR-017, Constitution IV) |
| Open a figure's inspector, click into the reply box, type `-0` and an arrow key | the characters are typed, the caret moves, and the camera does not move (FR-015) |
| From the fitted four-org city, keyboard only, reach a readable session name | three actions or fewer (SC-001) |

With a screen reader, a zoom step should announce the new scale and level from
`#camstate` (FR-019).

---

## 6. Story 3 — the view I left (FR-035–FR-041, SC-005)

| Do | Expect |
|---|---|
| Zoom to `k = 4`, pan to one district, reload | the same scale and the same centre world point, and the level that scale implies (FR-035, FR-041, SC-005) |
| `localStorage.removeItem("ccwatch.map.view.v1")`, reload | the whole world, fitted (FR-036) |
| `localStorage.setItem("ccwatch.map.view.v1", '{"v":1,"idx":7,"tx":-999999,"ty":-999999}')`, reload | the whole world — not empty ground (FR-038, SC-005) |
| `localStorage.setItem("ccwatch.map.view.v1", "{oops")`, reload | the whole world, and **nothing thrown** in the console (FR-037) |
| `localStorage.setItem("ccwatch.map.view.v1", '{"v":0,"idx":3,"tx":0,"ty":0}')`, reload | the whole world (FR-037) |
| Zoom in, resize the window narrower | the scale is unchanged and the world point that was at the centre is still at the centre — no refit (FR-010, Story 3 §6) |
| Zoom into one district, then add a session in another org to the fixture and wait a tick | the camera does not move at all (FR-011) |
| Zoom into a district, then remove every session in the district *beyond* the current view so the extent shrinks | the camera is clamped back into bounds, **not** refitted (FR-011) |
| A window so small the world cannot fit at `k = ¼`, then press `0` | the smallest rung, and `#camnote` says the whole world does not fit at this zoom (FR-012) |
| Any state where it fits | `#camnote` says nothing about fitting — absent, not reassuring (Constitution XII) |

### Break the storage on purpose (FR-040)

In a private window, or with `localStorage` stubbed to throw:

```js
Object.defineProperty(window, "localStorage",
  {get() { throw new DOMException("nope", "SecurityError"); }});
location.reload();
```

Expected: the camera pans and zooms normally for the session; `#camnote` states
that the viewport will not be remembered; the console shows **one** failure, not
a stream — nothing retries in a loop.

---

## 7. Story 4 — wires and text hold their size (FR-031–FR-034, SC-006)

With an edge whose `count > 1` in the peers fixture:

| Do | Expect |
|---|---|
| Step from `k = ¼` to `k = 8` | the wire's apparent thickness does not change; it is neither a hairline at the bottom nor a slab at the top (FR-031) |
| Same sweep, watch the arrowhead | the same apparent size throughout (FR-031) |
| Same sweep, watch the count bubble | the same apparent size, still attached to the same point on the line, still absent when `count == 1` (FR-032) |
| Same sweep, watch any label the level draws | the same apparent size within a level (FR-033) |
| Confirm the wire behaviours | A→B and B→A are two bowed lines; edges only where both ends are on the map; the footer still reports `drawn/total` (FR-034) |

Measure rather than eyeball, in the console:

```js
$("camera").querySelector(".wire path").getBoundingClientRect().height   // before
// … zoom two rungs …
$("camera").querySelector(".wire path").getBoundingClientRect().height   // after
```

The bow's height scales — it is geometry — but
`getComputedStyle(el).strokeWidth` divided by nothing should track within a
pixel across the ladder (SC-006).

---

## 8. Story 5 — a camera move costs nothing (FR-043–FR-047, SC-007–SC-009, SC-012)

| Do | Expect |
|---|---|
| Open the network panel, pan and zoom continuously for ten seconds | the `/api/state` cadence is unchanged and no extra snapshot is fetched (FR-046, SC-007) |
| `document.querySelectorAll("#camera *").length` around a move | identical (SC-008) |
| System setting → reduce motion, then press `0` from a deep zoom | the view jumps; nothing animates (FR-045, SC-012) |
| Hide the tab, wait, bring it back | the camera is where it was left and the visibility pause is unchanged (FR-046) |
| Open a figure's inspector, scroll it, half-type a message, then zoom two rungs | the inspector stays open with its scroll position and the typed text intact (FR-051) |
| `grep -c requestAnimationFrame web/map.html web/index.html` | `0` and `0` (FR-043) |
| `grep -c 'setInterval(' web/map.html web/index.html` | `1` and `1` (FR-043) |
| `grep -c '\.innerHTML *=' web/map.html` | `2` (FR-047) |

---

## 9. Nothing that worked stopped working (FR-048–FR-054, SC-010)

| Do | Expect |
|---|---|
| Zoom to `k = 8` on one building, then stop `ccwatch serve` | the feed-down sentence is readable at that zoom, with the geography still drawn (FR-049, SC-010) |
| Repeat at `k = ¼` | the same sentence, equally readable (SC-010) |
| Do the same for warming, unreadable rows, and a genuine absence of sessions | four different sentences, at both extremes of the ladder (FR-049, SC-010) |
| While the feed is down at any zoom | context percentages and memory figures are **withheld**, not annotated (FR-050) |
| Compare the gauges, host-pressure line, legend, counts, footer and title with `main` | unchanged wording and behaviour (FR-051) |
| `git diff main -- bin/ccwatch` | empty — no payload change, no collector change (FR-053) |
| `git diff main --stat` | `web/camera.js` (new), `web/map.html`, `tests/run.sh`, `README.md`, and `specs/` only — no manifest, no image, no binary, no font (FR-054) |
| `grep -c 'const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";' web/map.html` | `1` (FR-052) |
| `curl -s localhost:18800/camera.js \| head -3` | the module, served by the static fallback with no route added (FR-054) |

---

## 10. Diff hygiene (FR-056–FR-058, SC-013)

```bash
shellcheck -x -S warning bin/ccwatch tests/run.sh
grep -nE 'mapfile|readarray|declare -A|\$\{[a-z_]+(,,|\^\^)\}' bin/ccwatch tests/run.sh
git diff main -- README.md | grep -c '^+.*|'      # mutation-table rows added
```

Expected: shellcheck silent; the bash-3.2 grep finds nothing outside the
suite's own guard; one mutation-table row per new assertion; `TALLY_FLOOR`
raised by the number of new assertions; and `README.md` documenting what each of
the three zoom levels shows and why the level of detail is semantic rather than
a scale factor (FR-057).

Every new assertion must have been mutation-checked: break the implementation in
the specific way the assertion describes, watch it fail, restore. An assertion
that passes against a broken implementation is worse than none.
