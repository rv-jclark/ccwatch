# Contract — what `/map` renders, and the four sentences

**Feature**: `002-map-stable-world` | **Applies to**: `web/map.html`

The page's obligations, stated as a contract because most of them are
Constitution invariants and because the four sentences must be four sentences
(SC-006). Wording below is the wording to ship; the existing wording that must
not change is marked **verbatim**.

---

## 1. The four trustworthiness renderings

Derived per tick from the read outcome and payload fields only — see
[data-model.md](../data-model.md) §5. `(c)` is additive and may appear beside
any of the others; `(d)` is gated on `(a)` and `(b)` both being absent.

| # | Condition | Sentence |
|---|---|---|
| **a** | the feed could not be read: the `fetch` threw, `!res.ok`, or `snapshot_ok === false` | `the feed is down: <reason> — is \`ccwatch serve\` still running? showing session data from <age> ago` |
| **b** | no snapshot has yet succeeded (`warming === true`) | `taking the first snapshot — no session data has been collected yet` |
| **c** | `parse_failed > 0` | `<N> registry file(s) could not be read — run: ccwatch doctor` |
| **d** | snapshot succeeded, no error, `sessions.length === 0` | `No live sessions. After a reboot, run ccwatch resume.` (**verbatim**, `web/map.html:748`) |

### Guarantees

- **R1** The four texts share no sentence, and each names the specific fact
  behind it — the read failure's real reason, the absent first snapshot, the
  number of unreadable rows, or the absence of sessions (FR-026, SC-006).
- **R2** In (a), (b) and (c) the districts, buildings and zones stay drawn. A
  failure never presents as an empty city (FR-027, Constitution IV). In (b)
  there is nothing yet to have drawn, which is consistent, not an exception.
- **R3** In (a) and (c) the map is marked stale and states the measured age of
  the session data still on screen, computed as
  `now - collected_at.snapshot` at every repaint (FR-028). In (b) there is no
  retained data and therefore no age; the sentence says so instead. This
  reading of FR-028 is recorded in the plan's Complexity Tracking.
- **R4** In (a), (b) and (c) every reading in the `VOLATILE` set is **withheld,
  not annotated**: the context fill inside a figure, every percentage, every
  memory figure (FR-029, Constitution III). Pose, colour, structure, the status
  word and the age remain.
- **R5** `parse_failed` absent or `null` prints nothing. Never `0`
  (Constitution IV, V).
- **R6** (d)'s sentence is never printed when the payload carries an `error` or
  `snapshot_error`, whatever `sessions` holds (FR-031, SC-008).
- **R7** A good snapshot clears the stale marking and restores every withheld
  reading on that same tick, with no reload (FR-032, SC-006). Nothing is
  latched.
- **R8** `if (s.warming) return` (`web/map.html:707`) is gone. A warming payload
  never leaves a previous drawing standing with only a footnote (FR-030).

---

## 2. Rendering invariants

| | Guarantee | Requirement |
|---|---|---|
| **V1** | No code reached by a refresh assigns a container's `innerHTML`. This covers the world, `#counts`, `#gauges`, `#foot`, `#hostwarn`, `#ask`, `#killbar` and `#convo`'s turn list | FR-016 |
| **V2** | The one surviving `innerHTML` write is a single **turn body** filled from `CCWATCH_MD.render(...)`, because that is the escape-first-then-tag path and `md.js` returns a string. The container is reconciled; the body is not | FR-016, Constitution X |
| **V3** | Nothing is created or destroyed for a payload that did not change | FR-020, SC-004 |
| **V4** | Hover, focus and text selection survive a refresh, because the nodes carrying them are not replaced | FR-018, SC-005 |
| **V5** | An open inspector stays bound to the same session across refreshes with its ask panel, conversation, send box and kill bar intact | FR-017, FR-042, SC-005 |
| **V6** | Wires are drawn inside the camera group from world coordinates. `getBoundingClientRect` is not used to position anything | FR-021 |
| **V7** | Each direction is a separate bowed line with an arrowhead; a count label appears only when `count > 1`; an edge with an endpoint that is not a figure on the map is not drawn | FR-022, FR-023, FR-024 |
| **V8** | When edges are undrawn the footer says how many of the total were drawn and that the rest involve sessions that have exited — **verbatim** from `web/map.html:690-693` | FR-025 |
| **V9** | A figure, a building and a district are each drawn by exactly one primitive, which owns all the art and nothing else; each primitive carries its own `<rect class="hit">` so swapping a shape for an `<image>` changes neither layout, reconciliation nor hit testing | FR-050, FR-051 |
| **V10** | Only shapes drawn by the page. No image asset, binary, font, external fetch or runtime dependency is added | FR-052, SC-014 |
| **V11** | Drawing happens only on a data change, a resize, or a pointer/focus interaction. No animation-frame loop; exactly one `setInterval`, the shared visibility-aware scheduler | FR-049, SC-012 |
| **V12** | Motion is signal-bearing: working, blocked and suspect figures may move, an idle one does not, and `prefers-reduced-motion: reduce` suppresses all of it with every distinction still readable | FR-053, spec Edge Cases |
| **V13** | Every figure state has a distinct word available as text — in the figure's `<title>` and in the legend — not colour or shape alone | FR-046, Constitution VII |
| **V14** | An unrecognised status token draws as the neutral figure and its own token stays readable as text. No pose, colour or severity is invented for it | Constitution V, spec Edge Cases |
| **V15** | A session with no branch or no project name still gets a figure; the missing part is shown as missing, not guessed | Constitution VI, spec Edge Cases |
| **V16** | `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` stays byte-identical | FR-047 |
| **V17** | Read-only and kill-disabled operation behaves exactly as today. No gate changes, and a disabled capability does not become a visible control — that is `map-agent-modal` | FR-048 |

---

## 3. Unchanged behaviour and wording

**Verbatim**, asserted by eye against the current page in
[quickstart.md](../quickstart.md) §7:

| Element | Requirement |
|---|---|
| the inspector: ask panel, conversation, send box, kill bar, and their wording | FR-042, SC-013 |
| the account-usage gauges, including withholding a reading past its staleness window and stating how old the last one was | FR-043 |
| the host memory-pressure line, appearing only at its threshold and absent below it | FR-044, Constitution XII |
| the legend, the footer, the live counts, and the document title | FR-045 |
| the `no repo` badge and its tooltip | FR-004 |
| the two-page navigation — `/` and `/map`, and no third page | FR-001 |
