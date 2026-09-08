# Phase 1 — Data Model

**Feature**: `002-map-stable-world` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md) | **Research**: [research.md](./research.md)

There is no database and no schema migration here. The entities below are (a)
one new field in the snapshot payload, (b) the in-page models the reconciler is
keyed on, and (c) the one persisted record. Nothing else about what is collected
changes (FR-037, and the spec's Out of Scope).

Everything the map draws other than `parse_failed` already exists in the
payload. See [contracts/api-state.md](./contracts/api-state.md) for the fields
consumed and [contracts/plots-js.md](./contracts/plots-js.md) for the functions
that turn identity into coordinates.

---

## 1. Snapshot payload — one new field

### `parse_failed` (new)

| | |
|---|---|
| Type | integer ≥ 0, or absent/`null` |
| Where produced | `collect_sessions` (`bin/ccwatch:189`), carried by `snapshot()` |
| Where consumed | terminal footer (`bin/ccwatch:1130`), `ccwatch doctor` (`bin/ccwatch:3087`), `ccwatch --json`, `/api/state`, `web/map.html` |
| Meaning | how many **files** in `~/.claude/sessions/` could not be parsed for this snapshot |
| Validation | a count of files, not of sessions: one unparseable file costs exactly 1 (spec Assumptions). `0` only when no file failed (FR-035) |
| `null` semantics | unknown, not zero. `/api/state` omits it while `warming`, because there is no snapshot to have taken it from. A consumer must print nothing rather than `0` (Constitution IV/V) |

The number reaches four consumers and must be equal in all four for the same
registry (FR-034, SC-009). It is equal by construction rather than by
convention, because all four read the same snapshot field — see
[research.md](./research.md) D6.

### `collect_sessions` return value (changed shape)

| Before | After |
|---|---|
| `[ {…}, {…} ]` | `{ "rows": [ {…}, {…} ], "parse_failed": N }` |

Three call sites destructure it: `snapshot()` (`bin/ccwatch:618`),
`cmd_doctor` (`bin/ccwatch:3086`) and the peer-name lookup in `cmd_convo`
(`bin/ccwatch:1515`, which becomes `… | jq -c '[ .rows[] | … ]'`).

---

## 2. Identity keys — the only inputs to a coordinate

Every coordinate in the world is a function of these strings and nothing else
(FR-006, FR-007). They are listed here because the list *is* the requirement:
anything not in this table may not reach the layout.

| Entity | Key | Derived from | Fallback |
|---|---|---|---|
| District | `org` | `row.repo.split("/")[0]` (FR-003) | the literal `no repo` when `row.repo` is null (FR-004) |
| Building | `slug` | `row.repo` | `dir:<row.cwd>` when there is no remote. The current page keys on `"dir:" + r.project` (`web/map.html:725`); `cwd` replaces `project` because two directories can share a basename-derived project name, and merging two scratch directories into one building would be a guess (Constitution VI) |
| Zone | `branch` | `row.branch` | the literal `?`, shown as missing rather than guessed (spec Edge Cases) |
| Figure | `sid` | `row.sid` | none; a row without a session id is not drawn |

**Explicitly excluded from every layout input** (FR-007): `sev`, `psev`,
`token`, `status`, `quiet`, `waited`, `cpu`, `cpu_delta`, `context.*`,
`rss_mb`, `cost`, `age`, `deploys`, `pipeline.*`, and the order rows appear in
`sessions`. The `no repo` district is never folded into a real organisation
(FR-004, Constitution VI).

### Scoping

Keys are namespaced by their parent so that two orgs may each hold a `main`
branch without competing for a slot:

```
district   "d|<org>"
building   "b|<org>|<slug>"
zone       "z|<slug>|<branch>"
figure     "f|<slug>|<branch>|<sid>"
```

An annex plot (research.md D2) appends `#2`, `#3`, … to the key, so an annex is
itself an identity and is itself persisted.

---

## 3. In-page models

Built fresh from each payload, keyed by the strings above, and handed to the
reconciler. They hold no coordinates: a coordinate is asked of `plots.js` at
draw time.

### `Figure`

| Field | Source | Notes |
|---|---|---|
| `sid`, `name`, `branch`, `slug`, `org` | payload row | identity |
| `token` | `row.token` | rendered as text verbatim, even when unrecognised (FR-046, Constitution V) |
| `kind` | `KIND[row.token]` | presentation only: pose class and colour. Falls through to the neutral figure with `row.sev`, inventing nothing (spec Edge Cases) |
| `sev`, `psev` | payload row | appearance and the counts line only — never a coordinate or an order (FR-008) |
| `ctxPct` | `row.context.used_percentage` | **volatile**: withheld entirely when `trust !== "ok"` (FR-029) |
| `rssMb` | `row.rss_mb` | **volatile** |
| `questions`, `note`, `waited`, `age`, `pipeline` | payload row | `<title>` text and the inspector |

### `Zone`, `Building`, `District`

| Entity | Fields | Notes |
|---|---|---|
| `Zone` | `branch`, `figures[]` | `branch` is the visible label, so two worktrees of one repository are distinguishable — the only thing that tells them apart (spec Key Entities) |
| `Building` | `slug`, `label`, `org`, `hasRemote`, `zones[]`, `unfinished[]`, `deploys[]` | `hasRemote === false` draws the existing `no repo` badge (FR-004). A building with no live session but an unfinished run or a deploy badge still exists and still holds its plot (spec Edge Cases) |
| `District` | `org`, `buildings[]`, `isNoRepo` | one organisation, or the single reserved `no repo` district shared by all remote-less directories, each as its own building (spec Assumptions) |

### `Wire`

| Field | Source | Notes |
|---|---|---|
| `from`, `to` | `peers.edges[].from` / `.to` | session **names**, as `peers_graph` emits them (`bin/ccwatch:2604-2608`) |
| `count` | `peers.edges[].count` | a count label is drawn only when `> 1` (FR-023) |
| `drawn` | both ends resolve to a figure on the map | FR-024. Undrawn edges are counted for the footer's drawn-of-total sentence (FR-025) |

Endpoints are resolved name → row → `sid` → figure key → world centre. Two
sessions in the same building are two distinct figures at two distinct
coordinates, so the line is still drawn and still bowed (spec Edge Cases).

---

## 4. `PlotAssignment` — the one persisted record

Stored under `localStorage["ccwatch.map.plots.v1"]`:

```json
{ "v": 1,
  "entries": {
    "d|acme":                    { "slot": 3, "seen": 1757280000 },
    "b|acme|acme/checkout-api":  { "slot": 1, "seen": 1757280000 },
    "z|acme/checkout-api|main":  { "slot": 0, "seen": 1757280000 },
    "f|acme/checkout-api|main|aaaaaaaa-0000-0000-0000-000000000001":
                                 { "slot": 2, "seen": 1757280000 } } }
```

| Field | Type | Rules |
|---|---|---|
| `v` | integer | `1`. Any other value ⇒ the whole payload is discarded, not migrated (research.md D3) |
| `entries` | object | key from §2, at most **512** entries |
| `slot` | integer ≥ 0 | the index within the parent's raster. **Never rewritten once written** — this is what FR-010 and FR-011 rest on |
| `seen` | epoch seconds | refreshed on every frame in which the identity is drawn; the eviction order |

**Lifecycle**: read once at load → an in-memory map → consulted before any hash
→ written back after each frame in which an assignment was added or a `seen`
advanced. Eviction drops the longest-unseen first and is passed the live key set
so it can never drop something on screen (FR-013).

**Failure**: read or write throwing, or storage absent, sets
`persistence = "unavailable"` once. The map still draws and stays
self-consistent for the session from the in-memory map, and the page states that
positions will not survive a reload (FR-014, Constitution IV).

---

## 5. `FeedCondition` — the page's trust model

Not a payload field: derived per tick from the outcome of the read plus payload
fields, and from nothing else.

| Field | Type | Set when |
|---|---|---|
| `trust` | `"ok"` \| `"feed_down"` \| `"warming"` | `feed_down`: the `fetch` threw, or `!res.ok`, or `snapshot_ok === false`. `warming`: `warming === true`. Otherwise `ok` |
| `reason` | string \| null | the thrown message, the HTTP status, or `snapshot_error` — the real reason, never a generic one (Constitution IV) |
| `dataAge` | seconds \| null | `now - collected_at.snapshot`, recomputed against the clock every repaint so it can never freeze (FR-028). `null` while `warming`, where no snapshot has ever completed |
| `unreadable` | integer \| null | `payload.parse_failed`. **Independent** of `trust`, so it can coexist with any other condition (spec Edge Cases). `null` ⇒ print nothing |
| `empty` | boolean | `trust === "ok"` and no `error` and `sessions.length === 0` (FR-031, SC-008) |

Transitions are computed fresh each tick and never latched, so a snapshot that
fails, succeeds and fails again is reflected in both directions on the next tick
(spec Edge Cases), and a good snapshot clears the staleness marking and restores
the withheld readings on that same tick (FR-032, SC-006 wording aside).

### The withheld set

One enumeration, `VOLATILE`, is the single place FR-029 is expressed:

| Withheld when `trust !== "ok"` | Where it is drawn today |
|---|---|
| the context fill rect inside a figure | `figure()`, `web/map.html:304` |
| `ctx NN%` in a figure's title text | `agentCard()`, `web/map.html:340` |
| `NN MB` in a figure's title text | `agentCard()`, `web/map.html:341` |
| every gauge percentage | `gauges()`, `web/map.html:455-474` — on top of its own existing staleness window (FR-043) |
| the host memory-pressure percentages | `hostwarn()`, `web/map.html:440-453` — which still appears only at its threshold (FR-044) |

Pose, colour, structure, the status word and the age stay. Constitution II is
satisfied by printing the measurement — the age — beside them. FR-029 is the
single place to extend if a reviewer disagrees (spec Assumptions).
