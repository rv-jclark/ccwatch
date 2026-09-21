# Feature Specification: Windows support for the taskbar tray and the overlay

**Feature Branch**: `006-windows-tray-overlay`

**Created**: 2026-09-20

**Status**: Draft

**Input**: User description: "Windows support for the ccwatch taskbar (tray) and overlay: extract a platform probe layer in bin/ccwatch for ps/stat/date -r/vm_stat/sysctl, add Windows implementations, and add a Windows tray+WebView2 app that renders the same `ccwatch bar --no-actions` bytes"

## Overview

ccwatch is a macOS tool by construction, and the constitution says so in as
many words: "**macOS `stat -f` and `ps -o lstart=`** in their BSD forms. This is
a macOS tool; CI runs on macOS only."
(`.specify/memory/constitution.md:114-115`). Claude Code, however, runs on
Windows, and on a Windows machine every one of ccwatch's five host probes is
either absent or answers in a different shape:

| The probe | Where | What it asks for | On Windows |
|---|---|---|---|
| liveness, start time, CPU seconds, RSS | `bin/ccwatch:168` | `ps -o pid=,lstart=,time=,rss= -p <pids>` | `ps` is absent, or a minimal MSYS `ps` with none of those columns |
| transcript mtime, newest first | `bin/ccwatch:1856` | `stat -f '%m %N'` | BSD-only format string; the GNU form is `stat -c` |
| epoch → Eastern wall clock | `bin/ccwatch:1191` | `TZ=America/New_York date -r <epoch>` | `date -r` means "reference file" in GNU date, and nothing at all in most Windows shells |
| free and compressed RAM | `bin/ccwatch:2329` | `vm_stat` | no such program |
| swap and load average | `bin/ccwatch:2340`, `bin/ccwatch:2348` | `sysctl -n vm.swapusage`, `sysctl -n vm.loadavg` | no such program; Windows has a pagefile, and **no load average at all** |

The failure this produces is not a crash, and that is the whole problem. It is
the single worst output this tool can produce, and it is already recorded in the
code: when `ps` cannot run it prints nothing, `collect_live` reports `[]`, every
session is filtered out as not-live, and ccwatch states "No live Claude Code
sessions" on a machine running eighteen of them. That measurement — `ps`
refused, 18 sessions live, 0 reported — is why the cross-check at
`bin/ccwatch:336-350` exists, and it exists for exactly one probe. A naive
Windows port reproduces that failure five times over: a blind tool and a quiet
machine look identical, which is constitution IV ("a failure must never look
like an absence") broken in the place it is hardest to see.

The second half is the surface. `app/` is 751 lines of Swift that own three
things — the `NSStatusItem`, an always-on-top `NSPanel` overlay hosting the same
`/map` the browser gets, and the `ccwatch serve` it supervises — and it holds no
judgement at all: "⚠️ NOTHING HERE DECIDES ANYTHING ABOUT A SESSION. Every
verdict, threshold, count and word comes from `ccwatch bar --no-actions`, which
this parses and renders" (`app/Sources/main.swift:9-15`). A Windows operator has
no equivalent, so the only way to know an agent is blocked is to keep a terminal
open and look at it.

This feature does two things and nothing else: it makes the read path on Windows
either answer correctly or say what it could not measure, and it gives Windows
the same two surfaces — a taskbar tray item and an always-on-top overlay —
rendered from the same `ccwatch bar --no-actions` bytes the macOS app parses. It
adds a second renderer of the snapshot, not a second place that computes it
(constitution XI).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The Windows read path tells the truth or says what it could not measure (Priority: P1)

An operator on Windows has seven Claude Code sessions open and runs `ccwatch
once` in their shell. They get the same table a macOS operator gets: names,
projects, status words, ages, and the measurement beside each verdict. Where a
reading genuinely cannot be taken on this host — there is no load average on
Windows — the row or panel says the figure is unavailable and why, and does not
print a zero.

**Why this priority**: Everything else in this feature renders what this
produces. The tray and the overlay are both views over `ccwatch bar`, and
`ccwatch bar` is a view over the snapshot; a tray fed by probes that silently
return nothing would show `cc 0` on a busy machine, which is the failure the
whole tool exists to prevent. It is also the only story that is worth anything
on its own: an operator with a working terminal read path already has the
product, even with no tray built.

**Independent Test**: On a Windows host with live Claude Code sessions, run
`ccwatch once`, `ccwatch --json` and `ccwatch doctor`. Verify every live session
appears with a status word and its measurement; verify the count matches the
number of registry files with running processes; then make each probe
unavailable in turn and verify each one is reported as a named failure rather
than as an empty result. On macOS, the existing suite passes unchanged.

**Acceptance Scenarios**:

1. **Given** a Windows host with 7 live sessions in the registry, **When** the operator runs `ccwatch once`, **Then** all 7 appear with their status word, age and the measurement behind each verdict — not "No live Claude Code sessions".
2. **Given** a Windows host where the process-enumeration probe cannot run at all, **When** the operator runs `ccwatch once`, **Then** the output states that the liveness probe produced no usable answer and does not report an empty machine.
3. **Given** a Windows host, **When** the operator runs `ccwatch doctor`, **Then** it names each probe the platform layer selected, states which platform it detected, and reports any probe that is missing or unreadable as a problem with the reason.
4. **Given** a Windows host, **When** a snapshot is taken, **Then** free RAM and pagefile usage are reported where the platform can supply them and the load average is reported as unavailable rather than as `0`.
5. **Given** a macOS host, **When** the whole existing test suite runs, **Then** every assertion that passed before the platform layer was extracted still passes, with the same probe programs and the same output bytes.
6. **Given** any host, **When** the operator runs `ccwatch once` twice in succession, **Then** the CPU-delta signal still corroborates the transcript-silence signal as it does today; no verdict is escalated on one signal because the second was unavailable (constitution I).

---

### User Story 2 - A Windows operator sees the worst verdict in the taskbar without a terminal open (Priority: P2)

The operator pins the ccwatch tray item. It shows a short status — the same
`cc 3` / `cc ! 1` / `cc ?` vocabulary the macOS menu bar shows — and its menu
lists the same rows with the same words and the same measurements. Clicking a
row does what the macOS menu does: opens the dashboard if one is up, or offers
to start one.

**Why this priority**: This is what the feature is named for and what makes
ccwatch usable on Windows without a dedicated terminal. It comes after the probe
layer because a tray that renders wrong bytes is worse than no tray: the macOS
app's own header records why — two renderings that compute "is anything stuck"
separately will eventually disagree and there is no way to tell which is lying.

**Independent Test**: Start the tray app on a Windows host with a mixture of
idle, working and blocked sessions. Compare its title and every menu row,
character for character, against the output of `ccwatch bar --no-actions` run in
a shell at the same moment. Then break the snapshot and verify the title becomes
the `?` form with the "this is NOT nothing is running" explanation, not a count.

**Acceptance Scenarios**:

1. **Given** a Windows host with 1 blocked and 4 idle sessions, **When** the tray item refreshes, **Then** its title and menu rows are exactly what `ccwatch bar --no-actions` printed, including the measurement on each row.
2. **Given** a snapshot that failed, **When** the tray item refreshes, **Then** it shows the `cc ?` title and the menu states that the snapshot itself failed and that this is not "nothing is running" — it never shows a count of `0`.
3. **Given** a bar line carrying a parameter the tray app does not implement, **When** it renders that line, **Then** the line is still shown as plain text rather than dropped, so a future CLI item cannot vanish from the menu unnoticed.
4. **Given** a session whose name contains a pipe character, **When** the tray app parses the bar document, **Then** the name renders as text and its characters are never taken as parameters.
5. **Given** the operator has `NO_COLOR` set or a high-contrast Windows theme, **When** they read the tray item, **Then** every severity is still distinguishable by its word alone (constitution VII).
6. **Given** `ccwatch` is installed where the operator's shell can find it but a GUI process's environment cannot, **When** the tray app starts, **Then** it locates the CLI by explicit search, shows the resolved path in its menu, and says plainly that it could not find one rather than showing an empty fleet.

---

### User Story 3 - The always-on-top overlay works over a maximised window (Priority: P3)

The operator opens the overlay from the tray. A small always-on-top window
appears showing the same `/map` the browser shows, it stays visible over a
maximised or full-screen application, it appears on whichever virtual desktop
they are on, and clicking it does not take keyboard focus away from the terminal
they are working in. A link in it that wants a new window opens in their real
browser.

**Why this priority**: It is the surface that makes a blocked agent
unmissable while the operator is working in something else, and it is the one
whose defects are invisible: a window at the wrong z-order looks perfect until
something covers it. It is third because the tray is the entry point to it and
because it needs a `ccwatch serve` to host.

**Independent Test**: Open the overlay, maximise another application over it,
switch virtual desktops, and click the overlay while typing in a terminal.
Verify it stayed visible in the first two cases and that the caret stayed in the
terminal in the third. Verify a `target="_blank"` link in the overlay opens the
default browser rather than doing nothing.

**Acceptance Scenarios**:

1. **Given** the overlay is open, **When** another application is maximised or made full-screen over it, **Then** the overlay remains visible above it.
2. **Given** the overlay is open, **When** the operator switches to another virtual desktop, **Then** the overlay is visible there too rather than appearing to have vanished.
3. **Given** the operator is typing in a terminal, **When** they click the overlay, **Then** the overlay does not take keyboard focus and the next keystroke still goes to the terminal.
4. **Given** the overlay shows a link that opens a new window, **When** the operator clicks it, **Then** the default browser opens it — the click is never swallowed in silence.
5. **Given** something is already answering on the dashboard port, **When** the tray app is asked for a dashboard, **Then** it adopts that server and labels it as one it did not start, rather than starting a second or fighting for the port.
6. **Given** the overlay's z-order, desktop and focus behaviour, **When** the Windows app's own selftest runs, **Then** it asserts each of those properties by name and fails loudly if one is not set — because each of them fails invisibly.

---

### User Story 4 - Nothing changes for the macOS operator (Priority: P4)

A macOS operator upgrades, runs `ccwatch once`, `ccwatch bar`, the menu bar app
and `./tests/run.sh`, and cannot tell that the platform layer was extracted: the
same probe programs are run, the same bytes come out, and the same assertions
pass.

**Why this priority**: The extraction is a refactor of the most load-bearing
code in the tool — the liveness probe every verdict is corroborated against —
and a regression here is a wrong claim about a session rather than a missing
feature. It is last as a *story* only because it delivers no new value; it is a
gate on shipping any of the three above.

**Independent Test**: Run `./tests/run.sh` on macOS before and after the
extraction and compare the tally and the skips. Run `ccwatch --json` on the same
machine before and after and diff the payloads for everything but the timestamps.

**Acceptance Scenarios**:

1. **Given** a macOS host, **When** `./tests/run.sh` runs, **Then** it is green and the assertion tally is at or above the floor, with no new skip that hides a Windows-only path.
2. **Given** a macOS host, **When** `ccwatch --json` runs before and after the change, **Then** the payload shape and every non-time-varying value are identical.
3. **Given** a macOS host with no Windows toolchain and no compiler, **When** the suite runs, **Then** the Windows app's checks skip with the reason stated, exactly as the macOS app's checks already do.
4. **Given** `CCWATCH_FAKE_PS` is set, **When** any assertion runs on either platform, **Then** the platform layer still honours it as the one liveness testing seam, so fixtures keep working unchanged.

---

### Edge Cases

- **A probe is present but refuses.** A sandbox or a policy can refuse process enumeration outright; on Windows this is a denied query rather than a missing program. Both must read as "the probe could not run", never as "nothing is running" — the distinction is the one in `bin/ccwatch:336-350`, generalised to every probe.
- **A probe answers in an unrecognised shape.** A Windows version whose process query returns a column the parser does not know must cost that row and be counted, so `doctor` can report it — not be guessed at, because a wrong start time makes the pid-reuse guard reject a live session (constitution V, VI).
- **The clock formats disagree.** The Eastern reset clock is read by both the CLI and `web/usage.js`, and the suite already asserts they agree on both sides of a daylight-saving boundary. A Windows date implementation that is an hour out for half the year puts a wrong instant in somebody's calendar; the two must still agree on Windows.
- **There is no load average on Windows.** The honest reading is "unavailable", stated as such. A processor-queue-length proxy presented as a load average would be a status ccwatch did not read (constitution V, VI). Likewise a host with a disabled pagefile has no percentage to report, and `null` is the honest value — `0%` claims a pagefile exists and is empty, which is the exact shape that turned the first CI run red on macOS swap.
- **The host-pressure warning stays absent below its threshold** on Windows too, and never becomes a permanent "pagefile fine" line (constitution XII).
- **A session name contains a pipe.** `ccwatch bar` already replaces `|` with `¦` in every interpolated field so exactly one ` | ` separator can appear per line, and the macOS parser splits on the *first* one for that reason (`app/Sources/main.swift:145-150`). A Windows parser that split on the last one would hand an attacker-shaped session name the parameter list back.
- **The tray app cannot find the CLI.** A GUI process does not inherit the shell's `PATH`; the macOS app records a plugin that reported `jq` missing on a machine that plainly had it (`app/Sources/main.swift:25-33`). The Windows app must search explicitly, show what it resolved, and report a miss as a miss.
- **An SDK session on Windows.** An `sdk-ts` session writes no transcript and publishes no status, so its silence measures nothing and is never escalated to a hang — the CPU-seconds probe is the only signal it has, so a Windows host where CPU time cannot be read must say nothing about it rather than calling it hung (constitution VI).
- **Line endings.** Bytes produced on Windows and consumed by the tray parser, and registry or transcript files written with `\r\n`, must not turn a status word into an unrecognised value or leave a stray character in a rendered row.
- **Paths with spaces and drive letters.** `C:\Users\Jane Doe\.claude` must resolve, and a transcript listing must sort correctly across it.
- **The overlay with no server.** Opening the overlay when no `ccwatch serve` is answering must say so, not present an empty map as a quiet machine (constitution IV).

## Requirements *(mandatory)*

### Functional Requirements

**The platform probe layer**

- **FR-001**: `bin/ccwatch` MUST route every host-dependent measurement through a single named probe seam per measurement — process facts, file modification times, epoch-to-wall-clock formatting, memory pressure, swap/pagefile, and load — rather than calling a platform program inline. After the extraction there MUST be no direct `ps`, `stat -f`, `date -r`, `vm_stat` or `sysctl` invocation outside that seam.
- **FR-002**: The layer MUST detect the host platform once per run and select an implementation for each probe from that detection, and MUST report the platform it detected and the implementation chosen for each probe when asked (see FR-014).
- **FR-003**: Each probe MUST distinguish three outcomes and never conflate them: a measurement, a measured absence (the thing was asked and there is genuinely nothing), and a failure to measure (the probe is missing, refused, or answered in a shape not understood). The third MUST be surfaced with its reason and MUST NOT be rendered as the second (constitution IV).
- **FR-004**: Every probe whose empty answer could be mistaken for an empty machine MUST cross-check that empty answer against a query that cannot legitimately come back empty, and MUST say nothing rather than report an empty result when that cross-check fails — generalising the guard at `bin/ccwatch:336-350` from the one probe that has it to all of them.
- **FR-005**: The macOS implementations MUST run the same programs with the same arguments and produce the same values as today, and the existing assertions MUST pass unchanged against them.
- **FR-006**: `CCWATCH_FAKE_PS` MUST remain the single testing seam for liveness on every platform, so that existing hermetic fixtures continue to work and a Windows fixture can be substituted the same way.

**The Windows implementations**

- **FR-007**: On Windows, the process probe MUST supply, for each requested process id: whether it is running, its real start time, its cumulative CPU seconds, and its resident memory — the four facts `bin/ccwatch:168` gathers — in a shape the existing pid-reuse guard and CPU-delta comparison can use without change to their logic.
- **FR-008**: The start time and the registry's recorded start MUST be compared as epochs, never as strings, on Windows as on macOS; the pid-reuse guard MUST reject a recycled pid and MUST NOT reject a live session because of a timezone or format difference.
- **FR-009**: On Windows, the file-modification-time probe MUST return the same modification time and path pairs the transcript listing needs, sorted newest first, across paths containing spaces and drive letters.
- **FR-010**: On Windows, the epoch-to-Eastern-wall-clock probe MUST produce the same clock time and the same zone abbreviation as `web/usage.js` for the same instant, on both sides of a daylight-saving boundary, and MUST NOT be derived from `jq`'s local-time formatting (which reported EST for an instant in September).
- **FR-011**: On Windows, the host-pressure probe MUST report free physical memory and pagefile total/used/percentage where the platform can supply them, MUST report as unavailable — not as zero — any figure the platform cannot supply, and MUST NOT substitute a different measurement for one it could not take. Specifically, no load-average figure may be synthesised on a platform that has none.
- **FR-012**: The host-pressure warning MUST remain absent below its threshold on Windows, and MUST state which figure is unavailable when the pressure judgement cannot be made at all.
- **FR-013**: Every Windows probe MUST work in the shell environment `bin/ccwatch` runs in on that platform (see Assumptions) using facilities present on a stock supported Windows installation, and MUST NOT require the operator to install a package manager or a language runtime beyond the ones the requirements table already names.
- **FR-014**: `ccwatch doctor` MUST report, on every platform: the platform detected, the implementation selected for each probe, whether each probe can run, and each probe that is missing, refused or unparseable — as a named problem with its reason. An unrecognised answer from a probe MUST be surfaced here rather than falling through a default branch.
- **FR-015**: `ccwatch setup` on Windows MUST put `ccwatch` on the operator's `PATH` by whatever mechanism that platform supports, MUST verify by running what it installed and comparing the version, and MUST refuse with the reason rather than reporting success it did not confirm.

**The Windows tray and overlay app**

- **FR-016**: The Windows app MUST derive every status, count, word, threshold, severity and measurement it displays from the bytes of `ccwatch bar --no-actions`, and MUST NOT compute, infer or default any of them itself (constitution XI).
- **FR-017**: The Windows app MUST parse the bar document by the same rules the macOS app uses: line 0 is the title, `---` opens and splits the menu, and an item's text is separated from its `key=value` parameters by the **first** ` | ` on the line and no other.
- **FR-018**: A parameter the Windows app does not implement MUST leave its line displayed as plain text rather than dropping the line, so a future CLI item cannot silently disappear from the menu.
- **FR-019**: The tray item MUST present a title from the same short vocabulary the macOS status item uses, including the `?` form and its "this is NOT nothing is running" explanation for a failed snapshot, and MUST NOT present a count when the snapshot failed.
- **FR-020**: Every severity the tray shows MUST be distinguishable by its word alone, with icon, colour and shape as additions only, and MUST remain legible under a high-contrast Windows theme (constitution VII).
- **FR-021**: The Windows app MUST locate the `ccwatch` CLI by explicit search rather than relying on the `PATH` a GUI process inherits, MUST display the path it resolved, and MUST state plainly that it found none rather than rendering an empty fleet.
- **FR-022**: The Windows app MUST offer only verbs — show the overlay, open the dashboard, start or restart the server, open a session in a browser, quit — and MUST NOT add a judgement, a badge or a state the bar document did not carry.
- **FR-023**: The overlay MUST host the same `/map` page the browser is served, from the same server, so there is one renderer of the map on Windows as on macOS.
- **FR-024**: The overlay MUST stay above a maximised or full-screen application, MUST appear on the operator's current virtual desktop, and MUST NOT take keyboard focus when clicked.
- **FR-025**: The overlay MUST hand a link that asks for a new window to the operator's default browser; such a click MUST NOT be swallowed silently.
- **FR-026**: The Windows app MUST adopt an existing server already answering on the dashboard port and label it as one the app did not start, rather than starting a second or contending for the port.
- **FR-027**: The Windows app MUST provide its own selftest that asserts, by name, each window property responsible for the z-order, virtual-desktop and focus behaviour in FR-024, and MUST fail loudly when one is not set — those failures are invisible to a glance.
- **FR-028**: Nothing in `bin/ccwatch` or under `web/` may come to depend on the Windows app. The CLI and the pages MUST keep working on a Windows machine that has never built it, and the suite MUST skip the Windows app's checks with the reason stated rather than failing when it has not been built.

**Tests, documentation and governance**

- **FR-029**: New assertions MUST be hermetic — a fabricated config directory via `CLAUDE_CONFIG_DIR` with the liveness probe substituted — and MUST cover, at minimum: probe selection per platform, each of the three probe outcomes in FR-003, the empty-answer cross-check in FR-004, the unavailable-versus-zero distinction in FR-011, `doctor`'s probe report in FR-014, and the bar-parsing rules in FR-017 and FR-018.
- **FR-030**: Every new assertion MUST be mutation-checked — the implementation broken in the specific way the assertion describes, the assertion confirmed to fail, then restored — with a row added to the mutation table in `README.md`, and the assertion floor raised. An assertion that has never failed has not been tested.
- **FR-031**: An assertion that needs something the host cannot supply MUST skip with the reason stated rather than fail; a Windows-only assertion MUST skip on macOS with its reason, and a macOS-only assertion MUST skip on Windows with its reason. No skip may be so broad that it hides whether a platform's probes were exercised at all.
- **FR-032**: Continuous integration MUST exercise the Windows probes on a Windows host as well as the macOS probes on a macOS host, and the run MUST record which platform each job tested and which probes it exercised. A Windows implementation that no job runs is an implementation nobody has seen fail.
- **FR-033**: `CLAUDE.md`, `README.md` and `.specify/memory/constitution.md` MUST be amended together to state that ccwatch supports macOS and Windows, which probe each platform uses, what is unavailable on each, and which failure motivated the probe layer. The constitution's "This is a macOS tool; CI runs on macOS only" constraint MUST be replaced rather than left to contradict the shipped behaviour.
- **FR-034**: `shellcheck -x -S warning` MUST stay clean for `bin/ccwatch`, `tests/run.sh`, `extra/swiftbar/ccwatch.10s.sh` and `app/build.sh`, and the bash 3.2 forms the suite greps for MUST be honoured in the probe layer. Any suppression MUST be narrow and carry its reason.
- **FR-035**: The macOS menu bar app and the SwiftBar fallback plugin MUST keep working unchanged, and the Windows app MUST NOT become a dependency of either.

### Key Entities

- **Platform probe**: one named host-dependent measurement — process facts, file modification time, wall-clock formatting, memory, swap/pagefile, load — with a per-platform implementation and a declared answer shape. The unit the rest of the tool depends on instead of depending on a program name.
- **Probe outcome**: a measurement, a measured absence, or a failure to measure with a reason. Three values that must never collapse into two.
- **Platform selection**: the detected host and the implementation chosen for each probe, reportable by `doctor` so ccwatch can say which probes produced its view.
- **Bar document**: the title line and menu rows `ccwatch bar --no-actions` prints — the only source of any verdict either GUI displays, and the contract between the CLI and both apps.
- **Tray surface**: the Windows taskbar item and its menu, a rendering of a bar document plus verbs.
- **Overlay surface**: the always-on-top Windows window hosting the served `/map`, defined by its z-order, virtual-desktop and focus behaviour.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a Windows host running N live Claude Code sessions, the tool reports exactly N of them, for every N tested including N in double figures — and never reports zero while sessions are running.
- **SC-002**: With any single host probe made unavailable, 100% of affected readings are presented as a named failure with a reason, and 0% are presented as an empty result or a zero. A reader who sees a quiet fleet can be certain the fleet is quiet.
- **SC-003**: The status shown in the taskbar and the status the terminal prints for the same moment never disagree: for every state tested they are identical, character for character, including the measurement beside each verdict.
- **SC-004**: An operator can tell which session needs them, and how long it has been waiting, without opening a terminal — in under 5 seconds from noticing the tray item, and while another application is maximised.
- **SC-005**: Every severity remains identifiable from words alone: a text-only reading of the tray menu, and a screen reader, convey the same set of verdicts as the visual one, with no verdict carried by colour or icon alone.
- **SC-006**: The Eastern reset clock produced on Windows matches the one the pages show for the same instant, to the minute and the zone abbreviation, on both sides of a daylight-saving boundary.
- **SC-007**: On macOS, the existing verdicts, output bytes and assertion tally are unchanged by the extraction, and the suite remains green with no new unexplained skip.
- **SC-008**: Every new assertion has been observed to fail against the specific break it describes, with a row recorded for it; no new assertion is counted as coverage without that observation.
- **SC-009**: The overlay stays visible and non-focus-stealing in all three tested conditions — over a maximised window, after a virtual-desktop switch, and while typing in another application — and its selftest fails when any of the responsible properties is removed.
- **SC-010**: A Windows operator can go from a fresh checkout to a working tray item by following the documented install, with no step that the documentation does not name and no manual edit of a file.
- **SC-011**: Continuous integration reports, per run, which platform each job tested and which probes it exercised; a probe that was never exercised is visible in that report rather than silently untested.

## Assumptions

These are the informed defaults taken where the feature description did not
specify. Each is a decision the planning phase should confirm, and each is
recorded here rather than left implicit.

- **`bin/ccwatch` stays one bash script and runs on Windows under a POSIX-shell
  environment the operator already needs for Claude Code work (Git for Windows /
  MSYS2-class bash), not under WSL.** WSL is rejected on a measurement argument,
  not a preference: a WSL shell cannot see Windows process ids, so liveness and
  CPU seconds — the corroborating signal behind every verdict (constitution I)
  and the *only* signal an `sdk-ts` session has — would be unobtainable for the
  sessions the operator actually runs. A Windows-native rewrite of the CLI is
  likewise rejected: it would be a second place computing status (constitution
  XI) and it contradicts "no build step for the CLI".
- **The Windows probes may call the platform's own management tooling** (the
  shell's process, memory and time facilities) from inside the probe seam, in the
  same way the macOS probes call `ps`, `vm_stat` and `sysctl`. What FR-013 rules
  out is a new installed dependency, not a call to something the OS ships.
- **Read path only.** The CLI's read path, the tray and the overlay are in scope.
  `ccwatch send`, `ccwatch kill` and peer messaging depend on POSIX signals and
  the per-session Unix socket at `bin/ccwatch:2611-2650`, and are **out of scope
  on Windows** — but per constitution IV they are shown as unavailable on this
  platform with the reason, never hidden, because a control absent from the UI
  reads as a feature that was never built.
- **`ccwatch serve` is expected to run on Windows** because the overlay hosts the
  page it serves; it is python3's HTTP server today and is assumed portable, with
  any platform-specific part of it treated as a probe under FR-001.
- **The Windows app is the one build step on that platform, and it is one-way**,
  exactly as `app/` is on macOS: it needs a toolchain, nothing in `bin/ccwatch`
  or `web/` may depend on it, and the suite skips its checks with the reason when
  it has not been built.
- **Windows 10 or later, 64-bit, with the WebView2 runtime present or installable
  by the documented install**; the tray app states the requirement and what is
  missing rather than failing opaquely.
- **A Windows CI job is added** rather than accepting untested Windows probes.
  This repository has recorded that green and broken are indistinguishable until
  a check has been seen to fail, and probes that no job runs are the clearest
  case of that.
- **Linux is not in scope.** The probe layer will make a Linux implementation
  possible later; adding one here would widen the feature past the two surfaces
  it is named for, and Linux has neither of them built.
- **`extra/swiftbar/` gains no Windows counterpart.** It is the macOS fallback for
  a machine that cannot run the macOS app; the Windows tray app is the Windows
  surface.
- **The constitution is amended, not violated.** "This is a macOS tool; CI runs
  on macOS only" is a constraint this feature deliberately changes, and FR-033
  makes the amendment part of the deliverable so the governing document and the
  shipped behaviour cannot disagree.

## Out of Scope

Each of these is deliberately excluded, and each is excluded for a stated reason
rather than for lack of time.

- **Write actions on Windows** — `ccwatch send`, `ccwatch kill` and peer
  messaging. They rest on POSIX signals and the per-session Unix socket, which
  are a different problem from reading the host. They are shown on Windows as
  unavailable with the reason rather than hidden, because a control absent from
  the UI reads as a feature that was never built (constitution IV).
- **Linux support.** The probe layer makes it possible; nothing here builds it,
  and Linux has neither a tray nor an overlay in this repository.
- **Any change to what a verdict means.** No new status, severity, threshold,
  badge or word. This feature changes where a measurement comes from and who
  renders it, never what it says. A verdict that reads differently on Windows
  than on macOS is a defect of this feature, not a feature of it.
- **Any change to the pages.** `web/` is untouched apart from what FR-033's
  documentation amendment requires; the overlay hosts the map exactly as served.
- **A second bar format.** The Windows app consumes the bytes that exist. No
  machine-readable variant, no `--json` path for the tray, and no new endpoint —
  a tray that read a payload and decided severity for itself would be the second
  place computing status this whole arrangement exists to prevent.
- **Replacing or duplicating the macOS surfaces.** `app/` and
  `extra/swiftbar/` keep working as they are and gain no Windows counterpart
  between them.
