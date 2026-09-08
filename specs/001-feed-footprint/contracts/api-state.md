# Contract: `GET /api/state`

The only interface this feature changes. `ccwatch serve` exposes it on
`127.0.0.1:<port>` and both pages are its only intended clients; `curl` is a
supported reader and the assertion suite uses it.

**No endpoint is added or removed** (FR-030). `/`, `/map`, `/api/transcript`,
`/api/send` and `/api/kill` are unchanged by this feature, including their
authorisation and their `Cache-Control: no-store`.

## Side effect: this endpoint is the attention signal

A request to `/api/state` — and no other path — stamps the feed's attention
timestamp, which keeps all three collectors running for `CCWATCH_IDLE_GRACE`
seconds (FR-001, FR-006). The stamp happens whether the response is `200` or
`304`, and before the response is built.

A request never waits for a collection (FR-003). It is answered from what is
already published, in every feed state, including the first request after an
idle period.

## Request

```http
GET /api/state HTTP/1.1
If-None-Match: "3f8a1c0d7b4e2916"        ; optional
```

| Header | Required | Meaning |
|---|---|---|
| `If-None-Match` | no | A validator previously received from this endpoint. A comma-separated list is accepted; `*` matches any current payload. Absent, stale, or unparseable ⇒ a full `200`. |

No query parameters. No body. No authentication — as today; this is a read-only
endpoint on loopback, and the write endpoints' token and `Origin` checks are
untouched (FR-032).

## Responses

### `200 OK` — a payload the client does not already hold

```http
HTTP/1.0 200 OK
Content-Type: application/json
ETag: "3f8a1c0d7b4e2916"
Cache-Control: no-cache, private
Content-Length: <n>
```

### `304 Not Modified` — the client's copy is current

```http
HTTP/1.0 304 Not Modified
ETag: "3f8a1c0d7b4e2916"
Cache-Control: no-cache, private
```

Zero-byte body, no `Content-Type`, no `Content-Length` (FR-011). Verified against
python 3.9's `BaseHTTPRequestHandler`: `curl` reports `size_download=0` and the
HTTP/1.0 connection close leaves no framing ambiguity.

### Header contract

| Header | Value | Requirement |
|---|---|---|
| `ETag` | `"<16 lowercase hex>"`, strong (never `W/`) | FR-010. Present on both `200` and `304`. Changes when, and only when, the collected content changes (FR-012) — `ages`, `stale` and `feed` are excluded from its input. |
| `Cache-Control` | `no-cache, private` | FR-014: storage for revalidation permitted, use without revalidating forbidden. `private` because the payload names repositories and sessions. **Not** `no-store` — that would make revalidation impossible. |

## Payload

Additive to today's shape: every existing key keeps its name and type. Full
field rules, including which keys are inside the validator, are in
[../data-model.md](../data-model.md).

```jsonc
{
  // — unchanged —
  "sessions": [ /* … as `ccwatch --json` */ ],   // may be null: see below
  "unfinished": [ /* … */ ],                      // may be null: see below
  "unfinished_old": 0,
  "usage": { /* … */ },
  "host": { /* … */ },
  "deploys": { /* … as `ccwatch deploys --json` */ },
  "peers":   { /* … as `ccwatch peers --json` */ },
  "can_kill": false,
  "error": null,                 // now also carries a snapshot failure reason
  "warming": false,              // MEANING NARROWED: no snapshot has SUCCEEDED
  "ages":  { "snapshot": 1.9, "deploys": 43.2, "peers": 12.0 },  // or null each
  "stale": 1.9,                  // alias of ages.snapshot

  // — new —
  "snapshot_ok": true,           // did the last snapshot attempt succeed
  "snapshot_error": null,        // if not, why, verbatim
  "collected_at": { "snapshot": 1757203200.4, "deploys": null, "peers": null },
  "feed": "collecting"           // "warming" | "idle" | "collecting"
}
```

### The three shapes a reader must be able to tell apart

**A host with genuinely no live sessions** — an absence, asserted as a fact:

```jsonc
{ "snapshot_ok": true, "snapshot_error": null, "warming": false,
  "sessions": [], "unfinished": [], "collected_at": {"snapshot": 1757203200.4, …} }
```

**A snapshot that failed, with an earlier one to fall back on** — the known data
is kept with its true (growing) age, and the failure is stated beside it
(FR-025):

```jsonc
{ "snapshot_ok": false,
  "snapshot_error": "--json: Command '[…]' timed out after 90 seconds",
  "error": "--json: Command '[…]' timed out after 90 seconds",
  "warming": false,
  "sessions": [ /* the last successful snapshot */ ],
  "collected_at": {"snapshot": 1757203041.7, …},   // NOT advanced by the failure
  "ages": {"snapshot": 158.7, …} }
```

**A snapshot that has never succeeded** — no empty set is asserted (FR-026,
FR-008):

```jsonc
{ "snapshot_ok": false,
  "snapshot_error": "--json: Command '[…]' timed out after 90 seconds",
  "error": "--json: Command '[…]' timed out after 90 seconds",
  "warming": true,
  "sessions": null, "unfinished": null,
  "collected_at": {"snapshot": null, …}, "ages": {"snapshot": null, …} }
```

`sessions: []` therefore means "there are no sessions" and `sessions: null`
means "nobody knows", which is the whole of SC-007: the two are distinguishable
from the payload alone, with no reference to anything outside it.

## Client contract (both pages)

Both `web/index.html` and `web/map.html` must:

1. Send `If-None-Match` with the `ETag` of the body they hold, and **not** set
   `cache: "no-store"` on the request (FR-015).
2. On `304`: do no JSON parsing and no content redraw (FR-011); repaint only the
   freshness footer.
3. Compute each panel's displayed age as `Date.now()/1000 - collected_at[key]`,
   never from a stored `ages` value (FR-013). Server and page are the same
   machine, so the clocks agree.
4. Never render `feed`, `ages` or `stale` from a stored body.
5. Stop every periodic request while `document.hidden`, request state once
   immediately on becoming visible, and not begin polling at all if the page
   loads hidden (FR-016 – FR-019).

## Compatibility

A consumer written against today's payload keeps working, with one behaviour
change it should welcome: where it previously received a fabricated
`sessions: []` after a collection timeout, it now receives `sessions: null` with
a stated reason. Any consumer doing `sessions || []` degrades to today's
rendering rather than breaking — which is what lets this entry ship without a
rendering change (FR-027).
