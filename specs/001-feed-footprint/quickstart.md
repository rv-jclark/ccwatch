# Quickstart — validating the feed footprint

Runnable checks that prove the feature works end to end. Field-level detail is
in [contracts/api-state.md](./contracts/api-state.md) and
[data-model.md](./data-model.md); this file is the run guide.

## Prerequisites

- macOS, `python3`, `jq`, `curl`. No install step and no dependencies to fetch.
- Run everything from the repository root.
- **Sandbox note.** In a restricted sandbox `mktemp` is denied and roughly 13
  assertions (`resume`, `peers`, `serve`) fail with empty output. That is the
  sandbox, not a regression — re-run with the sandbox off before believing a
  failure.
- Scenarios 2–6 start a real server. Every one of them ends by reaping it; a
  leaked `serve` holds a port a later run may pick.

```bash
PORT=8799        # anything free; 8787 is the default and may be in use
```

## 1. The suite

```bash
./tests/run.sh
```

Expected: `shellcheck` clean for `bin/ccwatch` and `tests/run.sh` at unchanged
severity, every assertion passing or skipped-with-a-reason, and the counted
tally at or above the raised `TALLY_FLOOR`. The three new assertion groups —
idle gating, not-modified, failed-versus-empty — must each be
**mutation-checked** and must each add a row to the README mutation table
(FR-036, FR-037).

## 2. Collection stops when nothing is reading (US1, FR-001)

```bash
CCWATCH_IDLE_GRACE=3 ./bin/ccwatch serve --port "$PORT" &
sleep 8                                     # warm up, then let the grace lapse
A=$(curl -s "http://127.0.0.1:$PORT/api/state" | jq -r '.ages.snapshot')
sleep 10                                    # nobody reads in this window
B=$(curl -s "http://127.0.0.1:$PORT/api/state" | jq -r '.ages.snapshot')
echo "age before the quiet window: $A   age after: $B"
```

Expected: `B` is roughly `A + 10` — the snapshot did not move while nobody was
reading. Before this change `B` would be under 2 seconds.

Then, still with that server running:

```bash
sleep 4 && curl -s "http://127.0.0.1:$PORT/api/state" | jq -r '.ages.snapshot'
```

Expected: a small number — the read above resumed collection (FR-002), and
`.feed` on the first read after a quiet window reports `idle`.

## 3. A read is never made to wait (FR-003, SC-004)

Immediately after an idle period, with the server from scenario 2:

```bash
sleep 10
curl -s -o /dev/null -w 'first read after idle: %{time_total}s\n' \
  "http://127.0.0.1:$PORT/api/state"
```

Expected: well under 0.1s. It is answered from the last published data, not from
a collection started by the request.

## 4. An unchanged payload transfers no body (US2, FR-010 – FR-013)

```bash
E=$(curl -s -o /dev/null -D - "http://127.0.0.1:$PORT/api/state" \
     | awk -F'"' '/^ETag:/{print $2}')
curl -s -o /dev/null -w 'status=%{http_code} bytes=%{size_download}\n' \
  -H "If-None-Match: \"$E\"" "http://127.0.0.1:$PORT/api/state"
```

Expected: `status=304 bytes=0`. Both reads must land inside one collection cycle
for the validator to still match — with the 2s snapshot cadence, back-to-back
`curl` calls do; if a collection lands between them you get `200` and should
simply repeat.

Then confirm the two properties that make it honest:

```bash
# a stale validator gets a full body, not a 304
curl -s -o /dev/null -w 'stale validator: %{http_code}\n' \
  -H 'If-None-Match: "0000000000000000"' "http://127.0.0.1:$PORT/api/state"

# ages are NOT in the validator: two reads with no new data share an ETag
# even though their reported ages differ
curl -s -D - -o /dev/null "http://127.0.0.1:$PORT/api/state" | grep -i '^etag\|^cache-control'
```

Expected: `200` for the stale validator; `ETag` unchanged between reads with no
new collection; `Cache-Control: no-cache, private`.

Reap the server before moving on:

```bash
kill %1 2>/dev/null; wait %1 2>/dev/null
```

## 5. A failed snapshot is not an empty host (US3, FR-024 – FR-026, SC-007)

```bash
CCWATCH_SNAPSHOT_TIMEOUT=0.001 ./bin/ccwatch serve --port "$PORT" &
sleep 6
curl -s "http://127.0.0.1:$PORT/api/state" \
  | jq '{snapshot_ok, snapshot_error, warming, sessions, feed}'
kill %1 2>/dev/null; wait %1 2>/dev/null
```

Expected: `snapshot_ok: false`, `snapshot_error` naming the timeout,
`warming: true`, `sessions: null`. Compare with a healthy server on a host with
no live sessions, which must read `snapshot_ok: true`, `snapshot_error: null`,
`sessions: []` — the two payloads distinguishable by inspection alone.

Also confirm the retention rule: start normally, let one snapshot succeed, then
force failures. `sessions` must keep the last successful list and
`ages.snapshot` must keep growing rather than resetting (FR-025).

## 6. The duty cycle, three conditions (FR-028, SC-001 – SC-003)

The figure that justifies the whole entry. Measure the **whole tree's** CPU —
`ps -o time=` on the python pid alone misses the transient `jq`/`ps`/`git`
forks, which is most of the cost:

```bash
( CCWATCH_PORT="$PORT" ./bin/ccwatch serve >/dev/null 2>&1 & p=$!;
  sleep 60; kill "$p"; wait "$p" 2>/dev/null; times )
```

`times` prints the subshell's own and its reaped children's CPU; divide the
children's figure by 60 for the duty cycle. Run it three ways:

| Condition | Expectation |
|---|---|
| no client at all | under 1% of one core (SC-001) — from ~50% |
| a page open in a hidden tab | the same as no client (SC-002) |
| a page open and visible | **reported, not improved** (SC-003) — and the panel freshness and update interval must be indistinguishable from before the change |

Record all three in the README's Performance section with the live session
population alongside, as the existing figures there do, before and after.

## 7. The pages pause when unattended (US1, FR-016 – FR-019, SC-009)

By hand, in a browser, on both `http://127.0.0.1:$PORT/` and `/map`:

1. Open the page, then switch to another tab. In devtools → Network, requests to
   `/api/state` stop. After the grace period the server's CPU drops to the
   idle figure.
2. Switch back. A request fires **immediately**, before the next 3s tick, and
   the data shown was collected after the return (SC-009).
3. Open a page directly into a background tab (⌘-click a link to it). No
   `/api/state` request is made until it is brought to the front (FR-019).
4. On the map, open an agent's conversation, switch tabs: the 5s transcript
   re-read stops too (FR-018), and resumes on return.
5. Two tabs, one visible and one hidden: collection continues, because the feed
   stays active for as long as *any* client is reading.
6. With reduced motion enabled in System Settings, the working/blocked/suspect
   figures stay still (FR-021).

## 8. Nothing repaints between updates (FR-020 – FR-022, SC-010)

```bash
grep -c requestAnimationFrame web/index.html web/map.html   # expect 0 and 0
grep -c 'setInterval(' web/index.html web/map.html          # expect 1 and 1
grep -c visibilitychange web/index.html web/map.html        # expect ≥1 each
```

One `setInterval` per page, inside the single visibility-aware scheduler, is the
invariant the suite guards so a later entry's renderer cannot reintroduce a loop
unnoticed.

## 9. Nothing else moved

```bash
./bin/ccwatch once      # unchanged output
./bin/ccwatch doctor    # still trustworthy
```

Both pages must be pixel-identical to their current rendering for the same
payload (SC-012), and no status, severity or verdict may have changed (FR-033).
