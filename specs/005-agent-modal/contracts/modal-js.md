# Contract: `web/modal.js` — the pure per-agent-modal module

**Feature**: `005-agent-modal` | **Plan**: [../plan.md](../plan.md) |
**Data model**: [../data-model.md](../data-model.md)

A fifth static module beside `md.js`, `plots.js`, `camera.js` and `roster.js`,
for the documented reason those exist: `tests/run.sh` can `require()` it under
`node` and assert on it without a browser (D1, FR-050). Same shape as
`roster.js`:

```js
(function (root) {
  "use strict";
  /* … */
  root.CCWATCH_MODAL = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
```

**Purity**: no DOM, no `fetch`, no timers, no `localStorage`, no `require`, and
no global read — every input is an argument (D2). In particular it does **not**
reach for `CCWATCH_ROSTER`: the caller passes `rowFields`'s output in.

**Never derives a status.** No comparator, no default arm that manufactures a
word, no branch that turns an absent reading into a number (FR-009,
principles V and XI).

Served by the static fallback in `serve` (`SimpleHTTPRequestHandler` with
`directory=WEB`, `bin/ccwatch:2900-2901`) — no route, and **no change to
`bin/ccwatch`**.

---

## §1 Constants

| Name | Value | Referenced by |
|---|---|---|
| `FOLLOW_EPS` | `8` | §7 |
| `TRANSCRIPT_N` | `40` | page §5 — the `n` the page already requests |

Frozen values, independent of viewport size and of the payload.

## §2 `Input` — what `panel()` is given

```js
{
  row:        SessionRow | null,   // null ⇒ the session is not in this payload
  fields:     RosterRow  | null,   // CCWATCH_ROSTER.rowFields(row, {volatile})
  subject:    {sid, name},         // held independently of the payload (§1 data-model)
  names:      string[],            // the payload's own session names, for edge matching
  edges:      PeerEdge[],          // s.peers.edges, or []
  cond:       FeedCondition,
  volatile:   boolean,             // the page's VOLATILE for this same tick
  canSend:    boolean,             // the page's CAN_SEND
  canKill:    boolean,             // !!s.can_kill
  confirmOpen: boolean,            // whether the kill confirmation step is showing
}
```

`row` and `fields` are always both present or both null; `panel()` treats a
null `fields` with a non-null `row` as null-row (it cannot format what it was
not given, and it does not format anything itself).

## §3 `panel(input) → PanelModel`

Returns the object in data-model §4. One call per render; the page writes it
into nodes built once at load.

Asserted claims:

| id | Claim |
|---|---|
| M‑A | `header.name` is `subject.name` verbatim — **not** `row.name` — so it survives the row disappearing |
| M‑B | `header.status` is `"<fields.word> · <fields.measure>"` when a measure exists, `"<fields.word>"` when it does not, and `null` when `row` is null |
| M‑C | `header.status` for a given `fields` is byte-identical to the roster row's `.rstatus` join for the same `fields` |
| M‑D | every string in the model is either a payload value or a fixed template over payload values: no input produces a status word, severity or verdict absent from `row`/`cond` |
| M‑E | with `row: null`, `stats` contains exactly the `sid` line, `gone` is non-null, and both write controls are `disabled` |
| M‑F | `panel()` is a pure function of its argument: called twice with the same input it returns deeply equal models, and it mutates no part of the input |

## §4 `statLines(fields, row, opts) → StatLine[]`

Data-model §4's table, in that order.

| id | Claim |
|---|---|
| S‑A | order is exactly `silence, age, ctx, mem, pipeline, where, sid, edge:*` for a row carrying all of them |
| S‑B | a `waited` row yields one `silence` line labelled `waiting`; a `quiet`-only row yields one labelled `silent`; `waited` wins when both are present |
| S‑C | a row with neither `waited` nor `quiet` yields **no** `silence` line — never `0s`, `-` or an empty text |
| S‑D | an absent `fields` key yields no line at all: no `0`, `0%`, `0MB`, `-` or `null` reaches any `text` (FR-011) |
| S‑E | with `volatile: false`, `ctx` and `mem` are absent and `where` and `sid` are present (FR-012) |
| S‑F | `sid` line text is `row.sid` verbatim, including a sid the module has never seen |
| S‑G | `where` is `"no repo"` with no repository named when `row.repo` is null (principle VI) |
| S‑H | a `pipeline` whose `crashed` is true reads `<phase>/CRASHED`, via `fields.pipeline` — the module does not re-derive it |
| S‑I | every `key` in the returned array is unique, so the page can reconcile by it |

## §5 `edgesFor(name, edges, names) → PeerEdgeLine[]`

Data-model §5.

| id | Claim |
|---|---|
| E‑A | an edge with neither end equal to `name` is excluded |
| E‑B | `from === name` yields `dir: "out"`; `to === name` yields `dir: "in"` |
| E‑C | `count` is `e.count` verbatim, with no re-aggregation and no grouping |
| E‑D | a far end absent from `names` sets `unknown: true` rather than dropping the edge |
| E‑E | a self-edge (`from === to === name`) yields exactly one line |
| E‑F | `edges: []`, `edges: null` and an absent `peers` all yield `[]` — never a placeholder line |
| E‑G | neither `last` nor `sample` appears anywhere in the output |
| E‑H | the rendered text carries the direction as a word (`to`/`from`) as well as the arrow (principle VII) |

## §6 `feedLines(cond) → {main, mainKind, unreadable}` and `goneText(name, sid)`

Data-model §6.

| id | Claim |
|---|---|
| F‑A | `feed_down` yields `mainKind: "down"`, names the reason verbatim, and states the age with `dur()` |
| F‑B | `warming` yields `mainKind: "warming"`, no age, and no reading |
| F‑C | `ok` yields `main: ""` and `mainKind: ""` — normal conditions are silent (principle XII) |
| F‑D | `unreadable` is a separate string, never a substring of `main`, and is `""` for `0`, `null` and `undefined` (FR-044) |
| F‑E | `unreadable` is produced for a `feed_down` cond as well as an `ok` one — it is additive, not exclusive |
| F‑F | `goneText` names the session, states it left the machine's session list, and includes `claude --resume <sid>` |
| F‑G | the five renderings — the three `main` values, the `unreadable` string, and `goneText` — are **pairwise distinct** and share no leading clause (SC-009) |
| F‑H | no branch prints `0s`, `0`, `null` or `undefined` for an absent `dataAge`, `reason` or `unreadable` |

## §7 `atBottom({scrollTop, scrollHeight, clientHeight}) → boolean`

The follow-the-conversation predicate (FR-018, D14). `FOLLOW_EPS` is `8`.

| id | Claim |
|---|---|
| B‑A | exactly at the bottom (`scrollTop + clientHeight === scrollHeight`) is true |
| B‑B | within `FOLLOW_EPS` of the bottom is true — sub-pixel layout must not stop the follow |
| B‑C | one 12px line above the bottom is false, so a reader who scrolled up is not dragged down |
| B‑D | a box shorter than its viewport (`scrollHeight <= clientHeight`) is true |
| B‑E | non-finite or missing measurements return true rather than throwing — a broken measurement must not wedge the conversation at the top |

## §8 `killModel(input) → KillModel`

Data-model §8.

| id | Claim |
|---|---|
| K‑A | `canKill: false` yields `state: "disabled"`, a non-empty reason naming `ccwatch serve --allow-kill`, and a `startLabel` that does not read as an available action |
| K‑B | `canKill: false` yields `confirmOpen: false` **even when the caller passed `confirmOpen: true`** (FR-034) |
| K‑C | `canKill: true` with a row yields `state: "ready"` and a `confirm` object |
| K‑D | `frees` is `fields.mem` verbatim when volatile and present |
| K‑E | `volatile: true` with `row.rss_mb == null` yields `frees: "an unknown amount"` — the existing wording, unchanged |
| K‑F | `volatile: false` yields `frees: null` and a `freesNote` stating the reading is not current — the two absences read differently (FR-033, D10) |
| K‑G | `confirm.resume` is exactly `"claude --resume <sid>"` |
| K‑H | `pipeline.status === "running"` sets `confirm.phase` and the paid-model-call sentence; any other status leaves it `null` |
| K‑I | `token === "busy"` sets `confirm.busy`; any other token leaves it `null` |
| K‑J | `row: null` yields `state: "disabled"` with a reason distinct from K‑A's |
| K‑K | no input yields a `state` other than `"ready"` or `"disabled"` |

## §9 `sendModel(input) → SendModel`

Data-model §9.

| id | Claim |
|---|---|
| N‑A | `canSend: false` yields `state: "disabled"` and a reason naming `--read-only` (FR-026) |
| N‑B | `canSend: true` with a row yields `state: "ready"` and `reason: null` |
| N‑C | `row: null` yields `state: "disabled"` with a reason distinct from N‑A's |

## §10 `askModel(row) → AskModel`

Data-model §7. The three wordings are carried over from `web/map.html`
verbatim in meaning (FR-021, FR-022).

| id | Claim |
|---|---|
| A‑A | a row with `questions` yields `kind: "questions"`, the questions **untruncated**, and a `how` containing "queued behind it" and "does not answer it" |
| A‑B | a row with no `questions` and `sev === 4` yields `kind: "dialog"`, a `note` naming what it is waiting for, and a `how` distinct from A‑A's |
| A‑C | a row with no `questions` and `sev !== 4` yields `kind: "none"` and no sentences at all (FR-023) |
| A‑D | `row: null` yields `kind: "none"` |
| A‑E | a question 4KB long and one with fifteen options are returned whole — the module truncates nothing (the panel scrolls, page §3) |

## §11 `convoMessage({row, ok, reason, turnCount}) → {message, isError}`

The three transcript sentences (FR-019, D15).

| id | Claim |
|---|---|
| C‑A | `row.entrypoint === "sdk-ts"` yields the embedded-SDK sentence, whatever `turnCount` says |
| C‑B | `ok: true, turnCount: 0` on a non-`sdk-ts` row yields a sentence about there being no turns yet — distinct from C‑A's |
| C‑C | `ok: false` yields the reason verbatim with `isError: true` — distinct from both, and never an empty conversation (principle IV) |
| C‑D | `ok: true, turnCount > 0` yields `message: null` — the conversation itself is what is shown |
| C‑E | no branch escalates the session's silence to a hang or states anything about its status (principle VI) |

## §12 `dur(s)` — the one duration formatter

Identical in behaviour to `CCWATCH_ROSTER.dur` and to the page's own
(`web/map.html:345-347`), duplicated here rather than imported for the purity
reason in D2.

| id | Claim |
|---|---|
| D‑A | the four bands and their units match `roster.js`'s `dur` for a table of inputs spanning all of them |
| D‑B | `null` yields `"-"`, and no `statLines`/`feedLines` branch passes `null` to it (§4 S‑C, §6 F‑H) |

## §13 Exports

```js
{
  FOLLOW_EPS, TRANSCRIPT_N,
  dur,
  panel, statLines, edgesFor, feedLines, goneText,
  atBottom, killModel, sendModel, askModel, convoMessage,
}
```

Every exported name is reachable from `panel()` as well, so the composed model
and the pieces are asserted against the same code.
