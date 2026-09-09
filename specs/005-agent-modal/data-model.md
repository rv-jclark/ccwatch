# Data Model: Map — per-agent modal

**Feature**: `005-agent-modal` | **Plan**: [plan.md](./plan.md) |
**Research**: [research.md](./research.md)

Every entity here is either a verbatim slice of the `/api/state` payload, a
fixed join of verbatim payload values, or a rendering decision — never a
status, a severity, a verdict or an ordering computed in the page
(FR-009, principle XI). Nothing in this model is persisted: the modal has no
stored record and adds no `localStorage` key.

---

## §1 Subject — the identity the modal was opened on

```
Subject { sid: string, name: string, opener: {sid: string, kind: "row" | "figure"} }
```

Captured by `openModal(sid, name, kind)` and **held independently of the
payload** so the panel can still say something when the row disappears
(FR-045, D13). `sid` is the only key ever used to look the row up again;
`name` is what the header and the tombstone sentence use once the row is gone.

Exactly one `Subject` exists at a time, or none. Opening a second session
replaces it wholly, together with the in-progress message, the confirmation
step and the outcome text (FR-006).

`opener` is what close-focus is restored from, by identity rather than by node
(FR-037, D5). Restoration order: the live row for `opener.sid` → the live
figure for `opener.sid` → `#rosterlist` if it has rows → `#world`.

## §2 SessionRow — the sole source of every stat

One entry of `/api/state`'s `sessions` array (`bin/ccwatch:896-936`). The
fields this feature reads, and nothing else:

| Field | Used for |
|---|---|
| `sid` | subject key, session-id stat, `claude --resume <sid>`, `/api/transcript`, `/api/send`, `/api/kill` |
| `name` | header, kill confirmation, tombstone, peer-edge matching |
| `token`, `note`, `sev` | via `rowFields` — the status word, the measurement, the ask panel's waiting case |
| `quiet`, `waited` | via `rowFields` for the measurement; directly for the labelled `silent`/`waiting` stat (D9) |
| `age` | via `rowFields` |
| `repo`, `branch` | via `rowFields` (`where`), which is exactly `"no repo"` when `repo` is null (principle VI) |
| `context.used_percentage` | via `rowFields` (`ctx`), volatile-gated |
| `rss_mb` | via `rowFields` (`mem`), volatile-gated — including the kill figure (FR-033, D10) |
| `pipeline.{phase,status,crashed}` | via `rowFields` (`pipeline`); `status === "running"` also drives the kill warning (FR-031) |
| `questions[]` | the ask panel: `question`, `options[].label`, `options[].description` |
| `entrypoint` | the embedded-SDK transcript sentence — `"sdk-ts"` writes no transcript (D15) |

Not read: `pid`, `cwd`, `project`, `version`, `status_raw`, `cpu`, `cpu_delta`,
`psev`, `context.{window,cost_usd,model,effort,age}`.

## §3 PanelFields — the row's text, produced once

`fields = CCWATCH_ROSTER.rowFields(row, {volatile: VOLATILE})`
(`web/roster.js:49-77`, `contracts/roster-js.md §2`). The modal formats no stat
of its own; it is handed this object (D2), which is the same object the roster
row is drawn from — so "reads identically to that snapshot's roster row"
(SC-002, FR-010) holds by construction and not by vigilance.

Absent readings are **absent keys** — never `0`, `"0%"`, `"0MB"`, `"-"` or
`null` (FR-011). The modal's omission rule is therefore "the key is not there",
with no second absence test of its own.

## §4 PanelModel — the whole rendering, as data

The return value of `CCWATCH_MODAL.panel(input)`
(`contracts/modal-js.md §3`). The page writes it into nodes built once at load
and never rebuilt (FR-040).

```
PanelModel {
  header: { lead: "agent", name: string, status: string | null },
  stats:  StatLine[],
  feed:   { main: string, mainKind: "" | "down" | "warming", unreadable: string },
  gone:   string | null,
  ask:    AskModel,
  convo:  { message: string | null, isError: boolean },
  kill:   KillModel,
  send:   SendModel,
}
```

- `header.status` is `"<word> · <measure>"`, or `"<word>"` when there is no
  measure, or `null` when there is no row at all — byte-identical to the roster
  row's `.rstatus` join (`web/map.html:1808-1810`, FR-010).
- `stats` is ordered and omits absent readings entirely.
- `feed`, `gone`: §6.
- `convo.message` is `null` when the conversation itself is what should be
  shown; a string when a sentence replaces it (D15).

### StatLine

```
StatLine { key: string, label: string, text: string }
```

Fixed order, identity last so an untrusted tick visibly loses the middle and
keeps the ends (D9, FR-012):

| # | `key` | `label` | `text` | Source |
|---|---|---|---|---|
| 1 | `silence` | `waiting` \| `silent` | `dur(row.waited)` \| `dur(row.quiet)` | `waited` wins; absent when both are null |
| 2 | `age` | `age` | `fields.age` | absent key ⇒ no line |
| 3 | `ctx` | `context` | `fields.ctx` | volatile-gated in `rowFields` |
| 4 | `mem` | `memory` | `fields.mem` | volatile-gated in `rowFields` |
| 5 | `pipeline` | `pipeline` | `fields.pipeline` | `phase/status`, `phase/CRASHED` |
| 6 | `where` | `repo` | `fields.where` | `"<repo> · <branch>"` or `"no repo"` |
| 7 | `sid` | `session` | `row.sid` | verbatim; the one line that survives every condition |
| 8… | `edge:<n>` | `messages` | one line per edge, §5 | absent when there are none |

The twelve stats FR-008 names map onto the header (name, status word, its
measurement) plus lines 1–8 above.

## §5 PeerEdgeLine — the message edges touching this session

```
PeerEdgeLine { dir: "out" | "in", other: string, count: number, unknown: boolean }
```

From `edgesFor(name, edges, names)` (`contracts/modal-js.md §5`), over
`/api/state`'s `peers.edges` (`{from, to, count, last, sample}`,
`bin/ccwatch:2673-2676`):

- kept when `e.from === name || e.to === name`, matched **by name** as the
  map's own wire drawing already does (`web/map.html:867-890`);
- `dir` is `"out"` when `e.from === name`, else `"in"`;
- `other` is the far end's name verbatim; a self-edge yields one line with
  `dir: "out"` and `other === name`;
- `count` is `e.count` verbatim — no re-aggregation;
- `unknown` is true when `other` is not in `names` (the payload's own session
  names), rendered with a trailing "— not in this snapshot" rather than being
  dropped;
- rendered text: `→ <other> · <count> message(s)` / `← <other> · <count>
  message(s)`, the arrow accompanied by the words `to`/`from` so direction is
  not carried by a glyph alone (principle VII).

`last` and `sample` are not read: `sample` is message text (D11).

## §6 FeedCondition and the two failure sentences

The modal restates the page's existing condition object rather than relying on
the banner it covers (FR-042–FR-044). The object is unchanged
(`computeFeedCondition`, `web/map.html:1677-1692`):

```
FeedCondition { trust: "ok" | "warming" | "feed_down",
                reason: string | null, dataAge: number | null,
                unreadable: number | null, empty: boolean }
```

`feedLines(cond)` (`contracts/modal-js.md §6`) yields:

| `trust` | `mainKind` | `main` |
|---|---|---|
| `feed_down` | `down` | the feed is down: `<reason>` — the readings in this panel are `<dur(dataAge)>` old |
| `warming` | `warming` | taking the first snapshot — nothing has been collected about this session yet |
| `ok` | `""` | `""` |

`unreadable` is a **separate, additive** string, never joined into `main`, and
empty when the count is absent or zero (FR-044, R5 of entry 002):
`<n> registry file(s) could not be read — run: ccwatch doctor`.

`empty` is not rendered by the modal: a panel is open on a named session, so
"no live sessions" is not a statement it can make. That case reaches the reader
as `gone` instead.

`goneText(name, sid)` is the fifth rendering (FR-045, D13):

> `<name>` is gone from the snapshot — it is no longer one of the machine's
> sessions. Reopen the conversation with `claude --resume <sid>`.

It shares no leading clause with any `feedLines` string, and it is only
reachable when `trust === "ok"` — a feed that cannot be read is not evidence a
session exited (the rule `resolveSelection` already encodes,
`web/roster.js:150-160`).

**SC-009**: `feedLines` over the three trusts, the additive unreadable string,
and `goneText` are five pairwise-distinct strings, asserted as such.

## §7 AskModel — the pending question, unchanged in meaning

```
AskModel { kind: "none" | "dialog" | "questions",
           note: string | null, how: string, questions: Question[] }
```

- `questions` — `row.questions` is non-empty: the recorded question(s) with
  their options, **in full** (the roster truncates at 100 chars; FR-020 gives
  the modal the question whole), above the conversation, and the `how`
  statement carried over verbatim in meaning from `web/map.html:1170-1176`:
  a dialog can only be answered in that session's own terminal, and a message
  sent from here is **queued behind it** and does not answer it (FR-021).
- `dialog` — no recorded question but `row.sev === 4`: `note` is
  `"Waiting on you: " + (row.note || "input needed")` and `how` is the
  distinct existing sentence about the text living only in that terminal
  (FR-022).
- `none` — neither: the panel is absent entirely, not empty (FR-023,
  principle XII).

## §8 KillModel

```
KillModel { state: "ready" | "disabled",
            reason: string | null,
            startLabel: string,
            confirmOpen: boolean,
            confirm: { name, frees, freesNote, resume, phase, busy } | null }
```

| Input | `state` | `reason` |
|---|---|---|
| `canKill === false` | `disabled` | killing is disabled on this server — restart it with: `ccwatch serve --allow-kill` |
| `row == null` (session gone) | `disabled` | this session is no longer in the snapshot — there is nothing to kill |
| otherwise | `ready` | `null` |

The control is **present in both states** (FR-028, principle IV) and a
`disabled` state issues no request and opens no confirmation step (FR-029).

`confirmOpen` is `confirmOpen && state === "ready"`, so `can_kill` going false
closes an open step (FR-034, D18).

The `frees` figure (FR-030, FR-033, D10):

| `volatile` | `fields.mem` | `frees` | `freesNote` |
|---|---|---|---|
| true | `"1832MB"` | `1832MB` | `null` |
| true | absent | `an unknown amount` | `null` |
| false | — | `null` | the memory reading is no longer current, so what killing would free cannot be stated |

`confirm.resume` is `claude --resume <sid>`; `confirm.phase` is the phase name
when `row.pipeline.status === "running"` (with "killing it aborts a paid model
call"), else `null`; `confirm.busy` is set when `row.token === "busy"` ("a tool
call may be left half-applied"), else `null` (FR-031).

## §9 SendModel

```
SendModel { state: "ready" | "disabled", reason: string | null }
```

| Input | `state` | `reason` |
|---|---|---|
| `canSend === false` | `disabled` | this server was started `--read-only` — sending is disabled |
| `row == null` | `disabled` | this session is no longer in the snapshot — there is nothing to send to |
| otherwise | `ready` | `null` |

Present and disabled, never hidden (FR-026), and a disabled control issues no
request (FR-027). `canSend` is the page's existing `CAN_SEND` — the per-run
token was substituted into the served HTML — which is true exactly when the
server was not started `--read-only` (`bin/ccwatch:2913`, `:2934`).

## §10 Outcomes — three each, and a transport failure that reads as one

```
SendOutcome { state: "delivered" | "queued" | "failed", text: string }
KillOutcome { state: "killed" | "refused" | "failed", text: string }
```

Both are written by the page from the endpoint's own reply, unchanged in
meaning (FR-024, FR-032, principle VIII):

| Endpoint reply | Rendered |
|---|---|
| `{state:"delivered"}` | delivered — it has the message; the message box is cleared |
| `{state:"queued", detail}` | queued — mid-turn, it will read this next turn, with the detail |
| any other, or non-2xx | the server's own `error`/`detail`, verbatim |
| exception (no reply at all) | `the send request did not complete: <message>` (D22) |
| `{state:"killed"}` | killed — `<mem>` released; the modal closes and focus returns (FR-007, §1) |
| `{state:"refused", detail}` | the refusal's own text, verbatim |
| exception | `the kill request did not complete: <message>` (D22) |

## §11 ConvoView — the reduced transcript, unchanged

`/api/transcript?sid=<sid>&n=40` → `{turns: [{timestamp, kind, text, origin,
from}]}`, produced by `ccwatch convo --json` (`bin/ccwatch:3023-3046`). The
reduction is the server's and is not touched (FR-015, principle X): bounded
byte tail, text truncated, a tool *use* reduced to its name and a short
argument summary, a tool *result* reduced to its size.

Rendering is unchanged: one `.turn` per entry, reconciled by
`at|<kind>|<timestamp>|<n>`, with `.what`'s single `innerHTML` write being
`md.js`'s escape-first-then-tag render (FR-016). Two additions:

- `atBottom({scrollTop, scrollHeight, clientHeight})` sampled before the
  reconcile decides whether the view follows new turns after it (FR-018, D14);
- the three distinct empty/failed sentences of §4's `convo.message` (D15).

## §12 What the modal explicitly does not read or derive

- No comparator: the modal shows one session and orders nothing.
- No severity, status word, verdict or feed condition of its own (FR-048,
  principle V, XI). Every word it prints is either payload text or a fixed
  template over payload text.
- No second staleness test: `VOLATILE` is the only gate (D10).
- No `localStorage`, no new endpoint, no `bin/ccwatch` change (FR-047, D16).
- No transcript content on any outbound path, and no anchor: the transcript is
  escaped before formatting and a markdown link renders as text
  (`web/md.js`, FR-016, principle X).
