---

description: "Task list for: Windows support for the taskbar tray and the overlay"
---

# Tasks: Windows support for the taskbar tray and the overlay

**Input**: Design documents from `/specs/006-windows-tray-overlay/`
**Prerequisites**: plan.md, spec.md, research.md (D1-D24), data-model.md, contracts/{probe-layer,bar-document,tray-app}.md, quickstart.md

**Tests**: `tests/run.sh` assertions are explicitly required by FR-029/FR-030 and are included below, hermetic and mutation-checked per the project's test discipline.

**Organization**: tasks are grouped by user story (US1-US4, priority order from spec.md) so each can be implemented and independently tested.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files/functions, no dependency on an incomplete task)
- **[Story]**: which user story this task serves (US1-US4)
- File paths are exact; line numbers cited are from spec.md/plan.md/research.md and may drift slightly as earlier tasks land — locate by banner section and function name, not line number alone.

---

## Phase 1: Setup

**Purpose**: scaffolding that has no story-specific behavior yet, so both later phases have somewhere to put code.

- [X] T001 [P] Create the `app-win/` skeleton: `app-win/Sources/Program.cs` (empty `Main`), `app-win/ccwatch-tray.csproj` targeting `net8.0-windows` with `UseWindowsForms` and a `Microsoft.Web.WebView2` package reference, and `app-win/README.md` stating the .NET 8 SDK and WebView2 runtime requirements (FR-035, D18)
- [X] T002 [P] Create `app-win/build.ps1` with `-SelfTest`, `-Run`, `-Install`, `-SelfContained` flags that only `dotnet publish` for now (refuses with a named reason when the SDK is missing), mirroring `app/build.sh`'s shape

**Checkpoint**: `app-win/` exists and `dotnet publish` runs on a machine with the SDK; nothing in `bin/ccwatch` or `web/` references it (FR-028).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: the platform-detection and probe-reporting plumbing every probe in US1 is built on. No probe is implemented here — only the seam they all use.

**⚠️ CRITICAL**: US1 cannot start until this phase is complete.

- [X] T003 Add the `platform` banner section to `bin/ccwatch`, placed immediately before the `collection` section (contracts/probe-layer.md "Where it lives"), with empty stubs for `platform_detect`, `probe_report`, `probe_note`, `probe_proc`, `probe_mtimes`, `probe_clock`, `probe_host`, `probe_native_path`, `probe_posix_path`
- [X] T004 Implement `platform_detect` in `bin/ccwatch`: run `uname -s` once, map `Darwin`→`macos`, `MINGW*`/`MSYS*`/`CYGWIN*`→`windows`, anything else→`unsupported` (no default-arm fallthrough — principle V), set `CCWATCH_PLATFORM`/`CCWATCH_UNAME`; honour a pre-set `CCWATCH_PLATFORM` as an override rather than re-detecting (D2, FR-002)
- [X] T005 Implement `CCWATCH_PY` resolution in `bin/ccwatch` (D4): try `python3`, then `python` (accept only if `sys.version_info.major == 3`), then `py -3`; set `CCWATCH_PY` to the first that answers, empty when none do; called once from `platform_detect`
- [X] T006 Implement `CCWATCH_BASH` resolution stub in `bin/ccwatch` for the Windows case only (D1, D18 candidate order: build-time recorded path, `HKLM\SOFTWARE\GitForWindows\InstallPath`, `%ProgramFiles%\Git\bin\bash.exe`, `C:\msys64\usr\bin\bash.exe`, `PATH`), excluding `%SystemRoot%\System32\bash.exe` by path and verified by running `uname -s`
- [X] T007 Implement `probe_note`/`probe_report` in `bin/ccwatch`: a run-scoped TSV file created lazily via `mktemp "${TMPDIR:-/tmp}/ccwatch-probes.XXXXXX"` (a template, never a bare `mktemp` — D8), one row per `probe_note` call (`name`, `impl`, `outcome`, `reason`, `detail`), removed by the existing `cleanup` EXIT trap
- [X] T008 [P] Add `CCWATCH_PLATFORM`, `CCWATCH_PY`, `CCWATCH_BASH` to `usage()`'s environment-variable documentation in `bin/ccwatch`, and to the "Running things" section of `CLAUDE.md`

**Checkpoint**: `platform_detect` runs once per invocation, sets the three variables correctly on macOS (verified interactively) and under `CCWATCH_PLATFORM=windows`/`unsupported` overrides; `probe_report` produces a file and `doctor` can read it (wired in T028). No probe has real behaviour yet.

---

## Phase 3: User Story 1 - The Windows read path tells the truth or says what it could not measure (Priority: P1) 🎯 MVP

**Goal**: every host-dependent measurement in `bin/ccwatch` goes through a named probe that returns one of three outcomes (measurement / measured absence / failure to measure) and never conflates them; macOS keeps identical behaviour.

**Independent Test**: on a Windows host, `ccwatch once`, `ccwatch --json`, `ccwatch doctor` report every live session with its measurement; each probe made unavailable in turn is a named failure, never an empty result or a zero; on macOS the existing suite passes unchanged.

### Tests for User Story 1

> Hermetic per the project's rules: `CLAUDE_CONFIG_DIR` fixtures, `CCWATCH_FAKE_PS` for liveness, `CCWATCH_PLATFORM` override for selection. Each assertion below must be mutation-checked (FR-030) before being counted.

- [X] T009 [P] [US1] Add assertions to `tests/run.sh` for probe selection per platform: run `ccwatch doctor` under `CCWATCH_PLATFORM=macos` and `CCWATCH_PLATFORM=windows` from either host and assert the platform block names the right implementation per probe (FR-029, quickstart §5)
- [X] T010 [P] [US1] Add assertions to `tests/run.sh` for the three probe outcomes never collapsing into two: a forced `ok`, a forced `absent` (empty payload with control query passing), and a forced `failed` (control query failing) each produce the exit code / stdout / report shape data-model.md §3 specifies
- [X] T011 [P] [US1] Add an assertion to `tests/run.sh` that the empty-answer cross-check (control query) is generalised to every probe: with the control query failing, the probe reports `failed` and `ccwatch once` says nothing about that measurement rather than reporting an empty result (FR-004, mutation target: make the Windows `proc` control query use `$$` instead of `/proc/self/winpid`)
- [X] T012 [P] [US1] Add an assertion to `tests/run.sh` for the unavailable-versus-zero distinction in `probe_host`'s payload: `load1` is `null` with a reason in `unavailable`, never `0`; pagefile fields are `null` together when no pagefile exists, never `0%` (FR-011, mutation target: report `load1: 0`)
- [X] T013 [P] [US1] Add an assertion to `tests/run.sh` for `doctor`'s probe report (FR-014): every one of the six probes appears, including healthy ones; an unrecognised answer from a probe is reported as a named problem rather than falling through a default branch
- [X] T014 [P] [US1] Add an assertion to `tests/run.sh` that `CCWATCH_FAKE_PS` still works unchanged as the single liveness seam on both platforms, parsed with the BSD text parser regardless of `CCWATCH_PLATFORM` (FR-006, D10)
- [X] T015 [P] [US1] Add an assertion to `tests/run.sh` for the `unsupported` platform path: `CCWATCH_PLATFORM=unsupported ccwatch doctor` reports every probe `failed` with "no implementation for this platform", exits non-zero, and invents nothing (D3)

### Implementation for User Story 1 — process facts

- [X] T016 [US1] Implement `probe_proc` for macOS in `bin/ccwatch`: wrap the existing `ps -o pid=,lstart=,time=,rss= -p <pids>` pipeline verbatim behind the probe interface, with the control query `ps -o pid= -p $$` (FR-005, contracts/probe-layer.md)
- [X] T017 [US1] Implement `probe_proc` for Windows in `bin/ccwatch`: one `$CCWATCH_PY -c` program using `ctypes` — `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`, `GetProcessTimes` (creation FILETIME→UTC epoch, kernel+user CPU seconds), `GetProcessMemoryInfo` (working set→MB) — for the whole pid list in one process (D12)
- [X] T018 [US1] In the Windows `probe_proc`, distinguish per-pid outcomes: handle opened→a record; `ERROR_INVALID_PARAMETER` (87)→measured absence for that pid; `ERROR_ACCESS_DENIED` (5)→failure to measure for that pid, counted and reasoned, never folded into "not running" (D12)
- [X] T019 [US1] Implement the Windows control query for `probe_proc` using the pid from `/proc/self/winpid`, never `$$` (D11); on the fallback path where `/proc/self/winpid` is absent, report the probe as `failed`("refused") rather than guessing
- [X] T020 [US1] Add the PowerShell `Get-CimInstance Win32_Process` fallback for `probe_proc` on Windows, selected only when `CCWATCH_PY` is empty, reported by `doctor` as the implementation in use when selected (D12)
- [X] T021 [US1] Rewrite `collect_live`'s process-facts call site (`bin/ccwatch` around line 168) to call `probe_proc` instead of invoking `ps` inline; keep the pid-reuse guard and CPU-delta comparison logic unchanged (FR-007, FR-008)

### Implementation for User Story 1 — transcript mtimes

- [X] T022 [US1] Implement `probe_mtimes` for macOS in `bin/ccwatch`: `find … -print0 | xargs -0 stat -f '%m %N' | sort -rn`, unchanged from today (FR-005)
- [X] T023 [US1] Implement `probe_mtimes` for Windows in `bin/ccwatch`: `find … -print0 | xargs -0 stat -c '%Y %n' | sort -rn` (GNU `stat`, D13), with the control query being the mtime of the listing's own root directory
- [X] T024 [US1] Rewrite the transcript-listing call site (`bin/ccwatch` around line 1856) to call `probe_mtimes`; an unreadable root is `failed`, not `absent` (contracts/probe-layer.md)

### Implementation for User Story 1 — the Eastern clock

- [X] T025 [US1] Implement `probe_clock` in `bin/ccwatch`: validate each candidate once per run against two fixed instants (one EDT, one EST) with hard-coded known-correct answers, in order — BSD `date -r` (macOS), GNU `date -d "@<epoch>"` (Windows), PowerShell `TimeZoneInfo.ConvertTimeFromUtc` with zone id `Eastern Standard Time` — and use only the first candidate that answers both correctly; never `jq` (D14)
- [X] T026 [US1] Implement the "clock withheld" path in `probe_clock`: when no candidate validates, return empty and record `failed` with each candidate's answer to the two fixed instants, so `doctor` can show why each was rejected
- [X] T027 [US1] Rewrite `reset_clock`'s call site (`bin/ccwatch` around line 1191) to call `probe_clock`; keep the existing "empty/null/non-numeric input returns empty without consulting an implementation" behaviour (contracts/probe-layer.md)

### Implementation for User Story 1 — host pressure

- [X] T028 [US1] Implement `probe_host` for macOS in `bin/ccwatch`: `vm_stat` + `sysctl -n vm.swapusage` + `sysctl -n vm.loadavg`, unchanged (FR-005)
- [X] T029 [US1] Implement `probe_host` for Windows in `bin/ccwatch`: one PowerShell invocation querying `Win32_OperatingSystem.FreePhysicalMemory` and `Win32_PageFileUsage.{AllocatedBaseSize,CurrentUsage}`; `swap_total_mb`/`swap_used_mb`/`swap_used_pct` are `null` together with reason "this host has no pagefile" when no `Win32_PageFileUsage` instance exists; `compressed_mb` is simply absent; `load1` is always `null` with reason "Windows has no load average" (D15, FR-011)
- [X] T030 [US1] Add the 250ms-measured cache for the Windows host probe: if `CCWATCH_PROFILE=1` measurement exceeds 250ms, cache the reading for 30s under `$CCWATCH_HOME` with its age, and withhold (not annotate) a reading past that window (D15, principle III)
- [X] T031 [US1] Rewrite the host-pressure call sites (`bin/ccwatch` around lines 2329/2340/2348) to call `probe_host`
- [X] T032 [US1] Fix `cmd_doctor`'s pressure branch (`bin/ccwatch` around line 5046) so `[ "${swp:-0}" -ge "$CCWATCH_SWAP_WARN" ]`-style arithmetic never runs on the string `null`: when `swap_used_pct` is `null`, state which figure is unavailable and why instead of computing a verdict (FR-012, D15 "Consequence to fix")

### Implementation for User Story 1 — paths, encoding, platform edges

- [X] T033 [US1] Implement `probe_native_path`/`probe_posix_path` in `bin/ccwatch`: `cygpath -w`/`cygpath -u` on Windows, identity on macOS (D5)
- [X] T034 [US1] Apply `probe_native_path`/`probe_posix_path` at every bash↔native boundary: the python probe call sites, `serve`'s `CCWATCH_SELF`/`CCWATCH_WEB`, transcript paths handed to `convo`, and the path passed to the tray app — not applied to paths that stay inside the shell (D5)
- [X] T035 [US1] Change `serve`'s `SELF` to an argv list (`[SELF]` on macOS, `[CCWATCH_BASH, SELF]` on Windows) at all four `subprocess.run` call sites (`bin/ccwatch` around lines 3397, 3584, 3608, 3641), so CPython on Windows never tries to execute the shebang line directly (D6)
- [X] T036 [US1] Strip `\r` from every Windows probe's own output before it returns (D16); make registry/transcript readers tolerate `\r\n` so a stray carriage return never turns `idle` into an unrecognised status value
- [X] T037 [US1] Normalise Windows `cwd` values from backslashes to forward slashes at ingest in `collect_sessions`, before the `split("/") | last` project-name join sees them (`bin/ccwatch` around lines 958 and 1978) (D17)
- [X] T038 [US1] Update all 16 existing `python3` call sites in `bin/ccwatch` to invoke `$CCWATCH_PY` (resolved in T005) instead of the literal `python3`, preserving the `-c`-only, never-stdin invocation style (D4, constitution's stdin rule unchanged)

### Implementation for User Story 1 — reporting, write-action refusal, install

- [X] T039 [US1] Update `cmd_doctor` to print the platform/probe block from contracts/probe-layer.md "What doctor must print": platform, python, bash (Windows), then one line per probe with its implementation, outcome, and reason/detail when not `ok` — every probe listed, including healthy ones (FR-014)
- [X] T040 [US1] Make `ccwatch send`, `ccwatch kill` and `ccwatch peers` exit with a named refusal on Windows — "not available on Windows: this needs POSIX signals and the per-session Unix socket" — and make `ccwatch serve` on Windows read-only: no token generated, write endpoints refuse, startup banner and `doctor` both state why (D23, FR per Out of Scope)
- [X] T041 [US1] Update `cmd_setup` for Windows: attempt `ln -s`, check whether the result is actually a symlink (not a silent MSYS copy), fall back to a two-line `exec` shim when it is not, then verify by running the installed thing and comparing the version — refuse with the reason on any failure (D24, FR-015)

### Assertions cleanup for User Story 1

- [X] T042 [US1] Add the FR-001 grep assertion to `tests/run.sh`: no `ps`, `stat -f`, `date -r`, `vm_stat` or `sysctl` invocation exists outside the `platform` section, with comment lines excluded from the match and the assertion mutation-checked against a real inline call planted outside the seam (plan.md "Post-Design Constitution Re-check")
- [X] T043 [US1] Mutation-check every assertion added in T009-T015 and T042 against the specific break quickstart.md §6 names for it (control query using `$$`, `ERROR_ACCESS_DENIED` folded into "not running", `load1: 0`, a pagefile percentage with no pagefile, clock validation skipped, CRLF not stripped, `cwd` not normalised); add one row per assertion to the mutation table in `README.md`
- [X] T044 [US1] Raise `TALLY_FLOOR` in `tests/run.sh` by the number of new assertions from this story that always run (excluding anything gated behind a built `app-win` binary or a Windows host)

**Checkpoint**: on a fabricated Windows fixture (`CCWATCH_PLATFORM=windows` + `CCWATCH_FAKE_PS`), `ccwatch once`/`--json`/`doctor` report every session with its measurement and never an empty fleet; on macOS, `./tests/run.sh` and `ccwatch --json` are byte-identical to before this phase started (verified formally in US4, but this checkpoint is the first place it becomes possible to check).

---

## Phase 4: User Story 2 - A Windows operator sees the worst verdict in the taskbar without a terminal open (Priority: P2)

**Goal**: the Windows tray shows exactly what `ccwatch bar --no-actions` printed, character for character, with verbs added and no judgement computed locally.

**Independent Test**: compare the tray's title and every menu row against `ccwatch bar --no-actions` run in a shell at the same moment; break the snapshot and confirm the title becomes `cc ?` with the explanatory sentence, never a count.

### Implementation for User Story 2

- [X] T045 [US2] Implement the CLI/bash locator in `app-win/Sources/Program.cs` per contracts/tray-app.md: bash candidates in order (build-time recorded path, `HKLM\SOFTWARE\GitForWindows\InstallPath`, `%ProgramFiles%\Git\bin\bash.exe`, `C:\msys64\usr\bin\bash.exe`, `PATH`), excluding `%SystemRoot%\System32\bash.exe` by path and accepting only candidates where `uname -s` reports `MINGW*`/`MSYS*`/`CYGWIN*` (D19)
- [X] T046 [US2] Extend the locator to resolve the `ccwatch` script itself (build-time recorded path, then documented install locations), accepted only if `bash <script> --version` prints a line beginning `ccwatch `; surface both resolved paths and the version in the menu, and a miss as a named miss rather than an empty fleet (FR-021, D19)
- [X] T047 [US2] Implement the bar-document parser in `app-win/Sources/Program.cs` per contracts/bar-document.md: line 0 is the title, `---` opens/splits the menu, an item's text ends at the **first** ` | ` and no other, quoted parameter values with spaces are unquoted, and any parameter this app does not implement is retained so the line still renders (FR-017, FR-018)
- [X] T048 [US2] Implement CLI invocation in `app-win/Sources/Program.cs`: `<bash> <script> bar --no-actions` with `NO_COLOR=1`, `CCWATCH_PORT=<port>`, `UseShellExecute=false`, `CreateNoWindow=true`, reading the pipe as it fills (no deadlock on a full buffer), a 120s timeout, refresh every `CCWATCH_BAR_REFRESH` seconds (default 10)
- [X] T049 [US2] Implement the `NotifyIcon` + `ContextMenuStrip` tray surface: title verbatim from the parsed document, menu rows in document order with separators, severity words and measurements shown as text with colour/glyph as additions only (FR-016, FR-019, FR-020)
- [X] T050 [US2] Implement the empty/failed-snapshot path: when CLI output is empty or unparseable, render the `cc ?` title and the menu sentence "ccwatch could not read the sessions" / "This is NOT \"nothing is running\" — the snapshot itself failed.", never `cc 0` (FR-019, contracts/bar-document.md)
- [X] T051 [US2] Implement the verb block below the parsed menu: Show/Hide Overlay, Open Dashboard in Browser, Open Agent in Browser (for a row carrying a session id), Restart serve, Quit — plus the two non-interactive lines (serve state, resolved CLI/bash paths with version) — and nothing else (FR-022)
- [X] T052 [US2] State plainly in the menu that send/kill/peer messaging are unavailable on Windows with the reason, rather than omitting them (D23, principle IV)
- [X] T053 [US2] Implement the `ServeSupervisor` in `app-win/Sources/Program.cs`: probe the dashboard port before starting anything; `notStarted`→`adopted` when something already answers (labelled "not started by this app"); `notStarted`→`running(pid)` when spawned; bounded at 3 restarts on failure, then `failed(reason)` and stop; reap a server this app started on quit (FR-026)
- [X] T054 [US2] Implement `--selftest` claims 1-9 from contracts/tray-app.md (title parsing, condition-in-words, separator survival, measurement travels with verdict, colour-not-recomputed, first-`|`-split injection-document claim, no `bash=` parsed, unknown-parameter-retained, empty-output-is-question-mark) against the four conformance inputs in contracts/bar-document.md
- [X] T055 [US2] Finish `app-win/build.ps1`: `-Run` launches the built app; `-Install` copies into `%LOCALAPPDATA%\Programs\ccwatch`; `-SelfContained` bundles the runtime; the build records the checkout path into the binary (D19); requirement checks for the .NET 8 SDK and the WebView2 runtime are refused with the named installer rather than failing opaquely

### Tests for User Story 2

- [X] T056 [P] [US2] Add an `app-win` section to `tests/run.sh`: `t_skip` with "app-win not built — run ./app-win/build.ps1" when the binary is absent, `t_skip` with "a Windows binary cannot run on macOS" on Darwin, and on a built Windows binary assert the selftest's summary line, exit code, and claims 6, 7, 9 by their exact substring text (contracts/tray-app.md "What tests/run.sh asserts about this app"); none of these count toward `TALLY_FLOOR`
- [ ] T057 [US2] Mutation-check the parser assertions (T056) by splitting the bar line on the last ` | ` instead of the first, and by dropping a line carrying an unknown parameter, confirming each break turns the corresponding selftest claim red; add rows to the mutation table in `README.md`

**Checkpoint**: with a mixture of idle/working/blocked sessions, the tray's title and every menu row are byte-identical to `ccwatch bar --no-actions` at the same moment; a broken snapshot shows `cc ?` with the explanation, never `cc 0`; a session name containing `|` never produces a clickable menu row.

---

## Phase 5: User Story 3 - The always-on-top overlay works over a maximised window (Priority: P3)

**Goal**: an always-on-top, non-focus-stealing WebView2 window on the served `/map`, visible over a maximised application and on the operator's current virtual desktop.

**Independent Test**: open the overlay, maximise another application over it, switch virtual desktops, click it while typing in a terminal, and click a `target="_blank"` link — verify visibility, focus retention and browser hand-off in each case.

### Implementation for User Story 3

- [ ] T058 [US3] Implement the overlay `Form` in `app-win/Sources/Program.cs` hosting `Microsoft.Web.WebView2.WinForms.WebView2` pointed at `http://127.0.0.1:<port>/map` — the same page the browser is served, from the same server (FR-023)
- [ ] T059 [US3] Implement the z-order property: `TopMost = true` and `WS_EX_TOPMOST`, re-asserted via `SetWindowPos(HWND_TOPMOST, …)` on show and on foreground-change (FR-024, D20)
- [ ] T060 [US3] Implement the virtual-desktop property: obtain `IVirtualDesktopManager`, check `IsWindowOnCurrentVirtualDesktop`, and hide/re-show the window when it is false so it materialises on the desktop in use (FR-024, D20)
- [ ] T061 [US3] Implement the no-focus-steal property: `WS_EX_NOACTIVATE`, `WM_MOUSEACTIVATE` answered with `MA_NOACTIVATE`, and shown via `ShowWindow(SW_SHOWNOACTIVATE)` rather than `.Show()` (FR-024, D20)
- [ ] T062 [US3] Implement the taskbar/Alt-Tab exclusion: `ShowInTaskbar = false` and `WS_EX_TOOLWINDOW` (D20)
- [ ] T063 [US3] Implement `NewWindowRequested` handling: `Process.Start(UseShellExecute = true)` on the requested URL, then `e.Handled = true`, so a link is never swallowed in silence (FR-025)
- [ ] T064 [US3] Implement reload-on-show: re-navigate the WebView2 to the `/map` URL each time the overlay is shown rather than leaving it running hidden (contracts/tray-app.md — avoids keeping the collector awake for a hidden view)
- [ ] T065 [US3] Implement the no-server-answering message: opening the overlay when nothing answers on the dashboard port states that plainly rather than presenting an empty map (FR-023, principle IV)
- [ ] T066 [US3] Document the stated limitation in `app-win/README.md`: `TopMost` covers maximised and borderless-fullscreen windows but not exclusive-fullscreen Direct3D applications, and name the undocumented alternatives that were rejected and why (D20)
- [ ] T067 [US3] Extend `--selftest` with claims 10-19 from contracts/tray-app.md (z-order bit, re-assert path, focus bit, `WM_MOUSEACTIVATE` handler, `SW_SHOWNOACTIVATE` show path, virtual-desktop interface + reveal, taskbar/Alt-Tab exclusion, new-window-request handled, closed-port probe, WSL-bash exclusion, verify-by-running-uname) — window-property checks (10-16) run without the WebView2 runtime present; only the navigation check skips with its reason when it is absent (FR-027)

### Tests for User Story 3

- [ ] T068 [US3] Extend the `app-win` section of `tests/run.sh` to assert selftest claims 10, 12, 15, 17, 19 by their exact substring text when running on a built Windows binary (contracts/tray-app.md)
- [ ] T069 [US3] Mutation-check the overlay assertions in T068 by removing `WS_EX_NOACTIVATE` and by removing the `System32\bash.exe` exclusion, confirming each break turns the corresponding claim red; add rows to the mutation table in `README.md`

**Checkpoint**: the overlay's window-property selftest passes on a built Windows binary; the four manual checks in quickstart.md §3 (maximised app, virtual-desktop switch, click-while-typing, new-window link) are the only remaining verification and are run once as part of US3's manual pass, not automated.

---

## Phase 6: User Story 4 - Nothing changes for the macOS operator (Priority: P4) — the shipping gate

**Goal**: prove the extraction changed nothing observable on macOS, and land the CI/documentation obligations the feature carries.

**Independent Test**: run `./tests/run.sh` and `ccwatch --json` before and after the extraction on the same macOS machine and diff.

### Implementation for User Story 4

- [ ] T070 [US4] Capture `ccwatch --json` output on macOS before Phase 2 begins (if not already captured) and diff it against the post-extraction output with `jq -S 'del(.at, .sessions[].age, .sessions[].cpu)'` on both sides — confirm the diff is empty (SC-007, quickstart §4)
- [ ] T071 [US4] Run `./tests/run.sh` on macOS and confirm it is green, the assertion tally is at or above the (now-raised) floor, and no new skip hides a Windows-only path
- [ ] T072 [US4] Run `./app/build.sh --selftest` and confirm the macOS menu bar app's own checks still pass unchanged (FR-035)
- [ ] T073 [US4] Confirm `CCWATCH_FAKE_PS=tests/fixtures/ps-sample ./bin/ccwatch --json | jq '.sessions | length'` is unchanged from before the extraction
- [ ] T074 [US4] Add a `windows-latest` job to `.github/workflows/ci.yml` running `tests/run.sh` under the runner's Git Bash, printing `ccwatch doctor`'s platform/probe section and the suite's per-probe "exercised" lines; keep `macos-latest` unchanged and owning lint (D22, FR-032, SC-011)
- [ ] T075 [US4] Amend `CLAUDE.md`, `README.md` and `.specify/memory/constitution.md` together (FR-033): replace "This is a macOS tool; CI runs on macOS only" with a statement that ccwatch supports macOS and Windows, which probe implementation each platform uses, what is unavailable on each (load average, `send`/`kill`/`peers`, the compressor figure), and the failure that motivated the probe layer (`ps` refused, 18 sessions live, 0 reported)
- [ ] T076 [P] [US4] Run `shellcheck -x -S warning` over `bin/ccwatch`, `tests/run.sh`, `extra/swiftbar/ccwatch.10s.sh` and `app/build.sh` and fix or narrowly suppress (with a reason) anything the platform section introduced (FR-034)

**Checkpoint**: this phase is the gate — none of US1-US3 may be considered shippable until every item here passes, per plan.md's Constitution Check.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: the run-through and bookkeeping that spans every story.

- [ ] T077 Walk `quickstart.md` end to end on both a macOS host and a Windows host (or the CI Windows runner if no physical host is available) and record which of U1-U6 (research.md's "What remains unverified" table) were settled and how
- [ ] T078 [P] Update `app-win/README.md` with the final requirements, install steps and what is unavailable on Windows, so SC-010's "no step the documentation does not name" holds
- [ ] T079 Final `TALLY_FLOOR` pass in `tests/run.sh`: confirm the floor reflects exactly the always-run assertions added across US1-US4 (not anything gated behind a built `app-win` binary or a Windows-only host)

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup only for T001/T002 not colliding with T003-T008's file; blocks every user story
- **US1 (Phase 3)**: depends on Foundational; nothing else blocks it — it is the MVP
- **US2 (Phase 4)**: depends on Foundational (uses the bar document, which US1 makes trustworthy) and on `app-win/`'s skeleton from Setup; does not require US1's assertions (T009-T015) to be finished, only the probes US1 wires (T016-T041), since the tray consumes `ccwatch bar` output rather than probes directly
- **US3 (Phase 5)**: depends on US2's `Program.cs` (tray, locator, serve supervisor) existing, since the overlay is opened from the tray and hosted by the same supervised server
- **US4 (Phase 6)**: depends on US1, US2 and US3 all being functionally complete — it is the gate on shipping any of them, not a phase that unlocks new capability
- **Polish (Phase 7)**: depends on all of the above

### Within each story

- Tests before the implementation they assert on, where both exist in the same story (US1, US2, US3 each list tests as their own subsection)
- Probe implementations before their call-site rewrites (e.g., T016/T017 before T021)
- The locator (T045-T046) before anything that invokes the CLI through it (T048)

### Parallel opportunities

- T001/T002 (Setup) in parallel
- T008 in parallel with T003-T007 (documentation, no code dependency)
- T009-T015 (US1 test additions) in parallel with each other, and in parallel with early implementation tasks once the probe stubs from T003 exist
- Within US1: the four probe families (process T016-T021, mtimes T022-T024, clock T025-T027, host T028-T032) touch disjoint functions and can proceed in parallel once Phase 2 is done
- T056 in parallel with T057 once both exist; T068 in parallel with T069

---

## Parallel Example: User Story 1

```bash
# Once Phase 2 lands, these probe families are independent:
Task: "Implement probe_proc for macOS in bin/ccwatch"          # T016
Task: "Implement probe_mtimes for macOS in bin/ccwatch"        # T022
Task: "Implement probe_clock in bin/ccwatch"                   # T025
Task: "Implement probe_host for macOS in bin/ccwatch"          # T028

# And the hermetic test additions are independent of each other:
Task: "Add probe-selection assertions to tests/run.sh"          # T009
Task: "Add the three-outcomes assertion to tests/run.sh"        # T010
Task: "Add the unavailable-vs-zero assertion to tests/run.sh"   # T012
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1: Setup
2. Phase 2: Foundational (platform detection + probe reporting plumbing)
3. Phase 3: User Story 1 — the read path
4. **STOP and VALIDATE**: run `ccwatch once`/`--json`/`doctor` against a Windows fixture and confirm the independent test in spec.md; confirm macOS is unchanged
5. This alone is shippable: an operator with a working terminal read path already has the product, even with no tray built (spec.md, US1's "Why this priority")

### Incremental delivery

1. Setup + Foundational → the seam exists
2. Add US1 → validate independently → the CLI tells the truth on Windows (MVP)
3. Add US2 → validate independently → the tray exists and agrees with the terminal
4. Add US3 → validate independently → the overlay is unmissable over a maximised window
5. Add US4 → the shipping gate: prove nothing on macOS moved, land CI and the documentation amendment
6. Polish

### Notes

- US1 is the only story worth anything entirely on its own; US2 cannot be trusted without it and US3 cannot exist without US2's tray as its entry point.
- US4 is deliberately last as a *phase* even though its content (CI, docs) could be written earlier — it is a gate, not an increment, and plan.md is explicit that it "delivers no new value."
- Every new assertion added in US1-US3 must be mutation-checked before it is counted (FR-030) — this is not optional polish, it is a per-task acceptance criterion baked into T043, T057 and T069.
