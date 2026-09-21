# Phase 1 data model — Windows support for the taskbar tray and the overlay

The entities here are the ones the spec names, given concrete fields, shapes and
transitions. Two rules govern all of them and are repeated because breaking
either is how this feature would fail invisibly:

- **A measurement, a measured absence and a failure to measure are three
  values, never two** (FR-003, principle IV).
- **A figure the platform cannot supply is `null` with a reason, never `0`**
  (FR-011, principle III).

Decisions referenced as `D<n>` are in [research.md](./research.md).

---

## 1. Platform

The detected host, decided once per run (D2).

| Field | Type | Values | Notes |
|---|---|---|---|
| `id` | string | `macos` \| `windows` \| `unsupported` | from `uname -s`; `CCWATCH_PLATFORM` overrides |
| `uname` | string | e.g. `Darwin`, `MINGW64_NT-10.0-26100` | reported verbatim by `doctor`, never parsed twice |
| `py` | string | e.g. `python3`, `python`, `py -3` | resolved once (D4); empty when none was found |
| `bash` | string | path | Windows only; the verified MSYS bash (D19). Absent on macOS |

**Validation**

- `id` is exactly one of the three. There is no default arm: an unmatched
  `uname` is `unsupported` explicitly, not by falling through (principle V).
- `id = unsupported` is not an error state. The run continues; every probe
  reports failure-to-measure with the platform in the reason (D3).
- `py` empty is a failure-to-measure for every probe that needs it, named as
  such — not a crash and not a zero.

**Transitions**: none. Detected once, carried for the run. `doctor` reports the
same value the snapshot used rather than re-deriving it (principle XI, inside
the script).

---

## 2. Probe

One named host-dependent measurement with a per-platform implementation (D7).
Six exist and no seventh is introduced by this feature.

| `name` | Measures | Payload shape | macOS impl | Windows impl |
|---|---|---|---|---|
| `proc` | process facts for a pid list | JSON array of ProcFact | `ps -o pid=,lstart=,time=,rss= -p` + parser | Win32 `OpenProcess`/`GetProcessTimes`/`GetProcessMemoryInfo` via `ctypes` (D12) |
| `mtimes` | transcript modification times | `<epoch> <path>` lines, newest first | `stat -f '%m %N'` | `stat -c '%Y %n'` (D13) |
| `clock` | an epoch as an Eastern wall clock | `3:45 PM EDT` or empty | `TZ=… date -r` | validated GNU `date -d @`, else PowerShell `TimeZoneInfo` (D14) |
| `host` | host memory pressure | JSON object or `null` | `vm_stat` + `sysctl` | PowerShell CIM (D15) |
| `native_path` | a path for a native consumer | one path | identity | `cygpath -w` (D5) |
| `posix_path` | a path for the shell | one path | identity | `cygpath -u` (D5) |

**Validation**

- A probe prints only its declared shape on stdout. Reasons, warnings and
  diagnostics go to the report file (entity 4), never into the payload.
- `proc`'s records are normalised: the caller cannot tell which implementation
  produced them (FR-007). `collect_live`'s pid-reuse guard and CPU-delta
  comparison are unchanged by this feature.
- No `ps`, `stat -f`, `date -r`, `vm_stat` or `sysctl` invocation exists
  outside these implementations (FR-001) — a greppable, and therefore
  assertable, property.

---

## 3. ProbeOutcome

The three values that must never collapse into two (FR-003).

| Outcome | Exit | stdout | Report entry | Caller behaviour |
|---|---|---|---|---|
| `ok` | 0 | the payload | `ok` + implementation | uses the payload |
| `absent` | 0 | the empty payload (`[]`, `null`, no lines) | `absent` + reason | renders an honest empty |
| `failed` | non-zero | **nothing** | `failed` + reason | says nothing; `require_json` names the stage |

**Validation**

- `absent` is only reachable when a **control query** succeeded (entity 5). An
  empty answer with a failed control query is `failed` (D9, FR-004).
- `failed` never prints a payload. A sentinel object would be rendered as data
  by the first caller that forgot about it.
- Every `absent` and every `failed` carries a reason. "The process probe
  failed" without "access denied on pid 4212" is the absence-shaped failure this
  feature exists to remove.

**Transitions**

```
             control query ok?
                 /        \
               yes         no
                |           |
   payload empty?           failed(reason)
      /      \
    yes       no
     |         |
 absent(reason)  ok(payload)
```

---

## 4. ProbeReport

What ccwatch can say about the probes that produced its view (FR-014). One TSV
line per probe per run, appended to a run-scoped file created with an explicit
`$TMPDIR` template and removed by the existing `cleanup` trap (D8).

| Field | Type | Notes |
|---|---|---|
| `name` | string | one of the six in entity 2 |
| `impl` | string | the implementation selected, e.g. `ps(BSD)`, `win32-ctypes`, `powershell-cim` |
| `outcome` | enum | `ok` \| `absent` \| `failed` |
| `reason` | string | required for `absent` and `failed`; empty for `ok` |
| `detail` | string | optional measurement context, e.g. `2 of 7 pids denied` |

**Validation**

- A file, not a shell variable: a global assigned inside `$(...)` does not
  survive the subshell, which this repository has already paid for once (D8).
- `doctor` prints one line per probe, always — including `ok` ones, because the
  question it answers is "which probes produced this view", and a report that
  only lists problems cannot answer it. This is not a warning line and so is
  not subject to principle XII: it appears under an explicit diagnostic command
  the operator ran on purpose.
- An unparseable answer from a probe is `failed` with the offending shape
  summarised — surfaced here rather than falling through a default branch
  (FR-014, principle V).

---

## 5. ControlQuery

The query whose empty answer is not believable (D9, FR-004). One per probe whose
emptiness is ambiguous.

| Probe | Control query | Why it cannot legitimately be empty |
|---|---|---|
| `proc` (macOS) | `ps -o pid= -p $$` | our own process exists |
| `proc` (Windows) | the probe against **our own Windows pid**, from `/proc/self/winpid` | same, in the namespace the registry uses (D11) |
| `mtimes` | the mtime of `$PROJ_DIR` itself | the directory exists whenever the listing was attempted |
| `host` | the probe's own first field | a host always has physical memory |
| `clock` | two fixed instants, one EDT one EST, with known answers | arithmetic on a known input (D14) |

**Validation**

- Skipped when `CCWATCH_FAKE_PS` is set: a fake `ps` says nothing about whether
  the real one works, which is why the existing guard skips it too (D10).
- Windows `proc` must use `/proc/self/winpid`, **never `$$`** — MSYS's `$$` is
  an MSYS pid, so a control query built on it fails always, and the probe would
  then say nothing on every run: an empty fleet on a busy machine, arriving by
  way of the guard meant to prevent exactly that (D11).

---

## 6. ProcFact

One live process, normalised. The four facts `bin/ccwatch:168` gathers.

| Field | Type | Unit | Notes |
|---|---|---|---|
| `pid` | integer | — | the platform's own pid; on Windows a Windows pid, as the registry records |
| `start` | integer | epoch seconds, **UTC** | compared as an epoch against the registry's `startedAt`, never as a string (FR-008) |
| `cpu` | number | seconds, cumulative | kernel + user; the second independent progress signal (principle I) |
| `rss_mb` | integer | MB | **optional** — a missing figure must not drop the row |

**Validation**

- A record that cannot be parsed is skipped and **counted**, not guessed at: a
  wrong start time makes the pid-reuse guard reject a live session (principle
  VI). The count reaches `doctor` through the report.
- On Windows, per-pid outcomes are distinguished: opened → running;
  `ERROR_INVALID_PARAMETER` → not running (a measured absence for that pid);
  `ERROR_ACCESS_DENIED` → failure for that pid, recorded with its reason and
  counted. Access-denied must never be folded into "not running", which would
  drop a session from the fleet silently, one row at a time (D12).
- `start` is UTC on both platforms. The macOS path converts a local `lstart`
  string; the Windows path gets UTC from the FILETIME directly.

---

## 7. HostReading

What `collect_host` returns, with the platform difference made explicit.

| Field | Type | macOS | Windows |
|---|---|---|---|
| `ram_free_mb` | integer \| null | `vm_stat` pages free | `Win32_OperatingSystem.FreePhysicalMemory` |
| `compressed_mb` | integer \| absent | `vm_stat` compressor pages | **absent** — macOS has a compressor, Windows does not |
| `swap_total_mb` | integer \| null | `vm.swapusage` total | `Win32_PageFileUsage.AllocatedBaseSize`; `null` with no pagefile |
| `swap_used_mb` | integer \| null | `vm.swapusage` used | `Win32_PageFileUsage.CurrentUsage`; `null` with no pagefile |
| `swap_used_pct` | integer \| null | derived | derived; `null` when either input is `null` |
| `load1` | number \| null | `vm.loadavg` | **always `null`** — Windows has no load average (FR-011) |
| `unavailable` | array of `{field, reason}` | usually empty | e.g. `[{"field":"load1","reason":"Windows has no load average"}]` |

**Validation**

- `null`, never `0`. "0% of swap used" claims there is swap and it is empty —
  the shape that first turned CI red on a macOS runner with swap disabled, and
  the reason the suite asserts this field by field rather than grepping the JSON
  for `null` (`tests/run.sh:3206-3235`).
- No figure may be substituted for another. Commit charge is not pagefile usage
  and processor queue length is not a load average (D15, principle V).
- `unavailable` is how FR-012's "state which figure is unavailable" is
  satisfied without inventing a value to carry the message.

**Transitions (the pressure verdict)**

```
swap_used_pct null?  -> the judgement cannot be made:
                        say which figure is missing and why (FR-012)
       |
      no
       |
  >= CCWATCH_SWAP_WARN ? -> warn, with the measurement beside it (II)
       |
      no -> say NOTHING (XII). Not green. Absent.
```

---

## 8. ClockReading

| Field | Type | Notes |
|---|---|---|
| `text` | string | `3:45 PM EDT`, leading zero stripped; **empty** when withheld |
| `impl` | string | `date-r(BSD)`, `date-d(GNU)`, `powershell-tz`, or `none` |
| `validated` | boolean | did the implementation answer both fixed instants correctly (D14) |

**Validation**

- An implementation that fails validation is not used. There is no "probably
  right" state: the clock is withheld and `doctor` says which candidates were
  tried and how each answered.
- The abbreviation is always present when the text is. `EDT` and `EST` are an
  hour apart and a bare clock time is ambiguous for half the year.
- The reading must match `web/usage.js` for the same instant, to the minute and
  the abbreviation, on both sides of a DST boundary (FR-010, SC-006) — the
  existing assertion, now run on both platforms.

---

## 9. BarDocument / BarItem

The contract between the CLI and both GUIs (FR-016–FR-019). Unchanged in format
by this feature; restated because a third renderer now depends on it. Full rules
in [contracts/bar-document.md](./contracts/bar-document.md).

**BarDocument**

| Field | Type | Notes |
|---|---|---|
| `title` | string | line 0's text, parameters stripped. `cc ?` when the snapshot failed — never a count |
| `titleColor` | string \| null | an addition to the words, never the carrier of them |
| `symbolName` | string \| null | `sfimage=`; the Windows app maps it to an icon or ignores it |
| `items` | array of BarItem | in document order; separators included |

**BarItem**

| Field | Type | Notes |
|---|---|---|
| `text` | string | everything before the **first** ` | ` |
| `isSeparator` | boolean | the line was `---` |
| `color`, `size`, `monospaced` | — | rendering hints, all optional |
| `unhandledParams` | map | every parameter this renderer does not implement, **kept** so the line still shows (FR-018) |

**Validation**

- Split on the first ` | ` and no other. `cmd_bar`'s `clean` filter replaces
  `|` with `¦` in every interpolated field so that exactly one separator can
  appear per line; splitting on the last one hands a session name the parameter
  list back (FR-017).
- An unimplemented parameter never drops its line. A future CLI item vanishing
  from the menu is failure-as-absence.
- No item's severity, count, threshold or word is computed by a renderer
  (FR-016, principle XI).

---

## 10. TraySurface

| Field | Type | Notes |
|---|---|---|
| `title` | string | the BarDocument's title, verbatim |
| `menu` | array | the BarDocument's items, plus the verb block |
| `verbs` | enum set | show/hide overlay, open dashboard, start/restart serve, open agent in browser, quit — and nothing else (FR-022) |
| `cliPath`, `bashPath` | string \| null | shown in the menu; `null` renders as a named miss, never an empty fleet (FR-021, D19) |
| `serveState` | enum | `notStarted` \| `running(pid)` \| `adopted` \| `failed(reason)` (FR-026) |

**Validation**

- Every severity is identifiable from its word alone; colour, icon and glyph are
  additions (FR-020, principle VII), which is what makes the surface legible
  under a high-contrast theme and to a screen reader.
- `adopted` is labelled as a server this app did not start. The menu never
  claims to manage something it did not start (FR-026).
- No badge, judgement or state that the bar document did not carry (FR-022).

**Transitions (serve)**

```
notStarted --port already answering--> adopted
notStarted --spawned--> running(pid) --child exited--> failed(reason)
failed --up to 3 restarts--> running(pid)
failed --after 3--> failed("gave up after 3 restarts")
```

Bounded restarts, as the macOS supervisor does: a serve that cannot bind would
otherwise be respawned forever while the menu cheerfully reported "running".

---

## 11. OverlaySurface

Defined by its properties, because that is what fails invisibly (FR-024,
FR-027, D20).

| Property | Value | Selftest asserts |
|---|---|---|
| z-order | `TopMost` + `WS_EX_TOPMOST`, re-asserted on show | the property and the ex-style bit, by name |
| virtual desktop | `IVirtualDesktopManager` detection + hide/re-show reveal | the interface is obtained and the reveal path runs |
| focus | `WS_EX_NOACTIVATE`, `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`, `SW_SHOWNOACTIVATE` | all three, by name |
| task bar / Alt-Tab | `ShowInTaskbar = false`, `WS_EX_TOOLWINDOW` | both |
| new window | `NewWindowRequested` → shell-open, `Handled = true` | the handler exists and marks the event handled |
| content | `http://127.0.0.1:<port>/map`, the served page (FR-023) | the URL the view was given |

**Validation**

- A missing property fails the selftest **loudly**. Each of these looks perfect
  until something covers the window, the desktop changes, or a keystroke goes
  somewhere unexpected.
- Stated limitation: exclusive-fullscreen Direct3D applications can still cover
  a `TopMost` window; Windows has no public equivalent of macOS's `.statusBar`
  level. Documented, not claimed away (D20).
- Opening the overlay with no server answering says so. An empty map presented
  as a quiet machine is failure-as-absence.

---

## 12. Relationships

```
Platform ──selects──> Probe ──produces──> ProbeOutcome ──logged in──> ProbeReport
                        │                      │                          │
                        │                      └── guarded by ControlQuery│
                        │                                                 v
                        ├── proc   ──> [ProcFact]  ──> collect_live ──> snapshot ──> doctor
                        ├── mtimes ──> transcript listing ──────────────> snapshot
                        ├── clock  ──> ClockReading ────────────────────> render / bar
                        ├── host   ──> HostReading ─────────────────────> snapshot
                        └── paths  ──> every bash→native boundary

snapshot ──> `ccwatch bar --no-actions` ──> BarDocument ──> TraySurface (Windows)
                                                       └──> macOS status item (unchanged)
                                                       └──> SwiftBar plugin (unchanged)

serve ──/map──> OverlaySurface (WebView2)  and  the browser  — one renderer, two hosts
```

Nothing in the diagram flows backwards: no surface computes a value it then
feeds to the snapshot, and no page or app derives a status of its own
(principle XI).
