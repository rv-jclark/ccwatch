# Quickstart: validating the per-agent modal

**Feature**: `005-agent-modal` | **Plan**: [plan.md](./plan.md) |
**Contracts**: [modal-js.md](./contracts/modal-js.md),
[page-modal.md](./contracts/page-modal.md)

Two kinds of validation, and the split matters: what a headless suite can
prove, and what only a browser can. The first kind is the acceptance gate. The
second is a checklist a human runs once per story, because the repository has
no browser driver and adding one would break "no build step, no dependencies"
(FR-047) — so the honest thing is to name it as manual rather than to claim
coverage that does not exist.

## Prerequisites

```bash
cd /path/to/ccwatch-citymap    # this worktree
command -v jq awk              # hard requirements
command -v shellcheck node     # optional; each section skips with its reason
```

`node` is what runs the `modal-module` assertions. Without it that whole
section `t_skip`s with the reason and the suite still passes — the rule for a
host that cannot supply what a test needs (FR-056).

---

## 1. The acceptance gate

```bash
./tests/run.sh
```

Expected: every assertion passes, the tally is at or above the raised
`TALLY_FLOOR`, and these sections appear:

```
modal-module         # web/modal.js under node — §2 below
serve                # the static, source-level guards — §3 below
kill / send          # unchanged; the server-side gates this feature does not touch
```

**In a restricted sandbox roughly 13 assertions fail with empty output**
(`resume`, `peers`, `serve`) because `mktemp` is denied. That is the sandbox,
not a regression; re-run with the sandbox off before believing a failure
(`CLAUDE.md`).

While iterating, check the export surface first:

```bash
node -e 'const M=require("./web/modal.js"); console.log(Object.keys(M).sort().join(" "))'
```

Expected: exactly the list in
[modal-js.md §13](./contracts/modal-js.md#13-exports) — and in particular
**no** `sort`, `severity`, `statusOf` or `rowFields`. An export that computes
an order, a status, or a second copy of the roster's formatting is the failure
this check exists to catch.

## 2. The module assertions (`node`, no browser)

Each claim id is asserted in the `modal-module` section of `tests/run.sh`.
The table maps user story to evidence.

| Story | Claims (see [modal-js.md](./contracts/modal-js.md)) |
|---|---|
| US1 — everything the snapshot says | M‑A…M‑F, S‑A…S‑I, E‑A…E‑H |
| US2 — the visible kill gate | K‑A…K‑K |
| US3 — the conversation | C‑A…C‑E, B‑A…B‑E |
| US4 — the blocked one, answered honestly | A‑A…A‑E, N‑A…N‑C |
| US5 — operating it as a modal | B‑A…B‑E (scroll), and §3's page guards |
| US6 — when it cannot be believed | F‑A…F‑H, M‑E |

Four spot checks worth running by hand, because each is a sentence someone
will read and act on:

```bash
# SC-001 / FR-028 — the named defect. Ungated must still render a control,
# and it must name the flag.
node -e '
const M=require("./web/modal.js");
const k=M.killModel({row:{sid:"s",name:"web-app",rss_mb:1832}, fields:{mem:"1832MB"},
                     volatile:true, canKill:false, confirmOpen:true});
console.log(k.state, "|", k.reason, "|", "confirmOpen:", k.confirmOpen);'
# Expected: disabled | …ccwatch serve --allow-kill | confirmOpen: false
# A `state` of anything else, an empty reason, or confirmOpen true is a fail.

# FR-033 / D10 — withheld is not unmeasured. Three inputs, three answers.
node -e '
const M=require("./web/modal.js");
const f=(volatile,mem)=>M.killModel({row:{sid:"s",name:"web-app"},fields:mem?{mem}:{},
        volatile,canKill:true,confirmOpen:true}).confirm;
console.log(JSON.stringify(f(true,"1832MB").frees));
console.log(JSON.stringify(f(true,null).frees));
console.log(JSON.stringify([f(false,"1832MB").frees, !!f(false,"1832MB").freesNote]));'
# Expected: "1832MB" / "an unknown amount" / [null,true]

# FR-011 — an absent reading is absent, not zero.
node -e '
const M=require("./web/modal.js");
const lines=M.statLines({sid:"s",name:"n",word:"idle",where:"no repo"},
                        {sid:"s",name:"n",token:"idle"},{volatile:true});
console.log(lines.map(l=>l.key+"="+l.text).join(" | "));'
# Expected: where=no repo | session=s     (no ctx, no memory, no age, no silence)
# A `0`, `0%`, `0MB`, `-` or `null` anywhere in that output is a fail.

# SC-009 — five pairwise-distinct renderings.
node -e '
const M=require("./web/modal.js");
const s=[["ok"],["warming"],["feed_down"]].map(([t])=>
  M.feedLines({trust:t,reason:"HTTP 502",dataAge:245,unreadable:0}).main);
s.push(M.feedLines({trust:"ok",unreadable:2}).unreadable);
s.push(M.goneText("web-app","1111-2222"));
const nonEmpty=s.filter(Boolean);
console.log(new Set(nonEmpty).size === nonEmpty.length ? "distinct" : "COLLISION", nonEmpty.length);'
# Expected: distinct 4    (the `ok` main is deliberately empty — principle XII)
```

## 3. The static, source-level guards

In the `serve` section, beside the guards they must not disturb
(`tests/run.sh:1464-1551`). Each is a property of the file, so the file is what
is read:

```bash
grep -c 'id="reply"'                web/map.html   # → 0   FR-001
grep -c 'showModal()'               web/map.html   # → 1   D3
grep -c '\.innerHTML *='            web/map.html   # → 2   FR-049
grep -c 'setInterval('              web/map.html   # → 1   SC-010
grep -c 'requestAnimationFrame'     web/map.html   # → 0   SC-010
grep -c 'if (drag.moved)'           web/map.html   # → 1   FR-005 (consumed in one place)
grep -c 'const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";' web/map.html  # → 1  FR-025
grep -c 'X-CCWatch-Token'           web/map.html   # → 2   FR-025 (send and kill)
grep -n 'src="/roster.js"\|src="/modal.js"' web/map.html   # roster.js first, D2
```

Plus, asserted as text rather than counts:

- `#rosteropen` is created outside `#rosterlist` — a `role="option"` has
  presentational children, so an opener inside a row would be invisible to a
  screen reader (research D6).
- `#rosterlist` carries `aria-keyshortcuts`, and `#rosternote` names both
  roster paths in words.
- `updateFigure` writes `tabindex`, `role="button"`, `aria-haspopup="dialog"`
  and an `aria-label` built from the same `titleBits(row)` as the `<title>`.
- The dialog carries `aria-labelledby="ilead iname"` and there is no
  `<form method="dialog">`.
- `#killbar` has no `display:none` rule left, and `#ifoot` is never assigned
  `style.display`.

## 4. Manual browser validation, one pass per story

```bash
# The default server: killing NOT permitted. This is the state SC-001 is about.
./bin/ccwatch serve --open

# And, in a second run, the two gated variants:
./bin/ccwatch serve --allow-kill --port 8788     # kill enabled
./bin/ccwatch serve --read-only  --port 8789     # send disabled
```

Fixtures: for a fabricated set (one waiting with a recorded question, one
`sdk-ts`, one busy-and-quiet holding memory, one with a running pipeline
phase, one idle with no git remote), use the `mksess`/`mktrans`/`mkpeer`
helpers in `tests/run.sh` against a `CLAUDE_CONFIG_DIR` of your own and point
`serve` at it.

### US1 — open one agent and see everything

1. Open from the top roster row (§US5 for the paths) and from a figure.
2. Expect, for a row that carries them: the name; the status word with its
   measurement; the silence or waited duration; age; context; memory; the
   pipeline phase and status; repo · branch; the session id; and one line per
   peer edge touching this session, with its direction in words and its count.
3. Compare the header's status text with the roster row's for the same
   session. They must read identically (SC-002).
4. Open a session whose row has no `rss_mb` and no `context`: neither reading
   appears — not `0MB`, not `ctx 0%`, not `-`.
5. Wait for a tick in which the context percentage changes: the value updates
   and nothing else in the panel moves.
6. Answer the pending question in that session's own terminal: within a tick
   the ask panel stops showing it.

### US2 — the visible kill gate

1. On the **default** server, open any agent: a kill control is present,
   disabled, and states that killing is disabled and that
   `ccwatch serve --allow-kill` enables it (SC-001).
2. Click it, and Tab to it and press Enter: nothing happens, no request in the
   network panel, no confirmation step.
3. On the `--allow-kill` server, open the same agent: the control is live.
   Activate it — a second, distinct step names the session, what killing would
   free, and `claude --resume <sid>`.
4. On a session with `pipeline.status: "running"`: the step names the phase and
   says killing aborts a paid model call. On a `busy` session: it says a tool
   call may be left half-applied.
5. With the confirmation open, stop the server: the memory figure is withheld
   and the panel says the reading is no longer current — not a stale figure
   (FR-033).
6. Restart without `--allow-kill` while the page is open: within a tick the
   open confirmation closes and the disabled reason is shown (FR-034).
7. Kill something the server refuses: the refusal's own text appears verbatim.

### US3 — the conversation

1. Open a session with a long transcript: assistant and user text truncated,
   each tool use reduced to its name and a short argument summary, each tool
   result reduced to its size. **No tool-result content anywhere** (SC-004).
2. A transcript containing a markdown link renders it as text; there is no
   anchor in the panel (`document.querySelectorAll('#agentmodal a').length`
   is 0).
3. Open the `sdk-ts` session: the panel says it writes no transcript, as a fact
   about embedded-SDK sessions.
4. Stop the server and reopen: the panel says the transcript could not be read,
   with the reason.
5. Scrolled to the bottom, new turns bring the view with them. Scrolled up into
   earlier turns, a refresh leaves the position untouched (FR-018).
6. Switch tabs away for a minute: no `/api/transcript` and no `/api/state`
   requests during that time (SC-011).

### US4 — the blocked one

1. A session with a recorded question: the question and its options are above
   the conversation, whole, and the panel says the dialog can only be answered
   in that session's own terminal and that a message from here is queued
   *behind* it.
2. A waiting session with no recorded question: distinct wording, naming what
   it is waiting for.
3. Send a message and watch the outcome: delivered, or queued with the reason,
   or the server's own refusal text. In the network panel, the request carries
   `X-CCWatch-Token`.
4. On the `--read-only` server: the message box and send button are present,
   disabled, and say the server was started read-only. Activating them issues
   no request.
5. Send a message longer than the server's limit: the size reason is shown, not
   "failed".

### US5 — operating it as a modal

1. Tab to a roster row, press `o`: the modal opens for that row and focus is
   inside it. The row is still selected as before, and the camera behaviour is
   unchanged (FR-004).
2. Tab to a figure in the city, press Enter: the modal opens for that figure.
   The figure shows a visible focus indicator before you press anything.
3. Tab repeatedly inside the open modal: focus never reaches the map, the
   roster or the browser chrome's page content behind it (FR-036, FR-039).
4. Press Escape: the modal closes and focus is back on the row (or figure) you
   opened it from (FR-037).
5. Type half a message, leave it, and let ten ticks pass: the text, the
   conversation's scroll position, an open confirmation step, the outcome text
   and the focus are all still there (SC-005).
6. Drag-pan the map and release the pointer over a figure: nothing opens
   (FR-005).
7. Open a second agent while one is open: the subject is replaced wholly and
   the half-typed message does not follow it (FR-006).
8. Narrow the window below 720px: every control in the modal is reachable and
   the conversation is still readable (FR-041).
9. With `prefers-reduced-motion` set, open and close it: nothing about its
   appearance requires motion to understand.

### US6 — when it cannot be believed

1. With a modal open, stop the server: the panel states the feed is down, with
   the reason and the age of what it is showing; the context and memory lines
   are gone; repo, branch and session id remain (SC-008).
2. Restart the server so the first snapshot is warming: the panel says so, with
   no age and no volatile reading.
3. With an unreadable registry file present, the count is stated additively,
   alongside whatever else the panel is saying — and never when the count is
   zero.
4. Exit the session the modal is open on: the panel says it is gone, keeps the
   name and session id it was opened with, and offers
   `claude --resume <sid>`. That sentence must not read like the feed-down one.
5. Kill a session from an `--allow-kill` server with its modal open: the panel
   reports the kill, closes, and focus lands somewhere sensible — not on a row
   that no longer exists.

## 5. What must still be true afterwards

```bash
./tests/run.sh                       # green, tally ≥ TALLY_FLOOR
shellcheck -x -S warning bin/ccwatch tests/run.sh
git diff --stat -- bin/ccwatch       # empty: this feature changes no server code
./bin/ccwatch once                   # the terminal view, unchanged
./bin/ccwatch doctor                 # ccwatch's own view still trustworthy
```

And in the browser, on the default server: the city's geography has not moved,
the camera and its level-of-detail rungs behave as before, the persisted
viewport still restores, the roster's order, selection and width are unchanged,
and the four feed conditions above the map still read as four distinct things
(FR-046).
