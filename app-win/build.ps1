<#
.SYNOPSIS
    Build ccwatch-tray.exe — the Windows taskbar tray and the overlay.

.DESCRIPTION
    Mirrors app/build.sh's shape:

        ./app-win/build.ps1                build into app-win/build/
        ./app-win/build.ps1 -Run            build, then launch it
        ./app-win/build.ps1 -SelfTest       build, then run the app's own checks
        ./app-win/build.ps1 -Install        build, then copy into %LOCALAPPDATA%\Programs\ccwatch
        ./app-win/build.ps1 -SelfContained  bundle the .NET runtime into the output

    Requirements are refused with a named reason rather than failing
    opaquely: the .NET 8 SDK always, and the WebView2 runtime for anything
    that opens the overlay (present by default on Windows 11).
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Run,
    [switch]$Install,
    [switch]$SelfContained
)

$ErrorActionPreference = 'Stop'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $Here
$Project = Join-Path $Here 'ccwatch-tray.csproj'
$Out = Join-Path $Here 'build'
$BuildInfoFile = Join-Path $Here 'Sources/BuildInfo.cs'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet not found. Install the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0"
    exit 1
}

$sdks = & dotnet --list-sdks 2>$null
if (-not ($sdks | Where-Object { $_ -match '^8\.' })) {
    Write-Error (".NET 8 SDK not found (only: $($sdks -join ', ')). " +
        "Install it from https://dotnet.microsoft.com/download/dotnet/8.0")
    exit 1
}

if (($Run -or $SelfContained) -and -not $SelfTest) {
    # The overlay needs the WebView2 runtime; --selftest's window-property
    # checks do not (contracts/tray-app.md), so this check is skipped for
    # -SelfTest alone.
    $webview2Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    if (-not (Test-Path $webview2Key) -and -not (Test-Path ($webview2Key -replace 'WOW6432Node\\', ''))) {
        # The concatenation is PARENTHESISED. `Write-Warning "a" + "b"` does not
        # continue a line in PowerShell: the `+` is read as another argument to
        # the cmdlet, and the parser then fails at the end of the enclosing
        # block with `Missing closing '}'`, pointing dozens of lines away from
        # the real fault. This script had never been run, so it had never been
        # parsed, and the whole file was unusable for that one pair of quotes.
        Write-Warning ("WebView2 runtime not detected — the overlay will not navigate. " +
            "Install it from https://developer.microsoft.com/microsoft-edge/webview2/")
    }
}

# ⚠️ Recorded into the binary because a GUI process launched from Explorer
# does not inherit the shell's PATH (D19) — this is the candidate that
# normally wins, and moving the checkout means rebuilding.
#
# ⚠️ Which makes it the WORST place to record WSL's bash, and that is exactly
# what `Get-Command bash.exe` returned here: `C:\Windows\system32\bash.exe`,
# with %LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe behind it and no MSYS
# bash on the Windows PATH at all. BashLocator excludes System32 by path and
# verifies every candidate by running `uname -s`; this recorder did neither,
# so it baked the one interpreter the whole design rules out into the binary
# as the candidate that normally wins. WSL cannot see Windows process ids, so
# the tray would have shown an empty fleet forever, with no error anywhere.
# Same candidate order as BashLocator.Candidates(), and the same verification.
function Find-MsysBash {
    $candidates = @()
    $gitInstall = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\GitForWindows' -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
    if ($gitInstall) { $candidates += (Join-Path $gitInstall 'bin\bash.exe') }
    $candidates += (Join-Path ${env:ProgramFiles} 'Git\bin\bash.exe')
    $candidates += 'C:\msys64\usr\bin\bash.exe'
    $onPath = Get-Command bash.exe -All -ErrorAction SilentlyContinue | ForEach-Object { $_.Source }
    if ($onPath) { $candidates += $onPath }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        # Excluded by path, before it is ever run: System32 and WindowsApps are
        # the two places WSL's launcher lives.
        if ($c -match '(?i)\\System32\\bash\.exe$' -or $c -match '(?i)\\WindowsApps\\bash\.exe$') { continue }
        if (-not (Test-Path $c)) { continue }
        $kernel = & $c -c 'uname -s' 2>$null
        if ($LASTEXITCODE -eq 0 -and $kernel -match '^(MINGW|MSYS|CYGWIN)') { return $c }
    }
    return ''
}

$BashPath = Find-MsysBash
if (-not $BashPath) {
    Write-Warning ("No MSYS/MINGW/Cygwin bash found to record. The tray will fall back " +
        "to its own BashLocator at run time; install Git for Windows to record one.")
}
# ⚠️ .Replace, not -replace. These become C# string literals, where one
# backslash has to be written as two. In a .NET regex REPLACEMENT a backslash
# is literal - only `$` is special - so `-replace '\\', '\\\\'` inserted FOUR
# backslashes per separator and the recorded path came out as
# `C:\\Windows\\system32\\bash.exe`, which is not a path at all. Measured.
$BashPath = $BashPath.Replace('\', '\\')
$ScriptPath = (Join-Path $RepoRoot 'bin/ccwatch').Replace('\', '\\')

@"
// GENERATED by build.ps1 — do not edit by hand. See Sources/BuildInfo.cs
// for what this is and why it exists.

namespace CCWatch.Tray;

internal static class BuildInfo
{
    public const string BuiltFromBash = "$BashPath";
    public const string BuiltFromScript = "$ScriptPath";
}
"@ | Set-Content -Path $BuildInfoFile -Encoding UTF8

$publishArgs = @(
    'publish', $Project,
    '-c', 'Release',
    '-o', $Out
)

if ($SelfContained) {
    $publishArgs += @('--self-contained', 'true', '-r', 'win-x64')
} else {
    $publishArgs += @('--self-contained', 'false')
}

& dotnet @publishArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "dotnet publish failed (exit $LASTEXITCODE)"
    exit $LASTEXITCODE
}

$Binary = Join-Path $Out 'ccwatch-tray.exe'
if (-not (Test-Path $Binary)) {
    Write-Error "publish did not produce $Binary"
    exit 1
}

if ($SelfTest) {
    & $Binary --selftest
    exit $LASTEXITCODE
}

if ($Run) {
    & $Binary
    exit $LASTEXITCODE
}

if ($Install) {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\ccwatch'
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Path (Join-Path $Out '*') -Destination $InstallDir -Recurse -Force
    Write-Host "Installed to $InstallDir"
}
