# Phase 0 research — Windows support for the taskbar tray and the overlay

Every decision below is recorded with what was rejected, because the rejections
are the part a later reader cannot reconstruct. Where a claim could not be
measured on this host (a macOS development machine with no Windows available),
it says so and names the observation that will settle it — an unverified claim
presented as a measurement is the failure this repository keeps paying for.

Read with `spec.md`. Requirement ids are that document's.

---

## The shell and the interpreters

### D1 — The host shell is Git for Windows / MSYS2 bash, and WSL is excluded by a test

**Decision**: `bin/ccwatch` runs under the MSYS2-class bash that Git for Windows
installs (`MINGW64_NT-*` / `MSYS_NT-*` from `uname -s`). Anything running under
WSL is treated as Linux, which this feature declares unsupported (D3).

**Rationale**: the spec's assumption already argues this from measurement — a
WSL shell cannot see Windows process ids, so liveness and CPU seconds, the
corroborating signal behind every verdict (principle I) and the *only* signal an
`sdk-ts` session has, would be unobtainable for the sessions the operator
actually runs.

What is new here is that the exclusion must be **enforced, not documented**. A
machine with WSL installed has `C:\Windows\System32\bash.exe` on `PATH`, ahead
of Git's bash on many machines, and it is a launcher into a Linux userspace. A
tray app that resolves "bash" from `PATH` would run the CLI in the one
environment where its central probe cannot work, and the result would look like
a working install reporting a quiet machine. So the Windows app's interpreter
search (D18) excludes `System32\bash.exe` by path *and* verifies the candidate
by running `uname -s` and requiring `MINGW`/`MSYS`.

**Alternatives rejected**: WSL as the supported environment (cannot see the
pids, as above); a Windows-native rewrite of the CLI (a second place computing
status — principle XI — and it contradicts "no build step for the CLI"); Cygwin
(works, but it is not what Claude Code users on Windows already have, and adding
it as a supported variant doubles the matrix for no measured gain; `uname -s`
reports `CYGWIN_NT-*`, so the detection in D2 accepts it and the probes are the
same, but nothing here is verified against it and `doctor` says so).

### D2 — Platform detection happens once, from `uname -s`, with an override

**Decision**: one detection per run into `CCWATCH_PLATFORM`, valued `macos`,
`windows` or `unsupported`:

| `uname -s` | Platform |
|---|---|
| `Darwin` | `macos` |
| `MINGW*`, `MSYS*`, `CYGWIN*` | `windows` |
| anything else (including `Linux`) | `unsupported` |

An environment variable of the same name **overrides** the detection. That is
not a convenience: it is what lets the hermetic suite assert *probe selection*
for both platforms from either platform (FR-029), which is otherwise a property
only a two-machine CI run can see.

**Rationale**: `uname` is present in every shell this runs in, costs one fork
per run, and is the only probe that cannot itself be platform-dependent. Doing
the detection once and passing the answer down also means `doctor` reports the
same selection the snapshot used, rather than re-deriving it and possibly
disagreeing (principle XI applied inside the script).

**Alternatives rejected**: `$OSTYPE` (set by bash, and `msys` there does not
distinguish the Cygwin build); probing for each program's existence instead of
detecting the platform (`command -v stat` is true on both and answers nothing —
what differs is the *flag*, and a probe that discovers that by trying `stat -f`
and parsing the error is a guess dressed as a detection); detecting per probe
call (the same fork cost repeated 20+ times a snapshot, on the path that has a
2s repaint budget).

### D3 — An unsupported platform is stated, not approximated

**Decision**: on `unsupported`, every probe returns *failure to measure* with
the reason "no implementation for this platform (uname: …)", `doctor` reports it
as a problem, and the tool keeps running and says what it could not measure.
Linux gets no implementation in this feature.

**Rationale**: this is strictly better than today. On Linux right now `stat -f`
means "file system status" and prints nothing usable, and `date -r` means
"reference file" and prints the wrong instant — so the transcript listing and
the reset clock are already silently wrong there, and nothing says so. Naming
the absence converts two silent wrong answers into a stated one (principle IV).
Adding a Linux implementation would widen the feature past the two surfaces it
is named for, and Linux has neither of them built.

**Alternatives rejected**: falling back to the macOS implementations on unknown
platforms (that is the current silent-wrong-answer behaviour, promoted to a
decision); falling back to "GNU-ish" implementations (a guess about a platform
nobody ran a test on, and the Windows implementations are not portable to it —
D12's process probe is Win32-specific).

### D4 — The python interpreter is resolved, not assumed to be `python3`

**Decision**: one resolution per run into `CCWATCH_PY`, trying `python3`, then
`python` (accepted only if `sys.version_info.major == 3`), then `py -3`. Every
one of the 16 `python3` call sites in `bin/ccwatch` goes through it. Absence is
a *failure to measure* naming what is lost, not a crash and not a zero.

**Rationale**: Git for Windows ships no python at all, and the two normal ways
to get one on Windows disagree about the name — a python.org install provides
`python.exe` and a `py` launcher and (recent installers) no `python3.exe`; the
Microsoft Store install provides `python3.exe`. `python3` is therefore not a
name that can be assumed on the platform. This is not speculative: the project's
own spec-kit scaffold already ships exactly this fallback
(`.specify/scripts/bash/common.sh:400-413`), which is evidence the problem is
real in this repository's own tooling.

The constitution's "Programs are passed with `python3 -c`, never on stdin"
survives unchanged — what changes is the *name*, not the invocation style, and
the "never on stdin" rule is what keeps `-c` mandatory.

**Alternatives rejected**: requiring the operator to create a `python3` shim
(an install step the documentation would have to name, and FR-013 forbids
requiring runtimes beyond the ones already named — but it does not forbid
finding the one that is there under a different name); using `py -3` first (it
is a Windows-only launcher, so the macOS path would branch anyway and the
resolution loop is the same code).

### D5 — Paths are translated at the bash→native-python boundary, with `cygpath`

**Decision**: on Windows, every filesystem path that crosses from bash into a
native-Windows program — the python probes, `serve`'s `CCWATCH_SELF` and
`CCWATCH_WEB`, transcript paths handed to `convo`, the path the tray app is
given — is converted with `cygpath -w` at the seam. The reverse conversion
(`cygpath -u`) is applied to paths that arrive *from* Windows programs. On macOS
both are the identity function.

**Rationale**: this is the failure that would otherwise look like a corrupt
install. Inside MSYS bash, `$HOME/.claude` is `/c/Users/Jane/.claude`; a
python.org interpreter is a native Windows program and cannot open that path at
all. `serve` passes `CCWATCH_SELF="$root/bin/ccwatch"` into python, which then
runs `subprocess.run([SELF] + args)` (`bin/ccwatch:3397`) — on Windows that
fails twice over: the path form, and the fact that CPython cannot execute a
`#!/usr/bin/env bash` script at all (D6). `cygpath` ships with Git for Windows
and MSYS2, so this adds no dependency.

A Windows path also works when the interpreter happens to be an MSYS/Cygwin
python, which accepts both forms — so translating unconditionally on Windows is
correct for both interpreters and needs no second mode.

**Alternatives rejected**: requiring an MSYS2 python (accepts POSIX paths, needs
no translation — but it is a package-manager install, which FR-013 rules out,
and it is slower and less likely to be what the operator already has); passing
paths on stdin to avoid quoting (the constitution forbids stdin for these
programs, and the payload collision it forbids is exactly what would happen);
`sed`-ing `/c/` to `C:/` by hand (`cygpath` exists precisely because that
transformation has more cases than it looks — `/tmp`, `/usr`, UNC paths).

### D6 — `serve` invokes the CLI through an explicit interpreter

**Decision**: the server's `SELF` becomes an argv *list* — `[SELF]` on macOS,
`[BASH, SELF]` on Windows, where `BASH` is the interpreter resolved in D1/D18
and passed in the environment beside `CCWATCH_SELF`. All four `subprocess.run`
call sites (`:3397`, `:3584`, `:3608`, `:3641`) use it.

**Rationale**: CPython on Windows does not honour a shebang line, so
`subprocess.run(["/c/…/bin/ccwatch", "--json"])` raises `WinError 193` (not a
valid Win32 application) — and `/api/state` would then return the same "snapshot
failed" shape forever, on a machine where the CLI works perfectly in the
terminal. Principle XI requires `/api/state` to invoke the CLI; this is what
invoking it costs on Windows.

**Alternatives rejected**: `shell=True` (quoting a path with spaces through
`cmd.exe` is the classic injection surface, and a session name never reaches
these argv lists but a *path* does); a `ccwatch.cmd` wrapper (works, but then
the server is invoking a wrapper whose own resolution rules are a second place
to get the interpreter wrong).

---

## The probe seam

### D7 — One named function per measurement, returning a normalised shape

**Decision**: a new `platform` section in `bin/ccwatch`, placed before
`collection` because the collectors call it, exposing exactly six probes:

| Probe | Answers | Normalised shape |
|---|---|---|
| `probe_proc` | process facts for a pid list | JSON array of `{pid, start, cpu, rss_mb?}` |
| `probe_mtimes` | transcript mtimes, newest first | `<epoch> <path>` lines, `sort -rn` applied |
| `probe_clock` | an epoch as an Eastern wall clock | `3:45 PM EDT`, or empty |
| `probe_host` | host memory pressure | JSON object, or `null` |
| `probe_native_path` / `probe_posix_path` | path form across the seam | one path |

After the extraction there is no `ps`, `stat -f`, `date -r`, `vm_stat` or
`sysctl` anywhere else in the file (FR-001), which is greppable and therefore
assertable.

**Rationale**: the shape is what the callers depend on, and it is the only thing
they should depend on. `probe_proc` returning the *parsed JSON* rather than
`ps`-shaped text is the important part: the macOS implementation keeps the
existing `ps | python3` pipeline verbatim (FR-005), while the Windows one
produces the same records from a completely different source (D12), and
`collect_live` cannot tell which it got.

**Alternatives rejected**: a seam at the *program* level (`ps_out`,
`stat_out`, …) with the parsing left outside — the parsing is where the platform
difference actually lives (BSD `lstart` local-time strings versus a Win32
FILETIME), so a seam above it would leave a second platform branch in every
caller; a single `probe <name> <args...>` dispatcher (one function with a
`case`, so `shellcheck` cannot see unused branches and a typo in a probe name
becomes a silent no-op rather than "command not found").

### D8 — Three outcomes, carried by exit status and a run-scoped report file

**Decision**:

| Outcome | Probe does | Caller sees |
|---|---|---|
| measurement | prints the payload, exits 0 | the payload |
| measured absence | prints the empty payload (`[]`, `null`, no lines), exits 0, records `absent` with the reason | an honest empty |
| failure to measure | prints **nothing**, exits non-zero, records `failed` with the reason | nothing — `require_json` names the stage |

Notes are appended as TSV to a run-scoped report file, created lazily with
`mktemp "${TMPDIR:-/tmp}/ccwatch-probes.XXXXXX"` and removed by the existing
`cleanup` trap.

**Rationale**: a file, not a shell variable, because a global assigned inside
`$(...)` never survives the subshell back to the caller — this repository has
already paid for that once (the `parse_failed` count, research D6 of feature
001, which is why that count travels inside the returned JSON object). Probes
are called from command substitutions everywhere, so the same trap applies to
every note they would like to leave.

`mktemp` **with a template**, because a bare `mktemp` resolves against
`confstr(_CS_DARWIN_USER_TEMP_DIR)` rather than `$TMPDIR` and a sandbox that
grants one and not the other makes the command print nothing at all — 13
assertions in this suite once failed that way and were read as a regression in
the tool. (Observed again while planning this feature: a bare `mktemp` in the
spec-kit scaffold failed in this very environment with `Operation not
permitted`.)

Printing nothing on failure is what makes the existing `require_json` machinery
do the work already: it names the stage that produced no usable JSON, which is
the sentence the operator needs.

**Alternatives rejected**: a sentinel payload such as `{"error": …}` (every
caller would need to learn to distinguish it, and one that forgot would render
an error object as data); exit-status-only with no reason (FR-003 requires the
reason, and "the process probe failed" without "access denied on pid 4212" is
the absence-shaped failure this feature exists to remove).

### D9 — Every probe whose empty answer is ambiguous cross-checks it

**Decision**: the guard at `bin/ccwatch:336-350` generalises. Each probe whose
empty answer could be read as an empty machine names a *control query* that
cannot legitimately come back empty:

| Probe | Control query | If the control fails |
|---|---|---|
| `probe_proc` (macOS) | `ps -o pid= -p $$` | say nothing |
| `probe_proc` (Windows) | the same query for **our own Windows pid** (D11) | say nothing |
| `probe_mtimes` | `stat` of `$PROJ_DIR` itself, which exists whenever the directory does | say nothing |
| `probe_host` | the probe's own first field | report the field as unavailable, not zero |
| `probe_clock` | two fixed instants with known answers (D14) | withhold the clock |

**Rationale**: this is the measured failure the whole feature is shaped around —
`ps` refused, 18 sessions live, 0 reported. A naive port reproduces it once per
probe, and the two cases that matter most are the two where the empty answer is
*plausible*: no transcripts (a fresh install) and no live sessions (a quiet
machine).

**Alternatives rejected**: cross-checking only liveness, as today (the other
probes have the same shape of failure; the transcript listing going silently
empty turns every session's silence measurement into "unknown" without saying
so); trusting an exit status alone (`ps -p` exits non-zero when none of the pids
exist, which is the ordinary state after a reboot — the exit status does not
distinguish "refused" from "nothing matched", which is the entire problem).

### D10 — `CCWATCH_FAKE_PS` stays the one seam, and keeps its current format

**Decision**: when `CCWATCH_FAKE_PS` is set, `probe_proc` parses the fixture
with the **BSD `ps` text parser on both platforms** and the cross-check in D9 is
skipped, exactly as today.

**Rationale**: FR-006 requires the seam to survive, and FR-005 requires the
existing assertions to pass unchanged — so the fixture format cannot change.
Keeping one fixture format also keeps one parser under test from both
platforms' assertions, which is worth more than a second Windows-shaped fixture
format would be: what a Windows fixture would exercise is the *parser*, and the
parser is not what differs — the *source* is (D12).

The Windows-native path is therefore exercised by (a) assertions that query the
shell's own real process, which is the one process a hermetic test may look at
because it is the test itself, and (b) the selection and outcome assertions,
which run on both platforms via the `CCWATCH_PLATFORM` override (D2).

**Alternatives rejected**: a second `CCWATCH_FAKE_PROC` carrying native-shaped
records (two seams, and the one that is not the default rots — this repository
already has a fixture that could not fail and counted as coverage); making the
fixture format the normalised JSON (breaks every existing fixture, which FR-005
forbids).

---

## The Windows implementations

### D11 — `$$` is not the process id the registry means

**Decision**: on Windows, "our own pid" for the D9 control query is read from
`/proc/self/winpid` (MSYS2 exposes it), never from `$$`.

**Rationale**: MSYS bash's `$$` is an MSYS pid — an id in the emulation layer's
own namespace, unrelated to the Windows pid that `OpenProcess` takes. A control
query built on `$$` would fail *always* on Windows, and by D9's rule the probe
would then say nothing on every run: the tool would report no sessions on a busy
machine, which is the exact failure this feature exists to prevent, arriving by
way of the guard meant to prevent it.

Claude Code writes a **Windows** pid into the registry (it is a native node
process), so no translation is needed for the pids under test — only for ours.

**Unverified**: that `/proc/self/winpid` is present in Git for Windows'
environment (it is documented for MSYS2 and Cygwin). Settled by the CI job in
D22, which prints it; if it is absent, the fallback is a single-line query
through the process probe itself for the pid of the current process tree, and
the probe reports `refused` rather than guessing.

### D12 — Process facts come from Win32 via python `ctypes`, in one process

**Decision**: `probe_proc` on Windows is a single `$CCWATCH_PY -c` program that,
for each requested pid, calls `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`,
then `GetProcessTimes` (creation time as a FILETIME, plus kernel and user times)
and `GetProcessMemoryInfo` (working set), and prints the normalised records.

- `start` = creation FILETIME converted to a **UTC epoch second**
- `cpu` = (kernel + user) / 10⁷ seconds
- `rss_mb` = working set / 1048576, rounded

Distinguished outcomes, per pid: opened → running; `ERROR_INVALID_PARAMETER`
(87) → not running (a measured absence for that pid); `ERROR_ACCESS_DENIED` (5)
→ **failure to measure that pid**, recorded with its reason and counted, never
silently dropped.

**Rationale**: it is one process, and the snapshot has a 2s repaint budget that
a per-pid PowerShell spawn would blow on its own (the first version of
`collect_live` cost ~1.7s of fork overhead on 19 sessions and had to be
rewritten into exactly one python process — the same constraint applies here,
and python is *already* the process that parses the answer). It yields all four
facts `bin/ccwatch:168` gathers, at full precision, and the creation time is UTC
by construction, which removes the local-time/UTC trap the macOS path has to
work around (FR-008 becomes structural rather than careful). `PROCESS_QUERY_
LIMITED_INFORMATION` succeeds for the operator's own processes without
elevation, which is what Claude Code sessions are.

The access-denied case is the one that must not be folded into "not running": a
session running as another user, or under a policy, would otherwise disappear
from the fleet silently — a failure wearing an absence's clothes, one row at a
time.

**Alternatives rejected**:
- `tasklist` — no start time and no CPU time at all. Insufficient, not merely
  awkward.
- `wmic process` — removed from Windows 11 24H2 and deprecated before that. A
  probe that vanishes on an OS update is a probe that fails in the field.
- PowerShell `Get-CimInstance Win32_Process` / `Get-Process` — has every field,
  but costs a ~200-600ms interpreter start *per snapshot*, and the snapshot runs
  every 2s behind the map. Kept as the documented fallback if `ctypes` is
  unavailable, reported by `doctor` when selected.
- Parsing MSYS `ps -W` — its columns are the emulation layer's, it reports no
  CPU time, and it is the "minimal MSYS ps" the spec's table already dismisses.

**Unverified**: the measured cost of the `ctypes` program against a realistic
pid count. The implementation records it with `CCWATCH_PROFILE=1`.

### D13 — Transcript mtimes: GNU `stat -c`, with the BSD form untouched

**Decision**: `probe_mtimes` keeps `find … -print0 | xargs -0 stat -f '%m %N'`
on macOS and uses `find … -print0 | xargs -0 stat -c '%Y %n'` on Windows, with
`sort -rn` where it already is.

**Rationale**: `-print0`/`-0` already handles spaces, which is what
`C:\Users\Jane Doe\.claude` needs, and MSYS paths are POSIX-form so a drive
letter is just a leading `/c`. Git for Windows ships GNU coreutils' `stat`, so
`-c '%Y %n'` is available with no new dependency, and the output shape is
identical to the BSD form's — one epoch, one path, space-separated.

**Alternatives rejected**: `find -printf '%T@ %p\n'` (GNU-only, so macOS needs
the `stat` form anyway — two implementations either way, and this one adds a
*third* output format with a fractional epoch); doing the whole listing in
python (one implementation for both platforms, but FR-005 requires macOS to run
the same programs with the same arguments as today, and rewriting the listing
would put the most-traversed path in the tool at risk for a cosmetic win).

### D14 — The Eastern clock is selected by validating candidates against known instants

**Decision**: `probe_clock` picks its implementation by **testing it**, once per
run, against two fixed instants whose answers are known and hard-coded — one in
EDT, one in EST. Candidates, in order:

1. GNU `date`: `TZ=America/New_York date -d "@<epoch>" '+%I:%M %p %Z'`
2. PowerShell: `TimeZoneInfo.ConvertTimeFromUtc` with the Windows zone id
   `Eastern Standard Time`, with the abbreviation chosen from
   `IsDaylightSavingTime`
3. none — the clock is **withheld** and `doctor` says why

**Rationale**: this is the one probe whose wrong answer is both plausible and
expensive: an hour out for half the year, on a number whose entire purpose is to
go in somebody's calendar. `reset_clock` already returns empty for an input it
cannot use, so withholding is a path that exists.

The validation is not ceremony. Whether MSYS bash's GNU `date` honours
`TZ=America/New_York` depends on a zoneinfo database being present, and Git for
Windows' inclusion of one is exactly the kind of thing that differs between
installs and versions — **this could not be verified from this host**. A probe
that is asked "what is 14:00 UTC on 2026-09-15 in Eastern?" and answers
"10:00 AM EDT" has demonstrated its zone data; one that answers "2:00 PM UTC"
has demonstrated the opposite, and the difference is invisible in production
output. Validating against a DST instant *and* a standard-time instant catches
the half-year case that a single probe date cannot.

The existing assertion that the CLI and `web/usage.js` agree on both sides of a
DST boundary stays as it is and becomes the Windows check too (FR-010, SC-006).

**Alternatives rejected**: `jq`'s `strflocaltime` (measured wrong on this
project already — EST for an instant in September, an hour out, which is why the
`⚠️` comments at `bin/ccwatch:1179` and `:1507` exist); python `zoneinfo`
(CPython on Windows ships **no** tz database and needs the `tzdata` package — a
new runtime dependency FR-013 forbids, and an `ImportError` at the worst moment);
hand-rolling the US DST rule (second Sunday in March, first Sunday in November)
— it is arithmetic anyone can audit, but it is a rule this tool would then own
forever and be silently wrong about the year it changes, which is principle VI's
"say nothing rather than guess" pointed directly at a number in a calendar.

### D15 — Host pressure: free RAM and the pagefile, and no load average at all

**Decision**: `probe_host` on Windows reports

```json
{ "ram_free_mb": 5312, "swap_total_mb": 16384, "swap_used_mb": 2048,
  "swap_used_pct": 13, "load1": null }
```

from a single PowerShell invocation querying `Win32_OperatingSystem`
(`FreePhysicalMemory`) and `Win32_PageFileUsage` (`AllocatedBaseSize`,
`CurrentUsage`). Absent figures are **omitted or null with a recorded reason**,
never zero:

- pagefile disabled → no `Win32_PageFileUsage` instances → `swap_total_mb`,
  `swap_used_mb`, `swap_used_pct` are `null`, reason "this host has no pagefile"
- `compressed_mb` is macOS-only and is simply absent on Windows
- `load1` is `null` with the reason "Windows has no load average"

**Rationale**: FR-011 forbids substituting a different measurement for one that
could not be taken, and the two temptations here are both substitutions.
`GlobalMemoryStatusEx`'s `ullTotalPageFile` is the **commit limit**, not the
pagefile's size, and reporting commit charge as "pagefile used %" would put a
number that is routinely 40% on a machine with no pagefile at all. The processor
queue length is not a load average and presenting it as one would be a status
ccwatch did not read (principle V).

`null` rather than `0` is the shape that already went red on CI once for macOS
swap and is asserted field-by-field in the suite for that reason
(`tests/run.sh:3206-3235`) — the same assertion shape covers Windows.

**Consequence to fix**: `cmd_doctor` currently does
`[ "${swp:-0}" -ge "$CCWATCH_SWAP_WARN" ]` on a value that can be the string
`null` (`bin/ccwatch:5046`), which under `set -u`-adjacent arithmetic prints a
bash error rather than a verdict. FR-012 requires it to state *which* figure is
unavailable when the judgement cannot be made, so this branch is rewritten
rather than left to be discovered on a pagefile-less host.

**Unverified**: the cost of the PowerShell invocation. `collect_host` runs on
every snapshot and the map refreshes every 2s. The implementation measures it
with `CCWATCH_PROFILE=1`; if it exceeds **250ms**, the Windows host probe is
cached for 30s under `$CCWATCH_HOME` *with its age*, and a reading past the
window is withheld rather than annotated (principle III). The threshold and the
fallback are decided here so the implementation does not have to invent a
policy under time pressure.

**Alternatives rejected**: `ctypes` `GlobalMemoryStatusEx` for everything (no
pagefile-file figures exist in that API, so the pagefile would have to be
substituted from commit — rejected above); `typeperf` (a sampling tool, seconds
of latency); reporting only free RAM and dropping the pagefile (the pagefile is
the figure that predicts a kill, which is why the probe exists at all).

### D16 — Windows programs' output is normalised at the seam

**Decision**: every Windows probe strips carriage returns from its own output
before returning it, and the registry/transcript readers tolerate `\r\n`.

**Rationale**: PowerShell and native Windows tools emit CRLF. A `\r` that
survives into a shell variable turns `idle` into `idle\r`, which reaches the
classification as an **unrecognised status value** — `doctor` would report it as
"ccwatch does not know how to classify these" and the reader would go looking
for a Claude Code format change that never happened. In a rendered row it is a
stray column-shifting character; in a `bar` line it is a broken menu item.

`jq` tolerates CRLF inside JSON whitespace, so the registry files themselves are
safe, but `read -r` over Windows-produced lines is not — the carriage return
lands in the last field.

**Alternatives rejected**: stripping at the consumers (one place per consumer,
and the next consumer added will not know to); `shopt -s igncr` (Cygwin-only,
not honoured by the MSYS bash Git for Windows ships, and a global switch for a
local problem).

### D17 — Windows `cwd` values are normalised to forward slashes at ingest

**Decision**: when the platform is Windows, `collect_sessions` normalises each
row's `cwd` from `C:\Users\Jane\code\proj` to `C:/Users/Jane/code/proj` before
the join sees it.

**Rationale**: found while reading the code for this plan, and it is a visible
defect rather than a refinement. The join derives a session's project name with
`(cwd // "?") | split("/") | last` (`bin/ccwatch:958`, and again at `:1978`), so
a backslash path yields *the whole path* as the project name — every row in the
`PROJECT` column would read `C:\Users\Jane\code\proj`, and the table User Story
1 promises would be unreadable at exactly the width that column has.

Forward slashes are accepted by `git -C`, by MSYS bash's own tests, and by
native Windows APIs, so one normalisation at ingest fixes the column, the
`resume` listing and the map's labels at once, with no second branch downstream.

**Alternatives rejected**: making the jq splitter separator-agnostic (four call
sites, and the fifth one added later will split on `/` again because that is
what every other path in the payload uses); normalising in the renderer only
(`--json` consumers and the pages would still see the raw form, so the same bug
would exist twice with one of them fixed).

---

## The tray and the overlay

### D18 — C# WinForms on .NET 8, WebView2 for the overlay, built with `dotnet publish`

**Decision**: a new top-level `app-win/` holding a single C# program
(`app-win/Sources/Program.cs`), a `.csproj`, and `app-win/build.ps1` with
`--selftest`, `--run` and `--install` flags mirroring `app/build.sh`. Tray =
`NotifyIcon` with a `ContextMenuStrip`; overlay = a borderless always-on-top
`Form` hosting `Microsoft.Web.WebView2.WinForms.WebView2` pointed at
`http://127.0.0.1:<port>/map`.

**Rationale**: it is the shortest path to the three things the surface must do —
a real tray item with a real menu, an owned always-on-top window, and an
embedded browser that is the *same* renderer as the page (FR-023) — and it
mirrors `app/`'s arrangement closely enough that the two can be read side by
side. `NotifyIcon` is the platform's tray API; WebView2 is the platform's
embedded browser and is already named in the spec's assumptions. The build is
one command and one-way: nothing in `bin/ccwatch` or `web/` may depend on it
(FR-028), and the suite skips its checks with the reason when it is not built.

**Alternatives rejected**:
- PowerShell + WinForms script, no build step at all — attractive (it would make
  the Windows surface buildless, which is *better* than macOS), but hosting
  WebView2 from a script is not supportable, so the overlay would have to be
  something else, and the overlay is half the feature.
- C++/Win32 directly — the four window properties are the same either way and
  everything else gets harder.
- WPF instead of WinForms — no tray primitive of its own, so it is WinForms'
  `NotifyIcon` plus a second UI framework.
- Electron/Tauri — a package manager, a runtime, and a second HTML renderer
  next to the one already in the repository.
- A single self-contained publish by default — `--self-contained` is offered by
  `build.ps1`, but the default is framework-dependent: whoever builds it has the
  SDK, which includes the runtime, and the default should not be a 70MB output.

### D19 — The app runs the CLI *through* a verified bash, and shows both paths

**Decision**: the locator resolves **two** things and verifies each by running
it:

1. a bash interpreter — candidates: a path recorded at build time, the
   `HKLM\SOFTWARE\GitForWindows\InstallPath` registry value,
   `%ProgramFiles%\Git\bin\bash.exe`, `C:\msys64\usr\bin\bash.exe`, then `PATH`
   — **excluding `%SystemRoot%\System32\bash.exe`**, and accepted only if
   `uname -s` reports `MINGW*`/`MSYS*`/`CYGWIN*`
2. the `ccwatch` script — candidates: a path recorded at build time, then the
   documented install locations — accepted only if
   `bash <script> --version` prints `ccwatch …`

Both resolved paths appear in the menu. A miss is stated as a miss with the list
of places searched, and the title becomes the `!` form — never an empty fleet
(FR-021).

**Rationale**: the macOS app's `CLILocator` exists because a GUI process
inherits a minimal environment and a plugin once reported `jq` missing on a
machine that plainly had it. Windows has that problem *and* a second one: the
thing being located is a script, so an interpreter has to be located too, and
the most likely interpreter on `PATH` is the one that must not be used (D1 —
`System32\bash.exe` is the WSL launcher, and running the CLI there means no
Windows pids and therefore a confidently empty fleet). "Verify by running" is
the project's existing rule for exactly this class of mistake, and `uname -s` is
the cheapest question that distinguishes the two bashes.

**Alternatives rejected**: `PATH` alone (the WSL trap, plus the GUI-environment
trap); a `ccwatch.cmd` shim as the only entry point (a second resolution path to
keep honest, and it hides which bash ran); requiring the operator to configure
the path (the menu offers an override, but a tool that *only* works after
configuration reads as broken on first launch).

### D20 — The overlay's four properties, and the one that cannot be fully had

**Decision**:

| Requirement | Mechanism | Asserted by the selftest |
|---|---|---|
| above other windows | `TopMost = true` and `WS_EX_TOPMOST`, re-asserted with `SetWindowPos(HWND_TOPMOST)` on show and on foreground change | both the property and the ex-style bit |
| on the current virtual desktop | `IVirtualDesktopManager.IsWindowOnCurrentVirtualDesktop`; when false, hide and re-show so the window materialises on the desktop in use | the interface is obtained and the reveal path runs |
| does not steal focus | `WS_EX_NOACTIVATE`, plus `WM_MOUSEACTIVATE` answered with `MA_NOACTIVATE`, plus `ShowWindow(SW_SHOWNOACTIVATE)` instead of `Show()` | all three, by name |
| not in the task bar or Alt-Tab | `ShowInTaskbar = false` and `WS_EX_TOOLWINDOW` | both |

**And the limitation, stated rather than papered over**: `TopMost` covers
maximised windows and borderless-fullscreen applications, which is the case the
spec's story is about (a maximised window over the overlay). It does **not**
reliably cover an exclusive-fullscreen Direct3D application — Windows has no
public equivalent of macOS's `.statusBar` window level. The documentation says
so, `doctor`/the menu do not claim otherwise, and the alternative (the
undocumented `SetWindowBand`, or the unpublished `IVirtualDesktopPinnedApps`
COM interface for real all-desktops pinning) is rejected: its GUIDs change
between Windows builds and it fails **silently** when they do, which is the
precise failure shape the macOS selftest was written to catch.

**Rationale**: every one of these fails invisibly. A window at the wrong z-order
looks perfect until something covers it; a focus thief is only discovered by the
keystroke that went to the wrong window. That is why FR-027 requires them
asserted by name and why the hide/re-show reveal is preferred to a COM interface
that cannot be asserted meaningfully.

**Alternatives rejected**: `SetWindowBand` with `ZBID_UIACCESS` (undocumented,
needs uiAccess and a signed manifest in a trusted location); pinning to all
virtual desktops via the unpublished COM interfaces (silent breakage per build,
as above); a `Form` with `TopMost` only (loses focus and taskbar behaviour,
which is three of the four properties).

### D21 — The tray renders the bar document and adds only verbs

**Decision**: the app parses `ccwatch bar --no-actions` with the same three
rules the macOS app uses — line 0 is the title, `---` opens and splits the menu,
and an item's text is separated from its parameters by the **first** ` | ` —
keeps any parameter it does not implement and shows the line as plain text, and
adds exactly the verbs in FR-022. A failed snapshot is the `cc ?` title with the
"this is NOT nothing is running" sentence, never a count.

**Rationale**: principle XI, and the macOS header's own argument — two
renderings that compute "is anything stuck" separately will eventually disagree
with no way to tell which is lying. Splitting on the first ` | ` is a security
property, not tidiness: `cmd_bar`'s `clean` filter replaces `|` with `¦` in
every interpolated field precisely so exactly one separator can appear per line,
and a parser that split on the last one would hand a session name the parameter
list back — including `bash=`, which in the SwiftBar vocabulary is a clickable
command. The Windows app implements no `bash=` at all, which makes that concrete
risk smaller, but the parse rule is a contract between three renderers and the
third one may not choose its own dialect.

Because the app's severity vocabulary is the CLI's words, high-contrast themes
and screen readers get the same verdicts as colour does (FR-020, principle VII):
the glyph and the colour are additions to a reading that survives without either.

**Alternatives rejected**: a JSON mode for the tray (explicitly out of scope,
and it is the second-place-computing-status mistake); dropping unhandled
parameter lines (a future CLI item would vanish from the menu unnoticed, which
is failure-as-absence); a submenu for the fleet (the macOS bar's comment
explains why nothing is collapsed: a submenu is a badge, and it turns a crashed
phase into something you have to hover to discover).

### D22 — CI grows a Windows job that says which probes it ran

**Decision**: `ci.yml` keeps its macOS job unchanged and gains a
`windows-latest` job running the same `tests/run.sh` under the runner's Git
Bash, plus a step that prints the probe report (`ccwatch doctor`'s platform
section) and the suite's own per-probe "exercised" lines. Neither job's skips
may be broad enough to hide whether a platform's probes ran at all (FR-031,
FR-032, SC-011).

**Rationale**: "green and broken are indistinguishable until you have seen it go
red on purpose" is this repository's most expensive lesson, and a Windows
implementation no job runs is the clearest possible case. The *record* is the
second half: a skip is quiet by design, so a job that skipped every Windows
probe would look exactly like one that exercised them. Printing which
implementation each probe selected, per job, makes that visible in the run log.

Lint stays on the macOS job — one linter, one version, one verdict.

**Unverified**: which sections pass on the hosted Windows image. `jq` is
present; `python3` may resolve via D4's fallback; `curl` is present;
`shellcheck` may not be, and skipping it there is correct because the macOS job
owns lint. The first run's skip list is read, and any skip that hides a probe is
converted into a check or a stated reason (FR-031) before this feature is done.

### D23 — Write actions are refused by name on Windows

**Decision**: `ccwatch send`, `ccwatch kill` and `ccwatch peers` on Windows exit
with a named refusal — "not available on Windows: this needs POSIX signals and
the per-session Unix socket" — and the tray app offers no verb for them.
`ccwatch serve` on Windows serves read-only: no token is generated, the write
endpoints refuse, and the startup banner and `doctor` both say why.

**Rationale**: out of scope is not the same as hidden. Principle IV's last
sentence is explicit — a capability disabled by configuration is shown as
disabled with the reason, never hidden, because hiding it reads as "not built".

**Known imprecision, recorded rather than absorbed**: the page's own wording for
a disabled send comes from `web/modal.js:185` — "this server was started
--read-only — sending is disabled". On Windows that sentence is true (the server
*is* read-only) but it does not say *why*, and making it say why means changing
a page module, which this feature puts out of scope. The CLI's surfaces — the
terminal, `bar`, the tray menu, `doctor`, the `serve` banner — all state the
real reason. The precise page wording is left for a follow-up entry, and named
here so it is a decision rather than an oversight.

### D24 — `ccwatch setup` on Windows installs a verified shim, not a copy

**Decision**: `setup` on Windows attempts `ln -s` first, **checks whether the
result is actually a symlink**, and if it is not, replaces it with a two-line
shim that `exec`s the checkout's script. Either way it then runs the installed
thing and compares the version, and refuses with the reason if that fails.

**Rationale**: `ln -s` in MSYS bash silently *copies* unless
`MSYS=winsymlinks:nativestrict` is set and the user has Developer Mode or
elevation — and a copy is the one outcome the macOS path explicitly refuses,
for two reasons that both still apply on Windows: `git pull` stops upgrading it,
and `serve` finds `web/` relative to the script's own resolved path, so a lone
copy in a bin directory cannot find the pages at all. A shim that `exec`s the
real path keeps both properties, because after the `exec` `BASH_SOURCE[0]` is
the real script and `resolved_self` is correct.

Checking the result rather than the mechanism is the point: "a symlink that
exists proves nothing" is already the rule for the verification step, and on
this platform it does not even prove it is a symlink.

**Alternatives rejected**: always a shim (loses the symlink on machines where it
works, and the symlink is what the README documents); setting
`MSYS=winsymlinks:nativestrict` for the operator (it changes behaviour for
every other tool in their shell); a `.cmd` wrapper as the primary install (it
only helps callers from `cmd.exe`/PowerShell, which is not where `ccwatch` is
used — `build.ps1` may emit one for the tray app's own use).

---

## What remains unverified, and how it gets settled

None of these block Phase 1; each names its observation.

| # | Claim | Settled by |
|---|---|---|
| U1 | `/proc/self/winpid` exists in Git for Windows' bash | D22's job prints it; fallback in D11 |
| U2 | GNU `date` in that bash honours `TZ=America/New_York` | D14's validated selection decides at run time, per host |
| U3 | The `ctypes` process probe's cost at realistic pid counts | `CCWATCH_PROFILE=1` during implementation; PowerShell fallback is D12's |
| U4 | The PowerShell host probe's cost | as above; the 250ms threshold and the 30s cache are decided in D15 |
| U5 | Which suite sections can run on the hosted Windows image | the first CI run's skip list, read and converted per FR-031 |
| U6 | Whether `WS_EX_NOACTIVATE` on the host keeps focus out of the WebView2 child on click | the manual pass in `quickstart.md`; it is the one property a selftest cannot prove |
