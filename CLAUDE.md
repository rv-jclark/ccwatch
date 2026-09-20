# ccwatch — notes for Claude Code

A single bash script that reports on every Claude Code session on the machine
and which one is stuck. No build, no dependencies to install, no package
manifest. Read `README.md` first: it explains *why* each verdict is shaped the
way it is, and most of the rules below are only sensible in light of that.

## Layout

```
bin/ccwatch      the whole tool (~4900 lines of bash + embedded python3/jq)
app/Sources/     the macOS menu bar app: the status item, the always-on-top
                 overlay, and the `ccwatch serve` it supervises. Swift, and the
                 only thing here that needs a build step
app/build.sh     swiftc -> app/build/ccwatch.app, ad-hoc signed
extra/swiftbar/  the SwiftBar/xbar plugin the app replaced. Kept as a fallback
                 for a machine that cannot run the app; it renders the same
                 `ccwatch bar` bytes, so the two cannot disagree about status
web/index.html   the table view, served by `ccwatch serve`
web/map.html     the map view — a scrolling column of owner blocks, sessions
                 as figures inside them
web/md.js        markdown for the transcript inspector; escapes, never links
web/roster.js    row shaping for the docked agent list beside the map
web/modal.js     the per-agent inspector's own pure shaping
web/alerts.js    the trust model both pages read, and the header alert set
                 shaped from it — never a banner in the page's flow
web/usage.js     the usage meter's arithmetic: how much of a window has gone,
                 and when it resets (Eastern, via `date -r` — never jq)
tests/run.sh     shellcheck + the assertion suite; the only test entry point
```

`web/camera.js` and `web/plots.js` are **gone** — the pan-and-zoom camera and
its identity→coordinate placement. Do not reintroduce a camera here without
reading the "scrolling list of blocks" section of `README.md` first: the
camera's default view was measured showing 1 of 4 territories and hiding 2 of
8 sessions off-screen, and the whole suite was green while it did.

`web/md.js` is a separate file rather than inline script so that `tests/run.sh`
can run it under node and assert on the HTML — including the escaping. It is
served by the static fallback in `serve`, so it needs no route of its own.

`bin/ccwatch` is organised in banner-commented sections — `collection`,
`statusline`, `the join`, `rendering`, `bar`, `resume`, `events`, `transcript`,
`pending asks`, `send`, `deploys`, `peers`, `serve`, `doctor`, `setup`,
`dispatch`. A new subcommand needs a `cmd_*` function, a line in the `case` in
`dispatch`, and an entry in `usage()`.

`app/` holds no judgement. It parses `ccwatch bar --no-actions` and renders it,
and adds only verbs — show the overlay, open the dashboard, restart serve. That
is principle XI: a second place deciding "is anything stuck" would eventually
disagree with the table and there would be no telling which was lying. The
overlay is a `WKWebView` on the same `/map` the browser gets, so there is one
renderer for it too.

⚠️ Four `NSPanel` properties are load-bearing and the obvious subset is wrong:
`.statusBar` (not `.floating`, which sits *under* a full-screen app — exactly
when you most need to see a blocked agent), `.canJoinAllSpaces`,
`.fullScreenAuxiliary`, and `.nonactivatingPanel` so clicking it does not steal
focus from the terminal. `app/build/ccwatch.app/Contents/MacOS/ccwatch-menu
--selftest` asserts all four, because those fail *invisibly* — a panel at the
wrong level looks perfect until something covers it. It is not a substitute for
opening the thing: `verify-ui` drives headless Chrome and knows nothing about a
menu bar.

`setup` is the install path and deliberately does **one** thing — the PATH
symlink — then prints the rest. `install-hooks` and `install-statusline` each
show their own change and ask first, and a second place asking the same
question is a second place to keep honest. It verifies by RUNNING what it
installed and comparing the version, because a symlink that exists proves
nothing: it can point at a moved path or a file that has lost its executable
bit, and the latter has happened here.

`bar` is the third renderer of the same snapshot, after the terminal and the
pages, and it exists as a subcommand for the reason `/api/state` invokes the
CLI: a menu bar plugin that read `--json` and decided severity for itself would
be a second place that computes "is anything stuck", and the two would
eventually disagree with no way to tell which was lying. Anything it prints is
`snapshot`'s own classification — including the measurement in each row, which
is the same expression the table's `LAST` column uses.

## Running things

```bash
./tests/run.sh                  # everything: shellcheck, then the assertions
./app/build.sh --selftest       # build the menu bar app and run its own checks
./app/build.sh --run            # build it and launch it
./bin/ccwatch once              # one paint against the real ~/.claude
./bin/ccwatch doctor            # is ccwatch's own view still trustworthy
./bin/ccwatch verify-ui --shots .screens   # render the pages and check them
CCWATCH_PROFILE=1 ./bin/ccwatch --json >/dev/null   # per-stage timings
```

`verify-ui` boots its own `serve`, drives headless Chrome against a harness
that iframes the real pages, and asserts on rendered boxes, computed styles and
synthetic interaction. It skips with the reason when there is no Chrome. **It
exists because 567 assertions were green while the map showed nothing**: the
suite is entirely browserless, so a roster whose rows collapsed to a
four-character ribbon, a default view whose zoom level sets `display:none` on
every figure, a drag that selected text instead of panning, and 258px of page
scroll with an unreachable dialog below the fold all passed at once.

It is also where the **whole-view** checks live, and they were added late for a
reason worth remembering: `verify-ui` itself was green on a default map that
had 1 of 4 territories fully visible and 2 of 8 sessions entirely off-screen,
because the check it had asserted that *an* agent was visible. It now asserts
that the board draws a figure for **every** session the roster lists, that none
is hidden or zero-sized, and that every one is inside the scrollable content.
A whole-view property needs a whole-view assertion; "something rendered" is not
one.

⚠️ `verify-ui` runs Chrome with `--force-prefers-reduced-motion`, and that flag
is load-bearing. `--virtual-time-budget` fast-forwards timers but not the
compositor, so `scrollIntoView({behavior: "smooth"})` never progresses —
measured, smooth moved `scrollTop` 0→0 over a 900ms wait where `auto` moved
0→346. The harness asserts the flag took effect, so removing it fails loudly
instead of turning the reveal check into a no-op.

The `markdown` section runs `web/md.js` under `node`. That is the only optional
tool the suite uses: with no `node` the section skips with the reason and
nothing else is affected.

The suite starts real HTTP servers on loopback, creates temp directories, and
reads `ps`. In a restricted sandbox some of that is refused, and it is worth
knowing exactly which — the bare count of failures was read as a regression
here more than once.

**`mktemp` used to account for 13 of them and no longer does.** `cmd_resume`
and `cmd_peers` called `mktemp -d` with no template, and macOS resolves that
against `confstr(_CS_DARWIN_USER_TEMP_DIR)` — the login `/var/folders/…/T` —
*not* against `$TMPDIR`. A sandbox granting `$TMPDIR` and not `/var/folders`
refused it, `die` fired, and both commands printed nothing, so `resume`,
`peers` and the `ccwatch resume` assertions inside `roster` all failed with
empty output. Both calls now pass a template, as `cmd_verify_ui` always did.
Do not remove those templates: the failure they prevent looks like a missing
feature, not a permissions problem.

**`ps` is the one that matters most**, because it is refused outright here and
what it costs is a wrong answer rather than a failure. `collect_live` runs
`ps`; where `ps` cannot run it prints nothing, so the collector would report
`[]` and every session would be filtered out as not-live — `ccwatch` stating
"No live Claude Code sessions" on a machine running eighteen of them.
`collect_live` now cross-checks an empty answer against `ps -o pid= -p $$`,
which cannot legitimately be empty, and says nothing rather than reporting an
empty machine. So under a sandbox that refuses `ps`, expect `collect_live
produced no usable JSON` and a `cc ?` in the menu bar — that is the tool
working correctly, and the *old* silent `0 live` was the bug.

The remaining sandbox failure is the `serve` orphan assertion, which reaps with
**`pkill -f`** — and process enumeration can be refused outright: `pgrep`
reports `sysmon request failed … pgrep: Cannot get process list`. The server is
then never killed, the port stays up, and "leaving no orphan" fails while
describing the opposite of the problem. `cleanup_suite` reaps the same way, so
a sandboxed run also **leaks every server it started** — measured 2026-09-19:
5 left listening on 18542/18615/18673/18734/18785 after one run, and
`kill <pid>` on them is refused too, so they can only be reaped from an
unsandboxed shell with `pkill -f 'ccwatch serve'`. That is the 1686-orphan
problem again by a different route, so check for them after a sandboxed run.

## The rules that are not negotiable

These are invariants, not preferences. Each one exists because breaking it
produced a specific wrong output that someone believed.

1. **Never make a claim on one signal.** A status is corroborated against a
   second, independent one (transcript mtime, CPU time, a runner pid) before it
   is escalated. `busy` from the registry alone is not evidence of work.
2. **Print the measurement next to the verdict.** `HUNG?` always shows the
   silence and the CPU reading that produced it. The judgement belongs to the
   person reading, and a column that cries wolf is a column they stop reading.
3. **A stale reading is withheld, not annotated.** A percentage on screen is
   read as current whatever is printed beside it. Usage and context readings
   past their staleness window are dropped; the header says how old the last one
   was. Never render a number with an "(old)" note and call that honest.
4. **A failure must never look like an absence.** "no deploys" and "HTTP 401:
   Bad credentials" are different facts and must read differently. A `gh`
   failure leaves the previous cache in place rather than replacing it with an
   empty list. An unreadable registry file costs one row and is counted, so
   `doctor` can report it.
5. **Never invent a status you did not read.** An unrecognised value from the
   registry is surfaced by `doctor` rather than falling through a default branch
   and being presented as though it had been understood.
6. **Say nothing rather than guess.** An embedded-SDK session (`sdk-ts`) writes
   no transcript and publishes no status, so its silence measures nothing and is
   never escalated to a hang. A directory with no git remote is marked `no repo`
   rather than folded into a real repository.
7. **Colour is never the only carrier of meaning.** Every severity also has a
   distinct word, so `ccwatch once | grep HUNG` works and so does a screen
   reader. Honour `NO_COLOR`.
8. **Delivery is observed, not assumed.** `ccwatch send` watches the receiver's
   transcript for the message to land and reports delivered / queued / failed
   with the real reason. Writing to a socket proves nothing.
9. **Loopback is not a security gate.** Any page in the browser can POST to
   `127.0.0.1`. The send endpoint requires both a per-run token injected into
   the page ccwatch serves *and* an `Origin` check. Never weaken one on the
   grounds that the other exists.
10. **Transcripts are sensitive.** They contain whole tool outputs and file
    contents. `convo` reads a bounded byte tail, keeps assistant/user text
    truncated, reduces a tool *use* to its name and a short argument summary,
    and a tool *result* to its size — never its content. Nothing may put that
    content on a socket. It follows that transcript text reaching the page is
    **escaped before it is formatted, and never linked**: `web/md.js` escapes
    first and adds tags second, and renders a markdown link as text, because an
    anchor here would be a one-click outbound request carrying transcript
    content. There is no sanitise-the-HTML-afterwards path — that is the path
    with the hole in it.
11. **The dashboard runs the same code path as the terminal.** `/api/state`
    invokes the commands the CLI does. Two renderings that compute status
    separately will eventually disagree, and there is no way to tell which is
    lying.
12. **Normal conditions are silent, and a warning never moves the content.** A
    line that appears on every refresh to say things are fine is a line people
    learn to skip, and then it is not there when it matters. Warnings appear at
    a threshold and are absent below it — not green, absent. The host-pressure
    line works this way. In the pages they are also *out of flow*: they were
    block-level banners, and each arrival pushed the board down by up to 81px
    of its 676 while somebody was reading it. A condition that comes and goes
    on its own may not take the layout with it — but it still has to be stated
    in words where it cannot be missed, because a collapsed "2 alerts" badge
    turns a failure into an absence, which rule 4 forbids.
13. **A change under `web/` is not done until it has been rendered and looked
    at.** Not "the assertions pass" — rendered, in a browser, and looked at,
    with `ccwatch verify-ui` and a screenshot. Every UI bug this project has
    had was found in the first minutes of somebody opening the page and by
    nothing else: structure-only assertions cannot see a collapsed column, a
    figure hidden by its own level-of-detail rule, or a panel below the fold.
    Reporting "the manual browser pass is not done" and shipping anyway is the
    specific mistake this rule exists to prevent.
14. **An assertion must not encode one machine's configuration.** Where the host
    cannot supply what a test needs — no swap, a slow CPU, no `curl` — skip with
    the reason stated rather than failing. A red suite that means "this runner
    is configured differently" costs the same attention as a real regression.

## Portability constraints

- **bash 3.2**, because that is what macOS ships. No `mapfile`/`readarray`, no
  `declare -A`, no `${var,,}`/`${var^^}`. The suite greps for these.
- **macOS `stat -f` and `ps -o lstart=`** in their BSD forms. This is a macOS
  tool; CI runs on macOS only.
- `python3` is used for the socket client, date parsing and the HTTP server.
  Pass programs with `python3 -c`, never on stdin — a heredoc on stdin collides
  with the payload the program is trying to read, which cost a whole debugging
  session once.
- `shellcheck -x -S warning` must be clean for `bin/ccwatch`, `tests/run.sh`
  and `extra/swiftbar/ccwatch.10s.sh`. Suppress with a narrow
  `# shellcheck disable=` and a reason, never by loosening the severity. The
  plugin is in the list because the menu bar host runs it with no terminal to
  print a complaint to, and its shebang is `/bin/bash` — which on macOS is 3.2,
  so it is the one file here that cannot fall back to a newer bash on PATH.

## Test discipline

- **Hermetic.** Every assertion runs against a fabricated `~/.claude` under
  `$WORK` via `CLAUDE_CONFIG_DIR`, with `CCWATCH_FAKE_PS` substituting the
  liveness probe. Never assert against the developer's live sessions — that is
  a screenshot, not a test.
- **Mutation-check every new assertion.** Break the implementation in the
  specific way the assertion describes, confirm the assertion fails, then
  restore. An assertion that passes against a broken implementation is worse
  than none, because it is counted as coverage. Add a row to the mutation table
  in `README.md`.
- **And mutation-check every check, not just the ones in `tests/run.sh`.** The
  rule above reads as though it were about the suite, and that reading is how a
  whole day's worth of broken checks got trusted. It applies to anything whose
  answer you are about to believe: a `verify-ui` check, a `grep` that gates a
  decision, a `pgrep` in a wait loop, a one-off diagnostic. Before trusting one,
  make it report the failure you are looking for — or establish that it can.
  Every one of these was written, run, and believed here:

  | The check | What it actually did |
  |---|---|
  | `grep -c 'calc(100vh -'` guarding a layout fix | failed on the comment explaining why the guard exists |
  | `getBBox()` overlap between labels and figures | measured each element in its own local space, so everything sat at (0,0) and 14 collisions were reported on a map with none |
  | "has text but zero rendered width" | flagged `.rsel`, which is `display:none` until selected, seven times |
  | `pgrep -f "bash ./bin/ccwatch verify-ui"` in an until-loop | matched its own shell's command line, so the loop could never exit |
  | four successive fixes to the ETag assertions | three of them tuned timings under a theory of the race that had never been checked against what the validator actually covers |

  The shape is always the same: a check is trusted because it is *green*, when
  green and broken are indistinguishable until you have seen it go red on
  purpose. A check that has never failed has not been tested, it has only been
  run.
- **Fixtures must be able to fail.** A fixture where the behaviour under test
  could not have succeeded anyway will pass either way — that has happened here
  (the de-duplication assertion) and is a test defect.
- `TALLY_FLOOR` in `tests/run.sh` guards against assertions that run but are
  never counted. Raise it when adding a batch.
- Reap anything you start. A leaked `serve` holds a port a later run may pick,
  and then that run tests the leaked binary.
- A slow machine is not a defect: prefer `t_skip` with a reason over a flake.

## Writing style, in code and in prose

Comments say **why**, and name the failure that motivated the code — the `⚠️`
comments are the load-bearing ones and should not be trimmed. Prefer the
concrete number that was measured ("850KB from the end of a real 4.9MB
transcript") over an adjective. This applies to `README.md` too: it documents
the reasoning and the bugs found, not just the flags.

Keep examples in the README **generic** (`acme/checkout-api`, `web-app`,
`pricing`). Do not paste real session names, repository slugs, feature ids or
costs from the machine this is developed on into documentation or fixtures.

## Commits

**Conventional Commits, always.** `<type>: <subject>` with the subject in the
imperative, describing the user-visible change rather than the diff. The types
in use are `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `chore`, `ci`,
`build`. A breaking change is `feat!:` or a `BREAKING CHANGE:` footer.

This is no longer only a convention: **the commit log is the input to
versioning and to the changelog** (see Releases below). A `feat:` that should
have been a `fix:` ships the wrong version number, and a subject that describes
the diff ("update transcript.js") becomes a changelog line that tells a reader
nothing.

**Small, logically grouped commits.** One reason-to-change per commit, and
everything belonging to that reason in it — the implementation, its assertion,
its `README.md` row. A reviewer should be able to read the subject, then the
diff, and find nothing in the diff that the subject did not promise.

- Do not batch unrelated changes because they happened in the same sitting; a
  renderer change and a `doctor` fix are two commits, in either order.
- Do not split one change across commits such that the tree is broken in the
  middle. An implementation without its assertion is not a smaller commit, it is
  half a commit.
- Formatting or renames that touch a lot of lines go in their own commit, so the
  behavioural change beside them stays reviewable.

**Commit finished work without being asked.** A change that is complete — its
implementation, its assertion, its `README.md` row, and a green `./tests/run.sh`
— gets committed. Leaving it sitting in the working tree is not caution: it
hands back a dirty tree for somebody else to sort out, it makes the next
session's `git status` ambiguous about what was deliberate, and it loses the
one-reason-per-commit grouping that only the person who made the change still
knows. Split it as the rules above describe and commit it.

Pushing is still explicit, because it is outward-facing — ask first. So is
committing something you could not verify: if the suite is red, or red for a
reason you have not run down, say so instead of committing over it.

⚠️ Check `git status` before staging, and commit only your own hunks. This
repository is worked on by more than one session at a time, and unrelated
in-flight work in a file you touched is not yours to commit or to attribute.

`~/.claude/ccwatch/` is runtime state and is never committed.

## Releases

`release-please` owns the version. On every push to `main` it reads the
conventional commits since the last release and keeps a release PR up to date;
merging that PR bumps `CCWATCH_VERSION`, writes the `CHANGELOG.md` entry, tags
`vX.Y.Z` and cuts the GitHub release.

```
.github/workflows/release.yml   the job (ubuntu — it runs no ccwatch code)
release-please-config.json      release type, changelog sections, extra-files
.release-please-manifest.json   the current version, as release-please sees it
```

- **Never edit `CCWATCH_VERSION` by hand.** It is bumped in `bin/ccwatch` by the
  `# x-release-please-version` marker on that line. A hand-edit makes the tag
  and the script disagree about what shipped, which is the one thing a version
  number exists to prevent.
- **Never edit `.release-please-manifest.json` by hand** either. It is the
  tool's record of the last release, not a place to declare a wanted version.
- `bootstrap-sha` in the config pins where history starts being read, because
  1.0.0 shipped before any of this and has no tag. Leave it.
- Generated entries land in `CHANGELOG.md` above the hand-written 1.0.0 prose.
  Editing the release PR's changelog text is fine and expected; editing the
  version in it is not.
