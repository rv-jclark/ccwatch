// The always-on-top overlay, hosting the same `/map` the browser is served.
//
// contracts/tray-app.md "The overlay" (FR-023-FR-025, D20). Six properties,
// each with its own Win32 mechanism because there is no single flag for
// "behave like a HUD": stays on top of a maximised app, follows the current
// virtual desktop, never steals keyboard focus, stays out of the taskbar and
// Alt-Tab, hands a target="_blank" link to the real browser instead of
// swallowing it, and reloads its page each time it is shown rather than
// holding the collector awake while hidden.
//
// ⚠️ Stated limitation (also in app-win/README.md): TopMost covers maximised
// and borderless-fullscreen windows, not exclusive-fullscreen Direct3D
// applications — Windows has no public equivalent of macOS's `.statusBar`
// window level. The undocumented alternatives (SetWindowBand, unpublished
// virtual-desktop pinning interfaces) are rejected because their GUIDs
// change between Windows builds and fail *silently* when they do.

using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.WinForms;

namespace CCWatch.Tray;

internal sealed class OverlayForm : Form
{
    // MARK: - Win32 interop for the properties WinForms has no property for

    internal const int GWL_EXSTYLE = -20;
    internal const int WS_EX_TOPMOST = 0x00000008;
    internal const int WS_EX_NOACTIVATE = 0x08000000;
    internal const int WS_EX_TOOLWINDOW = 0x00000080;

    internal const int WM_MOUSEACTIVATE = 0x0021;
    internal const int MA_NOACTIVATE = 3;

    private const int SW_SHOWNOACTIVATE = 4;

    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private const uint SWP_NOMOVE = 0x0002;
    private const uint SWP_NOSIZE = 0x0001;
    private const uint SWP_NOACTIVATE = 0x0010;

    [DllImport("user32.dll")]
    internal static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int x, int y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IVirtualDesktopManager
    {
        int IsWindowOnCurrentVirtualDesktop(IntPtr topLevelWindow, out int onCurrentDesktop);
        int GetWindowDesktopId(IntPtr topLevelWindow, out Guid desktopId);
        int MoveWindowToDesktop(IntPtr topLevelWindow, ref Guid desktopId);
    }

    [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
    private class VirtualDesktopManager
    {
    }

    private readonly WebView2 _webView;
    private readonly string _url;
    private readonly Func<bool>? _portIsOpen;
    private readonly System.Windows.Forms.Timer _topmostTimer;

    /// Applies the always-on-top, no-focus, virtual-desktop-follow and
    /// taskbar/Alt-Tab-exclusion window properties. Exposed so the selftest
    /// (claims 10-16) can exercise it on a bare `Form` with no server and no
    /// WebView2 runtime — these are Win32 styles on the host window, not
    /// anything that needs a navigation to have happened.
    public static void ApplyOverlayWindowProperties(Form form)
    {
        var handle = form.Handle;
        var exStyle = GetWindowLong(handle, GWL_EXSTYLE);
        exStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
        SetWindowLong(handle, GWL_EXSTYLE, exStyle);
        form.TopMost = true;
        form.ShowInTaskbar = false;

        // ⚠️ Topmost is set with SetWindowPos, NOT by OR-ing WS_EX_TOPMOST into
        // the extended style. Windows ignores that bit when it arrives through
        // SetWindowLong - the write appears to succeed and the bit is simply
        // not there when you read it back - and `form.TopMost = true` does not
        // supply it either while the form has a handle but has never been
        // shown. The overlay was therefore correct in every visible respect
        // and sat UNDER the window it exists to float over.
        //
        // This is the Windows twin of the NSPanel level on macOS, and it fails
        // the same way: invisibly, until something covers it. It was caught the
        // first run where --selftest's output could be read at all, as
        // `✗ the overlay stays above other windows (WS_EX_TOPMOST)`.
        ReassertTopmost(form);
    }

    /// Re-asserted on show and on foreground change — `WS_EX_TOPMOST` alone
    /// can still be overtaken by another window that also claims topmost, so
    /// the position is nailed back down explicitly (tray-app.md).
    public static void ReassertTopmost(Form form)
    {
        SetWindowPos(form.Handle, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    /// `ShowWindow(SW_SHOWNOACTIVATE)` rather than `.Show()`, so opening the
    /// overlay never steals keyboard focus from whatever the operator was
    /// typing into.
    public static void ShowWithoutActivating(Form form)
    {
        ShowWindow(form.Handle, SW_SHOWNOACTIVATE);
    }

    /// `false` when the API is unavailable (older Windows) rather than
    /// throwing — the overlay still works, it just does not follow desktop
    /// switches.
    public static bool IsOnCurrentVirtualDesktop(Form form)
    {
        try
        {
            var mgr = (IVirtualDesktopManager)new VirtualDesktopManager();
            var hr = mgr.IsWindowOnCurrentVirtualDesktop(form.Handle, out var onCurrent);
            return hr >= 0 && onCurrent != 0;
        }
        catch
        {
            return true;
        }
    }

    public OverlayForm(string url, Func<bool>? portIsOpen = null)
    {
        _url = url;
        _portIsOpen = portIsOpen;
        Text = "ccwatch";
        Width = 460;
        Height = 620;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(80, 120);
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.SizableToolWindow;

        _webView = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(_webView);
        _ = InitializeAsync();

        // Re-asserts topmost on a low-frequency tick while visible — a
        // one-shot re-assert on show is not enough, because another
        // window can claim topmost after us at any point (tray-app.md
        // "re-asserted ... on foreground change").
        _topmostTimer = new System.Windows.Forms.Timer { Interval = 2000 };
        _topmostTimer.Tick += (_, _) => { if (Visible) ReassertTopmost(this); };
        VisibleChanged += (_, _) =>
        {
            if (Visible) _topmostTimer.Start();
            else _topmostTimer.Stop();
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        ApplyOverlayWindowProperties(this);
    }

    /// `WM_MOUSEACTIVATE` → `MA_NOACTIVATE`: clicking the overlay (e.g. to
    /// scroll the map) must never pull keyboard focus away from a terminal
    /// the operator is typing into.
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = new IntPtr(MA_NOACTIVATE);
            return;
        }
        base.WndProc(ref m);
    }

    private async Task InitializeAsync()
    {
        try
        {
            await _webView.EnsureCoreWebView2Async();
            _webView.CoreWebView2.NewWindowRequested += OnNewWindowRequested;
            _webView.CoreWebView2.Navigate(_url);
        }
        catch
        {
            // The WebView2 runtime is absent, or the port answers nothing.
            // ShowNoServerMessage (called from Present) turns this into the
            // stated "server not answering" message rather than a blank pane.
        }
    }

    /// A `target="_blank"` link (or a middle-click) must never be swallowed
    /// in silence — the reader sees a link, clicks it, and nothing happens —
    /// so it is handed to the real browser and marked handled either way.
    ///
    /// Split out from the event handler so the selftest can exercise the
    /// hand-off logic without constructing a real (sealed, native-backed)
    /// `CoreWebView2NewWindowRequestedEventArgs` — it always returns `true`,
    /// on success or failure alike, and the event handler's only job is to
    /// copy that into `e.Handled`.
    internal static bool HandleNewWindowRequest(string uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch
        {
            // The browser hand-off failed; still report handled so
            // WebView2 does not silently swallow the request either way.
        }
        return true;
    }

    private static void OnNewWindowRequested(object? sender,
        Microsoft.Web.WebView2.Core.CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = HandleNewWindowRequest(e.Uri);
    }

    /// Reloaded on show rather than left running hidden: `serve` stops
    /// collecting 15s after the last read of /api/state, so a hidden
    /// overlay holding the feed open would keep the collector awake for
    /// nothing (tray-app.md "reloads on show").
    ///
    /// Opening the overlay with nothing answering on the port says so
    /// plainly rather than presenting an empty map — an empty map presented
    /// as a quiet machine is failure-as-absence (principle IV).
    public void Present()
    {
        if (_portIsOpen != null && !_portIsOpen())
        {
            ShowNoServerMessage();
        }
        else
        {
            try
            {
                _webView.CoreWebView2?.Navigate(_url);
            }
            catch
            {
                // ignored — EnsureCoreWebView2Async may still be pending
            }
        }

        if (!Visible)
        {
            ShowWithoutActivating(this);
        }
        ReassertTopmost(this);
        if (!IsOnCurrentVirtualDesktop(this))
        {
            Hide();
            ShowWithoutActivating(this);
        }
    }

    private void ShowNoServerMessage()
    {
        try
        {
            _webView.CoreWebView2?.NavigateToString(
                "<html><body style=\"font-family:sans-serif;padding:2em\">"
                + "<h2>ccwatch serve is not answering</h2>"
                + "<p>Nothing is listening on this port — this is not the same as "
                + "\"no sessions running\".</p></body></html>");
        }
        catch
        {
            // WebView2 runtime unavailable — the plain Form still shows.
        }
    }
}
