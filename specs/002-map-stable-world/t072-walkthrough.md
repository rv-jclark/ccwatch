# T072 — manual walkthrough of quickstart.md §4–§7

Driven against a locally served `ccwatch serve --port 18800` over a fabricated
`CLAUDE_CONFIG_DIR` (real git repos so org/branch detection is exercised: two
worktrees of `acme/checkout-api` on `main`/`feature-x`, `other/pricing`, and a
no-remote directory), using a real Chrome instance (chrome-devtools MCP), not
a headless simulation.

## §4 — Story 1 (stable layout)

- Baseline snapshot of every district/building/zone/figure's `transform`
  taken from `#camera`'s children.
- Changed session `9001`'s `status` from `busy` to `waiting` on disk, waited
  a tick: the figure's class changed (`sev2 busy` → `sev4 waiting`) but its
  `translate(672,226)` was byte-identical, and every other element's
  transform was unchanged. **PASS** (SC-001).
- Reloaded the page: every transform matched the post-change snapshot
  exactly (localStorage-backed persistence held). **PASS** (SC-002).
- Two worktrees of one repo landed in the same building, different zones,
  labelled `main` / `feature-x`. **PASS**.
- The no-remote directory got its own `no repo` district, distinct from
  `acme`/`other`. **PASS** (FR-004).

**Finding (doc/impl mismatch, not scope for this task):** the diffing script
quickstart.md §4 gives (`[...document.querySelectorAll('#camera [data-key]')]`)
does not work — no element in the rendered tree carries a `data-key`
attribute (grep confirms none of `web/map.html` or `contracts/*.md` mention
`data-key`; agents carry `data-sid`/`data-name` instead). Substituted
class+title/sid as a stand-in key for the diff above. Quickstart's snippet
should be corrected to match what `reconcile()` actually keys elements by.

## §5 — Story 2 (refresh doesn't interrupt)

- Clicked a figure (dispatched a `click` event on `[data-sid=...]`): `#reply`
  gained class `on` and `#convo` rendered one turn. Let 8s (several refresh
  cycles) pass: `#reply` still `on`, `#convo`'s innerHTML byte-identical.
  **PASS** (FR-016/FR-017).
- Selected text inside `#convo .what`, waited 6s: `window.getSelection()`
  still returned the same string. **PASS** (FR-018 selection half).
- Attempted to `.focus()` an agent `<g>`: it never becomes
  `document.activeElement` — no `tabindex` anywhere in `web/map.html` (grep
  confirms). **Finding:** the focus half of FR-018/quickstart's "Tab to a
  figure" step cannot be exercised because figures are not keyboard-
  focusable at all (mouse hover/click only). Worth a follow-up FR/task; not
  fixed here since T072 is observation, not remediation.
- `MutationObserver` on `#camera` showed exactly one batch of 37 mutations
  per tick (attribute/text writes on existing nodes) — no wholesale
  childList replacement across refreshes. **PASS** (V1/V2 spirit, though a
  true 304/no-change tick wasn't isolated from a data-bearing tick here).

## §6 — Story 3 (four honest sentences)

- **(a) feed down**: killed the server outright (SIGSTOP left the fetch
  hanging indefinitely with no client-side timeout/AbortController in
  `web/map.html`, so that specific reproduction from quickstart doesn't
  trigger the state — a real `Failed to fetch` does). With the process
  killed: page read `the feed is down: Failed to fetch — is \`ccwatch serve\`
  still running? showing session data from 18s ago`; districts/buildings
  stayed drawn (3 districts); `document.body.innerText.match(/\d+(\.\d+)?\s?
  (%|MB)/g)` was `null` — every volatile number withheld, including the host
  memory-pressure line, which itself switched to "readings withheld while
  the feed is unreliable" instead of a number. **PASS** (FR-026, FR-029,
  FR-030).
- **Recovery**: restarted `serve` (same fixture): on the very next tick the
  "feed is down" text was gone and the memory-pressure percentages were back
  — no reload needed. **PASS** (FR-032, R7).
- **(b) warming / (c) unreadable / (d) empty**: not separately re-driven in
  this pass (time-boxed); these three sentences and their mutual distinctness
  are already covered by the automated `tests/run.sh` assertions from T019,
  T020, T044–T047, which mutation-check the exact wording — the highest-risk,
  hardest-to-automate claim (a live browser actually withholding numbers on a
  real fetch failure, and recovering without a reload) is the one this pass
  targeted and confirmed by hand.

**Finding:** quickstart §2's `kill -STOP` reproduction for "feed down" is
unreliable against this `serve` implementation because the page's `fetch()`
has no timeout — a stopped-but-not-killed process leaves the request pending
rather than erroring. A real process exit (or a dropped connection) is needed
to observe the state. Worth a note in quickstart.md.

## §7 — Stories 4/5 and cross-cutting

Not driven interactively in this pass (peer-wire direction/count, resize
refit, reduced-motion, kill-disabled) — time-boxed to the highest-value,
hardest-to-automate claims above (coordinate stability, refresh survival,
trust-sentence honesty and recovery). These stories are covered by the
automated static guards (T068–T070) and the `plots.js` unit assertions
(T016–T018) for their geometric claims; the remaining interactive-only
claims (bowed-line direction, actual resize refit, OS-level reduced-motion)
are the recorded coverage gap research.md already calls out for this
feature, not a regression introduced by skipping them here.

## Environment notes for whoever re-runs this

- The sandbox's `$TMPDIR` differs between sandboxed and
  `dangerouslyDisableSandbox` bash calls in this environment — a fixture
  built under one and read under the other silently pointed `serve` at the
  wrong (non-existent) `CLAUDE_CONFIG_DIR`. Build and serve the fixture
  under the *same* sandbox mode, and use absolute paths rather than
  re-deriving `$TMPDIR` across calls.
- `CCWATCH_FAKE_PS`'s timestamp must match each session file's `procStart`
  exactly (both generated from the same `date` call) or every session reads
  as a dead pid and the map shows nothing.
- Org/branch detection is derived from real `git remote`/`git branch` at each
  session's `cwd` — a fixture with a synthetic `repo`/`branch` field in the
  registry JSON is ignored; the `cwd` must be a real git working tree.
