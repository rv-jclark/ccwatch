# Implementation Plan: Feed — idle-aware refresh, visibility-paused polling, conditional responses

**Branch**: `001-feed-footprint` | **Date**: 2026-09-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/001-feed-footprint/spec.md`

## Summary

`ccwatch serve` runs three collector threads on fixed cadences for as long as
the process lives, whether or not anything is reading. Make the cost follow the
attention: gate each collector on a recent read of `/api/state`, pause both
pages' polling while they are hidden, answer an unchanged payload with `304`,
and — separately — stop a timed-out snapshot from being published as an empty
session list.

The whole change lands in three places: the embedded python HTTP server inside
`cmd_serve` (`bin/ccwatch`), the polling and freshness code in `web/index.html`
and `web/map.html`, and the `serve` section of `tests/run.sh`. No collector's
computation changes, no verdict changes, no endpoint is added, and neither page
gains or loses a pixel for the same payload.

Three design decisions carry the feature:

1. **Attention is a timestamp, not a registration.** `/api/state` stamps
   `LAST_READ`; each collector loop refuses to *start* a collection when
   `LAST_READ` is older than `CCWATCH_IDLE_GRACE` (default 15s). Each loop keeps
   its own `next_due`, which is not advanced while idle, so a resumed 60s
   collector fires at once instead of waking a minute later.
2. **The validator covers every measurement in the body.** `ETag` is a hash of
   the published payload minus the fields that are recomputed per request
   (`ages`, `stale`, `feed`). A `304` therefore guarantees that no measured
   number changed — the strongest form of Constitution III available here.
   Panel freshness survives a `304` because the payload now also carries
   absolute `collected_at` instants, from which the page recomputes each panel's
   age against its own clock (same machine, no skew).
3. **A failed snapshot is a fact, not an empty set.** `snapshot_ok`,
   `snapshot_error` and a preserved previous snapshot replace today's fabricated
   `{"sessions": [], "unfinished": [], "error": …}`, and `warming` now means
   "no snapshot has ever *succeeded*".

## Technical Context

**Language/Version**: bash 3.2 (macOS system bash) for `bin/ccwatch`; python3
3.9.6 (macOS system python, confirmed on the dev host) for the embedded HTTP
server, passed with `python3 -c`; vanilla ES2020 browser JS with no framework in
`web/*.html`.

**Primary Dependencies**: none new. Existing: `python3`, `jq`, `ps`, `stat`,
`git`, optional `gh`; `curl` and `shellcheck` for the suite. No package
manifest, no bundler, no CDN fetch — the constitution forbids all three.

**Storage**: none new. Server state stays in memory (`STATE` under one lock);
runtime state remains `~/.claude/ccwatch/` and the CPU-sample cache in
`$TMPDIR`. Nothing new is written to disk.

**Testing**: `./tests/run.sh` only — `shellcheck -x -S warning`, then the
assertion suite. Hermetic: fabricated `~/.claude` under `$WORK` via
`CLAUDE_CONFIG_DIR`, liveness probe substituted via `CCWATCH_FAKE_PS`, real
loopback servers on a probed free port, all reaped on exit.

**Target Platform**: macOS (Darwin) only; loopback HTTP on `127.0.0.1`; Chrome
and Safari as the page runtimes.

**Project Type**: single-file bash CLI (~3252 lines) plus two static pages
served by an embedded python3 `ThreadingTCPServer`. No `src/` tree, no build
step.

**Performance Goals**: SC-001/SC-002 — under 1% of one core over 60s with no
client and with a hidden page, down from ~50%. SC-004 — first read after idle
answered under 100ms. SC-005 — `304` for reads of an unchanged payload (see the
deviation recorded under Complexity Tracking for the 90% figure).

**Constraints**: no new dependency, build step, package manifest or endpoint
(FR-030); bash 3.2 forms only, embedded programs passed as arguments and never
on stdin (FR-031); `shellcheck -x -S warning` clean for `bin/ccwatch` and
`tests/run.sh` at unchanged severity; write-endpoint token and `Origin` checks
and the `--allow-kill` opt-in untouched (FR-032); no collector computation,
status, severity or verdict altered (FR-033); pages pixel-identical for the same
payload (FR-034).

**Scale/Scope**: one user, loopback only, ~18 live sessions on the measurement
host; snapshot ~2.1s warm and ~24s cold under load. Touched surfaces:
`bin/ccwatch` `serve` section (~330 lines), `web/index.html` (~40 lines),
`web/map.html` (~60 lines), `tests/run.sh` (~120 new lines), `README.md`
(configuration table, performance section, mutation table).

No **NEEDS CLARIFICATION** remains: the spec's Assumptions section fixed every
open value (15s grace, 90s ceiling, unchanged cadences, attention inferred from
`/api/state` reads only).

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1. Both passes
below.*

| Principle | Bearing on this feature | Verdict |
|---|---|---|
| I. Never claim on one signal | No new verdict, badge or state; corroboration logic untouched | PASS (N/A) |
| II. Print the measurement next to the verdict | A `304` must not let `quiet`/`cpu`/`cpu_delta` go stale beside `HUNG?`. Mitigated by hashing every measured field into the validator — a `304` means none of them moved | PASS |
| III. Stale reading withheld, not annotated | Two new ways to lie (resumed collection, cached body). Closed by: `collected_at` absolute instants so age is always recomputed against now; validator covers all measurements; `warming` until a snapshot *succeeds*; FR-009 leaves every existing staleness window intact | PASS |
| IV. Failure must never look like an absence | The feature *fixes* a live violation: a timed-out snapshot currently publishes `sessions: []`. Replaced by `snapshot_ok:false` + `snapshot_error` + retained prior snapshot | PASS (repairs) |
| V. Never invent a status you did not read | `snapshot_ok()`'s fabricated empty result is removed; no default arm manufactures a session list | PASS |
| VI. Say nothing rather than guess | Never-succeeded snapshot publishes `sessions: null` with a reason, not `[]` | PASS |
| VII. Colour is never the only carrier | No rendering, colour or figure change | PASS (N/A) |
| VIII. Delivery is observed | `send`/`kill` paths untouched | PASS (N/A) |
| IX. Loopback is not a security gate | Token and `Origin` checks untouched. Page HTML keeps `Cache-Control: no-store` because it carries the per-run token — only `/api/state` moves to `no-cache`. See Complexity Tracking for the cacheability trade | PASS with recorded trade |
| X. Transcripts are sensitive | `/api/transcript` keeps `no-store` and is excluded from the attention signal (FR-006); `convo` untouched | PASS |
| XI. One code path computes status | `/api/state` still shells out to `ccwatch --json`, `deploys --json`, `peers --json`. The page gains arithmetic on `collected_at` only — formatting a duration, not deriving a status. Per-session `quiet`, `cpu`, `sev` stay server-computed and stay inside the validator | PASS |
| XII. Normal conditions are silent | No new always-on line; `feed` is a payload field, not a banner | PASS |
| XIII. Position is stable; only status moves | No layout, ordering or grouping change | PASS (N/A) |
| bash 3.2 / BSD `stat`,`ps` / `python3 -c` | New code is embedded python, browser JS and two `${VAR:-default}` lines. No `mapfile`, no `declare -A`, no case-modification expansions, nothing on stdin | PASS |
| No build step, no dependencies | Two env tunables and additive payload keys | PASS |
| Test discipline | Hermetic fixtures, ≥3 mutation-checked assertions with README rows, `TALLY_FLOOR` raised, servers reaped, timing-dependent assertions `t_skip` with a stated reason | PASS |

**Gate result: pass.** One accepted trade and one spec deviation are recorded in
Complexity Tracking; neither is a principle violation. Re-evaluated after Phase 1
with the data model and contracts in hand — unchanged.

## Project Structure

### Documentation (this feature)

```text
specs/001-feed-footprint/
├── plan.md              # This file
├── research.md           # Phase 0 output — the six decisions and what was rejected
├── data-model.md         # Phase 1 output — payload and server-state entities
├── quickstart.md         # Phase 1 output — how to validate the feature end to end
├── contracts/
│   ├── api-state.md      # GET /api/state: headers, status codes, payload, validator scope
│   └── config.md         # the two new environment tunables
├── checklists/
│   └── requirements.md   # written by /speckit-specify
└── tasks.md              # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
bin/ccwatch          # the whole tool. This feature touches only the `serve`
                     # section (banner "serve", ~line 2608) plus two tunable
                     # defaults near the other CCWATCH_* defaults at the top:
                     #   cmd_serve()          — export the two new tunables
                     #   embedded python3 -c  — LAST_READ + idle gate,
                     #                          next_due per collector,
                     #                          ETag/If-None-Match on /api/state,
                     #                          snapshot_ok / snapshot_error,
                     #                          collected_at instants
web/index.html       # table view: visibility-gated poll scheduler, conditional
                     # request, freshness repaint from collected_at
web/map.html         # map view: the same, plus the open-conversation timer and
                     # the resize handler
tests/run.sh         # new assertions in the `serve` section; TALLY_FLOOR raised
README.md            # configuration table, Performance section (duty cycle
                     # before/after, three conditions), mutation table rows
```

**Structure Decision**: the repository has no `src/` tree and no build step, and
the constitution forbids introducing either. The layout above is the existing
one; this feature adds no file outside `specs/`. Work is grouped by the four
files above rather than by layer, because `bin/ccwatch` is one script organised
into banner-commented sections and `serve` is the only section that changes.

## Complexity Tracking

> Recorded because both items are trades a reader should be able to audit, not
> because a gate failed.

| Item | Why accepted | Alternative rejected because |
|---|---|---|
| `/api/state` becomes browser-cacheable (`Cache-Control: no-cache, private`), so session and repo names may be written to the browser's cache store | FR-014 requires storage-for-revalidation, and FR-011 needs a real `304`. Exposure is bounded: loopback only, `private`, and the two genuinely sensitive responses — token-bearing page HTML and `/api/transcript` — keep `no-store` (Constitution IX, X) | `no-store` on `/api/state` forbids storage outright, which FR-015 explicitly rules out and which would make revalidation impossible |
| **Deviation from SC-005**: the 90%-unchanged target is not attainable for an attended page | The snapshot body embeds monotonic elapsed measurements (`age`, `quiet`, `cpu`, `cpu_delta`, `rss_mb`, `context.age`) plus host load. A truthful validator (FR-012, Constitution II/III) must cover them, so a new collection every 2s produces a new `ETag` and a 3s poll sees new content nearly every time. `304`s land where content genuinely is frozen: while the feed is idle or warming, on the resize/visibility-resume re-read, and for a second tab reading inside one cadence. The plan implements the mechanism honestly and the README will record the *measured* hit rate rather than assert 90% | Excluding measurements from the validator would buy the hit rate by presenting a stale `quiet` or `cpu` beside a verdict — precisely Constitution II and III. Lengthening the snapshot cadence is out of scope per the spec's own Assumptions. Rewriting elapsed fields as absolute instants throughout the payload would raise the rate on a quiet host but still churn on any host with a busy session, and it would move a measurement's computation into the view (Constitution XI) |
