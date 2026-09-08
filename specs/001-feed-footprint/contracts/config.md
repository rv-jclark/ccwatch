# Contract: configuration surface

Two new environment tunables, in the same form as the tool's twenty existing
ones (`${CCWATCH_X:-default}` read once near the top of `bin/ccwatch`, exported
into the embedded server by `cmd_serve`), and documented in the same README
table (FR-029).

| Variable | Default | Units | Controls |
|---|---|---|---|
| `CCWATCH_IDLE_GRACE` | `15` | seconds | How long after the last read of `/api/state` the collectors keep running. Below it the feed is active; above it no new collection is started. Five missed 3s polls — long enough that a busy browser never idles an attended feed, short enough that a closed tab stops costing almost at once (FR-001, FR-005). |
| `CCWATCH_SNAPSHOT_TIMEOUT` | `90` | seconds | The ceiling on one sessions-snapshot collection inside `serve`. Was a hard-coded `40`, a 1.7× margin over the measured 24s cold path; 90 is 3.75× (FR-023, SC-008). |

## Rules

- Both are read with `${VAR:-default}` and passed to the embedded python program
  through the environment, alongside the existing `CCWATCH_SELF`, `CCWATCH_WEB`,
  `CCWATCH_BIND_PORT`, `CCWATCH_SEND_TOKEN` and `CCWATCH_ALLOW_KILL`. No new
  command-line flag: these are cadence tunables, and the tool puts cadence
  tunables in the environment.
- `CCWATCH_SNAPSHOT_TIMEOUT` is parsed as a float so the suite can force a
  timeout deterministically (e.g. `0.001`) without waiting 90 seconds.
  Documented in seconds; a fractional value is legitimate but only useful for
  testing.
- A grace period below the pages' 3s poll interval would idle an attended feed
  on every gap between polls. That is the operator's choice to make and is not
  clamped, but the README states the constraint next to the default.
- No other tunable changes. In particular the collector cadences (2s / 60s /
  45s) and the deploy and peer collection timeouts (120s) stay as they are; the
  spec's Assumptions require the attended cadence to be unchanged so the
  before/after duty-cycle figures stay comparable.

## Existing tunables this feature must not disturb

`CCWATCH_PORT`, `CCWATCH_REFRESH`, `CCWATCH_DEPLOY_TTL`, `CCWATCH_BUSY_STALE`,
`CCWATCH_SDK_STALE`, `CCWATCH_CTX_STALE`, `CCWATCH_USAGE_STALE` — the last three
are the staleness windows that withhold readings, and FR-009 requires them to go
on withholding exactly as they do today.
