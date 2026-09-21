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

    Right now this only runs `dotnet publish` — the flags exist as the shape
    later tasks fill in (T053-T055 wire -Run/-Install/-SelfContained for real;
    T054 wires -SelfTest against the app's own claims).
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
$Project = Join-Path $Here 'ccwatch-tray.csproj'
$Out = Join-Path $Here 'build'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet not found. Install the .NET 8 SDK: https://dotnet.microsoft.com/download/dotnet/8.0"
    exit 1
}

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
