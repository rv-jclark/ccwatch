# Contract — the snapshot payload, and the one field this feature adds

**Feature**: `002-map-stable-world` | **Applies to**: `ccwatch --json`, `GET /api/state`, `ccwatch doctor`, the terminal footer

No endpoint is added and no existing field changes meaning (FR-055, FR-037).
This document states the one addition and pins the fields the map consumes, so
that a later change to either side is a contract change rather than a surprise.

---

## 1. Addition: `parse_failed`

```jsonc
{
  "sessions":   [ /* … unchanged … */ ],
  "unfinished": [ /* … unchanged … */ ],
  "unfinished_old": 0,
  "parse_failed": 1            // NEW: registry files that would not parse
}
```

| | |
|---|---|
| Type | integer ≥ 0 |
| Present in | `ccwatch --json`, and therefore `/api/state` (which shells out to it) |
| Absent in | `/api/state` while `warming` — there is no snapshot to have taken it from |
| Additive | yes; every existing key keeps its type and meaning |

### Guarantees

- **G1** — For the same `~/.claude/sessions/` directory, the number is identical
  in the terminal footer, in `ccwatch --json`, in `/api/state` and in
  `ccwatch doctor` (FR-034, SC-009). All four read the same field; none of them
  recount.
- **G2** — It counts **files**, not sessions. One unparseable file costs exactly
  one (spec Assumptions).
- **G3** — It is `0` only when no file failed to parse (FR-035). A registry
  containing an unparseable file reports non-zero.
- **G4** — Absent or `null` means *unknown*, never *zero*. A consumer prints
  nothing (Constitution IV, V).
- **G5** — It participates in the `/api/state` ETag, because `build_canonical`
  copies the snapshot's keys wholesale. A `304` therefore still guarantees the
  count has not changed, exactly as it does for every other measured number
  (`001-feed-footprint`, FR-012 there).

### Wording, where the count is rendered

| Consumer | Text | Condition |
|---|---|---|
| terminal footer | `· N unreadable registry file(s) — run: ccwatch doctor` | `N > 0` only — **absent** below the threshold (Constitution XII). Unchanged from `bin/ccwatch:1143`, which already formats it and never receives it |
| `ccwatch doctor` | `N registry file(s) would not parse (a session mid-write does this; persistent means trouble)` | `N > 0`. Unchanged from `bin/ccwatch:3087` |
| `/map` | `N registry file(s) could not be read — run: ccwatch doctor` | `N > 0`. New (FR-036: rendered from the payload, never inferred from a short list) |

---

## 2. Fields the map consumes (pinned, not changed)

Listed so that "the payload already carries everything the map draws" is a
checkable statement rather than an assumption.

### Layout inputs — the only fields allowed to reach a coordinate

| Field | Use |
|---|---|
| `sessions[].repo` | `owner/name`; split on `/` for the district (FR-003); `null` ⇒ `no repo` district (FR-004) |
| `sessions[].cwd` | the building key `dir:<cwd>` where there is no remote |
| `sessions[].branch` | the zone |
| `sessions[].sid` | the figure |

### Appearance inputs — may set pose, colour, emphasis and text; never position

`sessions[].token`, `.sev`, `.psev`, `.name`, `.project`, `.note`, `.waited`,
`.age`, `.questions[]`, `.pipeline{feature,phase,status,crashed,cost}`,
`.context{used_percentage,cost_usd,age}`, `.rss_mb`.

### Structure alongside the sessions

`unfinished[]` (`project`, `repo`, `feature`, `phase`, `status`, `cost`, `age`,
`sid`), `deploys.runs[]` (`repo`, `live`, `conclusion`, `workflowName`,
`headBranch`), `peers.edges[]` (`from`, `to`, `count`), `usage`, `host`,
`can_kill`.

### Trust inputs

`warming`, `snapshot_ok`, `snapshot_error`, `error`, `collected_at.snapshot`,
`ages`, `stale`, `feed`, and now `parse_failed`.

---

## 3. What this feature must not do to the payload

- No new status, severity, verdict or badge (FR-037, spec Out of Scope).
- No field derived in the page. Mapping a payload value to a pose or a colour is
  presentation and is allowed; deciding what the value should be is not
  (Constitution XI).
- No new endpoint, and no change to the write endpoints' token or `Origin`
  checks, or to the `--allow-kill` gate (FR-048, FR-055, Constitution IX).
- No change to `Cache-Control` on any response. Page HTML keeps `no-store`
  because it carries the per-run token; `/api/transcript` keeps `no-store`
  because it carries transcript text (Constitution X).
- The token placeholder line in the served page stays **verbatim** —
  `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` — because
  `bin/ccwatch:2842` substitutes on that exact byte string and an assertion
  greps the served page for the result (FR-047).
