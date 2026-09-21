# Implementation Plan: Windows support for the taskbar tray and the overlay

**Branch**: `006-windows-tray-overlay` | **Date**: 2026-09-20 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/006-windows-tray-overlay/spec.md`

## Summary

Two deliverables, in this order.

**A platform probe seam in `bin/ccwatch`.** Every host-dependent measurement —
process facts, transcript modification times, epoch→Eastern wall clock, host
memory/pagefile/load, and path translation — moves behind one named function per
measurement in a new `platform` section, placed before `collection` because the
collectors call it. Each probe returns one of three outcomes that may never
collapse into two: a measurement, a measured absence, or a **failure to measure**
carried with its reason. The guard at `bin/ccwatch:336-350` — the one that exists
because a refused `ps` made ccwatch say "No live Claude Code sessions" on a
machine running eighteen — is generalised from that one probe to all of them.
macOS keeps the same programs, the same arguments and the same output bytes.

**A Windows tray and overlay in `app-win/`.** A C# WinForms program on .NET 8: a
`NotifyIcon` tray item whose title and menu are the bytes of `ccwatch bar
--no-actions`, and a borderless always-on-top WebView2 window on the same `/map`
the browser is served. It holds no judgement — it parses the bar document with
the same three rules the macOS app uses (line 0 is the title, `---` splits the
menu, an item's text ends at the **first** ` | `) and adds only verbs. It is the
second renderer of the snapshot, not a second place that computes it.

The Windows probes are Win32 through python `ctypes` for process facts (one
process, not one per pid), GNU `stat -c` for mtimes, a validated `date`
implementation for the Eastern clock, and one PowerShell query for host
pressure — where `load1` is `null` with the reason "Windows has no load
average", because Windows has none and a processor-queue proxy would be a status
ccwatch did not read.

Full reasoning, with what was rejected and why, is in
[research.md](./research.md) (D1–D24). The three interface contracts are
[contracts/probe-layer.md](./contracts/probe-layer.md),
[contracts/bar-document.md](./contracts/bar-document.md) and
[contracts/tray-app.md](./contracts/tray-app.md).

## Technical Context

**Language/Version**: bash 3.2 for `bin/ccwatch` (no `mapfile`, no `declare -A`,
no `${var,,}`) and `tests/run.sh`; python3 for the socket client, date parsing,
the HTTP server and now the Windows process probe; C# on `net8.0-windows` for
`app-win/`; PowerShell 5.1+ for `app-win/build.ps1` and the Windows host probe.
Swift in `app/` is untouched.

**Primary Dependencies**: none new for the CLI. The Windows probes call what the
OS ships — Win32 via `ctypes`, PowerShell's CIM classes, `cygpath`, GNU
`stat`/`date` from the MSYS environment the operator already has. `app-win/`
depends on the .NET 8 SDK to build and on `Microsoft.Web.WebView2` (NuGet) plus
the WebView2 runtime to open the overlay; `jq` and `python3` stay the CLI's only
external programs.

**Storage**: files only. Runtime state under `~/.claude/ccwatch/`
(`$CCWATCH_HOME`), never committed; the run-scoped probe report is a file there,
and the Windows host reading is cached there **with its age** only if it is
measured over 250ms (D15). No database, no package manifest.

**Testing**: `./tests/run.sh` — shellcheck, then the assertion suite — remains
the only entry point. Assertions stay hermetic: a fabricated config directory
via `CLAUDE_CONFIG_DIR`, `CCWATCH_FAKE_PS` as the single liveness seam on both
platforms, and `CCWATCH_PLATFORM` as the seam that lets probe **selection** be
asserted for either platform from either platform. `app-win/build.ps1
-SelfTest` runs the window-property selftest; `ccwatch verify-ui` and the
`markdown` section are unchanged.

**Target Platform**: macOS (unchanged, `Darwin`) and Windows 10+ 64-bit under
Git for Windows / MSYS2 bash (`MINGW*`, `MSYS*`, `CYGWIN*` — Cygwin detected and
probed the same way but not verified, and `doctor` says so). **WSL is excluded
by a test, not by documentation**: a WSL shell cannot see Windows process ids, so
the corroborating signal behind every verdict would be unobtainable, and the
Windows app therefore rejects `%SystemRoot%\System32\bash.exe` by path and
requires `uname -s` to report MINGW/MSYS/CYGWIN. Anything else is
`unsupported` — a first-class value where every probe fails with the platform in
its reason and the run continues.

**Project Type**: a single bash CLI plus static pages, with one per-platform GUI
shell each: `app/` (macOS, Swift) and now `app-win/` (Windows, C#). Both are
one-way — nothing in `bin/ccwatch` or `web/` may come to depend on either.

**Performance Goals**: the snapshot keeps its ~2s repaint budget, so the Windows
process probe is one python process for all pids rather than one spawn per pid
(the first `collect_live` cost ~1.7s of fork overhead on 19 sessions and had to
be rewritten into exactly one process; the same constraint applies here).
`CCWATCH_PROFILE=1` is the measurement: the PowerShell host probe is cached for
30s with its age if it exceeds 250ms, and the `ctypes` probe falls back to
PowerShell only where `ctypes` is unavailable, reported by `doctor` when it does.

**Constraints**: `shellcheck -x -S warning` clean for `bin/ccwatch`,
`tests/run.sh`, `extra/swiftbar/ccwatch.10s.sh` and `app/build.sh`, with
suppressions narrow and reasoned. No build step for the CLI or the pages. No new
installed dependency for the CLI on either platform. Write actions (`send`,
`kill`, `peers`) are refused **by name with the reason** on Windows rather than
hidden, and `serve` there is read-only. `\r\n`, paths with spaces and drive
letters, and a session name containing `|` must all survive the round trip.

**Scale/Scope**: `bin/ccwatch` is ~4900 lines today; the probe seam adds one
section and rewrites the five call sites the spec's table names, plus
`cmd_doctor`'s pressure branch (which today does arithmetic on a value that can
be the string `null`). `app-win/` is a new top-level directory of roughly the
size of `app/`'s 751 Swift lines. One new CI job (`windows-latest`); lint stays
on the macOS job so there is one linter and one verdict.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against `.specify/memory/constitution.md` v1.1.0. Principles the
feature touches are judged; the rest are recorded as untouched so a reader can
see they were considered.

| Principle | Gate | Verdict |
|---|---|---|
| I — never one signal | Windows must supply CPU seconds as well as liveness, or a verdict would rest on transcript silence alone | **Pass.** `GetProcessTimes` gives start time and cumulative CPU in the same call as liveness (D12); where CPU cannot be read the probe reports a failure to measure and nothing is escalated (quickstart 1e) |
| II — measurement beside the verdict | the tray must carry the number, not just the word | **Pass.** The tray renders the bar document's rows verbatim, measurement included; FR-017/018 forbid reshaping a line |
| III — stale readings withheld | the 30s Windows host cache could put an old number on screen | **Pass.** The cache exists only above a measured 250ms, carries its age, and a reading past the window is dropped rather than annotated (D15) |
| IV — a failure is not an absence | five probes, each able to fail quietly; plus write actions unavailable on Windows | **Pass — this is the feature's spine.** Three outcomes that never collapse into two (FR-003), the empty-answer cross-check generalised to every probe (FR-004), `null` rather than `0` for a figure the host cannot supply (FR-011), `cc ?` rather than a count for a failed snapshot (FR-019), and `send`/`kill`/`peers` refused by name with the reason rather than hidden (D23) |
| V — never invent a status | an unrecognised column from a Windows process query | **Pass.** It costs that row, is counted, and is reported by `doctor`; no default arm manufactures a verdict. `ERROR_ACCESS_DENIED` is a failure to measure that pid, never "not running" |
| VI — say nothing rather than guess | no load average on Windows; `sdk-ts` sessions | **Pass.** `load1` is `null` with its reason; a processor-queue proxy is rejected by name. An `sdk-ts` session whose only signal is CPU time says nothing when CPU time cannot be read |
| VII — colour is never alone | a tray icon and a high-contrast theme | **Pass.** The severity vocabulary is the CLI's words; glyph and colour are additions (FR-020, quickstart 2e) |
| VIII — delivery observed | no new write action ships | **N/A.** Write actions are out of scope on Windows and refused by name |
| IX — loopback is not a gate | the overlay talks to `127.0.0.1` | **Pass.** No endpoint is added and no check is weakened; `serve` on Windows is read-only and issues no token, so there is less surface, not looser surface |
| X — transcripts are sensitive | the overlay is a WebView2 on the served page | **Pass.** It hosts `/map` as served; `web/` is untouched, so the escape-then-format path and the no-links rule are the same code |
| XI — one code path computes status | a third renderer of the snapshot | **Pass, and it is the reason the tray consumes bar bytes rather than JSON.** FR-016 forbids the app computing, inferring or defaulting anything; a `--json` path for the tray is explicitly out of scope |
| XII — normal conditions are silent | the host-pressure line on Windows | **Pass.** Absent below threshold, and when the judgement cannot be made at all it states which figure is unavailable rather than becoming a permanent "pagefile fine" line |
| XIII — position is stable | no layout change | **N/A.** `web/` is untouched apart from FR-033's documentation |

**Additional constraints**: bash 3.2 forms, BSD `stat -f`/`ps -o lstart=` on
macOS, `python3 -c` rather than stdin, shellcheck clean, no build step for the
CLI or the pages, runtime state uncommitted — all honoured. Two constraints are
deliberately changed rather than met, and both are recorded in **Complexity
Tracking** below with the amendment that carries them:

1. "This is a macOS tool; CI runs on macOS only" — replaced by FR-033, not
   contradicted in silence.
2. "`app/` is the one exception, and it is one-way" — becomes two exceptions,
   each one-way, with the one-way property asserted rather than asserted-to.

**Gate result: pass.** No unjustified violation; nothing here is a trade-off
taken quietly.

## Project Structure

### Documentation (this feature)

```text
specs/006-windows-tray-overlay/
├── plan.md              # This file (/speckit-plan command output)
├── research.md          # Phase 0 output — D1-D24, and what is still unverified
├── data-model.md        # Phase 1 output — 12 entities and their relationships
├── quickstart.md        # Phase 1 output — the validation run, per user story
├── contracts/           # Phase 1 output
│   ├── probe-layer.md   #   the seam inside bin/ccwatch
│   ├── bar-document.md  #   one CLI, three renderers
│   └── tray-app.md      #   the Windows app's own contract
├── checklists/          # /speckit-checklist output (already present)
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
bin/ccwatch                     the whole CLI. Gains one banner section:
                                # ===================== platform ====
                                #  platform_detect / probe_report / probe_note
                                #  probe_proc / probe_mtimes / probe_clock
                                #  probe_host
                                #  probe_native_path / probe_posix_path
                                placed *before* collection, because the
                                collectors call it. The only section permitted
                                to invoke ps, stat, date -r/-d, vm_stat,
                                sysctl, PowerShell, cygpath or uname.
                                Rewritten call sites: :168 (liveness), :1856
                                (transcript mtimes), :1191 (Eastern clock),
                                :2329/:2340/:2348 (host pressure), and
                                cmd_doctor's pressure branch at :5046, which
                                today does arithmetic on a value that can be
                                the string `null`.

app-win/                        NEW — the Windows surface, one-way like app/
├── Sources/Program.cs          locator, bar parser, tray, overlay, serve
│                               supervisor, selftest
├── ccwatch-tray.csproj         net8.0-windows, WinForms, WebView2
├── build.ps1                   build / -Run / -SelfTest / -Install /
│                               -SelfContained; records the checkout it was
│                               built from, because a GUI process does not
│                               inherit the shell's PATH
└── README.md                   requirements, what is unavailable on Windows

app/                            macOS menu bar app — unchanged (FR-035)
extra/swiftbar/                 macOS fallback plugin — unchanged, no Windows
                                counterpart
web/                            untouched apart from FR-033's documentation;
                                the overlay hosts /map exactly as served

tests/run.sh                    the only test entry point. Gains: probe
                                selection per platform, the three outcomes,
                                the empty-answer cross-check, unavailable vs
                                zero, doctor's probe report, the bar-parsing
                                rules, and the app-win skip with its reason.
                                TALLY_FLOOR raised.

.github/workflows/ci.yml        macos-latest unchanged and still owns lint;
                                windows-latest added, printing which platform
                                it tested and which implementation each probe
                                selected

CLAUDE.md
README.md                       amended together with the constitution
.specify/memory/constitution.md (FR-033) — supported platforms, the probe per
                                platform, what is unavailable on each, and the
                                failure that motivated the seam
```

**Structure Decision**: the existing shape is kept and extended rather than
reorganised. One bash script stays the whole CLI with the probe seam as an
internal section — not a sourced library, because `bin/ccwatch` being a single
file with no build step is a constitutional constraint and `serve` resolves
`web/` from the script's own resolved path. The Windows GUI goes in a new
top-level `app-win/` parallel to `app/` rather than inside it, so that each
platform's toolchain, build script and selftest stay separable and the suite can
skip either one independently with the reason.

## Complexity Tracking

> **Fill ONLY if Constitution Check has violations that must be justified**

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| The constitution's "This is a macOS tool; CI runs on macOS only" no longer holds | The feature's whole subject is a second platform. Leaving the constraint in place would leave the governing document contradicting the shipped behaviour, which is the one state a constitution cannot be in | Shipping Windows support without amending it — rejected because a contradicted invariant stops being read as an invariant. FR-033 makes the amendment part of the deliverable, and the commit names the failure that motivated it |
| A second exception to "no build step", so `app/` is no longer "the one exception" | The overlay is half the feature and it must be the *same* renderer as the page (FR-023); hosting WebView2 from a script is not supportable, so a buildless PowerShell tray would need a different overlay or none | A buildless PowerShell + WinForms script (loses the overlay); Electron/Tauri (a package manager, a runtime and a second HTML renderer beside the one already here); C++/Win32 (same four window properties, everything else harder). The exception is bounded the same way `app/`'s is: one-way, skipped with the reason when unbuilt, and asserted by FR-028 rather than promised |
| The overlay cannot claim macOS's `.statusBar` guarantee | Windows has no public equivalent, so an exclusive-fullscreen Direct3D application can cover the overlay. The story the spec asks for — a maximised or borderless-fullscreen window — is covered by `TopMost` plus a re-asserted `HWND_TOPMOST` | `SetWindowBand(ZBID_UIACCESS)` and the unpublished virtual-desktop pinning COM interfaces — rejected because their GUIDs change between Windows builds and they fail **silently** when they do, which is the exact failure shape the macOS selftest was written to catch. The limitation is documented and neither `doctor` nor the menu claims otherwise |
| `web/modal.js`'s disabled-send wording is true but incomplete on Windows | "this server was started --read-only — sending is disabled" is accurate there but does not say *why*. Making it say why means changing a page module, and "no change to the pages" is this feature's stated scope | Widening scope to touch `web/` — rejected here, but the imprecision is named in research D23 so it is a recorded decision rather than an oversight, and every CLI surface (terminal, `bar`, tray menu, `doctor`, the `serve` banner) does state the real reason |

## Post-Design Constitution Re-check

Re-run after Phase 1 produced `data-model.md`, the three contracts and
`quickstart.md`. Nothing in the design introduced a new violation, and three
things the design **added** to satisfy the gates are worth naming, because each
closes a hole the first pass through the principles did not see:

- **The FR-001 grep can lie to itself.** Asserting "no `ps` outside the seam" by
  grepping the file matches the comment that explains the guard — this
  repository has already shipped a `grep -c 'calc(100vh -'` that was satisfied by
  its own explanatory comment. The contract requires the assertion to exclude
  comment lines and to be mutation-checked against a real inline call.
- **`ERROR_ACCESS_DENIED` is a third answer, not a "no".** A session running as
  another user or under a policy would otherwise leave the fleet one row at a
  time, silently — a failure wearing an absence's clothes, which is IV in the
  place it is hardest to see. D12 makes it a counted failure to measure.
- **`doctor`'s pressure branch is already broken for `null`.** `[ "${swp:-0}"
  -ge … ]` on the string `null` prints a bash error instead of a verdict, so the
  honest Windows value would have surfaced as a crash. FR-012 requires it to
  state which figure is unavailable; the branch is rewritten as part of this
  work rather than left for a pagefile-less host to discover.

Six claims remain **unverified on this host** (a macOS development machine with
no Windows available) and each names the observation that settles it, in
`research.md`'s closing table: `/proc/self/winpid`'s existence, whether that
bash's `date` honours `TZ=America/New_York`, the two probe costs, which suite
sections run on the hosted Windows image, and whether `WS_EX_NOACTIVATE` keeps
focus out of the WebView2 child on click — the one property a selftest cannot
prove, so it is a step in the manual pass. None of them blocks task generation;
all of them are measurements to take during implementation, and none may be
recorded as a result until it has been taken.

**Gate result: pass.**
