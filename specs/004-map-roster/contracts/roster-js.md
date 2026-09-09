# Contract: `web/roster.js` — the pure roster module

**Feature**: `004-map-roster` | **Plan**: [../plan.md](../plan.md) |
**Data model**: [../data-model.md](../data-model.md)

A fourth static module beside `md.js`, `plots.js` and `camera.js`, for the
documented reason those exist: `tests/run.sh` can `require()` it under `node`
and assert on it without a browser (D1, FR-044). Same shape as `camera.js`:

```js
(function (root) {
  "use strict";
  /* … */
  root.CCWATCH_ROSTER = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
```

**Purity**: no DOM, no `fetch`, no timers, no `localStorage` reference. Storage
is reached only through injected `getItem`/`setItem`. Nothing in this module
reads a global; every input is an argument.

**Never derives a status.** There is no comparator over `sev`/`psev`, no default
arm that manufactures a word, and no branch that turns an absent reading into a
number (FR-007, Constitution V, XI).

Served by the static fallback in `serve` (`bin/ccwatch:3094`,
`directory=WEB` at `bin/ccwatch:2901`) — no route, and **no change to
`bin/ccwatch`**.

---

## §1 Constants

| Name | Value | Referenced by |
|---|---|---|
| `STORAGE_VERSION` | `1` | §7 |
| `WIDTH_DEFAULT` | `320` | §6 |
| `WIDTH_MIN` | `220` | §6 |
| `WIDTH_MAX_PX` | `560` | §6 |
| `WIDTH_MAX_FRAC` | `0.45` | §6 |
| `WIDTH_STEP` / `WIDTH_STEP_BIG` | `16` / `64` | page §4 |
| `STACK_BREAKPOINT` | `720` | page §3 |
| `NEAR_IDX` | `5` | §5 |
| `ASK_CHARS` | `100` | §2 |

Frozen values, independent of viewport size and of the payload.

## §2 `rowFields(row, opts) → RosterRow`

`opts` is `{volatile: boolean}`. Returns the object in data-model §1, with
**absent keys for absent readings** — never `0`, `"0%"`, `"0MB"`, `"-"` or
`null` (R1).

Asserted claims:

| id | Claim |
|---|---|
| R‑A | `word` is `row.token` verbatim, including a token the module has never seen |
| R‑B | `where` is `"<repo> · <branch>"`, and exactly `"no repo"` with no repository named when `row.repo` is null |
| R‑C | `measure` follows data-model §2's table, matching the terminal's last column |
| R‑D | `quiet == null` yields the payload's note and no duration; there is no `0s` |
| R‑E | `context == null`, `used_percentage == null` or `volatile: false` ⇒ **no `ctx` key** |
| R‑F | `rss_mb == null` or `volatile: false` ⇒ **no `mem` key** |
| R‑G | `pipeline` is a separate key from `word` and is never concatenated with it |
| R‑H | `pipeline` reads `"<phase>/CRASHED"` when `crashed`, else `"<phase>/<status>"` |
| R‑I | an `sdk-ts` row carries its note and no invented measurement |
| R‑J | `asks` is present only when the payload has a question, and is bounded to `ASK_CHARS` |
| R‑K | `age` is absent when `row.age == null` — never `dur(null)`'s `"-"` as a *reading* |

`dur` is exported so the page uses one duration formatter (it is the same
function the page already has; the module owns the copy and the page delegates).

## §3 `titleText(row, volatile) → string`

The figure `<title>` string, built by joining the same `rowFields` output with
`" · "` in the order `titleBits` uses today: word, `ASKS:` , measure, pipeline,
`age`, `ctx`, `mem` (D12).

| id | Claim |
|---|---|
| T‑A | For any row, `titleText` contains every value `rowFields` produced and nothing else |
| T‑B | `titleText(row, false)` contains no `%` and no `MB` |

`map.html`'s `titleBits()` becomes a one-line delegation to this, so the
figure's hover reading and the roster row can never state different things
(FR-012).

## §4 Ordering and reconciliation

The module contains **no sort**. It exposes only the two functions the DOM
sequence needs:

### `keysOf(sessions) → string[]`

`sessions.map(r => r.sid)`, in arrival order, with any row missing a `sid`
dropped. This is the roster's order (D2, O1–O3).

### `reorderPlan(currentKeys, wantedKeys) → [{key, before}]`

The minimal list of moves that turns `currentKeys` into `wantedKeys`, where
`before` is the key to insert ahead of, or `null` for append.

| id | Claim |
|---|---|
| O‑A | An unchanged order produces `[]` — zero moves, therefore zero DOM writes |
| O‑B | One row moving from last to first produces exactly one move |
| O‑C | A key in `currentKeys` but not in `wantedKeys` produces no move (removal is `reconcile()`'s job) |
| O‑D | Applying the plan in order yields exactly `wantedKeys` |
| O‑E | A reversal of *n* keys produces at most *n − 1* moves |

### `focusTarget(prevSid, wantedKeys) → string | null`

`prevSid` when it is still in `wantedKeys`, else `null` (D4).

### `nextFocus(keys, currentSid, key) → string | null`

`key` ∈ `{"ArrowDown", "ArrowUp", "Home", "End"}`.

| id | Claim |
|---|---|
| K‑A | `ArrowDown` from the last row stays on the last row (clamped, never wraps) |
| K‑B | `ArrowUp` from the first row stays on the first row |
| K‑C | `Home`/`End` return the first/last key |
| K‑D | A `currentSid` no longer in `keys` resolves to the first key rather than `null` |
| K‑E | An empty `keys` returns `null` for every key |

## §5 Selection

### `resolveSelection(storedSid, sessions, cond) → {state, sid}`

`state` ∈ `{"none", "present", "gone", "unknown"}`, per data-model §4.

| id | Claim |
|---|---|
| S‑A | sid present in a trusted payload ⇒ `present` |
| S‑B | sid absent from a trusted payload ⇒ `gone` |
| S‑C | sid absent while `trust === "feed_down"` ⇒ `unknown` (S2, FR-024) |
| S‑D | sid absent while `trust === "warming"` ⇒ `unknown` |
| S‑E | no stored sid ⇒ `none`, whatever the condition |
| S‑F | sid present while the feed is down ⇒ `present` (the row is still there to mark) |
| S‑G | a malformed `cond` (missing `trust`) is treated as untrusted, never as `ok` |

### `flyIdx(level) → number | null`

`NEAR_IDX` when `level === "far"`, `null` otherwise (D18).

| id | Claim |
|---|---|
| S‑H | `flyIdx("far") === 5` and `flyIdx("mid") === flyIdx("near") === null` |
| S‑I | `NEAR_IDX` is a rung `camera.js`'s `levelFor` resolves to `near` from `null`, `"far"`, `"mid"` and `"near"` alike — asserted against `camera.js` itself, so the two modules cannot drift |

## §6 Width

### `clampWidth(w, windowWidth) → number`

`min(max(w, WIDTH_MIN), min(WIDTH_MAX_PX, WIDTH_MAX_FRAC × windowWidth))`.

| id | Claim |
|---|---|
| W‑A | A width below `WIDTH_MIN` clamps up |
| W‑B | A width above `WIDTH_MAX_PX` clamps down |
| W‑C | On a narrow window the fraction bound wins: `clampWidth(500, 900) === 405` |
| W‑D | A non-finite or non-number width returns `WIDTH_DEFAULT` |
| W‑E | `clampWidth` is idempotent |
| W‑F | The result is never greater than `windowWidth` for any `windowWidth ≥ WIDTH_MIN / WIDTH_MAX_FRAC` |

### `stacked(windowWidth) → boolean`

`windowWidth < STACK_BREAKPOINT` (D11). The page uses it only to skip applying
a stored width; the layout itself is CSS (page §2), so this function is not the
carrier of the breakpoint's behaviour — the media query is, and both read
`STACK_BREAKPOINT`.

## §7 Storage

```
validateSelection(raw) → {sid} | null
validateWidth(raw)     → {w}   | null
loadSelection(getItem) → {sid} | null
saveSelection(setItem, sid)
loadWidth(getItem)     → {w}   | null
saveWidth(setItem, w)
persistence            → "ok" | "unavailable"   (getter)
```

`raw` may be a string or an already-parsed object, as `validateView` accepts
(`web/camera.js:131`).

| id | Claim |
|---|---|
| P‑A | Unparseable JSON returns `null` and does not throw |
| P‑B | `v !== STORAGE_VERSION` returns `null` |
| P‑C | A `sid` that is not session-id-shaped (hex and dashes, 1–64 chars) returns `null` |
| P‑D | A non-finite or non-number `w` returns `null` |
| P‑E | An array, `null` or a primitive returns `null` |
| P‑F | A throwing `getItem` returns `null` and flips `persistence` to `"unavailable"` |
| P‑G | A throwing `setItem` flips `persistence` to `"unavailable"` and does not throw |
| P‑H | `persistence` never returns to `"ok"` once unavailable, and is not retried |
| P‑I | `saveSelection(setItem, null)` writes a record clearing the selection rather than leaving the old sid behind |

## §8 Condition statements

### `statements(cond) → {main, mainKind, unreadable, empty}`

Strings, empty when not applicable. `mainKind` ∈ `{"", "down", "warming"}` for
the page's class.

| id | Claim |
|---|---|
| C‑A | `trust: "feed_down"` ⇒ `main` names the reason **and** the measured age of the rows still shown (F3, FR-027) |
| C‑B | `trust: "warming"` ⇒ `main` says the first snapshot is still being taken, and carries no age |
| C‑C | `unreadable: 3` ⇒ `unreadable` states `3` and names `ccwatch doctor` (FR-026) |
| C‑D | `unreadable: 0` or `null` ⇒ `unreadable` is `""` — never `"0 registry files"` (R5 of entry 002) |
| C‑E | `empty: true, trust: "ok"` ⇒ `empty` states there are no live sessions |
| C‑F | `empty: true, trust: "feed_down"` ⇒ `empty` is `""` — the exclusion is enforced here, whatever the caller passed (F2, FR-029, SC-007) |
| C‑G | `empty: true, trust: "warming"` ⇒ `empty` is `""` |
| C‑H | The four sentences are pairwise distinct strings, and no two of `main`/`empty` are non-empty together |
| C‑I | `unreadable` may accompany any `main` — it is additive (F2) |

### `goneText(sid, name) → string`

The tombstone sentence (data-model §6).

| id | Claim |
|---|---|
| C‑J | It shares no leading clause with any string `statements()` can produce, so "the session went away" and "the feed went away" cannot be misread for each other (FR-023) |

## §9 Exports

```js
{
  STORAGE_VERSION, WIDTH_DEFAULT, WIDTH_MIN, WIDTH_MAX_PX, WIDTH_MAX_FRAC,
  WIDTH_STEP, WIDTH_STEP_BIG, STACK_BREAKPOINT, NEAR_IDX, ASK_CHARS,
  dur, rowFields, titleText,
  keysOf, reorderPlan, focusTarget, nextFocus,
  resolveSelection, flyIdx,
  clampWidth, stacked,
  validateSelection, validateWidth,
  loadSelection, saveSelection, loadWidth, saveWidth,
  persistence /* getter */,
}
```

Nothing else is exported. In particular there is no `sort`, no `severity`, no
`statusOf` and no `render`.
