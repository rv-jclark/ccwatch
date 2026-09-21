// The always-on-top overlay, hosting the same `/map` the browser is served.
//
// This file starts as a plain WebView2 window (US2's "Show/Hide Overlay"
// verb needs something to toggle). The always-on-top, no-focus-steal,
// virtual-desktop and new-window properties required by US3
// (contracts/tray-app.md "The overlay") are added on top of this shell —
// see specs/006-windows-tray-overlay/tasks.md T058-T067.

using Microsoft.Web.WebView2.WinForms;

namespace CCWatch.Tray;

internal sealed class OverlayForm : Form
{
    private readonly WebView2 _webView;
    private readonly string _url;

    public OverlayForm(string url)
    {
        _url = url;
        Text = "ccwatch";
        Width = 460;
        Height = 620;
        StartPosition = FormStartPosition.Manual;
        Location = new Point(80, 120);
        ShowInTaskbar = false;

        _webView = new WebView2 { Dock = DockStyle.Fill };
        Controls.Add(_webView);
        _ = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            await _webView.EnsureCoreWebView2Async();
            _webView.CoreWebView2.Navigate(_url);
        }
        catch
        {
            // The WebView2 runtime is absent, or the port answers nothing.
            // T065 (US3) turns this into the stated "server not answering"
            // message rather than a blank pane.
        }
    }

    /// Reloaded on show rather than left running hidden: `serve` stops
    /// collecting 15s after the last read of /api/state, so a hidden
    /// overlay holding the feed open would keep the collector awake for
    /// nothing (tray-app.md "reloads on show").
    public void Present()
    {
        try
        {
            _webView.CoreWebView2?.Navigate(_url);
        }
        catch
        {
            // ignored — EnsureCoreWebView2Async may still be pending
        }
        Show();
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(value);
    }
}
