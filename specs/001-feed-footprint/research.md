# Phase 0 — Research: feed footprint

Six decisions had to be settled before the design could be written. Each one is
recorded with what was measured or read to settle it, because two of them look
like efficiency questions and are actually honesty questions.

No **NEEDS CLARIFICATION** markers were carried in from the spec: its Assumptions
section already fixed the grace period (15s), the snapshot ceiling (90s), the
unchanged collector cadences (2s/60s/45s) and the attention signal (reads of
`/api/state` only). What remained were implementation unknowns, below.

---

## 1. How attention is detected, and how a collector idles

**Decision.** One module-level `LAST_READ` float, stamped with
`time.monotonic()` at the top of the `/api/state` branch of `do_GET` and nowhere
else. Each of the three collector threads runs its own loop holding its own
`next_due`:

```
next_due = 0.0                     # due immediately at start
loop:
    now = time.monotonic()
    if now - LAST_READ > GRACE:    # nobody is reading
        sleep(TICK); continue      # ← next_due is NOT advanced
    if now < next_due:
        sleep(TICK); continue
    value = run(...)               # a collection in flight is never abandoned
    publish(value)
    next_due = time.monotonic() + every
```

`LAST_READ` is seeded to `time.monotonic()` at server start, so a server started
with `--open` warms up once and then idles after the grace period rather than
sitting cold until the browser arrives.

**Rationale.** `TICK` of 0.25s makes resume feel immediate (FR-002) while
costing nothing measurable — the loop does a subtraction and sleeps. Not
advancing `next_due` while idle is what satisfies the spec's stated edge case:
after ten idle minutes the 60s deploy collector is long overdue, so it fires on
the first tick after resume instead of leaving its panel a minute stale.
Checking the gate *before* starting work, rather than interrupting work, is what
satisfies FR-004 for free. The three loops share nothing but `LAST_READ` and the
lock, so idling and resuming stay independent (FR-002, and the spec's
"collectors idle and resume independently" edge case).

**Alternatives considered.**
- *A single supervisor thread that starts and stops the three collectors.* One
  more moving part, one more place for the three cadences to become coupled —
  which is the exact bug the three-thread design was introduced to fix (the
  existing `⚠️` comment: one pass took 14 seconds and the sessions panel went
  stale behind `gh`).
- *Client registration or a heartbeat endpoint.* Forbidden by FR-030 (no new
  endpoint) and unnecessary: a read is already the signal.
- *A condition variable the handler notifies instead of polling a timestamp.*
  Marginally more elegant, materially harder to reason about with three
  independent cadences and a 90s collection that must not be interrupted. The
  timestamp is inspectable, which matters for the assertions.
- *`time.time()` instead of `time.monotonic()`.* A clock step (NTP, sleep/wake)
  would either freeze collection or defeat the gate. `collected_at` still uses
  `time.time()`, because that one has to be comparable to the browser's clock.

## 2. What goes into the validator — and the measurement that decides it

**Decision.** `ETag` is `"<first 16 hex of sha256 of the canonical JSON>"`, a
**strong** validator (no `W/`), computed over the published payload with exactly
three keys removed: `ages`, `stale` and `feed`. Everything else — every session
row, `cpu`, `cpu_delta`, `quiet`, `age`, `rss_mb`, `context`, `host`, `usage`,
`deploys`, `peers`, `warming`, `can_kill`, `snapshot_ok`, `snapshot_error`,
`error`, `collected_at` — is inside it. The hash is computed once per publish
and cached beside the state, not per request.

**Rationale.** The three excluded keys are functions of `now` at request time
and carry no new fact about the host; if they were included, no two reads would
ever share an `ETag` and the not-modified path could never fire (FR-012 says so
explicitly). Everything else is a measurement, and Constitution II and III say a
measurement may not be shown next to a verdict once it has gone stale. Because a
`304` means every one of them is byte-identical, the page can legitimately keep
its whole rendering — there is nothing that could have moved.

**The measurement that forced this, and the deviation it causes.** Reading a
real `ccwatch --json` on the dev host shows each session row carrying `age`,
`quiet`, `cpu`, `cpu_delta`, `rss_mb` and `context.age` — monotonic elapsed
counters that advance on *every* collection whether or not anything happened,
plus a `host` block whose load figures move continuously. So with the snapshot
cadence unchanged at 2s (which the spec's Assumptions require), a truthful
`ETag` changes every 2s, and a page polling at 3s will see a fresh body nearly
every time. **SC-005's "at least 90% of reads answered as unchanged" is
therefore not attainable for an attended page**, and the plan records that as a
deviation rather than meeting it by cheating the validator. The mechanism still
pays where content genuinely is frozen: while the feed is idle or warming, on the
extra read a page issues when it becomes visible or is resized, and for a second
tab reading inside one cadence. The README will record the measured hit rate.

**Alternatives considered.**
- *Exclude the volatile measurements from the validator.* Buys the 90% figure by
  letting a page show a `quiet` of 6m when the truth is 8m, next to `HUNG?`.
  That is Constitution II and III, and it is the failure mode the tool exists to
  prevent. Rejected outright.
- *Re-express every elapsed field as an absolute instant so the page derives it.*
  Raises the hit rate on a fully idle host, but any single busy session moves
  `cpu`/`cpu_delta` every sample so the `ETag` churns anyway; and it moves the
  computation of a measurement into the view, against Constitution XI. Rejected,
  except for the three *panel* instants, where it is the mechanism that makes a
  `304` honest at all (decision 3).
- *`Last-Modified` instead of `ETag`.* One-second resolution against a 2s
  cadence, and it is a weak validator. FR-010 asks for a strong one.
- *Hash of the serialised body including whitespace.* Same result but recomputed
  per request; hashing at publish time is cheaper and makes the "and only when
  the content changes" property obvious by construction.

## 3. Keeping panel freshness true across a `304`

**Decision.** Add `collected_at: {snapshot, deploys, peers}` — absolute epoch
seconds (`time.time()`), or `null` where that collector has never published — to
the payload, alongside the existing relative `ages` map, which stays for
backward compatibility. The page keeps the last full body plus its `ETag`,
issues `If-None-Match` itself, and on a `304` skips parsing and redrawing but
still repaints the freshness footer, computing each panel's age as
`Date.now()/1000 - collected_at[k]`.

**Rationale.** This is the whole of FR-013. A `304` carries no body, so a page
that read `ages` from the last body would state an age frozen at the moment that
body arrived — a stale reading presented as current, which is the exact failure
Constitution III names. Absolute instants are immune: the age is recomputed
against the local clock on every repaint, whether the last response was a `200`
or a `304`. Server and client are the same machine over loopback, so there is no
clock skew to account for. The footer's existing `"updated <time>"` keeps its
current meaning — the time of this successful read — so the rendering is
unchanged (FR-034) while the panel ages beside it carry the data's true age.

**Alternatives considered.**
- *Carry the ages in headers on the `304`.* Works (a `304`'s headers are
  readable from `fetch`), but it puts the same fact in two formats and makes the
  page's freshness path depend on which status it got. Rejected as needless.
- *Let the browser manage revalidation (`cache: "no-cache"`).* The browser then
  answers from its store and `fetch` returns an opaque `200` with the *old*
  body, so JS cannot tell a revalidation from a fresh response and would display
  the old `ages` as current. This is a real trap and the reason FR-011 is worded
  around the client doing "no parsing and no redrawing": it needs to see the
  `304`. Rejected.
- *Drop `ages` and keep only `collected_at`.* A payload-shape break for any
  scripted consumer, for no gain. The spec's Assumptions ask for additive keys.

## 4. How the request is made, so a real `304` reaches the page

**Decision.** Server sends `Cache-Control: no-cache, private` and `ETag` on
`/api/state`. Both pages call `fetch("/api/state", {headers: lastEtag ?
{"If-None-Match": lastEtag} : {}})` with the `cache` option **omitted** — the
current `{cache: "no-store"}` is removed. Page HTML and `/api/transcript` keep
`no-store`, unchanged.

**Rationale.** `no-cache` is precisely FR-014: storage permitted, use without
revalidation forbidden. Dropping `cache: "no-store"` is FR-015. A request that
carries its own conditional header is not served from the browser's cache — the
Fetch/HTTP-cache rules treat it as a conditional request and forward it — so the
`304` is surfaced to JS with its status and headers intact, which is what FR-011
needs. Verified against the actual runtime rather than assumed: a
`BaseHTTPRequestHandler` `send_response(304)` with `ETag` and `Cache-Control`
and no body produced a well-formed `HTTP/1.0 304 Not Modified` with
`size_download=0` under `curl`, and the handler's HTTP/1.0 default closes the
connection so there is no framing ambiguity from the absent body.

The two responses that keep `no-store` keep it for constitutional reasons, not
consistency: the page HTML carries the per-run send token (Constitution IX — a
token in a disk cache is a token that outlives the run), and `/api/transcript`
carries transcript content (Constitution X).

**Residual risk, and why it is not a correctness risk.** If some browser were to
reuse its cache despite the conditional header, the page would receive a `200`
with a body it already had and would redraw it — wasted work, but the freshness
footer is computed from `collected_at` against the local clock, so nothing false
is displayed. The failure mode is efficiency, not a wrong reading.

**Alternatives considered.**
- *Keep `cache: "no-store"` and still send `If-None-Match`.* Would probably
  work, but FR-015 rules it out and it would leave the server's `no-cache`
  pointless.
- *`ETag` on `/api/transcript` too.* Out of scope, and the transcript response
  must not be stored at all.

## 5. Distinguishing a failed snapshot from an empty host

**Decision.** Delete the `snapshot_ok()` transform that fabricates
`{"sessions": [], "unfinished": [], "error": …}`. Instead:

- Publish success as today, and set `snapshot_ok: true`, `snapshot_error: null`,
  and `collected_at.snapshot` to the collection instant.
- On failure **with** a prior success: leave the previous snapshot content and
  its `collected_at` untouched — so its age keeps growing truthfully — and set
  `snapshot_ok: false` and `snapshot_error: "<reason>"` (FR-025).
- On failure with **no** prior success: `sessions: null`, `unfinished: null`,
  `snapshot_ok: false`, `snapshot_error: "<reason>"`, and `warming` stays
  `true` (FR-026, FR-008).
- Mirror the reason into the existing top-level `error` key, which is what
  `web/index.html` already renders in its footer, so the fact surfaces today
  without a rendering change (FR-027).
- Raise the collection ceiling from a hard-coded 40s to `CCWATCH_SNAPSHOT_TIMEOUT`,
  default 90.

**Rationale.** `warming` today flips to `false` on the first *publish*, including
a fabricated failure, which is why a timed-out cold collection currently draws
"No live sessions" — a failure that looks exactly like an absence
(Constitution IV) built out of a status nobody read (Constitution V). Redefining
`warming` as "no snapshot has ever succeeded" makes the never-succeeded case
render as today's honest "taking the first snapshot…" instead of a fabricated
empty list, with the reason carried in the payload for the next roadmap entry to
draw. 90s is 3.75× the measured 24s cold path, satisfying SC-008's 3× floor;
the old 40s was 1.7×, which the measurement shows is too thin.
`subprocess.TimeoutExpired` stringifies as `Command '[…]' timed out after 90
seconds`, so the reason is specific without any extra work and an assertion can
match on it.

**Alternatives considered.**
- *`sessions: []` plus a failure flag.* The empty array is still an assertion of
  fact about the host, and every consumer that does `s.sessions || []` reads it
  as one. FR-026 and Constitution VI forbid it.
- *Flip `warming` to `false` on a failed first collection and rely on the error
  key.* The map view does not render `error`, so the result would still be "No
  live sessions" — the reported bug, unfixed.
- *Keep 40s and retry on timeout.* Retrying a 24s collection on a loaded host
  makes the load worse; the ceiling is the honest knob.

## 6. Pausing the pages, and guarding against a repainting loop

**Decision.** Replace the bare `setInterval(tick, 3000)` in each page with a
single visibility-aware scheduler, and route *every* periodic call through it —
including `map.html`'s 5s open-conversation timer:

```js
let timer = null;
function every(ms, fn) { … }        // the one and only setInterval in the file
function resume() { if (document.hidden) return; fn(); start(); }
document.addEventListener("visibilitychange", …);
if (!document.hidden) resume();     // a page that loads hidden does not poll
```

On becoming visible the page fires once immediately and then restarts the
interval (FR-017, FR-005's grace makes this safe). `map.html`'s `resize`
handler is guarded with `if (!document.hidden)`. The conversation timer starts
only while the inspector is open *and* the page is visible, and is cleared on
both close and hide (FR-018).

The guard for FR-020–FR-022 is a **static assertion over `web/*.html`**: no
occurrence of `requestAnimationFrame`, and exactly one occurrence of
`setInterval(` per file — the one inside the scheduler. Each page must also
mention `visibilitychange`.

**Rationale.** `document.hidden` plus `visibilitychange` is the only signal
available without a dependency, and it is what the spec's last Assumption
describes: if a browser did not report visibility the page would simply keep
polling as it does today. Funnelling all periodicity through one helper is what
makes FR-022 testable at all — "no animation loop" is otherwise a property no
grep can check. A count-based assertion is blunt, but it is deterministic, needs
no browser in the suite, and fails loudly the moment someone adds a second timer
or a frame loop, which is exactly the regression FR-022 anticipates from the
renderer the next roadmap entries add.

Verified by reading both pages: there is no `requestAnimationFrame` today, and
the only motion is the four declarative CSS keyframe animations on
`.busy .body`, `.waiting .arm`, `.waiting .bubble` and `.hung .body` — all
status-carrying, all already suppressed under
`@media (prefers-reduced-motion: reduce)`. FR-020–FR-022 lock in the current
position rather than change it.

**Alternatives considered.**
- *A headless-browser assertion.* Would test the real behaviour, but it means a
  browser dependency in the suite, against FR-030 and the "no dependencies"
  constraint. The visibility behaviour is validated by hand per
  `quickstart.md`; the static assertion is what guards the regression.
- *`blur`/`focus` instead of `visibilitychange`.* A page can be visible and
  unfocused on a second monitor — exactly the use this tool is built for — and
  pausing then would be a regression, not an optimisation.
- *`IntersectionObserver`/`Page Lifecycle`.* Solves a problem this page does not
  have, at the cost of more surface.

---

## Measurement method for FR-028 (settled here so the figures are comparable)

Cumulative CPU of the whole server tree over a 60s window, in three conditions,
taken on the dev host with its live session population and the population size
recorded alongside — as the existing README figures do:

```bash
( CCWATCH_PORT=8799 ./bin/ccwatch serve >/dev/null 2>&1 & p=$!; sleep 60;
  kill "$p"; wait "$p" 2>/dev/null; times )
```

The subshell's `times` reports its own and its **reaped children's** CPU, which
is what makes the transient `jq`/`ps`/`git` forks visible — `ps -o time=` on the
python pid alone misses them, and that is the mistake that would make the "after"
figure look better than it is. Divide the children's CPU by 60 for the duty
cycle. Conditions: (a) no client, (b) a page open in a hidden tab, (c) a page
open and visible. Condition (c) is the one that must be reported unchanged
rather than improved (SC-003).
