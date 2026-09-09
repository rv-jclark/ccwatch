# Contract: what `/map` does — the per-agent modal

**Feature**: `005-agent-modal` | **Plan**: [../plan.md](../plan.md) |
**Module**: [modal-js.md](./modal-js.md) |
**Data model**: [../data-model.md](../data-model.md)

What changes in `web/map.html`. Everything not named here is unchanged, and
FR-046 makes that a requirement rather than an aspiration: the world layout,
the camera and its level-of-detail behaviour, the persisted viewport, the
roster's order, selection and width, and the four feed conditions above the map
all keep working exactly as they do now.

`bin/ccwatch` is **not modified** (D16, D20).

---

## §1 The modal element

`#reply` (`web/map.html:320-333`) becomes:

```html
<dialog id="agentmodal" aria-labelledby="ilead iname">
  <div id="ihead">
    <span id="ilead">agent</span><span id="iname"></span>
    <span id="istatus"></span>
    <button class="ghost" id="iclose">close</button>
  </div>
  <div id="ifeed"><span class="main"></span><span class="unreadable"></span></div>
  <div id="igone"></div>
  <dl id="istats"></dl>
  <div id="ask"></div>
  <div id="convo"></div>
  <div id="killbar"></div>
  <div id="ifoot">
    <input id="replyText" placeholder="message…" autocomplete="off">
    <button id="replySend">send</button>
    <span id="sendwhy"></span>
  </div>
  <span id="replyOut"></span>
</dialog>
```

- **`id="reply"` no longer exists anywhere on the page** (FR-001).
- `#ask`, `#convo`, `#killbar`, `#ifoot`, `#replyText`, `#replySend` and
  `#replyOut` keep their ids, their CSS and their existing `askEls`/`killEls`
  builders (D4). `#istatus`, `#ifeed`, `#igone`, `#istats`, `#ilead` and
  `#sendwhy` are new.
- Order is fixed: header, feed sentences, tombstone, stats, ask, conversation,
  kill, send — the ask panel above the conversation (FR-020).
- The accessible name comes from `#ilead` + `#iname`, so the session's name is
  in exactly one place and cannot drift from the header (FR-038).
- The element stays a `<body>` child, outside `#stage`/`#wrap`, so the map's
  `#world`-bound `keydown` cannot see keys pressed in it (FR-039).
- No `<form method="dialog">`: `Enter` in the message box must send the
  message and nothing else (D20).
- Nodes are built with `createElement`/`textContent`; `innerHTML` assignments
  in `map.html` stay at exactly **two** — the once-built legend and the
  escape-first turn body (FR-049).

## §2 Stylesheet additions

- `dialog#agentmodal` — `max-width: min(760px, 92vw)`, `max-height: 88vh`,
  `display: flex; flex-direction: column`, `border: 1px solid var(--line)`,
  the page's own `--bg`/`--ink`; `#convo` keeps `flex: 1; overflow-y: auto`.
  `dialog:not([open]) { display: none }` is the browser's own rule and is not
  restated.
- `#agentmodal::backdrop` — a dim wash, so the panel reads as a layer over the
  city rather than as part of it.
- `#istats` — a two-column label/value grid; the label column is the `<dt>`,
  so every reading is announced with what it is (principle VII).
- `#ifeed .main.down` / `.main.warming` and `#igone` — the same colours the
  existing `#trust` sentences use, and each carries its own word, never colour
  alone.
- `#killbar` — `display: flex` **always**, replacing `#killbar { display:none }`
  + `.on` (`web/map.html:220-222`): the bar is present whether or not killing
  is permitted (FR-028). `#killconfirm` keeps its `display:none` + `.on`.
- `#ifoot` is never `display:none`; a read-only server gets disabled controls
  and `#sendwhy` (FR-026), replacing `$("ifoot").style.display = CAN_SEND ?
  "flex" : "none"` (`web/map.html:1302`).
- `@media (max-width: 720px)` — the modal goes full-width, same internal
  order; the constant is `CCWATCH_ROSTER.STACK_BREAKPOINT`'s value, shared with
  the roster's own rule (FR-041, D19).
- `.agent:focus-visible .focusring { display: block }` — the drawn focus
  indicator (D7). No `outline` on an SVG group.
- No transition or animation on the dialog, its backdrop or the focus ring
  (D19).

## §3 Rendering — `renderModal()`

One function, called from `openModal()`, from `applyFeed()` on every tick, and
from the kill/send handlers. It **writes into existing nodes only** — nothing
in the panel is created, removed or replaced by a render (FR-040).

```
renderModal():
  if no subject: return
  row    = lastRows[subject.sid] ?? null
  fields = row ? CCWATCH_ROSTER.rowFields(row, {volatile: VOLATILE}) : null
  m      = CCWATCH_MODAL.panel({row, fields, subject, names, edges,
                                cond: lastCond, volatile: VOLATILE,
                                canSend: CAN_SEND, canKill: CAN_KILL,
                                confirmOpen: <#killconfirm has .on>})
  #iname   ← m.header.name        #istatus ← m.header.status ?? ""
  #ifeed   ← m.feed  (main, mainKind class, unreadable — separate nodes)
  #igone   ← m.gone ?? "" and toggle .on
  #istats  ← reconcile(m.stats, key: "stat")   // dt/dd pairs, one per StatLine
  #ask     ← renderAsk from m.ask
  #killbar ← from m.kill (button disabled state, reason text, labels, confirm)
  #ifoot   ← from m.send (input/button disabled state, #sendwhy)
```

Rules:

- `names` is the payload's own session names; `edges` is
  `lastBody.peers.edges` or `[]`.
- Never touched by a render: `#replyText.value`, `#replyOut`'s text,
  `#killout`'s text, `#convo`'s scroll position, and `document.activeElement`
  (FR-040, SC-005).
- `#killconfirm`'s `.on` class is added by its own start button, removed by its
  cancel button, and removed by a render **only** when `m.kill.confirmOpen` is
  false (FR-034).
- `#istats` uses `reconcile()` keyed on `StatLine.key`, the same primitive the
  roster rows and the turns use, so a line appearing or disappearing does not
  rebuild the others.
- `stats` is a `<dl>`; `reconcile` creates one wrapper per line containing a
  `<dt>` and a `<dd>`.

## §4 Opening and closing

```
openModal(sid, name, kind):    // kind is "row" | "figure"
  subject = {sid, name}; opener = {sid, kind}
  #replyText.value = ""; #replyOut ← ""; #killout ← ""
  #killconfirm .on removed
  reconcile(#convo, {}, "turn", …)      // empty
  convo message ← "reading the transcript…"
  renderModal()
  #agentmodal.showModal()
  focus: #replyText when m.send.state === "ready", else #iclose
  loadConvo(); every("convo", 5000, loadConvo)

closeModal():
  subject = null; clearEvery("convo"); #agentmodal.close()
  focus, by identity (D5): live row for opener.sid
        → live figure for opener.sid → #rosterlist if it has rows → #world
```

- Opening for a second session while one is open calls `openModal` again,
  which resets every per-subject field above (FR-006).
- Escape closes via the dialog's native `cancel` → `close`; the
  `#replyText` `Escape` handler is removed (D20). `#iclose` closes. A
  successful kill closes after its 1.2s message, as today (FR-007).
- `showModal()` supplies the focus move, the focus trap and the inert
  background (FR-036, FR-039, D3).

## §5 The four openers

| Path | Mechanism |
|---|---|
| figure, pointer | the existing document `click` handler on `.agent[data-sid]` (`web/map.html:1345-1352`), unchanged except that it calls `openModal(sid, name, "figure")` |
| figure, keyboard | each `<g class="agent">` carries `tabindex="0"`, `role="button"`, `aria-haspopup="dialog"` and an `aria-label` of `"agent <name>: " + titleBits(row)`; `Enter`/`Space` opens (FR-002) |
| roster, keyboard | `o` in the existing `#rosterlist` `keydown` handler, on `focusedSid`; `#rosterlist` gains `aria-keyshortcuts="o"` (FR-003) |
| roster, pointer | `#rosteropen`, a real `<button>` in the roster header **outside** `#rosterlist`, labelled `open <name>` for the focused row and `disabled` with "no agents to open" when there are none; plus `dblclick` on a row as a shortcut (FR-003, FR-004, D6) |

- A row's single click still only selects — emphasise the figure and fly the
  camera — and no opener changes that (FR-004,
  `contracts/page-roster.md §3/§6`).
- `drag.moved` is still consumed in exactly one place, so a pan that ends over
  a figure opens nothing (FR-005, D8).
- The figure's `aria-label` is written in `updateFigure` from the same
  `titleBits(row)` the `<title>` gets, so the two cannot disagree.
- `#rosternote` states both roster paths in words: click selects and flies,
  `o` or a double click opens.

## §6 The conversation

- `loadConvo()` keeps `/api/transcript?sid=<sid>&n=40` and the existing
  `renderConvo` reconciliation (FR-015).
- `renderConvo` samples `CCWATCH_MODAL.atBottom(#convo)` **before**
  reconciling and, when true, sets `scrollTop = scrollHeight` after (FR-018,
  D14).
- The empty/failed message comes from `CCWATCH_MODAL.convoMessage(...)`, so an
  `sdk-ts` session, an empty tail and a failed read are three sentences
  (FR-019, D15).
- Polling uses the existing shared `every("convo", 5000, …)` slot and stops
  with everything else when the tab is hidden — `resume()` is unchanged
  (FR-017, SC-011).
- `.what`'s `innerHTML` write is still `CCWATCH_MD.render`, escape-first, with
  a markdown link rendered as text (FR-016, principle X).

## §7 The gated controls

```
kill:  #killstart.disabled = (m.kill.state !== "ready")
       #killwhy ← m.kill.reason ?? ""
       doKill() returns early unless CAN_KILL and a row is present   (FR-029)
send:  #replyText.disabled = #replySend.disabled = (m.send.state !== "ready")
       #sendwhy ← m.send.reason ?? ""
       doSend() returns early unless CAN_SEND and a row is present   (FR-027)
```

- Both controls are always in the DOM; only their `disabled` state and their
  reason text change (FR-026, FR-028, principle IV).
- The attribute and the handler guard are two independent reasons no request is
  issued from a disabled control (D17).
- Every write still sends `X-CCWatch-Token: SEND_TOKEN` and is still subject to
  the server's `Origin` check; neither is relaxed (FR-025, principle IX). The
  `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` line stays byte-identical.
- Outcome text: the three server states verbatim, plus a transport failure
  prefixed with what did not happen (FR-024, FR-032, D22).

## §8 Load order

1. `<script src="/roster.js">`, then `<script src="/modal.js">` — the page's
   inline script uses both, and the order is asserted at source level so a
   later reordering cannot leave `modal.js` first.
2. `rosterEls` IIFE (unchanged) — builds `#stage`, `#roster`, `#rosterlist`
   and now `#rosteropen`.
3. `askEls`, `killEls`, `convoMsgEl` (unchanged builders), then the modal's own
   node builders — all before the first `tick()`.
4. `reflowWorld()`, `resume()` — unchanged.

## §9 What must not change

- One `setInterval`, zero `requestAnimationFrame`, two `innerHTML`
  assignments (FR-049, SC-010).
- Four endpoints, no fifth; no build step, no dependency, no CDN fetch
  (FR-047).
- `bin/ccwatch`: not touched. The `--allow-kill` gate, the `--read-only`
  behaviour, the token check, the `Origin` check, the message size limits, the
  transcript byte tail and the reduction rules are all read as fixed (FR-035).
- `computeFeedCondition`, `renderTrust`, `repaintFooter` and the four
  sentences above the map (FR-046).
- `renderRoster`, `rowFields`, `titleText`, `reorderPlan`, `focusTarget`,
  `nextFocus`, `resolveSelection`, `clampWidth`, the two stored records, and
  `Enter`-selects on a row (FR-046).
- `place()`, `#camera`'s transform writers, `data-lod`, the persisted viewport
  (FR-046).
- No new status, severity, verdict or feed condition (FR-048).
