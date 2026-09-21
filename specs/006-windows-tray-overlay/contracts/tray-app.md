# Contract — the Windows tray and overlay app (`app-win/`)

What the app must do, what it must never do, and the exact lines its selftest
prints so `tests/run.sh` can assert on them. It is the Windows counterpart of
`app/`, and it holds no judgement: everything it displays comes from
`ccwatch bar --no-actions` (see
[bar-document.md](./bar-document.md)).

Decisions referenced as `D<n>` are in [../research.md](../research.md).

---

## Layout

```
app-win/
├── Sources/Program.cs        the whole app: locator, bar parser, tray, overlay,
│                             serve supervisor, selftest
├── ccwatch-tray.csproj       net8.0-windows, WinForms, WebView2
├── build.ps1                 build / --run / --selftest / --install
└── README.md                 requirements, what is unavailable on Windows, why
```

**One-way, like `app/`** (FR-028, FR-035): nothing in `bin/ccwatch`, `web/`,
`app/` or `extra/` may come to depend on this. The CLI and the pages keep
working on a Windows machine that has never built it, and the suite skips its
checks with the reason stated rather than failing.

---

## Build

```
./app-win/build.ps1                # publish into app-win/build/
./app-win/build.ps1 -SelfTest      # publish, then run --selftest and exit with it
./app-win/build.ps1 -Run           # publish, then launch
./app-win/build.ps1 -Install       # publish, then copy into %LOCALAPPDATA%\Programs\ccwatch
./app-win/build.ps1 -SelfContained # bundle the runtime (for a machine with no SDK)
```

Requirements, stated by the script and refused with the reason rather than
failing opaquely: the .NET 8 SDK, and the WebView2 runtime for anything that
opens the overlay (present by default on Windows 11; the script names the
installer when it is absent).

Mirroring `app/build.sh`, the build **records the checkout it was built from**
into the binary, because a GUI process does not inherit the shell's `PATH` (D19)
and this is the candidate that normally wins. Moving the checkout therefore
needs a rebuild, and the menu says which checkout it is driving.

---

## Locating what it drives (FR-021, D19)

Two things, each **verified by running it**:

### 1. A bash interpreter

Candidates, in order:

1. the path recorded at build time
2. `HKLM\SOFTWARE\GitForWindows\InstallPath` + `\bin\bash.exe`
3. `%ProgramFiles%\Git\bin\bash.exe`
4. `C:\msys64\usr\bin\bash.exe`
5. `bash.exe` from `PATH`

**`%SystemRoot%\System32\bash.exe` is excluded by path**, and every candidate is
accepted only if `uname -s` reports `MINGW*`, `MSYS*` or `CYGWIN*`.

That exclusion is the load-bearing part. `System32\bash.exe` is the WSL
launcher, it is on `PATH` by default on a machine with WSL installed, and a WSL
shell cannot see Windows process ids — so running the CLI there produces a
**confidently empty fleet** on a busy machine. That is the worst output this
tool can produce, and it would arrive through the app looking perfectly healthy.

### 2. The `ccwatch` script

Candidates: the path recorded at build time, then the documented install
locations. Accepted only if `bash <script> --version` prints a line beginning
`ccwatch `.

### Reporting

Both resolved paths, and the version, appear in the menu. A miss is a **named
miss**: the title becomes `cc !`, and the menu says what was looked for and
where — never an empty fleet, because "I cannot find ccwatch" and "nothing is
running" are different facts that look identical in a tray.

---

## Invoking the CLI

```
<bash> <script-path> bar --no-actions      with NO_COLOR=1, CCWATCH_PORT=<port>
                                           UseShellExecute=false, CreateNoWindow=true
```

- `NO_COLOR=1` because the output is parsed and an escape sequence in the middle
  of a title is not a title.
- `CreateNoWindow` because a child console process otherwise flashes a window
  every refresh.
- Read the pipe as it fills; a child that blocks on a full pipe buffer while the
  parent waits for exit is a deadlock, not a slow command.
- A generous timeout (the macOS app uses 120s): a cold snapshot over a large
  transcript tree was measured at 24s under load.
- Refresh cadence: `CCWATCH_BAR_REFRESH` seconds, default 10 — the same as the
  macOS app and the plugin, and for the same reason (a snapshot walks the
  transcript tree; a repaint nobody is watching is not worth it every 2s).

Empty or whitespace output renders the `cc ?` document with the "This is NOT
'nothing is running'" sentence. Never a count.

---

## The tray surface (FR-016–FR-022)

- Title: the bar document's title, verbatim.
- Menu: the bar document's items in document order, separators included,
  unimplemented parameters retained and their lines still shown.
- Then, and only then, the verbs:

| Verb | Does |
|---|---|
| Show / Hide Overlay | toggles the overlay window |
| Open Dashboard in Browser | shell-opens `http://127.0.0.1:<port>/` |
| Open Agent in Browser | shell-opens `http://127.0.0.1:<port>/map?sid=<sid>` for a row that carries one |
| Restart serve | stops the supervised server and starts it again |
| Quit | exits, reaping a server it started |

Plus two non-interactive lines: the serve state, and the resolved CLI/bash
paths with the version.

**Nothing else.** No badge, no count, no judgement, no state the bar document
did not carry (FR-022). Status rows are not clickable and must stay legible —
the severity colour goes on the rendered text rather than being thrown away by a
disabled control's grey.

**Not offered at all on Windows**: send, kill, peer messaging. They need POSIX
signals and the per-session Unix socket. The menu states that they are
unavailable on this platform with the reason (D23) — absent from the UI would
read as never built (principle IV).

---

## The serve supervisor (FR-026)

Identical in behaviour to the macOS `ServeSupervisor`:

| State | Meaning |
|---|---|
| `notStarted` | nothing running, nothing adopted |
| `running(pid)` | this app started it |
| `adopted` | something was already answering on the port — **labelled as not started by this app** |
| `failed(reason)` | with the child's last stderr line as the reason |

- The port is probed **before** starting anything. Something already listening
  is most likely a `ccwatch serve` the operator started in a terminal, and both
  killing it and fighting it for the port are worse than adopting it.
- Restarts are bounded at three, then it says what happened and stops. A serve
  that cannot bind would otherwise be respawned forever while the menu
  cheerfully reported "running".
- On quit, a server this app started is reaped. A leaked server holds a port
  with no visible owner, and this repository has already paid for that once:
  1686 orphaned servers, ~5GB, read as the host merely being short of memory.

---

## The overlay (FR-023–FR-025, D20)

A borderless `Form` hosting `WebView2` on `http://127.0.0.1:<port>/map` — the
same page the browser is served, from the same server, so there is one renderer
of the map on Windows as on macOS.

| Property | Mechanism |
|---|---|
| stays above other windows | `TopMost = true`, `WS_EX_TOPMOST`, re-asserted with `SetWindowPos(HWND_TOPMOST)` on show and on foreground change |
| appears on the current virtual desktop | `IVirtualDesktopManager.IsWindowOnCurrentVirtualDesktop`; when false, hide and re-show |
| does not take keyboard focus | `WS_EX_NOACTIVATE`, `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`, shown with `SW_SHOWNOACTIVATE` |
| not in the task bar or Alt-Tab | `ShowInTaskbar = false`, `WS_EX_TOOLWINDOW` |
| a link that wants a new window | `NewWindowRequested` → `Process.Start(UseShellExecute = true)`, `e.Handled = true` |
| reloads on show | the page is re-navigated when the overlay is shown |

Reloading on show rather than leaving it running hidden: `serve` stops
collecting 15s after the last read of `/api/state`, so a hidden overlay holding
the feed open would keep the collector awake for nothing.

`NewWindowRequested` must be handled. An unhandled one is **swallowed in
silence** — the reader sees a link, clicks it, and nothing at all happens —
which is the worst available outcome and exactly what the macOS
`OverlayUIDelegate` exists to prevent.

**Stated limitation**: `TopMost` covers maximised and borderless-fullscreen
windows, which is the case the user story describes. It does not reliably cover
an exclusive-fullscreen Direct3D application; Windows has no public equivalent
of macOS's `.statusBar` window level. The README says so. The undocumented
alternatives (`SetWindowBand`, the unpublished virtual-desktop pinning
interfaces) are rejected because their GUIDs change between Windows builds and
they fail *silently* when they do — the precise failure shape the selftest
exists to catch.

**Opening the overlay with no server answering says so.** An empty map presented
as a quiet machine is failure-as-absence.

---

## `--selftest` (FR-027)

Prints one `  ✓ <claim>` or `  ✗ <claim>` per check, then
`selftest: all checks passed` or `selftest: <n> FAILED`, and exits 0 or 1. The
suite asserts on the **text of specific claims**, not merely on the summary,
because a selftest that quietly stopped checking one property would still say
"all checks passed".

Claims, in order, with the substring `tests/run.sh` matches:

| # | Claim text contains | Asserts |
|---|---|---|
| 1 | `the title is the CLI's, parameters stripped` | title parsing |
| 2 | `the condition is still spelled out` | the words survive the colour (VII) |
| 3 | `both separators survive` | `---` handling |
| 4 | `the measurement travels with the verdict` | `quiet 20m` reaches the menu (II) |
| 5 | `severity colour is carried, not recomputed` | XI |
| 6 | `a neutralised pipe stays in the text where the CLI put it` | first-` | ` split |
| 7 | `no bash= parameter is ever parsed` | no clickable command from a name |
| 8 | `an unknown parameter leaves its line displayed` | FR-018 |
| 9 | `empty CLI output is a question mark, never a count` | FR-019 |
| 10 | `the overlay stays above other windows (WS_EX_TOPMOST)` | z-order bit |
| 11 | `and is re-asserted topmost when shown` | the re-assert path |
| 12 | `and does not steal focus when clicked (WS_EX_NOACTIVATE)` | focus bit |
| 13 | `and answers WM_MOUSEACTIVATE with MA_NOACTIVATE` | the message handler |
| 14 | `and is shown without activation (SW_SHOWNOACTIVATE)` | the show path |
| 15 | `and follows you to the current virtual desktop` | `IVirtualDesktopManager` + reveal |
| 16 | `and stays out of the task bar and Alt-Tab` | `WS_EX_TOOLWINDOW` |
| 17 | `a new-window request leaves the overlay` | `NewWindowRequested` handled |
| 18 | `the port probe reports a closed port as closed` | the adoption probe |
| 19 | `the WSL bash at System32 is never used` | D19's exclusion |
| 20 | `a candidate interpreter is verified by running uname` | verify-by-running |

Checks 10–17 need a window. Where the WebView2 runtime is absent, the
window-property checks still run (they are Win32 styles on the host `Form`) and
only the navigation check skips **with its reason** — a skip with a reason, not
a silent pass (principle IV, and the suite's own rule that a host which cannot
supply something skips rather than fails).

---

## What `tests/run.sh` asserts about this app

A new `app-win` section, skipped with the reason unless the binary exists:

```
if [ ! -x "$ROOT/app-win/build/ccwatch-tray.exe" ]; then
  t_skip "the Windows tray app's own checks" "app-win not built — run ./app-win/build.ps1"
elif [ "$(uname -s)" = Darwin ]; then
  t_skip "the Windows tray app's own checks" "a Windows binary cannot run on macOS"
else
  ... assert the summary, the exit code, and claims 6, 7, 9, 10, 12, 15, 17, 19 by name
fi
```

None of these count toward `TALLY_FLOOR`, for the same reason the macOS app's
seven do not: a floor counting them would fail on any machine that has never
built the app (principle: an assertion must not encode one machine's
configuration).
