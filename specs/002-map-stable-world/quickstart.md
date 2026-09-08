# Quickstart — validating `002-map-stable-world`

**Feature**: `002-map-stable-world` | **Date**: 2026-09-08

How to prove the feature works, end to end. Two halves, because the feature has
two kinds of claim:

- **Automated** — everything the suite can check without a browser: the
  `parse_failed` count across all four consumers, the pure geometry under
  `node`, and the static page guards. `./tests/run.sh`.
- **By hand, in a browser** — the claims that are about a *rendered* page over
  *time*: coordinates identical between frames, an inspector surviving a
  refresh, four sentences reading differently. There is no headless browser and
  FR-052/FR-054 forbid adding one, so these are scripted below with a
  fabricated registry and an expected outcome for each.

Nothing here reads live sessions. Every step drives a fabricated
`CLAUDE_CONFIG_DIR` with `CCWATCH_FAKE_PS` substituting the liveness probe
(FR-057).

---

## 0. Prerequisites

```bash
jq --version          # required
node --version        # optional; without it the plots and markdown sections skip
shellcheck --version  # optional; without it the lint section skips
curl --version        # optional; without it the serve section skips
```

Run everything from the worktree root. In a restricted sandbox roughly 13
assertions fail with empty output because `mktemp` is denied — that is the
sandbox, not a regression. Re-run with the sandbox off before believing a
failure.

---

## 1. The suite

```bash
./tests/run.sh
```

Expected: shellcheck clean at `-S warning`, zero failures, the tally at or above
the raised `TALLY_FLOOR`, and a new `plots` section. On a host without `node` the
`plots` and `markdown` sections skip with their reason stated and the tally still
clears the floor (FR-060, FR-061).

---

## 2. The unreadable-rows count, in all four places (FR-033–FR-036, SC-009)

This is the one part of the feature that is entirely server-side, and it is
asserted as such rather than by inspecting the page (FR-058). To reproduce by
hand what the suite asserts:

```bash
FH=$(mktemp -d)/claude; mkdir -p "$FH/sessions" "$FH/projects"
SID=aaaaaaaa-0000-0000-0000-000000000001
NOW_MS=$(( $(date '+%s') * 1000 ))

# one good session…
cat > "$FH/sessions/9001.json" <<EOF
{"pid":9001,"sessionId":"$SID","name":"web-app-1","cwd":"/fake/repo",
 "status":"idle","kind":"cli","startedAt":$NOW_MS,
 "procStart":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
EOF
mkdir -p "$FH/projects/-fake-repo"
printf '{"type":"assistant","timestamp":"%s"}\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  > "$FH/projects/-fake-repo/$SID.jsonl"

# …beside one file caught mid-write
printf '{"pid":9002,"cwd":' > "$FH/sessions/9002.json"

printf '%s %s %s\n' 9001 "$(date '+%a %b %e %T %Y')" "0:10.00" > /tmp/ps-pf

export CLAUDE_CONFIG_DIR="$FH" CCWATCH_FAKE_PS=/tmp/ps-pf
```

| Command | Expected |
|---|---|
| `./bin/ccwatch --json \| jq .parse_failed` | `1` |
| `./bin/ccwatch once \| tail -2` | the footer includes `· 1 unreadable registry file(s) — run: ccwatch doctor` |
| `./bin/ccwatch doctor \| grep -i parse` | `1 registry file(s) would not parse …` |
| `./bin/ccwatch serve --port 18799 &` then `curl -s localhost:18799/api/state \| jq .parse_failed` | `1` — the same number |

Then delete `9002.json` and repeat: all four must report `0`, and the footer and
`doctor` must say **nothing** about it (Constitution XII).

Against the code as it stands on 2026-09-08 every one of these yields nothing —
no key in `--json`, no footer note, no `doctor` line. That is the defect, and
this table is the proof it is fixed.

Reap the server when done: `pkill -f 'ccwatch serve --port 18799'`.

---

## 3. Serve the map against a fabricated city

A fixture with two orgs, a remote-less directory, two worktrees of one
repository, and peer traffic in both directions — enough to exercise Stories 1,
4 and 5 at once.

```bash
./bin/ccwatch serve --port 18800 --open   # CLAUDE_CONFIG_DIR/CCWATCH_FAKE_PS still exported
```

Open `http://127.0.0.1:18800/map`. Reap with
`pkill -f 'ccwatch serve --port 18800'` when finished.

---

## 4. Story 1 — the city stays where I learned it (FR-006–FR-013, SC-001–SC-003)

| Step | Expected |
|---|---|
| Note where each building sits. Change one session's `status` in its registry file from `busy` to `waiting` and wait one tick | **No** district, building, zone or figure moves. Only appearance changes — the raised arm, the colour, the border |
| Reload the page | Every coordinate is where it was before the reload |
| Add a registry file for a repository never seen before | It appears in unoccupied space. Nothing already placed moves |
| Delete a session's registry file, wait a tick, restore it | The figure returns to the coordinate it held |
| Two sessions in one repository on different branches | Same building, different zones, each zone labelled with its branch |
| A directory with no git remote | Its own district, labelled `no repo`, never inside a real organisation's district |

Read coordinates from the DOM rather than by eye where a judgement is close:

```js
// in the browser console — a stable, comparable snapshot of the whole world
[...document.querySelectorAll('#camera [data-key]')]
  .map(g => g.dataset.key + ' ' + g.getAttribute('transform')).sort().join('\n')
```

Copy that before and after each step and `diff` the two. SC-001 and SC-002 are
"identical", so a diff is the right instrument.

---

## 5. Story 2 — a refresh does not interrupt what I am doing (FR-015–FR-020, SC-004, SC-005)

| Step | Expected |
|---|---|
| Click a figure to open the inspector, then let 10 refreshes pass (30s) | Still open, still the same session, ask panel and send box and kill bar intact, conversation updated in place |
| Start a text selection inside the conversation and let 2 refreshes pass | The selection is still there |
| Rest the pointer on a figure and let a refresh land | The hover state and its tooltip are still there |
| Tab to a figure, then let a refresh land | Focus is still on the same figure |
| Delete a session's registry file and wait a tick | Its figure is removed; nothing else changes |
| With the payload unchanged (a `304`), watch the DOM | Zero nodes created or removed. Confirm with a `MutationObserver`: |

```js
new MutationObserver(m => console.log('mutations', m.length))
  .observe(document.getElementById('camera'), {childList:true, subtree:true})
// expected: silent across a 304, and only attribute/text writes across a change
```

---

## 6. Story 3 — a broken feed says which way it is broken (FR-026–FR-032, SC-006–SC-008)

Drive all four conditions and read the four sentences. Details and exact wording
in [contracts/page-render.md](./contracts/page-render.md) §1.

| Condition | How to drive it | Expected |
|---|---|---|
| **(a) feed down** | `pkill -STOP -f 'ccwatch serve --port 18800'` and wait a tick | The page says the feed is down, with the real reason, keeps the districts and buildings drawn, marks the map stale with the measured age, and shows **no** context fill, **no** percentage, **no** memory figure. Resume with `pkill -CONT` and the marking and the numbers return on the next tick, no reload |
| **(b) warming** | restart `serve` and read the page within the first snapshot | A first snapshot is still being taken. Reads differently from (a) and from (d) |
| **(c) unreadable rows** | add the truncated `9002.json` from §2 back | `1 registry file(s) could not be read — run: ccwatch doctor`. Reads differently from all three others |
| **(d) empty host** | remove every registry file | `No live sessions. After a reboot, run ccwatch resume.` — and **nothing** about staleness or failure |
| **(c) + (d) together** | remove every good registry file, keep the truncated one | Both facts stated. The unreadable count is not swallowed by the empty-host sentence |
| **error + empty list** | stop `serve`'s snapshot thread while `sessions` is `[]` | The empty-host sentence appears **zero** times (SC-008) |

Count the volatile readings on screen in conditions (a)–(c) — it must be zero:

```js
document.body.innerText.match(/\d+(\.\d+)?\s?(%|MB)/g)   // expected: null
```

And check the stated age against the truth: the page's age must equal
`Date.now()/1000 - lastBody.collected_at.snapshot` within the resolution it
displays (SC-007).

---

## 7. Stories 4 and 5, and everything that must keep working

| Step | Expected |
|---|---|
| Peer traffic A→B and B→A across two projects | Two separate bowed lines, each with an arrowhead showing direction (FR-022) |
| An edge carrying 3 messages, and one carrying 1 | A count on the first, none on the second (FR-023) |
| An edge whose sender has exited | Not drawn, and the footer says how many of the total were drawn and why (FR-024, FR-025) |
| Resize the window | Every wire still connects the same two figures; the view refits; **no** world coordinate changes (FR-019, SC-011) |
| Open at 1280×800 with 8 districts and 25 sessions | The whole occupied world is on screen with no interaction. Figures are at least as tall as body text (13px — expect ~22px, see [research.md](./research.md) D5) and visibly separated; every building shows a readable name (FR-040) |
| A single session, a single district | Not blown up to fill the window, not a few pixels tall (the 3.0 scale clamp) |
| Add and remove a district | The view refits; everything already placed keeps its coordinate (SC-003) |
| Set `prefers-reduced-motion: reduce` (macOS: Reduce Motion) | Nothing animates, and every state is still distinguishable (FR-053) |
| Push the host over `CCWATCH_SWAP_WARN` | The memory-pressure line appears. Below it: absent, not green (FR-044) |
| Let the usage reading age past `CCWATCH_USAGE_STALE` | The gauge numbers are withheld and the page says how old the last one was (FR-043) |
| `--read-only`, and without `--allow-kill` | Behaves exactly as today; no disabled control becomes visible (FR-048) |
| `curl -s localhost:18800/map \| grep SEND_TOKEN` | The injected token, not the `__CCWATCH_SEND_TOKEN__` placeholder (FR-047) |
| Compare the legend, footer, counts and title against the current page | Identical wording (FR-045, SC-013) |

### Break the storage on purpose (FR-014)

```js
// in the browser console, before a reload
Object.defineProperty(window, 'localStorage',
  { get() { throw new Error('denied'); } })
```

Expected: the map still draws, stays internally consistent for the session, and
the page states that positions will not survive a reload. Not a silent
fallback — that is Constitution IV.

---

## 8. Diff hygiene (SC-014, SC-015, SC-016)

```bash
git diff --stat main...HEAD
git diff main...HEAD -- . | grep -nE 'https?://|\.png|\.jpg|\.woff|package\.json|node_modules'
```

Expected: no image, binary, font, external reference, build step, package
manifest or endpoint. Files touched: `bin/ccwatch`, `web/map.html`,
`web/plots.js` (new), `tests/run.sh`, `README.md`, and `specs/`.

```bash
grep -n 'responsive grid' README.md          # expected: no match
```

The README's map section must name all three defects this entry fixes — the
re-flow on status, the destroy-on-refresh, and the failure that reads as an
absence — and must carry one mutation-table row per new assertion (FR-059,
FR-062, SC-016).
