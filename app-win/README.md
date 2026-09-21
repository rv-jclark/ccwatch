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
