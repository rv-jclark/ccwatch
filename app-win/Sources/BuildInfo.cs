// The checkout — and the bash interpreter that built it — recorded at build
// time (D19). A GUI process launched from Explorer does not inherit a
// shell's PATH, so this is the candidate that normally wins: moving the
// checkout needs a rebuild, and the menu says which checkout it is driving.
//
// ⚠️ This file is overwritten by build.ps1 immediately before `dotnet
// publish` with the real paths it found. The values below are the
// no-build-info fallback (e.g. `dotnet build` invoked directly) and must
// stay empty so BashLocator/CliLocator fall through to the other
// candidates rather than trusting a stale path.

namespace CCWatch.Tray;

internal static class BuildInfo
{
    public const string BuiltFromBash = "";
    public const string BuiltFromScript = "";
}
