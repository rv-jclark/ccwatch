# Phase 1 — Data model: feed footprint

There is no database and no persisted structure. The entities below are (a) the
in-memory state of the `serve` process and (b) the JSON `/api/state` publishes.
Field-level wire details are in [contracts/api-state.md](./contracts/api-state.md);
this file records the entities, their relationships, their validation rules and
the one state machine the feature introduces.

## Entity: Feed (server process state)

One instance per `ccwatch serve` process. Held in module-level variables inside
the embedded python program; never written to disk.

| Field | Type | Rule |
|---|---|---|
| `LAST_READ` | monotonic seconds | Seeded at server start. Stamped **only** by the `/api/state` branch of `do_GET`, before the response is built. Never stamped by `/`, `/map`, `/api/transcript`, `/api/send` or `/api/kill` (FR-006). |
| `GRACE` | seconds | `CCWATCH_IDLE_GRACE`, default 15. Must exceed the pages' 3s poll by a wide margin (FR-005); a value below the poll interval would idle an attended feed. |
| `LOCK` | mutex | Guards every read and write of the panel set and the cached validator. Unchanged in kind from today. |
| `ETAG` | string or `None` | Recomputed at each publish, not per request. `None` before the first publish. |

**Derived state (per request, never stored):** `feed` ∈
{`warming`, `idle`, `collecting`} — see the state machine below.

## Entity: Panel

Three instances, one per collector, keyed `snapshot` | `deploys` | `peers`. Each
owns its own data, its own instant and its own cadence, so a slow or failing
collector can only make its own panel stale. This is existing behaviour the
feature preserves and extends.

| Field | Type | Rule |
|---|---|---|
| `key` | enum | `snapshot`, `deploys`, `peers`. |
| `data` | object or `None` | The collector's parsed output. `None` until the first successful publish. Never replaced by a fabricated empty value on failure (FR-025, FR-026). |
| `collected_at` | epoch seconds (`time.time()`) or `None` | The instant `data` was produced. **Not updated when a collection fails**, so a retained panel's age keeps growing truthfully. |
| `next_due` | monotonic seconds | Not advanced while the feed is idle, so a resumed collector that is overdue fires at once. |
| `every` | seconds | Unchanged: snapshot 2, deploys 60, peers 45. |
| `timeout` | seconds | snapshot `CCWATCH_SNAPSHOT_TIMEOUT` (default 90, was a hard-coded 40); deploys and peers unchanged at 120. |
| `ok` | bool | Whether the **most recent** collection attempt succeeded. Published for `snapshot` as `snapshot_ok`. |
| `error` | string or `None` | The reason the most recent attempt failed, verbatim from the exception or the command's stderr. Published for `snapshot` as `snapshot_error`. |

**Relationships.** Feed 1—3 Panel. Panels share only `LAST_READ` and `LOCK`;
they have no ordering or dependency between them.

**Validation rules.**
- `ok = false` ∧ `data ≠ None` → the retained `data` and its original
  `collected_at` are published together with `error` (FR-025).
- `ok = false` ∧ `data = None` → nothing is published in `data`'s place;
  `sessions`/`unfinished` go out as `null`, never `[]` (FR-026).
- `collected_at = None` ⇔ the panel's entry in `ages` is `null`.

## Entity: Snapshot (the `snapshot` panel's data)

Unchanged in content: exactly what `ccwatch --json` emits — `sessions[]`,
`unfinished[]`, `unfinished_old`, `usage`, `host`. No field of a session row is
added, removed or recomputed by this feature (FR-033). What the feature adds is
*around* it: whether the collection that produced it succeeded, and why not.

The session row's `age`, `quiet`, `cpu`, `cpu_delta`, `rss_mb` and
`context.age` are monotonic elapsed measurements that advance on every
collection. That property is what makes them part of the validator and what
bounds the not-modified hit rate — see research decision 2.

## Entity: Payload (`/api/state` response body)

Assembled per request from the three panels. Additive: every key present today
keeps its name, type and meaning.

| Key | Change | In the validator? |
|---|---|---|
| `sessions`, `unfinished`, `unfinished_old`, `usage`, `host` | May now be `null` where no snapshot has ever succeeded (previously `[]` was fabricated) | yes |
| `deploys`, `peers` | unchanged | yes |
| `warming` | **Meaning narrowed**: `true` until a snapshot has *succeeded* (was: until the first publish, including a fabricated failure) | yes |
| `can_kill` | unchanged | yes |
| `error` | unchanged key; now also carries the snapshot failure reason so the table view's existing footer surfaces it | yes |
| `snapshot_ok` | **new** — bool, whether the last snapshot attempt succeeded | yes |
| `snapshot_error` | **new** — string or `null`, the reason it did not | yes |
| `collected_at` | **new** — `{snapshot, deploys, peers}` of epoch seconds or `null` | yes |
| `ages` | unchanged — `{snapshot, deploys, peers}` of elapsed seconds or `null`, computed against request time | **no** |
| `stale` | unchanged — alias of `ages.snapshot` | **no** |
| `feed` | **new** — `warming` \| `idle` \| `collecting` | **no** |

**Why three keys are excluded.** They are functions of the request instant and
carry no fact about the host, so including them would change the validator on
every read and no read could ever be answered as unchanged (FR-012). The
consequence is that a `304`-holding client's copies of `ages`, `stale` and `feed`
are stale — which is why no consumer may render them from a stored body: the
pages recompute panel age from `collected_at` against the local clock, and
neither page renders `feed` at all.

**Validation rules.**
- `collected_at.snapshot = null` ⇒ `warming = true`.
- `snapshot_ok = false` ∧ `sessions = null` ⇒ `warming = true` ∧
  `snapshot_error ≠ null`.
- `snapshot_ok = true` ⇒ `snapshot_error = null` ∧ `sessions` is an array
  (possibly empty — a genuine absence).
- The pair (`snapshot_ok`, `snapshot_error`) is what makes a failure and a
  genuine absence distinguishable **by inspection of the payload alone**
  (SC-007): `{snapshot_ok: true, sessions: [], snapshot_error: null}` is an
  empty host; `{snapshot_ok: false, snapshot_error: "…timed out after 90
  seconds", sessions: null}` is a failed collection.

## Entity: Validator (`ETag`)

| Field | Rule |
|---|---|
| Form | `"<16 lowercase hex>"`, double-quoted, **strong** — no `W/` prefix (FR-010). |
| Input | The payload with `ages`, `stale` and `feed` removed, serialised canonically (sorted keys, fixed separators) and hashed with SHA-256, first 16 hex characters. |
| Lifetime | Recomputed at each publish under the lock; identical across any number of reads between publishes (FR-012, and the spec's "validator is unchanged" edge case). |
| Comparison | `If-None-Match` is split on `,`, each entry stripped; a `304` is sent only on an exact match of the current value. `*` matches any current payload. A stale or unparseable value yields a full `200` (the spec's stale-validator edge case). |

## State machine: Feed

```text
                     first successful snapshot publish
   ┌───────────┐ ────────────────────────────────────────► ┌──────────────┐
   │  warming  │                                           │  collecting  │
   └───────────┘ ◄──── (never returns) ──────────────────── └──────────────┘
         │                                                    │        ▲
         │ no read for > GRACE                                │        │
         ▼                                                    ▼        │
   ┌───────────────────────────┐   no read for > GRACE   ┌──────────┐   │
   │ warming, idle             │ ◄────────────────────── │   idle   │───┘
   │ (nothing collected yet    │                          └──────────┘
   │  and nobody is reading)   │      a read of /api/state ───────────►
   └───────────────────────────┘
```

- `warming` is reported while no snapshot has ever succeeded, whatever the
  attention state — it is the more important fact for a reader (FR-008).
- `idle` is reported when the request that is being answered arrived more than
  `GRACE` after the previous one; that same request has already restarted
  collection, so the value means "this read resumed the feed", which is why it is
  a per-request derivation and not stored state.
- A read never waits for a collection in any state (FR-003): the response is
  always assembled from what is already published.
- A collection already running when the feed idles finishes and publishes
  normally (FR-004); idling only prevents the *next* one.

## What deliberately has no entity here

- No client, session or subscription record. Attention is one timestamp; there is
  no registration, no heartbeat and no new endpoint (FR-030).
- No cache, queue or persisted snapshot history. A retained snapshot is the
  single previous value already in memory.
- No new status, severity or verdict (FR-033). `snapshot_ok` is a fact about a
  *collection*, not a judgement about a session.
