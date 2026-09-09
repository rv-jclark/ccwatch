# Research: Map — per-agent modal with stats, conversation, chat, and a visible kill gate

**Feature**: `005-agent-modal` | **Plan**: [plan.md](./plan.md) |
**Spec**: [spec.md](./spec.md)

Each decision below is here because the spec left a choice open and the choice
has a consequence someone would have to live with. The format is the one
`specs/001`–`specs/004` use: what was chosen, why, and what was rejected and
for what reason. Line references are to the tree at the time of writing.

The spec's own Assumptions section already fixes several things this phase
would otherwise have had to decide — the panel replaces `#reply` in place, the
stats reuse `rowFields`, peer edges are matched by name, no endpoint or gate
changes. Those are read as settled and are not re-litigated here; what follows
is what remained.

---

## D1 — Where the logic lives: a fifth static module, `web/modal.js`

**Decision**: the modal's *rendering decisions* — which stats appear, the
enabled/disabled state of the send and kill controls and the exact reason text
for each, the wording of each failure condition, the peer-edge lines, and the
follow-the-bottom predicate — live in a new pure module `web/modal.js`
exporting `CCWATCH_MODAL`. `web/map.html` keeps the DOM and the fetches.

**Rationale**: FR-050 asks for exactly this and names the precedent: "in the
way the roster's shaping logic already is". `CLAUDE.md` gives the reason
`web/md.js` is a separate file — so `tests/run.sh` can run it under `node` and
assert on the result. `web/plots.js`, `web/camera.js` and `web/roster.js` all
followed. The alternative — asserting the wording by grepping `map.html` — was
tried in this repository for the trust sentences and produces assertions that
pass on a page whose branches are unreachable, which is the "fixture that
cannot fail" defect the constitution names.

FR-050's list is also the list of things this entry is most likely to get
wrong: SC-001 is a claim about a sentence, SC-007 about six sentences, SC-009
about five being pairwise distinct. Sentences are cheap to assert in `node` and
expensive to assert in a browser.

**Alternatives rejected**:

- *Extend `web/roster.js`*. The roster module is the row formatter; the modal
  is a second consumer of it. Folding the modal's dialog-state, kill-gate and
  transcript wording into it would make one module two things and would put
  `roster.js`'s existing 40-odd assertions at risk on every modal change.
- *Inline in `map.html` with source-level `grep` assertions*. Rejected as
  above: it asserts the text exists in the file, not that any input produces
  it.

## D2 — `modal.js` is handed `rowFields`'s output; it never formats a stat twice

**Decision**: the module's entry point is one pure function

```js
CCWATCH_MODAL.panel({row, fields, subject, names, edges, cond, volatile, canSend, canKill, confirmOpen})
  → PanelModel
```

`fields` is `CCWATCH_ROSTER.rowFields(row, {volatile})`, computed by the page.
`modal.js` `require()`s nothing and reads no global.

**Rationale**: SC-002 ("read identically to that snapshot's roster row") is true
by construction when the modal is handed the row's own formatted fields, and
true only by vigilance when it formats them again. The spec says so in as many
words. Keeping `rowFields` on the *caller's* side of the boundary is what keeps
`modal.js` pure in the sense `contracts/roster-js.md` established — "nothing in
this module reads a global; every input is an argument" — so the `node`
assertions can drive it with plain object literals and no module wiring.

The `panel()` shape (one function returning the whole rendering as data, which
the page then writes into pre-built nodes) mirrors `statements(cond)`: one call
site, one object to assert against, and no way for the page to render a
combination the model does not describe.

**Alternatives rejected**:

- *`modal.js` requires `roster.js`.* Works in `node` (relative `require`) and
  in the browser (script order), but introduces the first inter-module
  dependency in `web/`, and a load-order failure would show as a blank panel
  rather than as a stated failure. Not worth it to save one argument.
- *A global read (`root.CCWATCH_ROSTER`).* Same wiring problem, plus it breaks
  the purity property the existing module contracts state, which is what makes
  those assertions cheap.

## D3 — The surface is a native `<dialog>`, opened with `showModal()`

**Decision**: `#reply` becomes `<dialog id="agentmodal">`, opened with
`.showModal()` and closed with `.close()`.

**Rationale**: four of the modal-behaviour requirements are things the platform
already does correctly and that hand-rolled code in this repository would have
to keep doing correctly forever:

| Requirement | What `showModal()` gives |
|---|---|
| FR-036 focus moves in, and is trapped | native focus containment |
| FR-038 announced as a modal dialog with a name | implicit `role="dialog"` + `aria-modal` |
| FR-039 the content behind is not operable by keyboard | the rest of the document is inert |
| FR-007 closes on Escape | native `cancel` → `close` |

Baseline in current Chromium, WebKit and Gecko, which is the target the spec
states, and it costs nothing at load: no polyfill, no dependency, no build step
(FR-047).

FR-039's second clause — "the map's own key handling MUST NOT act on keys
pressed inside the modal" — is *already* true structurally and stays true: the
map's `keydown` listener is bound to `#world` (`web/map.html:1502`), not to
`document`, and the dialog is a `<body>` child outside `#wrap`/`#stage`. Two
independent reasons, which is the shape rule I in this project asks for.

**Alternatives rejected**:

- *Keep the fixed drawer and add a focus trap.* A hand-written trap has to
  enumerate focusable descendants, which now include a variable-length option
  list and two controls that come and go with the gate — the exact case
  hand-rolled traps get wrong. It would also leave the background operable
  (FR-039) unless `inert` were applied to `#stage` by hand.
- *`role="dialog"` on a plain `<div>` with `aria-modal="true"`.* Announces
  correctly and does nothing else; every row of the table above becomes code.

**Not adopted**: closing on a backdrop click. FR-040 protects a half-typed
message across ticks; discarding it on a stray click a few pixels outside the
panel would be the same loss by another route. Escape and the close control are
the two paths FR-007 names, and they are the two that exist.

## D4 — The drawer's contents move as they are; the ids stay

**Decision**: `#ask`, `#convo`, `#killbar`, `#ifoot`, `#replyText`,
`#replySend` and `#replyOut` keep their ids and their `askEls`/`killEls`
builders, and become children of the dialog. New nodes are added for the stats
(`#istats`), the feed sentences (`#ifeed`) and the tombstone (`#igone`).

**Rationale**: the spec's first assumption is that this is a replacement in
place, not a rewrite: the ask panel's two statements, the kill confirmation's
sentences, the send outcome messages and the transcript reduction "all carry
over as they are". Keeping the ids keeps the diff to the surface, and the
verbatim-in-meaning requirement (FR-021) is then satisfied by *not editing the
strings* rather than by re-deriving them. No assertion in `tests/run.sh`
currently names any of these ids, so nothing is pinned to them either way —
they are kept for the reviewer's sake, not the suite's.

`#reply` itself does not survive as an id: FR-001 requires there be no second
inspector surface left on the page, and an assertion that the page contains no
`id="reply"` is the cheapest way to hold that.

## D5 — Focus is restored by identity, not by the node the browser remembers

**Decision**: opening records `opener = {sid, kind}` where `kind` is `"row"` or
`"figure"`. On close the page focuses the *live* element for that sid, in the
order row → figure → `#rosterlist` → `#world`.

**Rationale**: `.close()` restores focus to the element that had it, but that
element may no longer be in the document. Two ways that happens here, both
real: a figure's `<g>` is keyed `f|slug|branch|sid` (`web/map.html:539`) so a
branch change recreates it, and after a successful kill the row and the figure
are both gone on the next tick — which the spec's edge case calls out ("not to
a row that is no longer there"). Entry 004 hit the same class of problem with
roster focus and settled it the same way (`focusTarget`, restored by sid, D4
there); repeating that construction is cheaper than reasoning about when the
native restore is enough.

FR-037's "somewhere sensible" is the tail of that chain: `#rosterlist` when it
has rows, else `#world`, which is focusable already (`tabindex="0"`,
`web/map.html:311`).

## D6 — Three openers, and none of them is the roster's selection

**Decision**:

- **Figure, pointer**: unchanged — the existing document `click` handler on
  `.agent[data-sid]` (`web/map.html:1345-1352`).
- **Figure, keyboard**: each `<g class="agent">` gets `tabindex="0"`,
  `role="button"` and an accessible name; `Enter`/`Space` opens.
- **Roster, keyboard**: the `o` key on a focused row, in the existing
  `#rosterlist` `keydown` handler, advertised by `aria-keyshortcuts` on the
  listbox and stated in `#rosternote`.
- **Roster, pointer**: a real `<button id="rosteropen">` in the roster header,
  outside the listbox, labelled `open <name>` for the currently focused row;
  plus `dblclick` on a row as the shortcut a pointer user expects from a list
  where single click selects.

**Rationale**: FR-004 forbids merging opening into the row's selection action,
and FR-003 requires both a pointer and a keyboard path from a row. The
constraint that decides the shape is ARIA's: `role="option"` has presentational
children, so a per-row `open` button inside a row would be *stripped from the
accessibility tree* — it would work with a mouse and be invisible to a screen
reader, which is precisely the failure principle VII exists to prevent. That
rules out the obvious construction and leaves the affordance outside the
listbox.

A header button naming the focused row is labelled (FR-004's word), reachable
by Tab, and states its own reason when there is nothing to open — "no agents to
open" — rather than disappearing (principle IV). `dblclick` is added because
selecting-then-clicking-open is two actions for something the same reader will
try to do with a double click on the first attempt; it is a shortcut, not the
affordance FR-004 asks for, so it carries no labelling burden.

Making the figures focusable is what FR-002's keyboard clause requires, and it
has a second effect worth stating: the city becomes tab-navigable, so the
`.agent` groups' `<title>` readings — which principle VII already requires them
to carry — are reachable without a pointer for the first time.

**Alternatives rejected**:

- *A per-row `open` button inside the option.* Invalid ARIA, as above.
- *`Enter` opens and something else selects.* Changes the roster's established
  keyboard contract (`Enter` selects, `contracts/page-roster.md §4`), which
  FR-046 forbids.
- *A focus cursor inside `#world` moved by keys, with one tab stop.* Fewer tab
  stops, but it invents a second selection model on the page and needs its own
  visible indicator, its own persistence question and its own assertions. Real
  focus on real elements is less machinery.

**Cost accepted**: one tab stop per figure. The roster precedes `#wrap` in DOM
order (`web/map.html:414`), so the keyboard reader who wants the list gets it
first, and the figures come after — which is the priority the roster was built
to express.

## D7 — Focus is drawn by a ring element, not by `outline`

**Decision**: each `.agent` group carries a `<rect class="focusring">`, shown by
`.agent:focus-visible .focusring`.

**Rationale**: `outline` on SVG container elements is inconsistently rendered
across engines, and a focus indicator that is missing in one browser is a
keyboard path that does not exist in that browser. A drawn rect is the same
mechanism the selected-figure emphasis already uses (a class on the outer `<g>`,
never inside `.figart`, which `updateFigure` rebuilds wholesale —
`web/map.html:801-811`), so it survives every tick for the same reason.

## D8 — A pan still never opens the modal

**Decision**: unchanged. `drag.moved` is set by the pointer handlers
(`web/map.html:1479-1493`) and consumed in exactly one place — the document
click handler (`web/map.html:1346`).

**Rationale**: FR-005 is already satisfied and the comment at that line says
why it is the only consumer. The new keyboard opener cannot regress it (a key
is not a drag), and the new roster openers are not on the map. The assertion
for FR-005 is therefore a source-level guard that the flag is still consumed
there and nowhere else.

## D9 — The stats: the header carries the verdict pair, the grid carries labelled readings

**Decision**: the modal's header shows `agent <name>` and the status pair
`<word> · <measure>` — byte-identical to the roster row's `.rstatus`
(`web/map.html:1808-1810`). Below it a labelled grid carries, in this fixed
order: the silence or waited duration, age, context, memory, pipeline, repo ·
branch, session id, and the peer edges.

**Rationale**: FR-008 names twelve things and FR-010 requires the status word to
read identically to the roster row's. Putting the word-plus-measurement pair in
the header, as one string produced from the same `fields` object, makes FR-010
true by construction. FR-008 also names "silence or waited time" *separately*
from "the measurement behind that status word", and those are genuinely two
readings: `measureOf` falls through to a bare `row.note` for a session with a
note and no duration (`web/roster.js:39-44`), in which case the pair carries no
number at all. The grid therefore states the duration itself, labelled
`silent`/`waiting`, from `row.quiet`/`row.waited`.

In the common case the two overlap — the header says `HUNG? · quiet 11m` and
the grid says `silent 11m`. That is accepted deliberately: they are the same
fact in two roles (the verdict with its measurement, principle II; and the
reading in the list of readings), and the alternative — showing the grid line
only when the header's measure happens not to contain a duration — is a
conditional nobody can hold in their head and an assertion nobody can read.

**Grid order** is fixed and identity-first at the bottom (repo, branch, session
id) because those are the fields that *stay* during an untrusted tick (FR-012):
the panel visibly loses its middle rather than reshuffling.

## D10 — The withheld set stays one gate, and "withheld" is not "never measured"

**Decision**: `VOLATILE` remains the single gate (`web/map.html:2058`). The
modal's context and memory readings come from `fields.ctx`/`fields.mem`, which
`rowFields` already omits when `volatile` is false. The kill confirmation's
`frees NMB` figure reads `fields.mem` — **not** `row.rss_mb`. `panel()` is
additionally passed `volatile` so it can distinguish two absences.

**Rationale**: defect 5 in the spec's overview is that the kill confirmation
writes `row.rss_mb` with no staleness gate (`web/map.html:1257-1258`), which is
principle III's exact prohibition applied to the one figure someone acts on.
Reading `fields.mem` fixes it and, more importantly, fixes it *at the gate* —
there is still one place to extend, which is what the comment at
`web/map.html:352-357` claims about `VOLATILE` and what this change must not
falsify.

The two absences are different facts and FR-033 asks for different sentences:

| `volatile` | `row.rss_mb` | what the panel says |
|---|---|---|
| true | `1832` | `kill this session (frees 1832MB)` |
| true | `null` | `frees an unknown amount` — existing wording, kept |
| false | anything | `frees` — figure withheld — plus "the memory reading is no longer current" |

Which is why `volatile` is an explicit argument rather than something inferred
from `fields.mem` being absent: from `fields` alone the second and third rows
are indistinguishable, and collapsing them would make a withheld figure read as
an unmeasured one.

## D11 — Peer edges: filtered by name, direction and count verbatim, an unknown far end stated

**Decision**: `edgesFor(name, edges, names) → [{dir, other, count, unknown}]`.
An edge is kept when `e.from === name || e.to === name`; `dir` is `"out"` for
`from`, `"in"` for `to`; `count` is `e.count` verbatim; `unknown` is true when
the other end is not in `names` (the payload's own session names). A self-edge
appears once.

**Rationale**: FR-013. Matching by name is what the map's own wire drawing does
(`web/map.html:867-890`) and what the payload supports — `peers_graph` groups
by `[from_name, to_name]` and emits `{from, to, count, last, sample}`
(`bin/ccwatch:2673-2676`), with no sid on either end. The spec's assumption
fixes this and adds that an edge whose other end is not in the payload is
"stated as such rather than silently dropped" — hence `unknown`, rendered as a
trailing "— not in this snapshot". `last` and `sample` are not read: `sample`
is message text, and the modal is not a place transcript-adjacent content needs
to appear (principle X's spirit; the roster made the same call, D21 there).

## D12 — Five failure renderings, from one function

**Decision**: `feedLines(cond) → {main, mainKind, unreadable}` and
`goneText(name, sid) → string`, both in `modal.js`. `panel()` composes them and
the page writes three nodes.

**Rationale**: SC-009 requires the four feed conditions and the vanished-session
case to be "five pairwise-distinct renderings inside the modal", which is a
property of a set of strings and is therefore asserted directly in `node` — one
assertion comparing all five pairwise, which no amount of later editing can
quietly break.

The wording is the modal's own, not the roster's, because the subject differs:
the roster says "rows shown are 4m old", the modal says what *this panel* is
showing. FR-044's "additively" is `unreadable` as a separate string that is
never joined into `main` — the same construction `renderTrust` and
`statements()` both use, and R5 of entry 002: absent or zero prints nothing.

FR-043 (warming) prints no age and no volatile reading; the age is absent from
the sentence, not printed as `0s`.

## D13 — The vanished session: the subject is held independently of the payload

**Decision**: `openModal` captures `subject = {sid, name}` and the page never
re-reads the name from the payload for it. `panel()` is called with
`row: null` when `lastRows[subject.sid]` is missing.

**Rationale**: FR-045 and the spec's Key Entities entry say exactly this — the
identity is held "so the panel can still say something when the row
disappears". With `row` null the model keeps the header name, keeps the session
id line, drops every other stat, disables both write controls with "this
session is no longer in the snapshot", and states `goneText`, which includes
`claude --resume <sid>` as the edge case requires.

`goneText` is only reachable when the feed is trusted, for the reason
`resolveSelection` already encodes (S2, `web/roster.js:150-160`): a feed that
cannot be read is not evidence a session exited. Under an untrusted tick the
panel says the feed is down and keeps what it had.

## D14 — Follow-at-bottom is a pure predicate; non-disturbance is kept by reconcile

**Decision**: `atBottom({scrollTop, scrollHeight, clientHeight}) → boolean`
with an 8px tolerance, in `modal.js`. `renderConvo` samples it *before*
reconciling and, if true, sets `scrollTop = scrollHeight` after.

**Rationale**: FR-018 is two properties and only one of them exists today. The
spec's assumption says so: reconciliation never removes a turn still wanted, so
scroll position is already undisturbed (`web/map.html:1098-1100`), and
following is new. Sampling before and applying after is the only ordering that
works, because reconcile changes `scrollHeight` underneath the reading.

8px rather than 0 because sub-pixel layout and fractional device pixel ratios
make an exact equality false on a view the reader considers to be at the bottom;
8 is small enough that one line of 12px text does not fit inside it, so
"scrolled up to read something" cannot be mistaken for "at the bottom".

Keeping the predicate in the module makes it assertable without a browser
(FR-050) — the interesting cases are the boundary ones.

## D15 — The transcript's one empty state becomes three sentences

**Decision**: three distinct messages, chosen from the row rather than from the
turn count:

| Condition | Sentence |
|---|---|
| `row.entrypoint === "sdk-ts"` | this is an embedded-SDK session: it writes no transcript, so there is nothing to read here |
| turns empty, not `sdk-ts` | no turns in the transcript's last <N> entries yet |
| fetch failed | could not read the transcript: `<reason>` |

**Rationale**: today all three land on one string — "No transcript yet.
Embedded-SDK sessions never write one." (`web/map.html:1094`) — which asserts
something about the session that the page did not check. That is principle IV
(a failure must not look like an absence) and V (never state what you did not
read) in one line. FR-019 requires the first two to be distinct and the third
to carry its reason.

`entrypoint` is the field that carries the fact (`bin/ccwatch:909`) and
`sdk-ts` is the value the collector writes for the embedded SDK
(`bin/ccwatch:883-887`); `token` is a verdict derived from it, so the panel
reads the fact. Nothing here escalates the session's silence (principle VI) —
the sentence is about the absence of a file, not about the session's state.

## D16 — No new timer, no new endpoint, no new `innerHTML`

**Decision**: the modal's transcript poll keeps using the existing shared
scheduler slot `every("convo", 5000, loadConvo)` (`web/map.html:1023-1033`),
and `resume()`'s visibility handling is unchanged.

**Rationale**: FR-049, SC-010 and SC-011. The scheduler exists for exactly this
and the suite already counts `setInterval` occurrences at 1 and
`requestAnimationFrame` at 0 (`tests/run.sh:1548-1551`). FR-017's "slower than
the map's state tick" is 5000 against 3000, unchanged. The two existing
`innerHTML` assignments — the once-built legend and the escape-first turn body
— stay at two, and the new stats/feed/tombstone nodes are built with
`createElement`/`textContent`, as `rosterEls`, `askEls` and `killEls` are.

`bin/ccwatch` is not modified at all: `modal.js` is served by the static
fallback (`SimpleHTTPRequestHandler` with `directory=WEB`,
`bin/ccwatch:2900-2901`), exactly as `roster.js` is. That is what makes
FR-035, FR-047 and FR-048 true literally rather than by inspection.

## D17 — Disabled means the `disabled` attribute *and* a guard in the handler

**Decision**: a gated control renders as a real `<button disabled>` (or a
disabled `<input>`), with its reason as adjacent text, and its handler also
returns early on the same condition.

**Rationale**: FR-027 and FR-029 require that activating a disabled control
issues no request. The attribute alone suppresses the click event in every
engine, but the handler guard is the assertion that survives a later
refactor that renders the control enabled by mistake — two independent reasons,
which is what principle I asks for applied to a control rather than a verdict.
It also covers the keyboard case FR-029's scenario names explicitly.

The reason text is adjacent, not a `title` attribute: a tooltip is not readable
by a keyboard user and is not text a screen reader announces reliably
(principle VII).

## D18 — `can_kill` flipping false closes an open confirmation

**Decision**: `panel()` returns `kill.confirmOpen` as `confirmOpen && canKill`,
and the page removes `#killconfirm`'s `.on` class whenever the model says the
step is closed.

**Rationale**: FR-034 and the spec's edge case for a server restarted without
the flag. Deciding it in the model rather than in an `if` in the page means the
transition is assertable without a browser: `panel({confirmOpen: true, canKill:
false})` must return a closed step and the disabled reason.

## D19 — Layout: centred, backdropped, stackable, and no motion

**Decision**: `dialog#agentmodal` at `max-width: min(760px, 92vw)`,
`max-height: 88vh`, an internal flex column with `#convo` as the flexed
scroller, a dimmed `::backdrop`, and — below the roster's existing 720px
`STACK_BREAKPOINT` — `max-width: 100vw` with the same internal order. No
transition or animation on open or close.

**Rationale**: FR-041 asks for usability in the stacked layout, and reusing
`STACK_BREAKPOINT` (720, `web/roster.js:21`) means the modal and the roster
cannot disagree about what "narrow" is — the same reason `stacked()` and the
`@media` rule both read that constant. The `prefers-reduced-motion` edge case
is satisfied by there being no motion to reduce, which is cheaper than a
motion-plus-media-query pair and cannot rot the way `#camera.eased` did (D8 of
entry 004).

Order inside the panel is fixed by FR-020: the ask panel is above the
conversation. Header, stats, feed sentences, tombstone, ask, conversation,
kill, send.

## D20 — Escape, Enter and the map's keys cannot collide

**Decision**: the dialog's `cancel` event closes it (native). The message
input keeps `Enter` → send and **loses** its `Escape` handler, which is now the
dialog's. The map's `keydown` stays bound to `#world`.

**Rationale**: today Escape only closes the drawer while the reply input has
focus (`web/map.html:1340-1343`), which is defect 2 in the spec's overview.
Native `cancel` covers every focus position inside the panel, so the
input-level handler becomes a second path to the same thing and is removed
rather than left to disagree. `Enter` in the input must not also submit
anything else — the dialog has no `<form method="dialog">`, deliberately, so
there is no implicit submit to fire.

## D21 — Test surfaces, and what each one is for

**Decision**: three places, matching where each claim is actually decided:

1. **`modal-module`** — a new section in `tests/run.sh`, `node`-only, shaped
   exactly like the existing `roster-module` (`tests/run.sh:2425`): a generated
   `modal-check.js` that `require()`s `web/modal.js`, emits one
   `PASS|name|detail` line per check, and calls `t_skip` with the reason when
   `node` is absent (constitution: an assertion must not encode one machine's
   configuration). This carries every sentence, every gate state, the stat
   ordering and absence rules, the edge filter, the five-way distinctness and
   the scroll predicate.
2. **`serve`** — source-level guards beside the existing `innerHTML`,
   `setInterval` and `SEND_TOKEN` ones (`tests/run.sh:1464-1551`): no
   `id="reply"` remains; the dialog is opened with `showModal`; `innerHTML`
   still exactly 2; `setInterval` still exactly 1; `requestAnimationFrame`
   still 0; `drag.moved` consumed in one place; the figures carry `tabindex`
   and a `role`; the roster's opener exists and is outside the listbox; the
   `SEND_TOKEN` placeholder is byte-identical; the send and kill `fetch` calls
   still carry `X-CCWatch-Token`.
3. **`kill` / `send`** — unchanged. The server-side gate assertions already
   exist (`tests/run.sh:1871`, `:637`) and FR-035 says nothing there changes;
   the entry adds no assertion there and must not disturb one.

`TALLY_FLOOR` rises from 455 by the number added, and every new assertion gets
a mutation-table row in `README.md` (FR-052, FR-054).

**Rationale**: each claim is asserted where it is computed. The five sentences
are computed in the module, so they are asserted there; "there is no second
inspector on the page" is a property of the file, so it is asserted by reading
the file; the kill gate is a property of the server, which this feature does
not touch.

## D22 — Three outcomes must read as three, including the transport failure

**Decision**: the `catch` arms of `doSend` and `doKill` prefix the exception
with what did not happen — "the send request did not complete: `<message>`" and
"the kill request did not complete: `<message>`".

**Rationale**: FR-024 and FR-032 require the refusal, the success and the
transport failure to read as three distinct outcomes. Today the transport arm
writes the bare `e.message` (`web/map.html:1289`, `web/map.html:1335`), which
lands in the same node, in the same red, as a server refusal — so a page that
could not reach the server reads as a server that refused. Principle IV: two
different facts must read differently. The refusal text itself is untouched and
still verbatim (FR-032).

---

## Numbers this plan settles

| Value | Chosen | Why |
|---|---|---|
| Transcript poll cadence | `5000` ms | unchanged; FR-017 needs only "slower than 3000" |
| State tick | `3000` ms | unchanged (FR-046) |
| Bottom-follow tolerance | `8` px | smaller than one 12px line, larger than sub-pixel error (D14) |
| Modal max width | `min(760px, 92vw)` | the conversation is the tallest thing in it; 760 keeps a readable measure |
| Modal max height | `88vh` | leaves the backdrop visible on all four sides, so it reads as a layer |
| Stacked breakpoint | `720` px | `CCWATCH_ROSTER.STACK_BREAKPOINT`, not a second number |
| Question text length in the modal | full | the roster truncates to 100 chars; FR-020 gives the modal the question and its options whole |
| Peer-edge fields read | `from`, `to`, `count` | `last`/`sample` are message content and are not shown (D11) |

## Unknowns

None. Every NEEDS CLARIFICATION the Technical Context could have carried is
resolved above or fixed by the spec's Assumptions; nothing in this feature
depends on a fact about the payload, the endpoints or the host that is not
already in the tree.
