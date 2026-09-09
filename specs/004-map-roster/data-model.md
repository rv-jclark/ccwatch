# Data Model: Map — docked agent roster

**Feature**: `004-map-roster` | **Spec**: [spec.md](./spec.md) |
**Research**: [research.md](./research.md)

Nothing here is a new payload field. Every entity below is either a *view* over
`/api/state` (a formatting of fields the CLI already computes) or *browser-side
state* that never leaves the browser. `/api/state` is unchanged (FR-036,
FR-037), and no entity carries a status, severity, verdict, note or badge the
payload did not supply (FR-007, Constitution V, XI).

---

## §1 RosterRow — the textual representation of one session

One per entry in `s.sessions`, identified by `sid`. Produced by
`CCWATCH_ROSTER.rowFields(row, {volatile})`.

| Field | Source | Absent when |
|---|---|---|
| `sid` | `row.sid` | never |
| `name` | `row.name` | never |
| `where` | `row.repo` + `" · "` + `row.branch`, or `"no repo"` | never — `no repo` is the value for a directory with no git remote (Constitution VI) |
| `word` | `row.token`, verbatim | never; an unrecognised token is printed as supplied (Constitution V) |
| `measure` | see §2 | when the payload supplied no measurement and no note |
| `age` | `dur(row.age)` | `row.age == null` |
| `pipeline` | `"<phase>/<CRASHED\|status>"` from `row.pipeline` | `row.pipeline == null` |
| `asks` | `row.questions[0].question`, bounded to 100 chars | no `questions` |
| `ctx` | `"ctx <floor(row.context.used_percentage)>%"` | **not volatile**, or `context == null`, or `used_percentage == null` |
| `mem` | `"<row.rss_mb>MB"` | **not volatile**, or `rss_mb == null` |

Rules:

- **R1 (FR-006)** An absent reading is absent from the object. There is no
  branch that produces `0`, `0%`, `0MB`, `-` or `null` as a *reading*. A caller
  that finds no `ctx` key renders no context text.
- **R2 (FR-005)** `word` and `pipeline` are separate fields and are rendered as
  separate statements. They are never concatenated into one claim, for the
  reason recorded at `bin/ccwatch:938-944`: a session can be honestly `idle`
  while the run it belongs to has crashed.
- **R3 (FR-002, Constitution II)** `word` and `measure` are the two fields that
  may never be truncated or hidden at any width (FR-034).
- **R4 (FR-028, Constitution III)** `ctx` and `mem` are the whole withheld set.
  They are dropped — not annotated — when `volatile` is false, through the one
  `VOLATILE` gate the map already uses (`web/map.html:1681`).
- **R5 (Constitution VI)** An `sdk-ts` row's silence measures nothing, so its
  `measure` is whatever note the payload gave it and never a derived duration.
  A row with no transcript at all (`quiet == null`) states the payload's note
  (`cannot verify progress`, `headless, cannot verify`), never a zero silence.

## §2 The measurement, and where its wording comes from

`measure` reproduces the terminal's last column (`bin/ccwatch:1092-1097`) so the
two renderings of one snapshot read the same:

| Condition | `measure` |
|---|---|
| `waited != null` | `"<note> <dur(waited)>"` |
| `note == "quiet"` | `"quiet <dur(quiet)>"` |
| `note` non-empty | `note` |
| `quiet != null` | `"<dur(quiet)> ago"` |
| otherwise | absent (R1) |

`dur()` is the page's existing formatter (`web/map.html:308-310`): `s`, `m`,
`h`, `d`. FR-003 is satisfied by construction — the waited time for a session
blocked on the person, the transcript silence otherwise, plus the payload's own
note.

## §3 RosterOrder — a sequence, not a computation

The order is `s.sessions`'s array order, unchanged (D2). There is no comparator
in the page and no ordering value is ever handed to `plots.js`.

- **O1 (FR-008, FR-009)** The payload arrives sorted
  `-max(sev, psev)`, then `-(waited // quiet // 0)` (`bin/ccwatch:953`), over
  rows that entered the sort in registry-file order — lexicographic by pid
  (`bin/ccwatch:221`) — so a tie is resolved the same way on every tick.
- **O2 (FR-010)** The roster's sequence and the terminal's row sequence are the
  same object, so they cannot disagree.
- **O3 (FR-011, Constitution XIII)** The order reaches the DOM sequence of
  `#rosterlist`'s children and nothing else. No district, building, zone or
  figure coordinate is a function of it.

## §4 Selection — at most one sid, with three observable states

Produced by `resolveSelection(storedSid, sessions, cond)`.

```
state ∈ { none, present, gone, unknown }
```

| state | condition | row marked | figure emphasised | statement | camera |
|---|---|---|---|---|---|
| `none` | no stored sid | – | – | – | – |
| `present` | sid ∈ sessions | yes | yes | – | fly iff sid ≠ `lastFlownSid` |
| `gone` | sid ∉ sessions **and** `cond.trust === "ok"` | – | – | tombstone (§6) | never |
| `unknown` | sid ∉ sessions and trust is `feed_down` or `warming` | – | – | – | never |

- **S1 (FR-018)** At most one sid is selected. Selecting another clears the
  previous row's marker and the previous figure's emphasis.
- **S2 (FR-024, Constitution I, IV)** `gone` is unreachable from an untrusted
  tick. A feed that cannot be read is not evidence a session exited.
- **S3 (edge case: the selection returns)** A sid reappearing in a later
  trusted payload goes back to `present` with no further camera move — the
  fly is guarded on `sid ≠ lastFlownSid` (D7), and the sid did not change.
- **S4 (edge case: never seen this run)** A stored sid absent from the *first*
  trusted payload is `gone` like any other absent selection: stated, not
  silently dropped, and not flown to.
- **S5 (FR-021)** Selection never opens the inspector. A figure click still
  opens it, unchanged (`web/map.html:1249-1256`).

## §5 FeedCondition — the existing object, rendered a second time

The roster consumes the *same* `cond` object `computeFeedCondition()` already
produces (`web/map.html:1575-1592`) and derives nothing of its own.
`statements(cond)` maps it to the roster's wording:

| Sentence | Emitted when | Says |
|---|---|---|
| `main` (down) | `trust === "feed_down"` | the feed is down, the reason, and the measured age of the rows still shown |
| `main` (warming) | `trust === "warming"` | the first snapshot is still being taken; **no rows are listed** |
| `unreadable` | `cond.unreadable > 0` | how many registry files could not be read, and `ccwatch doctor` |
| `empty` | `trust === "ok"` **and** `cond.empty` | there are no live sessions |

- **F1 (FR-025)** Four conditions, four distinct sentences. None is a variation
  in wording on another.
- **F2 (FR-029, SC-007)** `empty` is emitted only when `trust === "ok"`,
  enforced inside `statements()` regardless of what the caller passed, so it can
  never appear beside the down, warming or (payload-error) sentences.
  `unreadable` is additive and may accompany any of the others.
- **F3 (FR-027)** While down or warming the rows are not presented as current:
  the condition is stated and, where rows are retained, their measured age is
  stated with it.
- **F4 (FR-030)** Nothing is latched. `cond` is recomputed every tick from the
  read outcome and the body, so a good snapshot clears the statement and
  restores `ctx`/`mem` on that same repaint.
- **F5 (FR-026)** The unreadable sentence names `ccwatch doctor`, as the
  terminal footer and the map banner already do.

## §6 Tombstone — the gone-selection statement

A dismissible region above the listbox (D15), never a `role="option"`:

- text distinct from every sentence in §5 (FR-023);
- pinned at the top, where a needs-you-first list puts what needs attention;
- a real `<button>` dismisses it, clearing the selection and its stored record;
- the remaining rows keep rendering (FR-023).

## §7 RosterWidth — one persisted number, layout only

| Field | Value |
|---|---|
| `w` | pixels, clamped by `clampWidth(w, windowWidth)` to `[220, min(560, 0.45 × windowWidth)]` |

- **W1 (FR-031)** Restored on reload, clamped to what the current window can
  accommodate — a width stored on a wide monitor is not applied verbatim on a
  laptop.
- **W2 (FR-033)** A width change re-centres the camera on the world point at
  its centre and re-clamps; it never refits and never discards the viewport
  (D10).
- **W3 (FR-032)** Adjustable from the keyboard through the divider's
  `role="separator"` widget.
- **W4 (D11)** Below the 720px stacking breakpoint the stored width is not
  applied and the divider is hidden; the panel takes a bounded height instead.

## §8 Stored records

Two new `localStorage` keys, versioned and validated the way
`ccwatch.map.view.v1` is (`web/camera.js:131-162`), independent of it and of
`ccwatch.map.plots.v1`.

| Key | Record | Rejected when |
|---|---|---|
| `ccwatch.map.selection.v1` | `{v: 1, sid}` | not parseable; `v !== 1`; `sid` not a session-id-shaped string (hex and dashes, ≤ 64 chars) |
| `ccwatch.map.roster.v1` | `{v: 1, w}` | not parseable; `v !== 1`; `w` not a finite number |

- **P1** A rejected record is discarded, never partially trusted.
- **P2** `getItem`/`setItem` are injected, so the suite drives persistence — and
  a throwing storage — without a browser.
- **P3** The first throw flips `persistence` to `"unavailable"` one way and is
  never retried (the `plots.js`/`camera.js` rule), and the panel *states* that
  the selection and width will not be remembered (Constitution IV) rather than
  hiding the fact.

## §9 What the roster explicitly does not read

Stated so a later change has to argue with this list rather than quietly extend
the panel:

- `s.deploys`, `s.unfinished`, `s.unfinished_old` — badges on buildings, not
  sessions; no roster row is created for them (spec Assumptions). A *live*
  session's own `pipeline` is in its row, so a crashed phase attached to a live
  session is still reachable as text.
- `s.peers` — wires between figures; the roster lists sessions, not edges.
- `s.host`, `s.usage` — page chrome with their own withholding, unchanged.
- `row.cpu`, `row.cpu_delta`, `row.status_raw`, `row.pid`, `row.entrypoint`,
  `row.version` — corroborating signals behind a verdict the payload has
  already reached. Printing them beside the verdict would invite the reader to
  re-derive it (Constitution XI).
- `~/.claude/ccwatch/roster.json` — the runtime record `write_roster` keeps for
  `ccwatch resume` (`bin/ccwatch:2231`). Unrelated to this panel despite the
  name; nothing here reads or writes it (worth the note in `README.md` the spec
  asks for).
