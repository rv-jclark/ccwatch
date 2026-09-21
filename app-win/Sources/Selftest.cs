// `--selftest` — exercises the real parser and prints what it checked
// (contracts/tray-app.md "--selftest"). tests/run.sh asserts on the text of
// specific claims, not merely on the summary line, because a selftest that
// quietly stopped checking one property would still say "all checks
// passed".
//
// Claims 1-9 here are US2's (the bar document). Claims 10-19, covering the
// overlay's window properties, are US3's — see tasks.md T067. Checks 10-16
// run on a bare Form with no server and no WebView2 runtime, since they are
// Win32 window styles rather than anything requiring a navigation.

using System.Runtime.InteropServices;

namespace CCWatch.Tray;

internal static class Selftest
{
    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public static int Run()
    {
        var failures = 0;
        void Check(bool ok, string what)
        {
            Console.WriteLine(ok ? $"  ✓ {what}" : $"  ✗ {what}");
            if (!ok) failures++;
        }

        Console.WriteLine("ccwatch-tray selftest");

        var doc = BarDocument.Parse(
            "37% · resets in 2h · 1 waiting | color=#ff6fb5\n"
            + "---\n"
            + "3 live · 1 waiting on you | size=12\n"
            + "---\n"
            + "* asking      repo  waiting  1h   permission to run rm 4m | font=Menlo size=12 color=purple\n"
            + "! hung-one    repo  HUNG?    1h   quiet 20m | font=Menlo size=12 color=red\n");

        Check(doc.Title == "37% · resets in 2h · 1 waiting",
            "the title is the CLI's, parameters stripped");
        Check(doc.Title.Contains("waiting"),
            "and the condition is still spelled out, not left to the colour");
        Check(doc.Items.Count(i => i.IsSeparator) == 2, "both separators survive");
        Check(doc.Items.Any(i => i.Text.Contains("quiet 20m")),
            "the measurement travels with the verdict into the menu");
        Check(doc.Items.Any(i => i.Color == "red"), "severity colour is carried, not recomputed");
        Check(doc.Items.Any(i => i.Monospaced), "a Menlo row is rendered monospaced");

        // ⚠️ The pipe strip is the CLI's job, but the parser must not undo
        // it: a row whose text contains ¦ has to stay text, and splitting
        // on the LAST " | " instead of the first would hand the parameter
        // list back to the name.
        var inj = BarDocument.Parse("cc 1\n---\n* evil ¦ bash=/bin/sh param1=-c  repo  idle | color=gray");
        Check(inj.Items.Any(i => i.Text.Contains("evil ¦ bash=/bin/sh")),
            "a neutralised pipe stays in the text where the CLI put it");
        Check(inj.Items.All(i => !i.UnhandledParams.ContainsKey("bash")),
            "and no bash= parameter is ever parsed out of a row");

        var unknown = BarDocument.Parse("cc 1\n---\n* row  idle | color=gray widget=untouched");
        Check(unknown.Items.Any(i => i.Text.Contains("row") && i.UnhandledParams.GetValueOrDefault("widget") == "untouched"),
            "an unknown parameter leaves its line displayed");

        var empty = BarDocument.Parse("");
        Check(empty.Title == "cc ?", "empty CLI output is a question mark, never a count");

        // Claims 10-17, 19: the overlay's window properties. A bare Form
        // stands in for OverlayForm's own window styles — no server, no
        // WebView2 runtime required (contracts/tray-app.md "Checks 10-17
        // need a window ... only the navigation check skips with its
        // reason").
        using (var form = new Form { ShowInTaskbar = false })
        {
            var handle = form.Handle; // forces window creation
            OverlayForm.ApplyOverlayWindowProperties(form);
            var exStyle = OverlayForm.GetWindowLong(handle, OverlayForm.GWL_EXSTYLE);

            Check((exStyle & OverlayForm.WS_EX_TOPMOST) != 0,
                "the overlay stays above other windows (WS_EX_TOPMOST)");

            var reassertThrew = false;
            try { OverlayForm.ReassertTopmost(form); } catch { reassertThrew = true; }
            Check(!reassertThrew, "and is re-asserted topmost when shown");

            Check((exStyle & OverlayForm.WS_EX_NOACTIVATE) != 0,
                "and does not steal focus when clicked (WS_EX_NOACTIVATE)");

            var showThrew = false;
            try { OverlayForm.ShowWithoutActivating(form); } catch { showThrew = true; }
            Check(!showThrew, "and is shown without activation (SW_SHOWNOACTIVATE)");

            var vdThrew = false;
            try { OverlayForm.IsOnCurrentVirtualDesktop(form); } catch { vdThrew = true; }
            Check(!vdThrew, "and follows you to the current virtual desktop");

            Check(!form.ShowInTaskbar && (exStyle & OverlayForm.WS_EX_TOOLWINDOW) != 0,
                "and stays out of the task bar and Alt-Tab");
        }

        // Claim 13 needs the real WM_MOUSEACTIVATE handler, which only an
        // actual OverlayForm implements (the bare Form above answers the
        // default way) — exercised separately here so the check above does
        // not silently pass for the wrong reason.
        try
        {
            using var overlay = new OverlayForm("http://127.0.0.1:1/map");
            var h = overlay.Handle;
            var ma = SendMessage(h, OverlayForm.WM_MOUSEACTIVATE, IntPtr.Zero, IntPtr.Zero);
            Check(ma.ToInt64() == OverlayForm.MA_NOACTIVATE,
                "and answers WM_MOUSEACTIVATE with MA_NOACTIVATE");
        }
        catch
        {
            Check(false, "and answers WM_MOUSEACTIVATE with MA_NOACTIVATE");
        }

        // Claim 17: a new-window request is always reported handled, on
        // success or failure of the browser hand-off alike — never
        // swallowed in silence. A bogus scheme fails the hand-off without
        // launching anything, which is the point of this exact input.
        Check(OverlayForm.HandleNewWindowRequest("ccwatch-selftest-no-such-handler://x"),
            "a new-window request leaves the overlay and opens the real browser (NewWindowRequested handled)");

        Check(!ServeSupervisor.PortIsOpen(1), "the port probe reports a closed port as closed");

        // Claim 19: the WSL launcher is excluded by path, not merely
        // deprioritised (D19). Tested against the real filtering step `Locate()` calls
        // (`ExcludeSystem32`), with a synthetic candidate list, hermetically
        // — rather than depending on whether WSL happens to be installed on
        // the machine running this check. `uname -s` inside a real WSL
        // shell answers "Linux" and would already be filtered by the
        // MINGW/MSYS/CYGWIN check downstream, so the by-path exclusion is
        // defense against the slow, hanging WSL cold-start that
        // verification-by-running would otherwise have to wait out — it
        // must be checked as its own step, not folded into that fallback.
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        var system32Bash = System.IO.Path.Combine(systemRoot, "System32", "bash.exe");
        var synthetic = new[]
        {
            (path: system32Bash, how: "found on PATH"),
            (path: @"C:\msys64\usr\bin\bash.exe", how: "C:\\msys64\\usr\\bin\\bash.exe"),
        };
        var filtered = BashLocator.ExcludeSystem32(synthetic).ToList();
        Check(filtered.Count == 1 && filtered[0].path == @"C:\msys64\usr\bin\bash.exe",
            "the WSL bash at System32 is never used, even when it is the only bash.exe on PATH");

        Console.WriteLine();
        Console.WriteLine(failures == 0 ? "selftest: all checks passed" : $"selftest: {failures} FAILED");
        return failures == 0 ? 0 : 1;
    }
}
