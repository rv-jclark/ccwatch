# ccwatch-tray

The Windows taskbar tray and always-on-top overlay. See
`specs/006-windows-tray-overlay/` for the design and
`specs/006-windows-tray-overlay/contracts/tray-app.md` for the contract this
app is held to.

This holds no judgement of its own: it parses `ccwatch bar --no-actions` and
renders it, and adds only verbs (principle XI in `CLAUDE.md`).

## Requirements

- **.NET 8 SDK**, to build (`dotnet publish`). Get it from
  https://dotnet.microsoft.com/download/dotnet/8.0.
- **WebView2 runtime**, to run the overlay. Windows 11 and most current
  Windows 10 installs already have it (it ships with Microsoft Edge). If not,
  install the Evergreen Bootstrapper from
  https://developer.microsoft.com/microsoft-edge/webview2/.
- A bash that is **not** `%SystemRoot%\System32\bash.exe` (the WSL launcher):
  Git for Windows or MSYS2. See D1/D19 in `research.md` for why.

## Building

```powershell
./app-win/build.ps1               # dotnet publish into app-win/build/
./app-win/build.ps1 -Run           # build, then launch it
./app-win/build.ps1 -SelfTest      # build, then run the app's own checks
./app-win/build.ps1 -Install       # build, then copy into %LOCALAPPDATA%\Programs\ccwatch
./app-win/build.ps1 -SelfContained # bundle the .NET runtime into the output
```

Nothing in `bin/ccwatch` or `web/` depends on this app (FR-028). It is a
separate build step, same as `app/build.sh` is for macOS.

## Installing

`./app-win/build.ps1 -Install` builds and copies the published app into
`%LOCALAPPDATA%\Programs\ccwatch`. It does not add a Start Menu shortcut or
register the app to launch at sign-in — do both by hand if you want them,
since a step this app took silently would be a step the documentation could
not name (SC-010). Uninstalling is deleting that folder; the app writes no
registry keys.

### Launching at sign-in

A shortcut in the Startup folder, which is the mechanism with no service, no
scheduled task and nothing to uninstall but a file:

```powershell
$target  = Join-Path $env:LOCALAPPDATA 'Programs\ccwatch\ccwatch-tray.exe'
$lnk     = Join-Path ([Environment]::GetFolderPath('Startup')) 'ccwatch.lnk'
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sc.TargetPath = $target
$sc.WorkingDirectory = Split-Path $target
$sc.Save()
```

Point it at the **installed** copy, not `app-win/build/`: that directory is
git-ignored and a `git clean` would leave the shortcut aimed at nothing. The
cost of the installed copy is that `-Install` has to be re-run after a
rebuild, the same trade the CLI's symlink avoids and a compiled binary
cannot.

### Making the icon visible

⚠️ Windows 11 files every **new** tray icon into the hidden overflow, so the
first launch looks like nothing happened. It is behind the `^` chevron. Drag
it onto the tray, or set *Settings → Personalization → Taskbar → Other system
tray icons → ccwatch-tray*.

The preference is keyed by **executable path**, under
`HKCU\Control Panel\NotifyIconSettings\<id>` as `IsPromoted`. So promoting
the copy in `app-win/build/` does nothing for the installed one — they are
two different entries, and installing after a build hides the icon again
even though it was visible a moment earlier. Check which is which with:

```powershell
Get-ChildItem 'HKCU:\Control Panel\NotifyIconSettings' | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  if ($p.ExecutablePath -match 'ccwatch') { "$($_.PSChildName)  $($p.ExecutablePath)  IsPromoted=$($p.IsPromoted)" }
}
```

At launch the tray locates `ccwatch` the same way on every run: a build-time
path recorded at publish time, then `PATH`. If neither resolves, the tray
title reads `cc !` and the menu states what it looked for and where — never
an empty fleet (see `quickstart.md` §2f).

## What is unavailable here

The tray and overlay only ever show what `ccwatch bar`/`ccwatch --json`
report, so anything `bin/ccwatch` cannot measure on Windows is absent from
this app too, stated as unavailable rather than shown as zero or omitted:
load average (`load1` is `null`, never `0`), `send`/`kill`/`peers` (these need
POSIX signals and the per-session Unix socket; `serve` stays read-only on
Windows), and the separate "compressed" memory figure macOS reports. See the
"Portability constraints" section of the top-level `README.md` for the full
list and why each is missing rather than faked.

## The overlay's stated limitation

The overlay stays above other windows via `WS_EX_TOPMOST`, re-asserted with
`SetWindowPos(HWND_TOPMOST, …)`. That covers a maximised application and a
borderless-fullscreen one — the case this feature's user story describes —
but it does **not** reliably cover an **exclusive-fullscreen Direct3D**
application (most full-screen games): Windows has no public equivalent of
macOS's `.statusBar` window level, which sits above even that.

Two undocumented alternatives were considered and rejected:
`SetWindowBand` and the unpublished virtual-desktop pinning interfaces. Both
are rejected for the same reason — their GUIDs and ordinals change between
Windows builds and they fail **silently** when they do, which is exactly the
failure shape `--selftest` exists to catch loudly instead. `WS_EX_TOPMOST` is
a public, stable API; a window that occasionally loses the exclusive-fullscreen
case is a known, named limitation, not a surprise on the next Windows update.
