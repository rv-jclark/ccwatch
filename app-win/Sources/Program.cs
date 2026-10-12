// ccwatch-tray — the Windows taskbar tray and always-on-top overlay.
//
// Mirrors app/'s arrangement: this holds no judgement of its own. It parses
// `ccwatch bar --no-actions` and renders it, and adds only verbs (principle
// XI in CLAUDE.md). See specs/006-windows-tray-overlay/ for the design.
//
// ⚠️ NOTHING HERE DECIDES ANYTHING ABOUT A SESSION. Every verdict, threshold,
// count and word comes from `ccwatch bar --no-actions`. Two renderings that
// compute "is anything stuck" separately will eventually disagree — see
// contracts/bar-document.md and contracts/tray-app.md.

using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text;
using Microsoft.Win32;

namespace CCWatch.Tray;

// MARK: - the document `ccwatch bar` prints

/// One line of the menu, as the CLI described it.
internal sealed class BarItem
{
    public string Text { get; set; } = "";
    public bool IsSeparator { get; set; }
    public string? Color { get; set; }
    public double? Size { get; set; }
    public bool Monospaced { get; set; }

    /// Anything this app does not implement is kept and shown as plain text
    /// rather than dropped (bar-document.md rule 2) — a future CLI item
    /// silently vanishing from the menu would be a failure that looks like
    /// an absence.
    public Dictionary<string, string> UnhandledParams { get; set; } = new();
}

internal sealed class BarDocument
{
    public string Title { get; init; } = "cc ?";
    public string? TitleColor { get; init; }
    public List<BarItem> Items { get; init; } = new();

    /// The plugin format: line 0 is the title, `---` opens/splits the menu,
    /// and ` | ` separates an item's text from `key=value` parameters.
    ///
    /// ⚠️ Split on the FIRST ` | ` only (bar-document.md rule 1). `ccwatch
    /// bar` strips pipes out of every interpolated field precisely so that
    /// exactly one separator can appear per line — a session named `a|b`
    /// arrives as `a¦b`. Splitting on the last one instead would hand an
    /// attacker-shaped name the parameter list back, and this app parses no
    /// `bash=` parameter at all regardless.
    public static BarDocument Parse(string text)
    {
        var lines = new List<string>(text.Replace("\r\n", "\n").Split('\n'));
        while (lines.Count > 0 && lines[^1].Trim().Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }
        if (lines.Count == 0)
        {
            return new BarDocument { Title = "cc ?", TitleColor = null, Items = new List<BarItem>() };
        }

        var (titleText, titleParams) = Split(lines[0]);
        var items = new List<BarItem>();
        for (int i = 1; i < lines.Count; i++)
        {
            var raw = lines[i];
            if (raw.Trim() == "---")
            {
                items.Add(new BarItem { IsSeparator = true });
                continue;
            }
            if (raw.Trim().Length == 0) continue;

            var (t, parms) = Split(raw);
            var item = new BarItem { Text = t };
            if (parms.TryGetValue("color", out var c)) { item.Color = c; parms.Remove("color"); }
            if (parms.TryGetValue("size", out var s) && double.TryParse(s, out var sv))
            {
                item.Size = sv;
                parms.Remove("size");
            }
            if (parms.TryGetValue("font", out var f))
            {
                var lower = f.ToLowerInvariant();
                item.Monospaced = lower.Contains("menlo") || lower.Contains("mono");
                parms.Remove("font");
            }
            item.UnhandledParams = parms;
            items.Add(item);
        }
        return new BarDocument { Title = titleText, TitleColor = titleParams.GetValueOrDefault("color"), Items = items };
    }

    private static (string text, Dictionary<string, string> parms) Split(string line)
    {
        var sep = " | ";
        var idx = line.IndexOf(sep, StringComparison.Ordinal);
        if (idx < 0)
        {
            return (line.Trim(), new Dictionary<string, string>());
        }
        var text = line[..idx].Trim();
        var rest = line[(idx + sep.Length)..];
        var parms = new Dictionary<string, string>();
        foreach (var token in Tokenize(rest))
        {
            var eq = token.IndexOf('=');
            if (eq < 0) continue;
            var k = token[..eq];
            var v = token[(eq + 1)..];
            if (v.Length >= 2 && v.StartsWith('"') && v.EndsWith('"'))
            {
                v = v[1..^1];
            }
            parms[k] = v;
        }
        return (text, parms);
    }

    /// Splits on spaces but keeps a double-quoted value with spaces intact
    /// (bar-document.md rule 3), e.g. `param1="two words"`.
    private static IEnumerable<string> Tokenize(string s)
    {
        var tokens = new List<string>();
        var cur = new StringBuilder();
        bool inQuotes = false;
        foreach (var ch in s)
        {
            if (ch == '"') { inQuotes = !inQuotes; cur.Append(ch); continue; }
            if (ch == ' ' && !inQuotes)
            {
                if (cur.Length > 0) { tokens.Add(cur.ToString()); cur.Clear(); }
                continue;
            }
            cur.Append(ch);
        }
        if (cur.Length > 0) tokens.Add(cur.ToString());
        return tokens;
    }
}

// MARK: - finding what this app drives

internal sealed record LocatedBash(string Path, string How);

/// Finds a real MSYS2/Git-Bash interpreter.
///
/// ⚠️ `%SystemRoot%\System32\bash.exe` is excluded BY PATH, not merely
/// deprioritised. It is the WSL launcher, it sits on PATH by default on any
/// machine with WSL installed, and a WSL shell cannot see Windows process
/// ids — so running the CLI through it would produce a confidently empty
/// fleet on a busy machine. That is the worst output this tool can produce,
/// and it would look perfectly healthy through the app. See D19.
internal static class BashLocator
{
    public static IEnumerable<(string path, string how)> Candidates()
    {
        if (!string.IsNullOrEmpty(BuildInfo.BuiltFromBash))
        {
            yield return (BuildInfo.BuiltFromBash, "recorded at build time");
        }
        var gitInstall = ReadRegistryInstallPath();
        if (gitInstall != null)
        {
            yield return (Path.Combine(gitInstall, "bin", "bash.exe"), "HKLM\\SOFTWARE\\GitForWindows\\InstallPath");
        }
        var programFiles = Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";
        yield return (Path.Combine(programFiles, "Git", "bin", "bash.exe"), "%ProgramFiles%\\Git\\bin\\bash.exe");
        yield return (@"C:\msys64\usr\bin\bash.exe", "C:\\msys64\\usr\\bin\\bash.exe");
        var onPath = FindOnPath("bash.exe");
        if (onPath != null) yield return (onPath, "found on PATH");
    }

    private static string? ReadRegistryInstallPath()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\GitForWindows");
            return key?.GetValue("InstallPath") as string;
        }
        catch
        {
            return null;
        }
    }

    private static string? FindOnPath(string exe)
    {
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (dir.Length == 0) continue;
            try
            {
                var candidate = Path.Combine(dir, exe);
                if (File.Exists(candidate)) return candidate;
            }
            catch
            {
                // malformed PATH entry — skip it
            }
        }
        return null;
    }

    /// Excluded by path — the WSL launcher, never a valid candidate. Exposed
    /// so the selftest can assert this predicate directly against the real
    /// `%SystemRoot%\System32\bash.exe` path, rather than depending on
    /// whether WSL happens to be installed on the machine running the check
    /// (D19's "excluded by path, not merely deprioritised").
    internal static bool IsSystem32Bash(string path)
    {
        var systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ?? @"C:\Windows";
        var system32Bash = Path.Combine(systemRoot, "System32", "bash.exe");
        try
        {
            return string.Equals(Path.GetFullPath(path), Path.GetFullPath(system32Bash),
                StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }

    /// The System32 exclusion applied to a candidate list, extracted so the
    /// selftest can assert the filtering behaviour `Locate()` relies on
    /// directly, with a synthetic candidate list — no dependence on whether
    /// WSL happens to be installed on the machine running the check.
    internal static IEnumerable<(string path, string how)> ExcludeSystem32(
        IEnumerable<(string path, string how)> candidates)
        => candidates.Where(c => !IsSystem32Bash(c.path));

    /// Runs each candidate's `uname -s` and accepts only MINGW*/MSYS*/CYGWIN*
    /// (D19) — verification by running it, never by trusting that the file
    /// exists.
    public static LocatedBash? Locate()
    {
        foreach (var (path, how) in ExcludeSystem32(Candidates()))
        {
            if (!File.Exists(path)) continue;
            var uname = RunCaptureStdout(path, "-c \"uname -s\"", 5000);
            if (uname == null) continue;
            var trimmed = uname.Trim();
            if (trimmed.StartsWith("MINGW", StringComparison.Ordinal)
                || trimmed.StartsWith("MSYS", StringComparison.Ordinal)
                || trimmed.StartsWith("CYGWIN", StringComparison.Ordinal))
            {
                return new LocatedBash(path, how);
            }
        }
        return null;
    }

    public static string? RunCaptureStdout(string exe, string arguments, int timeoutMs)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = exe,
                Arguments = arguments,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // ⚠️ UTF-8, stated. Without this .NET decodes the child's
                // output with the console's ANSI code page, and `ccwatch bar`
                // speaks UTF-8: the `·` separator (U+00B7) arrived as `Â·` and
                // the em dash as `â€”`, so the menu filled with stray
                // characters while the CLI printing it was perfectly correct.
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var stdout = new StringBuilder();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) stdout.AppendLine(e.Data); };
            p.BeginOutputReadLine();
            p.WaitForExit(timeoutMs);
            if (!p.HasExited)
            {
                p.Kill(true);
                return null;
            }
            return stdout.ToString();
        }
        catch
        {
            return null;
        }
    }
}

internal sealed record LocatedCli(string Path, string Version, string How);

/// Finds the `ccwatch` script itself, verified the same way `ccwatch setup`
/// verifies its own symlink: RUN it and check the answer, because a symlink
/// that exists proves nothing — it can point at a moved checkout or a file
/// that lost its executable bit.
internal static class CliLocator
{
    public static IEnumerable<(string path, string how)> Candidates()
    {
        if (!string.IsNullOrEmpty(BuildInfo.BuiltFromScript))
        {
            yield return (BuildInfo.BuiltFromScript, "recorded at build time");
        }
        var userProfile = Environment.GetEnvironmentVariable("USERPROFILE") ?? "";
        if (userProfile.Length > 0)
        {
            yield return (Path.Combine(userProfile, ".local", "bin", "ccwatch"), "found in ~/.local/bin");
        }
        var localAppData = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "";
        if (localAppData.Length > 0)
        {
            yield return (Path.Combine(localAppData, "Programs", "ccwatch", "ccwatch"), "found in %LOCALAPPDATA%\\Programs\\ccwatch");
        }
    }

    public static LocatedCli? Locate(string bashPath)
    {
        foreach (var (path, how) in Candidates())
        {
            if (!File.Exists(path)) continue;
            var scriptPosix = ToPosixPath(path);
            var output = BashLocator.RunCaptureStdout(bashPath, $"\"{scriptPosix}\" --version", 5000);
            if (output == null) continue;
            var line = output.Trim();
            if (line.StartsWith("ccwatch ", StringComparison.Ordinal))
            {
                return new LocatedCli(path, line, how);
            }
        }
        return null;
    }

    /// `C:\Users\x\ccwatch` → `/c/Users/x/ccwatch`, what bash expects — a real
    /// `cygpath -w`/`-u` round trip is the probe layer's job (D5); this app
    /// only needs the one direction to invoke a script bash can read.
    public static string ToPosixPath(string windowsPath)
    {
        var full = Path.GetFullPath(windowsPath);
        if (full.Length >= 2 && full[1] == ':')
        {
            var drive = char.ToLowerInvariant(full[0]);
            return "/" + drive + full[2..].Replace('\\', '/');
        }
        return full.Replace('\\', '/');
    }
}

// MARK: - the serve we supervise

/// Runs `ccwatch serve` and says truthfully what state it is in. Mirrors
/// `app/Sources/main.swift`'s `ServeSupervisor` (FR-026).
///
/// ⚠️ It will not start a second one. Something already listening on the
/// port is most likely a `ccwatch serve` the operator started in a
/// terminal, and killing it or fighting it for the port are both worse than
/// adopting it — so the port is probed first and an existing server is used
/// and LABELLED as not ours.
internal sealed class ServeSupervisor
{
    public enum StateKind { NotStarted, Running, Adopted, Failed }

    public sealed record State(StateKind Kind, int Pid = 0, string Reason = "");

    private readonly string _bashPath;
    private readonly string _scriptPath;
    private readonly int _port;
    private Process? _process;
    private string _lastStderr = "";
    private int _restarts;

    public State Current { get; private set; } = new(StateKind.NotStarted);
    public event Action? OnChange;

    public ServeSupervisor(string bashPath, string scriptPath, int port)
    {
        _bashPath = bashPath;
        _scriptPath = scriptPath;
        _port = port;
    }

    /// A loopback connect to a closed port is refused immediately, so there
    /// is nothing to time out. The CLI probes with /dev/tcp for the same
    /// reason.
    public static bool PortIsOpen(int port)
    {
        try
        {
            using var client = new TcpClient();
            var task = client.ConnectAsync("127.0.0.1", port);
            return task.Wait(500) && client.Connected;
        }
        catch
        {
            return false;
        }
    }

    public void Start()
    {
        if (PortIsOpen(_port))
        {
            Current = new State(StateKind.Adopted);
            OnChange?.Invoke();
            return;
        }
        var psi = new ProcessStartInfo
        {
            FileName = _bashPath,
            Arguments = $"\"{CliLocator.ToPosixPath(_scriptPath)}\" serve --port {_port}",
            UseShellExecute = false,
            CreateNoWindow = true,
            // stdout is not redirected: nothing here reads it, and a
            // redirected pipe nobody drains is the same full-buffer deadlock
            // the CLI invocation (RunBar) is careful to avoid.
            RedirectStandardError = true,
        };
        psi.EnvironmentVariables["NO_COLOR"] = "1";

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrEmpty(e.Data)) _lastStderr = e.Data;
        };
        p.Exited += (_, _) => ChildExited(p);
        try
        {
            p.Start();
            p.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            Current = new State(StateKind.Failed, Reason: $"could not run {_bashPath}: {ex.Message}");
            OnChange?.Invoke();
            return;
        }
        _process = p;
        Current = new State(StateKind.Running, Pid: p.Id);
        OnChange?.Invoke();
    }

    private void ChildExited(Process proc)
    {
        _process = null;
        if (Current.Kind != StateKind.Running) return; // a deliberate stop
        var exitCode = SafeExitCode(proc);
        var why = string.IsNullOrEmpty(_lastStderr)
            ? $"exited {exitCode}"
            : $"exited {exitCode}: {_lastStderr}";
        // ⚠️ Bounded restarts (FR-026) — a serve that cannot bind would
        // otherwise be respawned forever while the menu cheerfully reports
        // "running".
        if (_restarts < 3)
        {
            _restarts++;
            Current = new State(StateKind.Failed, Reason: $"{why} — restarting ({_restarts}/3)");
            OnChange?.Invoke();
            _ = Task.Delay(2000).ContinueWith(_ => Start());
        }
        else
        {
            Current = new State(StateKind.Failed, Reason: $"{why} — gave up after 3 restarts");
            OnChange?.Invoke();
        }
    }

    private static int SafeExitCode(Process p)
    {
        try { return p.ExitCode; } catch { return -1; }
    }

    /// Reaps a server this app started, on quit (FR-026). This repository has
    /// already paid once for leaking these: 1686 orphaned servers, ~5GB.
    public void Stop()
    {
        var p = _process;
        if (p == null) return;
        Current = new State(StateKind.NotStarted);
        _process = null;
        try
        {
            p.Kill(true);
            p.WaitForExit(3000);
        }
        catch
        {
            // already gone
        }
    }

    public string Summary => Current.Kind switch
    {
        StateKind.NotStarted => "serve: not running",
        StateKind.Running => $"serve: running (pid {Current.Pid})",
        StateKind.Adopted => $"serve: already running on {_port} — not started by this app",
        StateKind.Failed => $"serve: {Current.Reason}",
        _ => "serve: unknown",
    };
}

// MARK: - the tray surface

internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly int _port;
    private readonly double _refreshSeconds;
    private readonly System.Windows.Forms.Timer _timer;
    private readonly object _renderLock = new();

    /// A parentless, never-shown control whose only job is to own a window
    /// handle on the UI thread, so work arriving from elsewhere can be posted
    /// back to it. See OnUiThread.
    private readonly Control _marshal;

    /// 0 idle, 1 a snapshot is in flight. See RefreshNow.
    private int _refreshInFlight;

    private LocatedBash? _bash;
    private LocatedCli? _cli;
    private ServeSupervisor? _serve;
    private BarDocument _doc = new() { Title = "cc …" };
    private OverlayForm? _overlay;

    public TrayContext()
    {
        // ⚠️ FIRST, and on this thread, because this constructor runs on the
        // UI thread and `.Handle` is what pins the handle to it. Everything
        // below marshals through it.
        _marshal = new Control();
        _ = _marshal.Handle;

        _port = int.TryParse(Environment.GetEnvironmentVariable("CCWATCH_PORT"), out var p) ? p : 8787;
        _refreshSeconds = double.TryParse(Environment.GetEnvironmentVariable("CCWATCH_BAR_REFRESH"), out var r) ? r : 10;

        _icon = new NotifyIcon
        {
            Text = "ccwatch",
            Visible = true,
            Icon = TrayGlyph.For(null),
            ContextMenuStrip = new ContextMenuStrip(),
        };

        _bash = BashLocator.Locate();
        _cli = _bash != null ? CliLocator.Locate(_bash.Path) : null;
        if (_bash != null && _cli != null)
        {
            _serve = new ServeSupervisor(_bash.Path, _cli.Path, _port);
            _serve.OnChange += () => RebuildMenu();
            _serve.Start();
        }

        RefreshNow();
        // Same cadence as the macOS app and the plugin, and for the same
        // reason: a snapshot walks the transcript tree, so a repaint nobody
        // is watching is not worth it every few seconds.
        _timer = new System.Windows.Forms.Timer { Interval = (int)(_refreshSeconds * 1000) };
        _timer.Tick += (_, _) => RefreshNow();
        _timer.Start();

        RebuildMenu();
    }

    private void RefreshNow()
    {
        if (_bash == null || _cli == null)
        {
            // ⚠️ Not "cc 0". "I cannot find ccwatch/bash" and "nothing is
            // running" are different facts, and the tray is where they look
            // identical: both are a calm item with nothing under it.
            _doc = new BarDocument
            {
                Title = "cc !",
                Items = new List<BarItem>
                {
                    new() { Text = "ccwatch or a Git-Bash interpreter was not found", Color = "red" },
                    new() { Text = "Looked for bash (Git for Windows / MSYS2 / PATH) and the ccwatch script "
                                   + "in ~/.local/bin and %LOCALAPPDATA%\\Programs\\ccwatch.", Size = 11 },
                },
            };
            Render();
            return;
        }
        var bash = _bash;
        var cli = _cli;

        // ⚠️ ONE snapshot at a time. The timer fires every CCWATCH_BAR_REFRESH
        // seconds (10 by default) and `ccwatch bar` walks the whole transcript
        // tree, so on a loaded machine it can take far longer than the gap
        // between ticks -- measured at 170 SECONDS here while the test suite
        // was running, against a 10s timer. Without this guard that is
        // seventeen overlapping snapshots, each spawning bash, jq and python,
        // all of them finishing into the same Render: the tray stops
        // responding and Windows eventually kills it with AppHangB1. The
        // RunBar timeout is 120s, which is itself longer than the interval, so
        // overlap was not an edge case but the design.
        //
        // A tick that arrives while one is running is DROPPED, not queued: the
        // next one is a fresh snapshot anyway, and a queue of stale ones is
        // the pile-up by another name.
        if (Interlocked.CompareExchange(ref _refreshInFlight, 1, 0) != 0) { return; }
        Task.Run(() =>
        {
            try
            {
            var env = new Dictionary<string, string> { ["NO_COLOR"] = "1", ["CCWATCH_PORT"] = _port.ToString() };
            var output = RunBar(bash.Path, cli.Path, env, 120_000);
            var doc = string.IsNullOrWhiteSpace(output)
                ? new BarDocument
                {
                    Title = "cc ?",
                    Items = new List<BarItem>
                    {
                        new() { Text = "ccwatch could not read the sessions", Color = "red" },
                        new() { Text = "This is NOT \"nothing is running\" — the snapshot itself failed.", Size = 11 },
                    },
                }
                : BarDocument.Parse(output);
            lock (_renderLock) { _doc = doc; }
            Render();
            }
            finally { Interlocked.Exchange(ref _refreshInFlight, 0); }
        });
    }

    /// `<bash> <script> bar --no-actions`, reading stdout as it fills — a
    /// child that blocks on a full pipe buffer while the parent waits for
    /// exit is a deadlock, not a slow command (tray-app.md "Invoking the
    /// CLI").
    private static string? RunBar(string bashPath, string scriptPath, Dictionary<string, string> env, int timeoutMs)
    {
        try
        {
            var scriptPosix = CliLocator.ToPosixPath(scriptPath);
            var psi = new ProcessStartInfo
            {
                FileName = bashPath,
                Arguments = $"\"{scriptPosix}\" bar --no-actions",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                // ⚠️ UTF-8, stated. Without this .NET decodes the child's
                // output with the console's ANSI code page, and `ccwatch bar`
                // speaks UTF-8: the `·` separator (U+00B7) arrived as `Â·` and
                // the em dash as `â€”`, so the menu filled with stray
                // characters while the CLI printing it was perfectly correct.
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false),
            };
            foreach (var (k, v) in env) psi.EnvironmentVariables[k] = v;
            using var p = Process.Start(psi);
            if (p == null) return null;
            var stdout = new StringBuilder();
            p.OutputDataReceived += (_, e) => { if (e.Data != null) { lock (stdout) { stdout.AppendLine(e.Data); } } };
            p.BeginOutputReadLine();
            if (!p.WaitForExit(timeoutMs))
            {
                p.Kill(true);
                return null;
            }
            return stdout.ToString();
        }
        catch
        {
            return null;
        }
    }

    /// Run <paramref name="action"/> on the UI thread, posting it there if we
    /// are not already on it.
    ///
    /// ⚠️ Windows killed this app with AppHangB1 — "stopped interacting with
    /// Windows" — and the cause was touching UI objects from the wrong thread.
    /// `RefreshNow` does its subprocess work on a thread-pool thread, which is
    /// right, and then called `Render` straight from it, which is not:
    /// `RebuildMenu` mutates a ContextMenuStrip, and a ContextMenuStrip is a
    /// Control. `ServeSupervisor.OnChange` did the same from its own monitor
    /// thread. Mutating a Control's items while the UI thread is painting them
    /// is a deadlock waiting for a slow enough tick, and a tray that polls a
    /// subprocess every ten seconds eventually finds one.
    ///
    /// It was always latent; it started biting when the icon began carrying
    /// severity, because that added GDI work — bitmap, Graphics, GetHicon — to
    /// the same wrong thread.
    ///
    /// BeginInvoke, not Invoke: the worker has nothing to wait for, and making
    /// it wait on the UI thread is how the other half of a deadlock is built.
    private void OnUiThread(Action action)
    {
        if (_marshal.IsHandleCreated && _marshal.InvokeRequired)
        {
            try { _marshal.BeginInvoke(action); }
            catch (ObjectDisposedException) { /* quitting; nothing to repaint */ }
            catch (InvalidOperationException) { /* handle gone; same */ }
            return;
        }
        action();
    }

    private void Render()
    {
        if (_marshal.IsHandleCreated && _marshal.InvokeRequired) { OnUiThread(Render); return; }
        BarDocument doc;
        lock (_renderLock) { doc = _doc; }
        _icon.Text = Truncate(doc.Title, 127); // NotifyIcon.Text is capped at 127 chars
        // The tint is ccwatch's own verdict, not one recomputed here: `bar`
        // puts a colour on the title line only when something wants a person
        // (principle XI). The words are already in the tooltip and the menu,
        // so this is decoration on top of them, never the carrier of the
        // meaning (principle VII).
        _icon.Icon = TrayGlyph.For(doc.TitleColor);
        RebuildMenu();
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max];

    private void RebuildMenu()
    {
        // Reached directly from ServeSupervisor.OnChange, which fires on its
        // own thread — so this guards itself rather than trusting its callers.
        if (_marshal.IsHandleCreated && _marshal.InvokeRequired) { OnUiThread(RebuildMenu); return; }
        var menu = _icon.ContextMenuStrip!;
        menu.Items.Clear();

        BarDocument doc;
        lock (_renderLock) { doc = _doc; }

        foreach (var item in doc.Items)
        {
            if (item.IsSeparator)
            {
                menu.Items.Add(new ToolStripSeparator());
                continue;
            }
            var mi = new ToolStripMenuItem(item.Text) { Enabled = false };
            if (item.Monospaced) mi.Font = new Font(FontFamily.GenericMonospace, (float)(item.Size ?? 9));
            else if (item.Size.HasValue) mi.Font = new Font(mi.Font.FontFamily, (float)item.Size.Value);
            if (Colors.TryParse(item.Color, out var color)) mi.ForeColor = color;
            menu.Items.Add(mi);
        }

        menu.Items.Add(new ToolStripSeparator());
        var showHide = new ToolStripMenuItem(_overlay is { Visible: true } ? "Hide Overlay" : "Show Overlay");
        showHide.Click += (_, _) => ToggleOverlay();
        menu.Items.Add(showHide);

        var openDashboard = new ToolStripMenuItem("Open Dashboard in Browser");
        openDashboard.Click += (_, _) => OpenInBrowser($"http://127.0.0.1:{_port}/");
        menu.Items.Add(openDashboard);

        var sid = doc.Items.Select(i => i.UnhandledParams.GetValueOrDefault("sid")).FirstOrDefault(v => v != null);
        if (sid != null)
        {
            var openAgent = new ToolStripMenuItem("Open Agent in Browser");
            openAgent.Click += (_, _) => OpenInBrowser($"http://127.0.0.1:{_port}/map?sid={sid}");
            menu.Items.Add(openAgent);
        }

        menu.Items.Add(new ToolStripSeparator());
        var serveLine = new ToolStripMenuItem(_serve?.Summary ?? "serve: no ccwatch found") { Enabled = false };
        menu.Items.Add(serveLine);
        if (_serve != null)
        {
            var restart = new ToolStripMenuItem("Restart serve");
            restart.Click += (_, _) => { _serve?.Stop(); _serve?.Start(); };
            menu.Items.Add(restart);
        }

        menu.Items.Add(new ToolStripSeparator());
        // Not offered at all on Windows: send, kill, peer messaging (D23).
        // Stated, not omitted — absent from the UI would read as never built.
        menu.Items.Add(new ToolStripMenuItem(
            "send / kill / peers: unavailable on Windows (need POSIX signals and a Unix socket)")
        { Enabled = false });

        if (_bash != null)
        {
            menu.Items.Add(new ToolStripMenuItem($"bash: {_bash.Path} ({_bash.How})") { Enabled = false });
        }
        if (_cli != null)
        {
            menu.Items.Add(new ToolStripMenuItem($"{_cli.Version} — {_cli.How}") { Enabled = false });
        }

        menu.Items.Add(new ToolStripSeparator());
        var quit = new ToolStripMenuItem("Quit");
        quit.Click += (_, _) => Quit();
        menu.Items.Add(quit);
    }

    private void ToggleOverlay()
    {
        if (_overlay is { Visible: true })
        {
            _overlay.Hide();
            RebuildMenu();
            return;
        }
        _overlay ??= new OverlayForm($"http://127.0.0.1:{_port}/map", () => ServeSupervisor.PortIsOpen(_port));
        _overlay.Present();
        RebuildMenu();
    }

    private static void OpenInBrowser(string url)
    {
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }

    private void Quit()
    {
        _timer.Stop();
        _serve?.Stop();
        _icon.Visible = false;
        _icon.Dispose();
        _marshal.Dispose();
        ExitThread();
    }
}

/// Named colours, `#rrggbb`, and SwiftBar's `light,dark` pair
/// (bar-document.md). An unparseable value returns false and the caller
/// keeps the default colour — losing an emphasis, never a word.
/// The tray icon: a `cc` monogram, tinted by the title colour `ccwatch bar`
/// supplies.
///
/// Drawn rather than shipped as an .ico so there is no binary in the tree and
/// no csproj resource plumbing for one 32px mark. Icons are CACHED per colour:
/// Render() runs every few seconds, `Icon.FromHandle` takes an unmanaged HICON,
/// and making a fresh one each tick would leak a GDI handle every time. The
/// set of colours is tiny and fixed (none, blocked-on-you, suspect), so the
/// cache is bounded and its icons live as long as the process does.
internal static class TrayGlyph
{
    private static readonly Dictionary<string, Icon> Cache = new();

    /// Calm. Light enough to read on a dark taskbar, dark enough on a light one.
    private static readonly Color Neutral = Color.FromArgb(0xC8, 0xD2, 0xDC);

    public static Icon For(string? colorSpec)
    {
        var key = colorSpec ?? "";
        lock (Cache)
        {
            if (Cache.TryGetValue(key, out var cached)) return cached;
            var tint = Colors.TryParse(colorSpec, out var c) ? c : Neutral;
            var icon = Draw(tint);
            Cache[key] = icon;
            return icon;
        }
    }

    private static Icon Draw(Color tint)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
            g.Clear(Color.Transparent);

            // ⚠️ A FILLED disc with the letter knocked out of it, and ONE
            // letter, not two. Windows draws this at 16x16, and the obvious
            // designs do not survive that: `cc` inside a ring turns to mush
            // (the two letters merge into a grey smudge), and a ring with no
            // letter reads as a generic record button. Rendered side by side
            // at the real 16px before choosing -- the solid disc is the only
            // one that stays crisp, and it carries the severity tint across
            // its whole area instead of in a 3px outline, so `blocked on you`
            // is visible at a glance rather than on inspection.
            using (var disc = new SolidBrush(tint))
            {
                g.FillEllipse(disc, 1f, 1f, 30f, 30f);
            }
            using (var knockout = new SolidBrush(Color.FromArgb(0x16, 0x18, 0x1C)))
            using (var font = new Font("Segoe UI", 22f, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var fmt = new StringFormat
                   {
                       Alignment = StringAlignment.Center,
                       LineAlignment = StringAlignment.Center,
                   })
            {
                g.DrawString("c", font, knockout, new RectangleF(0f, 0f, 32f, 32f), fmt);
            }
        }

        var handle = bmp.GetHicon();
        return Icon.FromHandle(handle);
    }
}

internal static class Colors
{
    public static bool TryParse(string? spec, out Color color)
    {
        color = Color.Empty;
        if (string.IsNullOrEmpty(spec)) return false;
        if (spec.Contains(','))
        {
            var parts = spec.Split(',');
            // Windows theme detection is a later concern; the light half is
            // the safe default when only one is asked for.
            return TryParse(parts[0], out color);
        }
        if (spec.StartsWith('#'))
        {
            var hex = spec[1..];
            if (hex.Length == 3) hex = string.Concat(hex.Select(c => $"{c}{c}"));
            if (hex.Length != 6 || !int.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var v))
            {
                return false;
            }
            color = Color.FromArgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
            return true;
        }
        switch (spec)
        {
            case "red": color = Color.Red; return true;
            case "orange": color = Color.DarkOrange; return true;
            case "green": color = Color.Green; return true;
            case "purple": color = Color.Purple; return true;
            case "teal": color = Color.Teal; return true;
            case "pink": color = Color.HotPink; return true;
            case "gray":
            case "grey": color = Color.Gray; return true;
            default: return false;
        }
    }
}

// MARK: - entry point

internal static class Program
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int dwProcessId);

    private const int AttachParentProcess = -1;

    /// <summary>
    /// Put stdout back on the terminal that launched us.
    /// </summary>
    /// <remarks>
    /// ⚠️ This project is a WinExe, which starts with NO console attached, so
    /// every Console.WriteLine in Selftest goes nowhere. `--selftest` ran, and
    /// exited with the right code, while printing absolutely nothing - and
    /// tests/run.sh asserts on the TEXT of specific claims, not on the exit
    /// code, precisely so that a selftest cannot pass by saying nothing. So an
    /// unreadable selftest is the same failure as no selftest at all.
    ///
    /// Attaching is not enough on its own: .NET resolves Console.Out once, at
    /// first use, and a WinExe resolves it to a sink that discards. It has to
    /// be replaced afterwards, which is what the SetOut below is for. Both
    /// steps fail harmlessly when there is genuinely no parent console (double
    /// -clicked from Explorer), which is why neither is checked.
    /// </remarks>
    private static void AttachToParentConsole()
    {
        // Only when stdout is NOT already going somewhere. AttachConsole
        // re-points the standard handles at the console it attaches to, so
        // calling it when the caller has redirected us sends the output to the
        // terminal and leaves the caller's pipe empty -- which is exactly how
        // tests/run.sh reads this (`$("$WINBIN" --selftest 2>&1)`), and it saw
        // nothing while the same command with `> file` worked by hand.
        if (Console.IsOutputRedirected)
        {
            // ⚠️ Redirected, so there is no console to attach to — but the
            // default writer still encodes with the console code page, and
            // that cannot represent the ✓ and ✗ the selftest prints: BOTH
            // arrive as a bare '?', which makes a pass and a failure
            // indistinguishable in any captured output. Say UTF-8.
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });
            return;
        }

        if (!AttachConsole(AttachParentProcess))
        {
            return;
        }

        var stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };
        Console.SetOut(stdout);
        var stderr = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true };
        Console.SetError(stderr);
    }

    [STAThread]
    private static void Main(string[] args)
    {
        if (args.Contains("--selftest"))
        {
            AttachToParentConsole();
            Environment.Exit(Selftest.Run());
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}
