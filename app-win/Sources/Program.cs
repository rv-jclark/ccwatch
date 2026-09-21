// ccwatch-tray — the Windows taskbar tray and always-on-top overlay.
//
// Mirrors app/'s arrangement: this holds no judgement of its own. It parses
// `ccwatch bar --no-actions` and renders it, and adds only verbs (principle
// XI in CLAUDE.md). See specs/006-windows-tray-overlay/ for the design.

namespace CCWatch.Tray;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
    }
}
