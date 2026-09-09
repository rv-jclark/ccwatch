# Research: Map — docked agent roster

**Feature**: `004-map-roster` | **Date**: 2026-09-08 | **Spec**: [spec.md](./spec.md)

The spec's Assumptions section closed every open question as a decision, so
there is no NEEDS CLARIFICATION to resolve. What is left is the set of
constructions and numbers the plan owes the implementation. Each decision below
was taken by reading the code that already exists, and each one names what was
rejected and why.

Line references are to the tree at `016e5d3`.

---

## D1 — Where the logic lives: a fourth static module, `web/roster.js`

**Decision**: the ordering-adjacent, formatting, selection-resolution, width
and storage arithmetic goes in a new pure module `web/roster.js`, exporting
`window.CCWATCH_ROSTER` with a `module.exports` tail. Every DOM concern stays
in `web/map.html`. `bin/ccwatch` is not modified.

**Rationale**: the suite has no browser. The only way an assertion can reach
roster behaviour is to `require()` it under `node`, which is the documented
reason `web/md.js` exists as a file (`CLAUDE.md`) and the reason `web/plots.js`
and `web/camera.js` followed. `serve` hands the handler `directory=WEB`
(`bin/ccwatch:2901`) and falls through to `SimpleHTTPRequestHandler.do_GET`
(`bin/ccwatch:3094`), so a new file under `web/` is served with no route and no
change to `bin/ccwatch` — which is what makes FR-035, FR-036 and FR-037 hold
literally rather than by inspection.

**Alternatives rejected**:

- *All of it inline in `map.html`.* Then FR-008/FR-009 ordering, FR-006's
  never-print-a-zero rule, FR-023/FR-024's selection states and FR-031's clamp
  are only assertable by grepping source text, which is not a test of
  behaviour. Entry 003 rejected the same shape for the same reason.
- *Extend `web/camera.js`.* The camera is pure viewport arithmetic with a
  frozen ladder; a roster's row formatter and a selection state machine share
  nothing with it, and `camera.js`'s contract is already asserted by K1–K14.

---

## D2 — The roster does not sort; it renders the payload's arrival order

**Decision**: the panel walks `s.sessions` in the order the payload supplies
and renders that order. No comparator, no sort key and no severity computation
exists anywhere in the page or in `roster.js`.

**Rationale**: FR-010 requires the roster's order to be the payload's order so
the terminal and the panel present the same sequence. A second comparator in
the page is a second implementation of the same rule, and two implementations
of one rule eventually disagree — which is Constitution XI's whole argument,
applied to ordering. The payload is already sorted needs-you-first at
`bin/ccwatch:953`:

```
| sort_by(-([.sev, .psev] | max), -(.waited // .quiet // 0))
```

which *is* FR-008 (descending by the greater of `sev` and `psev`) and FR-009's
first tie-break (descending `waited`, else `quiet`). FR-009's stability
obligation — two rows tied on every ordering field keep their relative order
across ticks — is satisfied upstream of the sort rather than by it: the rows
enter the sort in registry-file order (`for f in "$SESS_DIR"/*.json`,
`bin/ccwatch:221`), which is lexicographic by pid and therefore identical on
every tick for an unchanged set of sessions. The map already depends on this
arrival order for its district aggregate (`web/map.html:478-484`), so trusting
it here is consistent with what ships.

FR-011 follows for free: a severity change reorders the roster because the
payload's order changed, and nothing in the roster's path can reach a
coordinate because no ordering value is ever handed to `plots.js` (the
`NO_REPO`/identity-only rule at `web/map.html:437-440` is untouched).

**How FR-008/FR-009 are then tested**: where the order is computed. The
`ccwatch` section already fabricates sessions at several severities; the new
assertions check `ccwatch --json` for descending `max(sev, psev)`, for the
`waited`/`quiet` tie-break, and for byte-identical row order across two
consecutive runs against a fixture holding two rows tied on every field. That
is a stronger test than asserting a page-side comparator, because it tests the
claim at the one place that makes it.

**Alternatives rejected**:

- *Re-sort in the page with the same key.* Duplicates the rule; makes FR-010 an
  ongoing coincidence rather than a construction; and buys nothing, since the
  payload is already in that order.
- *Sort in the page and assert equality with the payload order.* The assertion
  would pass while the duplication remains, and the first CLI change to the key
  would make the map and the terminal disagree until someone noticed.

---

## D3 — Row order in the DOM: `reconcile()` for identity, a separate ordering pass for sequence

**Decision**: keep the existing `reconcile()` primitive
(`web/map.html:556-577`) unchanged for create/update/remove by `sid`, and add a
second pass that puts the rows in the wanted sequence using `insertBefore` on
already-attached nodes. The move set is computed by a pure
`reorderPlan(currentKeys, wantedKeys)` in `roster.js`, which returns the
minimal list of `{key, before}` moves — `before` being the key to insert ahead
of, or `null` for "append".

**Rationale**: `reconcile()` appends new children at the end and never
reorders, which is correct for a city whose positions come from identity and
wrong for a list whose whole product is its sequence. Splitting the two keeps
FR-042 intact — a row's node, and therefore its focus ring, its selection, its
hover, a text selection inside it and the panel's scroll offset, is the same
node across ticks — while making the sequence explicit. `reorderPlan` is pure,
so "an unchanged order produces zero moves" and "one row moving from last to
first produces exactly one move" are node-assertable, which is what SC-011 and
FR-042 need and what no source grep can show.

**Alternatives rejected**:

- *Teach `reconcile()` to order.* It has four callers on the map (district,
  building, zone, figure) plus turns, gauges, questions and options; none of
  them wants an order, and three of them explicitly must not have one
  (Constitution XIII). A shared primitive that grows a mode used by one caller
  is worse than two primitives.
- *Rebuild the list each tick.* Cheapest to write, and it destroys the focused
  row, the selection, the hover and the scroll offset on every tick — the exact
  wholesale-rebuild failure entry 002 removed from the map.
- *CSS `order` on a flex container.* Would move rows without touching the DOM,
  but leaves the accessibility tree in DOM order, so a screen reader and the
  keyboard would read the *unsorted* sequence while the eye reads the sorted
  one. That is a worse bug than the one being fixed.

---

## D4 — Focus survives an order change, by sid, not by index

**Decision**: before the ordering pass, record whether the active element is a
roster row and which `sid` it holds; after the pass, if the active element is
no longer that row, re-focus the row with that `sid`. The choice of what to
re-focus is the pure `focusTarget(prevSid, wantedKeys)`.

**Rationale**: `insertBefore` on an attached node is a move, and a move is a
remove followed by an insert; engines differ on whether the moved node keeps
focus, and the ones that do not silently drop focus to `<body>`. The spec's
edge case — "a tick that arrives mid-keyboard-navigation: focus stays on the
same session's row even if that row's index changed" — is therefore not free,
and keying the restore on `sid` rather than on the row index is the difference
between "focus stays on the session I was reading" and "focus stays on row 3,
which is now a different session".

**Alternatives rejected**:

- *Trust the engine to preserve focus across a move.* Untestable here (no
  browser in the suite) and untrue in at least some engines. A claim this
  feature makes about keyboard operation cannot rest on it.
- *`aria-activedescendant` instead of real focus.* Avoids the move problem, but
  FR-014 asks for focusable rows with exactly one in the tab order, and real
  focus is what makes `:focus-visible` and browser scroll-into-view work
  without reimplementing either.

---

## D5 — Keyboard model: roving tabindex, clamped at the ends

**Decision**: the list is `role="listbox"`; each row is `role="option"` with
`tabindex="0"` on exactly one row (the last focused, else the selected, else
the first) and `tabindex="-1"` on the rest. `ArrowDown`/`ArrowUp` move one row,
`Home`/`End` jump to the ends, `Enter` selects the focused row. Movement
**clamps** at the ends rather than wrapping. The arithmetic is the pure
`nextFocus(keys, currentSid, key)`.

**Rationale**: FR-014's "exactly one row in the tab order at a time" is the
roving-tabindex pattern by definition, and it keeps `Tab` a single step past
the whole list instead of one step per session — with eighteen sessions,
eighteen tab stops is the accessibility bug rather than the fix. Clamping is
chosen over wrapping because `End` already exists for "go to the bottom": a
wrap turns one keypress too many into a jump across the whole list, and in a
needs-you-first list the top and the bottom mean opposite things.

FR-017 falls out of where the listener is attached: the camera's `keydown` is
on `#world` (`web/map.html:1387`), the roster's is on the list element, and
neither is a descendant of the other, so arrows in the roster never pan and
arrows on the map never move the roster's focus. The reply box is untouched for
the same reason, and the existing `EDITABLE_SEL` guard in the camera's handler
stays as it is.

**Alternatives rejected**: `role="list"` with a `<button>` per row (every row
becomes a tab stop, violating FR-014); a `role="grid"` (a grid promises column
navigation this list does not have).

---

## D6 — Selection is resolved from the payload plus the feed condition, in one pure function

**Decision**: `resolveSelection(storedSid, sessions, cond)` returns one of

| state | when | what the page does |
|---|---|---|
| `none` | no stored sid | nothing |
| `present` | the sid is in `sessions` | mark the row, emphasise the figure, fly if the sid changed |
| `gone` | the sid is absent **and** `cond.trust === "ok"` | tombstone row at the top, no fly |
| `unknown` | the sid is absent and the feed is down or warming | nothing stated, selection retained |

**Rationale**: this is Constitution I and IV in one table. A feed that cannot
be read is not evidence that a session exited, so `gone` is reachable only from
a trusted payload (FR-024); and a selection that quietly disappears is a
failure presented as an absence, so `gone` must be *stated* rather than dropped
(FR-023). Putting all four branches in one pure function makes each of them a
node assertion, including the two the spec calls out as edge cases (absent
while down, absent while warming) and the one that has no observable at all
(`unknown` renders nothing, which is only provably different from `gone` if
both are computed in the same place).

`gone` is also the reason the selection is not simply "the row with a class on
it": the state has to outlive the row.

**Alternatives rejected**: latching a `gone` flag on the page (a latch survives
the session coming back, and the spec's "selected session returns" edge case
requires it not to); deleting the stored sid on the first absent tick (loses
the statement, and loses it hardest exactly when the feed is unreliable).

---

## D7 — Exactly one camera move per selection: `lastFlownSid`

**Decision**: the page keeps `lastFlownSid`. A fly happens only when the
resolved selection is `present` and its sid differs from `lastFlownSid`; the
fly sets it. A refresh tick with the same selection present therefore moves
nothing, and a `gone` → `present` return does not re-fly (the sid is unchanged).

**Rationale**: FR-022 and SC-006 — a selection made once, surviving twenty
ticks and a reload, must produce exactly one camera move. Guarding on "did the
selection change" rather than "is there a selection" is what makes that a
property of the code rather than of the tick cadence. On a reload the stored
selection is restored *without* a fly for the same reason a restored viewport
is not refit: the viewer's last camera position is theirs, and FR-033's
sibling rule (a width change must not discard the camera) says the same thing.
Acceptance scenario 4 of US3 asks only that the row be selected and the figure
emphasised after a reload, not that the camera move again.

**Alternatives rejected**: fly on every tick while a selection exists (twenty
moves instead of one, and it fights a pan the viewer just made); fly on restore
(a reload would yank the viewport the viewer deliberately left elsewhere).

---

## D8 — Reduced motion is decided in the page, not left to the stylesheet

**Decision**: the fly passes `{animate: !reduced}` where `reduced` is
`matchMedia("(prefers-reduced-motion: reduce)").matches`, read at the moment of
the fly.

**Rationale**: a defect found in entry 003's easing while reading it for this
entry. `#camera.eased` is a bounded transition removed by a `transitionend`
listener (`web/map.html:1485-1487`), and under
`@media (prefers-reduced-motion: reduce)` the rule becomes
`transition: none` (`web/map.html:117-119`). With no transition there is no
`transitionend`, so the class is added and never removed — the comment beside
that media query claims the opposite. It has never mattered because entry 003
shipped no caller (`web/map.html:1460-1462`); this feature is the first caller,
so it matters now. Deciding in the page means the class is only ever added when
a transition will actually run and fire, which satisfies FR-020's "immediate
jump when the person prefers reduced motion" literally and FR-043's "reduces to
an instant result" without relying on a listener that cannot fire.

The stylesheet keeps its `transition: none` rule: it is the belt to this
braces, and removing it would leave a motion path for anything that later calls
`centreOn({animate: true})` without checking.

**Alternatives rejected**: changing the CSS so a zero-duration transition still
fires `transitionend` (a 1ms transition is still motion, and it is motion the
person asked not to have); removing the class on the next `applyView` (leaves
the class on until some unrelated camera action happens).

---

## D9 — The panel is left-docked, sized by one custom property, and the divider is a real widget

**Decision**: a `#stage` flex row holds `#roster` then the existing `#wrap`.
`#roster` is `flex: 0 0 var(--roster-w)`. Between them is a
`<div id="rdivider" role="separator" aria-orientation="vertical" tabindex="0">`
carrying `aria-valuenow`/`aria-valuemin`/`aria-valuemax`, draggable by pointer
and adjustable by `ArrowLeft`/`ArrowRight` (`Shift` for a coarse step),
`Home`/`End` for the extremes.

**Rationale**: left, because the roster is the textual representation and the
map is now labelled its companion (FR-013) — reading order should reach the
words first — and because the inspector drawer is `position: fixed` on the
right (`web/map.html:156`), so a right-docked roster would sit under it. One
custom property means the width is written in exactly one place per change,
which keeps FR-041's "no extra repaint path" honest. `role="separator"` with
`tabindex` and the three `aria-value*` attributes is the ARIA window-splitter
pattern, and it is what makes FR-032 ("operable without a pointer") true with
no extra control invented for keyboard users.

Numbers, chosen to fit the row content rather than to look tidy:
`--roster-w` default **320px** (fits `acme/checkout-api` plus a
`004-map-roster` branch on one line at 13px monospace), minimum **220px**,
maximum `min(560px, 45% of the window)`. Keyboard step **16px**, coarse step
**64px**.

**Alternatives rejected**: `resize: horizontal` on the panel (no keyboard
operation, no clamp, no persistence hook); a CSS grid with a draggable gutter
(same work, and the grid's track sizes would need the same single writer);
right-docked (collides with the inspector).

---

## D10 — A width change reflows the world the way a window resize does — and the viewBox is synced once at load

**Decision**: extract the body of the existing `resize` listener
(`web/map.html:1752-1768`) into a `reflowWorld()` that syncs `#world`'s
`viewBox` to the element's pixel size and re-centres on the world point that
was at the centre, then re-clamps. Call it from the window `resize` listener
(unchanged behaviour), from the divider's drag/keyboard paths, and **once at
load**, after the panel exists and before the first tick.

**Rationale**: changing the panel's width changes `#world`'s client width
without firing a window `resize`, so without this the SVG user space and the
element's pixel size disagree and the camera's arithmetic — which is all in
screen pixels — is wrong by the ratio between them. Re-centring rather than
refitting is FR-033: the camera keeps the position the viewer chose.

The load-time call is required by this feature and not merely tidy: inserting
the panel changes `#world`'s width before `loadStoredView()` reads
`clientWidth` (`web/map.html:1324`). It also corrects a pre-existing mismatch
worth recording — `#world` ships `viewBox="0 0 408 408"`
(`web/map.html:276`) and nothing sets the viewBox until the first window
resize, so until this entry the very first paint scaled 408 world units across
the element's real width while `fitView` computed its translation in element
pixels. Syncing at load makes 1 world unit = 1 screen pixel at rung `idx 2`
from the first frame, which is what `contracts/page-camera.md §1` already says
is true. This is a fix, and the map's initial apparent scale changes with it;
nothing about the ladder, the thresholds, the hysteresis or the stored viewport
changes.

**Alternatives rejected**: a `ResizeObserver` on `#world` (a second, implicit
repaint path with no single writer, and FR-041 is specifically about not adding
one); leaving the viewBox alone and treating the divider as a refit (discards
the camera, contradicting FR-033); leaving the load-time mismatch in place (a
divider drag would then visibly jump the map's scale the first time it is used).

---

## D11 — Narrow viewports stack; the status word and the measurement are the last things standing

**Decision**: below **720px** of viewport width, `#stage` becomes a column:
`#roster` sits above the map with `max-height: 40vh` and its own scroll, the
divider is hidden (`display: none`) and the stored width is not applied. Within
a row, the identity line (name, repo, branch) truncates with
`text-overflow: ellipsis`; the status line (`flex: none; white-space: nowrap`)
never does.

**Rationale**: the spec's assumption, made concrete. 720px is the width at
which a 320px panel plus a map narrower than the panel stops being two views
and starts being one crowded one. FR-034 names the two things that may never be
truncated, so they get the CSS properties that make truncation impossible
rather than a comment asking for it — and both properties are greppable, which
is how the assertion checks them without a browser (the same technique the
counter-scaling assertions use at `tests/run.sh:841-860`).

**Alternatives rejected**: a fixed minimum width with horizontal scroll (the
spec rejects it: it eventually truncates exactly what FR-034 protects); hiding
the roster below the breakpoint (the roster is the textual representation —
hiding it removes the accessible reading of the page, Constitution VII).

---

## D12 — One formatter for the row and the figure's title

**Decision**: `rowFields(row, {volatile})` in `roster.js` returns the row's
parts — `{name, where, word, measure, age, pipeline, ctx, mem, asks}` — with
absent readings **absent from the object**, never zero. `map.html`'s
`titleBits()` (`web/map.html:676-691`) is reimplemented as a join over the same
function, so the figure's `<title>` and the roster row can never state
different things about the same session.

**Rationale**: FR-012 asks that every claim the figure draws be reachable as
text in the row. Two formatters would satisfy that on the day they were written
and drift after it. One formatter also makes FR-006 (never print a measurement
the payload did not supply) and FR-005 (the session's word and the pipeline's
phase/status are two statements, never one) properties of a single pure
function with node assertions on each: a null `quiet`, a null `context`, a null
`rss_mb`, an `sdk-ts` row whose silence measures nothing, and an `idle` session
whose pipeline has crashed.

The wording follows the terminal's last column verbatim
(`bin/ccwatch:1092-1097`) so the two renderings read the same:
`"<note> <dur(waited)>"` when `waited` is present, `"quiet <dur(quiet)>"` when
the note is `quiet`, the note alone when there is one, `"<dur(quiet)> ago"`
when there is only a silence, and — for a session with no transcript at all —
the note the payload already supplies (`cannot verify progress`,
`headless, cannot verify`), never a zero.

**Alternatives rejected**: keeping `titleBits()` and writing a second formatter
for the row (drift, and two places to extend when a payload field is added);
moving the whole title into the row and dropping the `<title>` (the hover
reading is useful and removing it is a regression against FR-038).

---

## D13 — The withheld set stays one gate

**Decision**: `rowFields` takes `volatile` as an argument and drops `ctx` and
`mem` when it is false. The page passes the existing module-level `VOLATILE`,
which `applyFeed` sets before anything draws (`web/map.html:1681`). The roster
render is called from `applyFeed`, after that assignment, in the same pass.

**Rationale**: FR-028 asks for the same single gate the map already uses, so
there remains exactly one place to extend the withheld set. Passing the flag as
an argument (rather than reading a global inside the module) is what lets the
suite assert both sides of the gate under `node`, and keeps `roster.js` pure.
The static guard is a line-order assertion of the kind already used for the
legend's `innerHTML` write (`tests/run.sh:1392-1395`): the roster's render call
sits after `VOLATILE = ` inside `applyFeed`.

---

## D14 — The four sentences: one condition, roster wording, exclusion enforced in the formatter

**Decision**: `computeFeedCondition()` stays where it is and is not duplicated.
`statements(cond)` in `roster.js` maps a condition object to
`{main, unreadable, empty, dataAge}` for the roster's own wording, and
**enforces the exclusion itself**: `empty` is emitted only when
`cond.trust === "ok"`, whatever the caller passed.

**Rationale**: the spec's assumption is that the condition is computed once and
rendered twice — the banner above the map and the panel — so the two can never
disagree about whether the feed is trusted (Constitution XI inside the page).
The wording differs because the claims differ: the banner talks about the map,
the roster talks about the rows it is still showing and how old they are
(FR-027). Enforcing the exclusion inside `statements()` rather than trusting
`computeFeedCondition` is what makes SC-007 provable under `node` on arbitrary
input, including a malformed condition object — it is a second gate, not a
second computation, and it derives no status.

FR-026's unreadable sentence names `ccwatch doctor`, matching the terminal
footer and the existing banner text (`web/map.html:1618`).

**Alternatives rejected**: moving `computeFeedCondition` into `roster.js`
(a refactor of delivered behaviour for a test's convenience, and FR-038 asks
for the opposite); reusing the banner's exact sentences (they say nothing about
the rows, so FR-027's "how old the rows you are showing are" would be missing).

---

## D15 — The tombstone lives outside the listbox

**Decision**: the `gone` statement is a dismissible region above the list, not
a `role="option"` inside it. Dismissing it (a real `<button>`) clears the
selection and the stored sid.

**Rationale**: the spec pins it at the top of a needs-you-first list, which is
where attention goes. But a session that has exited is not selectable, has no
`sev` to be ordered by, and must not be counted in the panel's row count
(FR-016) — three reasons it is not an option in the listbox. Keeping it outside
also keeps `nextFocus`'s key list exactly the set of live rows, so arrow
navigation cannot land on a tombstone.

---

## D16 — Two new storage records, versioned and validated like the viewport

**Decision**: `ccwatch.map.selection.v1` holding `{v: 1, sid}` and
`ccwatch.map.roster.v1` holding `{v: 1, w}`. `validateSelection` /
`validateWidth` reject a value that does not parse, carries the wrong `v`, or
is the wrong type, returning `null` rather than throwing; `loadX`/`saveX` take
injected `getItem`/`setItem` and flip a one-way `persistence` flag to
`"unavailable"` on the first throw.

**Rationale**: exactly the shape `camera.js` uses
(`web/camera.js:131-162`) and `plots.js` before it, for the documented reason:
a private-mode or quota-full storage must degrade to session-only rather than
take the page down, and it must not be retried every frame. Two records rather
than one because they have unrelated lifetimes — clearing a selection should
not reset a width — and because a single malformed record would then cost both.

A `sid` is validated as a session-id-shaped string (hex and dashes, bounded
length) before it is trusted, the same discipline `/api/transcript` applies
server-side (`bin/ccwatch:3033`). It is only ever compared against payload
sids and written into a `data-` attribute, never interpolated into markup.

**Persistence unavailable is stated, not hidden** (Constitution IV): a
`#rosternote` in the panel header says the selection and width will not be
remembered, and is empty otherwise (Constitution XII).

---

## D17 — Selection emphasis carries a word, not only a ring

**Decision**: the selected row gets `aria-selected="true"` plus a visible
`selected` marker in its status line; the corresponding figure gets a
`.selected` class on the `<g class="agent">` node, drawing a ring distinct from
every status appearance (a dashed outline in `--info`, which no status uses for
a ring).

**Rationale**: Constitution VII — colour is never the only carrier — applies to
the emphasis this feature introduces just as much as to a severity. The row's
word is the emphasis's textual equivalent, which is the mapping FR-012 asks for
and SC-003 counts. Putting the class on the outer `.agent` group rather than
inside `.figart` matters: `updateFigure()` rebuilds `.figart` wholesale on every
tick (`web/map.html:711-716`), so an emphasis drawn inside it would be
destroyed by the next tick, while the outer group is the node `reconcile()`
keeps.

FR-019's "distinguishably from the figure's status appearance" is why the ring
is dashed and `--info`: `sev4` is `--block`, `sev3` is `--bad`, `busy` is
`--ok`, and the only existing use of `--info` on a figure is the quiet
outline's stroke, which is solid and not a ring.

---

## D18 — Selecting a far-away figure reaches the level where figures carry names

**Decision**: `flyIdx(level)` returns `5` when the current level is `far` and
`null` (keep the current rung) otherwise. `null` means `centreOn` is called
without an `idx`, which keeps the zoom.

**Rationale**: the spec's assumption — keep the current zoom unless the
selected figure's detail level makes it illegible. At `far`, `.agent` is
`display: none` (`web/map.html:101-105`), so flying to a figure without
changing the rung would centre on nothing visible. Rung 5 is the first rung
that `levelFor` resolves to `near` from *any* previous level
(`web/camera.js:100-110`), so it is the lowest rung guaranteed to draw both the
figure and its `.alabel` regardless of hysteresis state — the level at which
figures carry their names, taken from the camera's own thresholds rather than
by picking a number. Nothing about the thresholds or the hysteresis changes.

**Alternatives rejected**: always flying at a fixed rung (discards a zoom the
viewer chose, for a selection that may already be legible); flying at `mid`
(figures are drawn but unlabelled there, so the arrival is ambiguous when
neighbours are close).

---

## D19 — Every figure's world centre is reachable by `sid`

**Decision**: `drawWorld()` builds a `centreBySid` map — `sid → {cx, cy}` —
during the pass it already makes over `placed.world.figures`, and the page
holds the latest one. The fly reads it; if the sid has no entry this tick,
nothing flies.

**Rationale**: `plots.js` already returns `cx`/`cy` per figure
(`web/plots.js:259-261`) and `drawWorld` already walks that object
(`web/map.html:1534-1546`), so this costs one assignment inside an existing
loop and no second pass. Keying by `sid` rather than by the composite figure
key (`f|slug|branch|sid`) is what makes the spec's "a figure that is not
currently drawn" and "two sessions with the same name in different worktrees"
edge cases fall out: the roster never has to know the key's shape, and a row
whose figure is hidden by the level of detail still has a world position,
because `display: none` removes the drawing, not the placement.

---

## D20 — Rendering stays event-driven, and no `innerHTML` is added

**Decision**: the roster renders from four events only — `applyFeed` (a data
change, including the retained-body redraw on a failed tick), a selection
change, a focus change, and a width/viewport change. Every node is built with
`createElement`/`textContent`.

**Rationale**: FR-041 and FR-042. The page keeps exactly one `setInterval`, the
shared visibility-aware scheduler (`web/map.html:928-936`), so the existing
static guard at `tests/run.sh:809-816` continues to pass unchanged; and the
`innerHTML` count stays at two, so `tests/run.sh:1389-1397` does too. Both are
already asserted, which is why this decision needs no new assertion beyond
keeping those green — the guards were built for exactly this kind of later
entry.

---

## D21 — The question text in a row is the payload's, bounded, and never linked

**Decision**: a waiting row's third line carries `asks: <question>` truncated
to 100 characters, taken from `row.questions[0].question` exactly as
`titleBits` already does, and written with `textContent`.

**Rationale**: this is the fact that makes US1's top row actionable, and it is
already on the page in the ask panel and in the figure's `<title>`
(`web/map.html:681`), so nothing new reaches the browser and nothing new
reaches a socket (Constitution X). The bound is this feature's own: the
collector does not truncate `questions[].question` (`bin/ccwatch:1865`) and
`titleBits` does not either, so an unbounded question in a fixed-width panel
would push the status word and the measurement off the row — the two things
FR-034 protects. `textContent` rather than markup is the same discipline
`md.js` and `convo` follow: escape or never format, never link.

---

## Numbers this plan settles

| Constant | Value | Why |
|---|---|---|
| `WIDTH_DEFAULT` | `320` px | fits `acme/checkout-api` plus a feature-branch name on one 13px monospace line |
| `WIDTH_MIN` | `220` px | the narrowest width at which the status word and the measurement still share a line (FR-034) |
| `WIDTH_MAX` | `min(560, 0.45 × window)` px | 560 is the inspector's own width; beyond 45% the map stops being the larger view |
| `WIDTH_STEP` / `WIDTH_STEP_BIG` | `16` / `64` px | one and four character cells at 13px monospace |
| `STACK_BREAKPOINT` | `720` px | below it a 320px panel leaves the map narrower than the panel (D11) |
| `NEAR_IDX` | `5` | the lowest rung `levelFor` resolves to `near` from any previous level (D18) |
| `ASK_CHARS` | `100` | roughly one line at `WIDTH_DEFAULT`; the payload bounds this string nowhere (D21) |
| `STORAGE_VERSION` | `1` | new records, versioned from the start like `camera.js`'s |

## Unknowns

None. No NEEDS CLARIFICATION remains: the spec's Assumptions closed every open
question, and the eight numbers above were the plan's to choose.
