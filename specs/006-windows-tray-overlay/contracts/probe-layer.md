# Contract — the platform probe layer in `bin/ccwatch`

The interface the rest of the tool depends on instead of depending on a program
name (FR-001–FR-014). This is an internal contract between sections of one
script, and it is written down because the whole point of the extraction is that
callers stop knowing what platform they are on.

Decisions referenced as `D<n>` are in [../research.md](../research.md).

---

## Where it lives

A new `platform` banner section in `bin/ccwatch`, **before** `collection`,
because the collectors call it. It is the only section permitted to invoke
`ps`, `stat -f`/`stat -c`, `date -r`/`date -d`, `vm_stat`, `sysctl`, PowerShell,
`cygpath` or `uname`.

```
# ============================================================== platform ====
#  platform_detect / probe_report / probe_note
#  probe_proc / probe_mtimes / probe_clock / probe_host
#  probe_native_path / probe_posix_path
# ============================================================== collection ==
```

FR-001 is asserted by grepping the rest of the file for those program names. The
assertion excludes comment lines — and the guard must be written so that the
comment *explaining the guard* does not satisfy it, which has happened here
before (`grep -c 'calc(100vh -'` matching its own explanatory comment).

---

## Selection

```
platform_detect          # sets CCWATCH_PLATFORM, CCWATCH_UNAME, CCWATCH_PY,
                         # and CCWATCH_BASH on Windows. Idempotent; called once
                         # from the top of the script.
```

| `uname -s` | `CCWATCH_PLATFORM` |
|---|---|
| `Darwin` | `macos` |
| `MINGW*` \| `MSYS*` \| `CYGWIN*` | `windows` |
| anything else | `unsupported` |

- `CCWATCH_PLATFORM` set in the environment **overrides** the detection. This
  is the seam the hermetic suite uses to assert selection for both platforms
  from either platform (FR-029).
- `CCWATCH_PY` is resolved by running each candidate: `python3`, `python`
  (accepted only when `sys.version_info.major == 3`), `py -3` (D4). Empty when
  none answered.
- `unsupported` is a first-class value, not an error: every probe returns
  `failed` with the platform in the reason and the run continues (D3).

---

## The three outcomes

Every probe obeys the same protocol (FR-003, D8).

| Outcome | Exit | stdout | Report |
|---|---|---|---|
| measurement | `0` | the declared payload | `ok` |
| measured absence | `0` | the *empty* payload | `absent` + reason |
| failure to measure | `≠0` | **nothing** | `failed` + reason |

```
probe_note <name> <impl> <outcome> <reason> [detail]
probe_report                       # prints the TSV lines collected this run
```

- The report file is created lazily with
  `mktemp "${TMPDIR:-/tmp}/ccwatch-probes.XXXXXX"` — **with a template**,
  because a bare `mktemp` resolves against `confstr(_CS_DARWIN_USER_TEMP_DIR)`
  and a sandbox granting `$TMPDIR` and not `/var/folders` makes the command
  print nothing at all. Removed by the existing `cleanup` EXIT trap.
- A file rather than a variable: a global assigned inside `$(...)` never
  survives the subshell back to the caller.
- An `absent` outcome is only reachable when the probe's control query
  succeeded. Otherwise it is `failed` (FR-004).

---

## `probe_proc <comma-separated-pids>`

**Payload**: one JSON array, exactly one value.

```json
[{"pid": 4212, "start": 1758300123, "cpu": 812.44, "rss_mb": 391}]
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `pid` | integer | yes | as the registry records it (a Windows pid on Windows) |
| `start` | integer | yes | creation time, **epoch seconds UTC** |
| `cpu` | number | yes | cumulative CPU seconds (kernel + user) |
| `rss_mb` | integer | no | resident/working set in MB; a missing figure must not drop the row |

**Implementations**

| Platform | Impl label | How |
|---|---|---|
| macOS | `ps(BSD)` | `ps -o pid=,lstart=,time=,rss= -p <pids>` piped into the existing python parser, **unchanged** (FR-005) |
| Windows | `win32-ctypes` | one `$CCWATCH_PY -c` program: `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)`, `GetProcessTimes`, `GetProcessMemoryInfo` (D12) |
| Windows | `powershell-cim` | fallback when `CCWATCH_PY` is empty; `Get-CimInstance Win32_Process` |
| unsupported | `none` | `failed`: "no implementation for this platform (uname: …)" |

**Control query** (FR-004): macOS `ps -o pid= -p $$`; Windows the same probe
against the pid in `/proc/self/winpid` — **never `$$`**, which is an MSYS pid
and would fail always, turning the guard into a permanent "say nothing" (D11).

**Per-pid outcomes on Windows** — these three must stay distinct (D12):

| Win32 result | Meaning | Effect |
|---|---|---|
| handle opened | running | a record |
| `ERROR_INVALID_PARAMETER` (87) | not running | no record; a measured absence for that pid |
| `ERROR_ACCESS_DENIED` (5) | could not measure | no record, **counted**, reason in the report |

**Testing seam**: `CCWATCH_FAKE_PS` is honoured first, on every platform, and
parsed with the BSD text parser regardless of platform; the control query is
skipped while it is set (FR-006, D10). A fake `ps` says nothing about whether
the real one works.

**Callers**: `collect_live` only. The pid-reuse guard and the CPU-delta
comparison are not changed by this feature.

---

## `probe_mtimes <root> [find-args...]`

**Payload**: zero or more lines, newest first.

```
1758300123 /Users/x/.claude/projects/-repo/1a2b.jsonl
```

| Platform | Impl label | How |
|---|---|---|
| macOS | `stat-f(BSD)` | `find … -print0 \| xargs -0 stat -f '%m %N' \| sort -rn` |
| Windows | `stat-c(GNU)` | `find … -print0 \| xargs -0 stat -c '%Y %n' \| sort -rn` |

- `-print0`/`-0` is load-bearing: `C:\Users\Jane Doe\.claude` has a space in it.
- `-maxdepth 2` stays where it is. Subagent transcripts live one level deeper
  and offering one as a resumable session id produces a command that cannot
  work.
- **Control query**: the mtime of `<root>` itself. An empty listing with an
  unreadable root is `failed`, not `absent` — otherwise every session's silence
  measurement becomes "unknown" without saying so.

---

## `probe_clock <epoch-seconds>`

**Payload**: one line, e.g. `3:45 PM EDT`, with the leading zero stripped. Empty
when the reading is withheld.

**Selection is by validation** (D14). Once per run, each candidate is asked for
two fixed instants — one in EDT, one in EST — and is used only if it answers
both correctly:

| Order | Impl label | Invocation |
|---|---|---|
| 1 (macOS) | `date-r(BSD)` | `TZ=America/New_York date -r <epoch> '+%I:%M %p %Z'` |
| 1 (Windows) | `date-d(GNU)` | `TZ=America/New_York date -d "@<epoch>" '+%I:%M %p %Z'` |
| 2 (Windows) | `powershell-tz` | `TimeZoneInfo.ConvertTimeFromUtc` with zone id `Eastern Standard Time`; abbreviation from `IsDaylightSavingTime` |
| 3 | `none` | the clock is **withheld**; `doctor` reports each candidate and how it answered |

- Never `jq`. `TZ=America/New_York jq 'strflocaltime("%Z")'` reported EST for an
  instant in September — an hour wrong for half the year, on a number whose
  whole purpose is to go in a calendar.
- An empty, `null` or non-numeric input returns empty without consulting any
  implementation, as `reset_clock` does today.
- The reading must equal `web/usage.js`'s for the same instant on both sides of
  a DST boundary (FR-010, SC-006). That assertion exists and now runs on both
  platforms.

---

## `probe_host`

**Payload**: one JSON object, or `null`.

```json
{ "ram_free_mb": 5312, "swap_total_mb": 16384, "swap_used_mb": 2048,
  "swap_used_pct": 13, "load1": null,
  "unavailable": [{"field": "load1", "reason": "Windows has no load average"}] }
```

| Platform | Impl label | How |
|---|---|---|
| macOS | `vm_stat+sysctl` | unchanged: `vm_stat`, `sysctl -n vm.swapusage`, `sysctl -n vm.loadavg` |
| Windows | `powershell-cim` | one invocation: `Win32_OperatingSystem.FreePhysicalMemory` and `Win32_PageFileUsage.{AllocatedBaseSize,CurrentUsage}` (D15) |

**Rules**

- A figure the platform cannot supply is `null` with an entry in `unavailable`
  — **never `0`**. `0%` claims a pagefile exists and is empty.
- No substitution. Commit charge is not pagefile usage; processor queue length
  is not a load average (principle V).
- `compressed_mb` is macOS-only and absent on Windows; `load1` is always `null`
  on Windows.
- If the Windows probe costs more than **250ms** (measured with
  `CCWATCH_PROFILE=1`), it is cached for 30s under `$CCWATCH_HOME` **with its
  age**, and a reading past the window is withheld rather than annotated
  (principle III).

**Consumers**: the host-pressure line stays absent below its threshold
(principle XII); when `swap_used_pct` is `null` the judgement is not made and
the missing figure is named (FR-012). `cmd_doctor`'s current arithmetic on this
field must stop treating a `null` as `0`.

---

## `probe_native_path <path>` / `probe_posix_path <path>`

**Payload**: one path.

| Platform | Native | Posix |
|---|---|---|
| macOS | identity | identity |
| Windows | `cygpath -w` | `cygpath -u` |

Applied at every boundary where a path crosses into a native-Windows program or
arrives from one (D5): the python probes, `serve`'s `CCWATCH_SELF` and
`CCWATCH_WEB`, transcript paths handed to `convo`, and the paths the tray app is
given. Not applied to paths that stay inside the shell.

---

## Output hygiene

- Every Windows probe strips `\r` from its own output before returning it (D16).
  A carriage return that survives turns `idle` into an unrecognised status value
  and a `bar` line into a broken menu item.
- On Windows, `collect_sessions` normalises each row's `cwd` to forward slashes
  (D17). Without it the join's `split("/") | last` yields the whole path as the
  project name, and the `PROJECT` column becomes unreadable for every row.

---

## What `doctor` must print

One block, always, on every platform (FR-014):

```
platform
  + platform: windows (MINGW64_NT-10.0-26100)
  + python: python (3.12.4)
  + bash: C:\Program Files\Git\bin\bash.exe (MINGW64_NT-10.0-26100)
  + proc     win32-ctypes      ok
  + mtimes   stat-c(GNU)       ok
  ~ clock    date-d(GNU)       failed — answered 2:00 PM UTC for a known EDT instant; using powershell-tz
  + host     powershell-cim    ok        load1 unavailable: Windows has no load average
  x proc     win32-ctypes      failed    access denied on 1 of 7 pids
```

- Every probe appears, including the healthy ones: the question is "which
  probes produced this view", and a report listing only problems cannot answer
  it.
- An unrecognised answer from a probe is reported here with the offending shape
  summarised, rather than falling through a default branch (principle V).
- `failed` counts as a problem and moves `doctor`'s exit status, as its other
  problems do. `absent` does not.

---

## Environment variables this contract adds

| Variable | Purpose | Notes |
|---|---|---|
| `CCWATCH_PLATFORM` | override the detection | the selection-testing seam; documented in `usage()` |
| `CCWATCH_PY` | the resolved interpreter | set by detection; an explicit value is honoured |
| `CCWATCH_BASH` | the verified MSYS bash | Windows only; passed to `serve` for its subprocess calls |
| `CCWATCH_FAKE_PS` | **unchanged** | still the single liveness seam, on every platform |

No existing variable changes meaning, and no existing default changes value.
