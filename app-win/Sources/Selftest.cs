// `--selftest` — exercises the real parser and prints what it checked
// (contracts/tray-app.md "--selftest"). tests/run.sh asserts on the text of
// specific claims, not merely on the summary line, because a selftest that
// quietly stopped checking one property would still say "all checks
// passed".
//
// Claims 1-9 here are US2's (the bar document). Claims 10-20, covering the
// overlay's window properties, are added in US3 — see tasks.md T067.

namespace CCWatch.Tray;

internal static class Selftest
{
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

        Check(!ServeSupervisor.PortIsOpen(1), "the port probe reports a closed port as closed");

        Console.WriteLine();
        Console.WriteLine(failures == 0 ? "selftest: all checks passed" : $"selftest: {failures} FAILED");
        return failures == 0 ? 0 : 1;
    }
}
