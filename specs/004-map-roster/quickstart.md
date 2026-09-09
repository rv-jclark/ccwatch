# Quickstart: validating the docked agent roster

**Feature**: `004-map-roster` | **Plan**: [plan.md](./plan.md) |
**Contracts**: [roster-js.md](./contracts/roster-js.md),
[page-roster.md](./contracts/page-roster.md)

Two kinds of validation, and the split matters: what a headless suite can
prove, and what only a browser can. The first kind is the acceptance gate. The
second kind is a checklist a human runs once per story, because the repository
has no browser driver and adding one would break "no build step, no
dependencies" (FR-040) — so the honest thing is to name it as manual rather
than to claim coverage that does not exist.

## Prerequisites

```bash
cd /path/to/ccwatch          # or the worktree
command -v jq awk            # hard requirements
command -v shellcheck node   # optional; each section skips with its reason
```

`node` is what runs the `roster` module assertions. Without it that whole
section `t_skip`s with the reason and the suite still passes — which is the
rule for a host that cannot supply what a test needs (FR-047).

---

## 1. The acceptance gate

```bash
./tests/run.sh
```

Expected: every assertion passes, the tally is at or above the raised
`TALLY_FLOOR`, and the new sections appear:

```
roster-module        # web/roster.js under node — §2 below
serve                # the static, source-level guards — §3 below
ccwatch              # the ordering assertions — §4 below
```

**In a restricted sandbox roughly 13 assertions fail with empty output**
(`resume`, `peers`, `serve`) because `mktemp` is denied. That is the sandbox,
not a regression; re-run with the sandbox off before believing a failure
(`CLAUDE.md`).

Run only the module section while iterating:

```bash
node -e 'const R=require("./web/roster.js"); console.log(Object.keys(R).sort().join(" "))'
```

Expected: exactly the export list in
[roster-js.md §9](./contracts/roster-js.md#9-exports) — and in particular **no**
`sort`, `severity` or `statusOf`. An export that computes an order or a status
is the failure this check exists to catch.

## 2. The module assertions (`node`, no browser)

Each claim id below is asserted in the `roster-module` section of
`tests/run.sh`; the table is the map from user story to evidence.

| Story | Claims (see [roster-js.md](./contracts/roster-js.md)) |
|---|---|
| US1 — order and content | R‑A…R‑K (row content), O‑A…O‑E (`reorderPlan`) |
| US2 — keyboard and text | K‑A…K‑E (`nextFocus`), T‑A…T‑B (`titleText` = row text) |
| US3 — selection and fly | S‑A…S‑I, P‑I |
| US4 — the four sentences | C‑A…C‑J |
| US5 — width | W‑A…W‑F, P‑A…P‑H |

Spot-check the two that carry the most weight, by hand:

```bash
# FR-006 — an absent reading is absent, never zero.
node -e '
const R = require("./web/roster.js");
const f = R.rowFields({sid:"s1", name:"web-app-4f", repo:null, branch:null,
  token:"busy", note:"no transcript; cpu moving", quiet:null, waited:null,
  age:3600, context:null, rss_mb:null}, {volatile:true});
console.log(JSON.stringify(f, null, 1));'
```

Expected: `where` is `"no repo"`, `word` is `"busy"`, `measure` is the note, and
there is **no** `ctx` key, **no** `mem` key and no `0`, `0%` or `0MB` anywhere
in the output.

```bash
# FR-029/SC-007 — "no live sessions" cannot appear beside a failure sentence.
node -e '
const R = require("./web/roster.js");
for (const t of ["ok","feed_down","warming"])
  console.log(t, JSON.stringify(R.statements(
    {trust:t, reason:"HTTP 500", dataAge:42, unreadable:2, empty:true})));'
```

Expected: `empty` is a sentence only on the `ok` line; on the other two it is
`""` even though `empty: true` was passed. `unreadable` names `ccwatch doctor`
on all three (it is additive).

## 3. The static, source-level guards

No server and no browser needed; these run inside the existing `serve` section.

| Guard | What it protects |
|---|---|
| `innerHTML` assigned exactly twice in `map.html` | FR-042 — the roster is built with `createElement` |
| exactly one `setInterval`, zero `requestAnimationFrame` | FR-041 — no new repaint path |
| `const SEND_TOKEN = "__CCWATCH_SEND_TOKEN__";` byte-identical | FR-039 |
| `.rrow .rstatus` carries `flex:none` and `white-space:nowrap` | FR-034 — the status word and measurement never truncate |
| `#rosterlist` has `role="listbox"`; `.rrow` template has `role="option"` and `tabindex` | FR-014, FR-016 |
| `#rdivider` has `role="separator"`, `tabindex="0"` and the three `aria-value*` | FR-032 |
| `#world`'s `aria-label` still contains `Arrow keys` **and** now names itself a companion view | FR-013 |
| the roster's `keydown` is bound to `#rosterlist`, not to `document` | FR-017 |
| the `renderRoster(` call inside `applyFeed` sits after the `VOLATILE =` line | FR-028 — one withholding gate |
| `if (!window.CCWATCH_ROSTER) return;` guard present | a missing module must not take the map down |
| no `@media (prefers-reduced-motion: reduce)` block precedes the `#camera.eased` one | keeps the existing reduced-motion assertion meaningful |

## 4. The ordering assertions (`ccwatch --json`, hermetic)

FR-008–FR-010 are asserted where the order is computed (research D2), against
a fabricated `~/.claude` under `$WORK` via `CLAUDE_CONFIG_DIR` with
`CCWATCH_FAKE_PS`:

1. sessions at severities 4, 3, 2, 1, 0 ⇒ `.sessions` is descending by
   `max(sev, psev)`;
2. two rows tied on `max(sev, psev)` with different `waited` ⇒ the larger
   `waited` first; with no `waited`, the larger `quiet` first;
3. a pipeline `needs_input` on an `idle` session ⇒ that row sorts with the
   `waiting` rows (its `psev` is 4) and its own `token` is still `idle`;
4. two rows tied on **every** ordering field ⇒ two consecutive
   `ccwatch --json` runs produce the same row order (FR-009's stability).

## 5. Manual browser validation, one pass per story

```bash
./bin/ccwatch serve --open        # or --port 8787, then open /map
```

Real sessions are fine for a *look*; for a repeatable check, point the server
at a fabricated home so the payload is under your control:

```bash
FAKE=$(mktemp -d); mkdir -p "$FAKE/sessions" "$FAKE/projects/-fake-repo"
# one waiting, one crashed-pipeline idle, one busy-and-quiet, one idle
# (see the mksess/mktrans helpers in tests/run.sh for the file shapes)
CLAUDE_CONFIG_DIR="$FAKE" ./bin/ccwatch serve --port 8788
```

### US1 — what needs me, in order

- [ ] The panel is docked beside the city with one row per session.
- [ ] The top row is the session blocked on you; it reads `waiting` **and** how
      long it has waited.
- [ ] A `HUNG?` row reads `HUNG?` and the silence behind it.
- [ ] An idle session whose run crashed shows two statements: `idle`, and
      `<phase>/CRASHED` — never one merged phrase.
- [ ] A session in a directory with no remote reads `no repo` and names no
      repository.
- [ ] Send a session from `busy` to `waiting` (or edit the fixture): the roster
      reorders and **no figure moves**. Note a figure's position first.

### US2 — keyboard and screen reader

- [ ] `Tab` reaches the panel in **one** stop, not one per row.
- [ ] `ArrowDown`/`ArrowUp` move between rows; `Home`/`End` jump to the ends;
      movement clamps at both ends.
- [ ] `Enter` selects the focused row and does **not** open the inspector.
- [ ] With VoiceOver (`Cmd-F5`): the panel announces as a list of active agents
      with a count; each row reads as one sentence — name, repo and branch,
      status word, measurement; the selected row announces as selected.
- [ ] Every figure appearance has a word in its row: raised arm ⇒ `waiting`,
      tilt+`?` ⇒ `HUNG?`, bobbing ⇒ `busy`, outline ⇒ `sdk-ts`/`shell`/
      `unknown`, `z` ⇒ `idle`, body fill ⇒ `ctx NN%`.
- [ ] The map graphic announces as a companion view, not as the sessions
      themselves.
- [ ] With the map focused, arrows still pan and `+`/`-`/`0` still zoom and fit.
- [ ] Typing in the reply box moves neither focus nor the camera.

### US3 — selection and the camera

- [ ] Selecting a row marks it, emphasises exactly one figure, and clears the
      previous emphasis.
- [ ] The camera flies to the selected figure once, animated.
- [ ] With **Reduce motion** on (System Settings → Accessibility → Display) the
      move is an instant jump, and a subsequent drag of the map is *not*
      sluggish — the `.eased` class must not have been left on (research D8).
- [ ] Zoom all the way out to `far`, then select a row: the camera arrives at a
      zoom where the figure and its name are drawn.
- [ ] Wait through several ticks: the selection, the row marker and the figure
      emphasis survive, and the camera does not move again.
- [ ] Reload: the same row is selected, the figure is emphasised, and the camera
      does **not** fly again.
- [ ] Remove the selected session from the fixture: a tombstone appears at the
      top of the list saying that session has gone, in a different sentence from
      the feed-down one; the other rows still render; dismissing it clears the
      selection.
- [ ] Clicking a figure still opens the inspector, with its ask panel,
      conversation, send box and kill bar.

### US4 — when the list cannot be believed

- [ ] `Ctrl-C` the server: the panel states the feed is down, with the reason
      and the age of the rows it still shows, and **every** `ctx NN%` and
      `NN MB` disappears from every row.
- [ ] Restart it: the statement clears and the readings come back on the same
      repaint.
- [ ] Cold start (`CCWATCH_SNAPSHOT_CADENCE=30 ccwatch serve`): the panel says
      the first snapshot is still being taken and lists no rows.
- [ ] `printf 'not json' > "$FAKE/sessions/9999.json"`: the panel says one
      registry file could not be read and names `ccwatch doctor`.
- [ ] An empty fixture home: the panel says there are no live sessions — and
      that sentence never shares the panel with the three above.

### US5 — width

- [ ] Drag the divider: both panes take the new width and the map's camera keeps
      its centre (it does not refit). Note the centre first.
- [ ] Reload: the width is restored.
- [ ] Narrow the window below the panel's stored width: the width clamps to
      something usable rather than crushing the map.
- [ ] Focus the divider and use `ArrowLeft`/`ArrowRight` (and `Shift`+arrow):
      the width changes with no pointer.
- [ ] At a 360px-wide viewport the panel sits above the map, scrolls, and every
      row still shows its status word and its measurement.

## 6. What must still be true afterwards

```bash
./bin/ccwatch once                 # unchanged rendering
./bin/ccwatch once | grep HUNG     # still greppable
NO_COLOR=1 ./bin/ccwatch once      # still colourless
./bin/ccwatch doctor
./bin/ccwatch --json | jq 'keys'   # same keys as before this feature
git diff --stat main -- bin/ccwatch # EMPTY — this feature touches no shell
```

`SC-010` is the strong form of that last check: for one fabricated fixture,
`ccwatch once`, `ccwatch once | grep HUNG` and `ccwatch --json` are
byte-identical to the pre-change build. The empty `git diff` for `bin/ccwatch`
is what makes it so by construction.
