// ccwatch menu bar app.
//
// One process that owns the three surfaces: the menu bar item, an always-on-top
// overlay, and the `ccwatch serve` it supervises. It replaced a SwiftBar plugin,
// which could do the first of those and none of the rest — a plugin is a script
// that prints text on a timer, so it cannot hold a window, cannot own a child
// process, and its menu items can only shell out.
//
// ⚠️ NOTHING HERE DECIDES ANYTHING ABOUT A SESSION. Every verdict, threshold,
// count and word comes from `ccwatch bar --no-actions`, which this parses and
// renders. That is the same rule `/api/state` follows by invoking the CLI
// instead of reimplementing the join: two renderings that compute "is anything
// stuck" separately will eventually disagree, and there is no way to tell which
// one is lying. What this app adds is verbs — show the overlay, open the
// dashboard, restart serve — never a judgement.

import AppKit
import WebKit
import ServiceManagement

// MARK: - finding the CLI

/// Where `ccwatch` is, and how we know.
///
/// ⚠️ `PATH` is not the answer. An app launched from Finder or as a login item
/// inherits a minimal environment — roughly `/usr/bin:/bin:/usr/sbin:/sbin` —
/// not the one your shell has, so `~/.local/bin` (where `ccwatch setup`
/// installs by default) is invisible to it. A plugin hit the same wall with jq
/// and reported it missing on a machine that plainly had it.
///
/// So the search is explicit, and the resolved path is shown in the menu: a
/// tool that cannot say which binary it is driving is one you cannot debug.
struct CLILocator {
    static let defaultsKey = "CCWatchCLIPath"

    struct Found {
        let url: URL
        let version: String
        let how: String
    }

    static func candidates() -> [(URL, String)] {
        var out: [(URL, String)] = []
        let d = UserDefaults.standard
        if let p = d.string(forKey: defaultsKey), !p.isEmpty {
            out.append((URL(fileURLWithPath: p), "set in preferences"))
        }
        // Recorded by build.sh from the checkout it was built in. This is the
        // one that normally wins, and it is why the app must be rebuilt rather
        // than moved if the checkout moves.
        if let p = Bundle.main.object(forInfoDictionaryKey: "CCWatchBuiltFrom") as? String,
           !p.isEmpty {
            out.append((URL(fileURLWithPath: p), "recorded at build time"))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        for d in [home.appendingPathComponent(".local/bin"),
                  URL(fileURLWithPath: "/opt/homebrew/bin"),
                  URL(fileURLWithPath: "/usr/local/bin"),
                  URL(fileURLWithPath: "/usr/bin")] {
            out.append((d.appendingPathComponent("ccwatch"), "found in \(d.path)"))
        }
        return out
    }

    /// Runs each candidate and keeps the first that answers `--version`.
    ///
    /// ⚠️ Executability is not enough to believe. A symlink can point at a moved
    /// checkout or at a file that has lost its executable bit — both happened in
    /// this repository — so the candidate is RUN and its answer checked before it
    /// is trusted. `ccwatch setup` verifies its own symlink the same way.
    static func locate() -> Found? {
        for (url, how) in candidates() {
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            guard let out = run(url, ["--version"], timeout: 5), out.hasPrefix("ccwatch ") else {
                continue
            }
            return Found(url: url, version: out.trimmingCharacters(in: .whitespacesAndNewlines),
                         how: how)
        }
        return nil
    }

    /// Captures stdout, discards stderr, and gives up rather than hanging the
    /// menu. A `snapshot` on a cold 1.7GB transcript tree was measured at 24s
    /// under load, so the timeout is generous and the caller is off the main
    /// thread regardless.
    static func run(_ url: URL, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        // NO_COLOR because this output is parsed, and an escape sequence in the
        // middle of a menu title is not a title.
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        p.environment = env
        do { try p.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        let handle = out.fileHandleForReading
        // Read as it comes: a child that fills the pipe buffer and blocks while
        // we wait for exit is a deadlock, not a slow command.
        while p.isRunning && Date() < deadline {
            data.append(handle.availableData)
        }
        if p.isRunning {
            p.terminate()
            return nil
        }
        data.append(handle.readDataToEndOfFile())
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - the document `ccwatch bar` prints

/// One line of the menu, as the CLI described it.
struct BarItem {
    var text: String
    var isSeparator = false
    var color: String?
    var size: CGFloat?
    var monospaced = false
    /// Anything this app does not implement is kept and shown as plain text
    /// rather than dropped. A future CLI item silently vanishing from the menu
    /// would be a failure that looks like an absence.
    var unhandledParams: [String: String] = [:]
}

struct BarDocument {
    var title: String
    var symbolName: String?
    /// The colour the CLI asked for on the title, if any. An addition to the
    /// words, never the carrier of them — the condition is already spelled out
    /// in the title text.
    var titleColor: String?
    var items: [BarItem]

    /// The plugin format: line 0 is the title, `---` opens/splits the dropdown,
    /// and ` | ` separates an item's text from `key=value` parameters.
    ///
    /// ⚠️ Split on the FIRST ` | ` only. `ccwatch bar` strips pipes out of every
    /// interpolated field precisely so that exactly one separator can appear per
    /// line — a session named `a|b` arrives as `a¦b`. Splitting on the last one
    /// instead would hand an attacker-shaped name the parameter list back.
    static func parse(_ text: String) -> BarDocument {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else {
            return BarDocument(title: "cc ?", symbolName: "questionmark.circle",
                               titleColor: nil, items: [])
        }

        let (titleText, titleParams) = split(lines[0])
        var items: [BarItem] = []
        for raw in lines.dropFirst() {
            if raw.trimmingCharacters(in: .whitespaces) == "---" {
                items.append(BarItem(text: "", isSeparator: true))
                continue
            }
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let (t, params) = split(raw)
            var item = BarItem(text: t)
            var rest = params
            item.color = rest.removeValue(forKey: "color")
            if let s = rest.removeValue(forKey: "size"), let v = Double(s) {
                item.size = CGFloat(v)
            }
            if let f = rest.removeValue(forKey: "font") {
                item.monospaced = f.lowercased().contains("menlo")
                    || f.lowercased().contains("mono")
            }
            item.unhandledParams = rest
            items.append(item)
        }
        return BarDocument(title: titleText,
                           symbolName: titleParams["sfimage"],
                           titleColor: titleParams["color"],
                           items: items)
    }

    private static func split(_ line: String) -> (String, [String: String]) {
        guard let r = line.range(of: " | ") else {
            return (line.trimmingCharacters(in: .whitespaces), [:])
        }
        let text = String(line[line.startIndex..<r.lowerBound])
        var params: [String: String] = [:]
        for token in String(line[r.upperBound...]).split(separator: " ") {
            guard let eq = token.firstIndex(of: "=") else { continue }
            let k = String(token[token.startIndex..<eq])
            var v = String(token[token.index(after: eq)...])
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            params[k] = v
        }
        return (text.trimmingCharacters(in: .whitespaces), params)
    }
}

// MARK: - the serve we supervise

/// Runs `ccwatch serve` and says truthfully what state it is in.
///
/// ⚠️ It will not start a second one. Something already listening on the port is
/// most likely a `ccwatch serve` the user started in a terminal, and killing it
/// or fighting it for the port are both worse than adopting it — so the port is
/// probed first and an existing server is used and LABELLED as not ours. The
/// menu never claims to manage something it did not start.
final class ServeSupervisor {
    enum State: Equatable {
        case notStarted
        case running(pid: Int32)
        case adopted                     // someone else's, already on the port
        case failed(reason: String)
    }

    let cli: URL
    let port: Int
    private(set) var state: State = .notStarted
    private var process: Process?
    private var lastStderr = ""
    private var restarts = 0
    private var startedAt: Date?
    private var restartPending = false
    var onChange: (() -> Void)?

    /// How long a serve must have stayed up for its death to be a new problem
    /// rather than the same one again.
    ///
    /// ⚠️ The budget used to be three restarts for the life of the app. A serve
    /// that ran for two days and then died — one was taken down by an edit to
    /// its own script mid-run — spent that budget one death at a time, and the
    /// fourth left the app with no serve at all: the overlay a blank white
    /// window, the menu still offering to show it. Three restarts is a guard
    /// against a crash LOOP, and a child that lived this long was not in one.
    static let steadyAfter: TimeInterval = 60
    static func budgetResets(afterRunning ran: TimeInterval) -> Bool { ran >= steadyAfter }

    init(cli: URL, port: Int) {
        self.cli = cli
        self.port = port
    }

    static func portIsOpen(_ port: Int) -> Bool {
        // A loopback connect to a closed port is refused immediately, so there
        // is nothing to time out. The CLI probes with /dev/tcp for the same
        // reason.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        return ok
    }

    func start() {
        if ServeSupervisor.portIsOpen(port) {
            state = .adopted
            onChange?()
            return
        }
        let p = Process()
        p.executableURL = cli
        p.arguments = ["serve", "--port", String(port)]
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            // Kept so the menu can say WHY it stopped. "serve: exited 1" with no
            // reason is the same as saying nothing.
            self?.lastStderr = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.childExited(proc) }
        }
        do {
            try p.run()
        } catch {
            state = .failed(reason: "could not run \(cli.path): \(error.localizedDescription)")
            onChange?()
            return
        }
        process = p
        startedAt = Date()
        state = .running(pid: p.processIdentifier)
        onChange?()
    }

    private func childExited(_ proc: Process) {
        process = nil
        guard case .running = state else { return }   // a deliberate stop
        if let t = startedAt, ServeSupervisor.budgetResets(afterRunning: Date().timeIntervalSince(t)) {
            restarts = 0
        }
        let why = lastStderr.isEmpty
            ? "exited \(proc.terminationStatus)"
            : "exited \(proc.terminationStatus): \(lastStderr.split(separator: "\n").last ?? "")"
        // ⚠️ Bounded restarts. A serve that cannot bind, or whose CLI is broken,
        // would otherwise be respawned forever — a loop that burns the machine
        // while the menu cheerfully reports "running". Three tries, then it says
        // what happened and stops.
        if restarts < 3 {
            restarts += 1
            state = .failed(reason: "\(why) — restarting (\(restarts)/3)")
            onChange?()
            restartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                // A manual restart in the meantime already started one; a second
                // start() would find our own child on the port and call it adopted.
                guard let self = self, self.restartPending else { return }
                self.restartPending = false
                self.start()
            }
        } else {
            state = .failed(reason: "\(why) — gave up after 3 restarts")
            onChange?()
        }
    }

    func stop() {
        guard let p = process else { return }
        state = .notStarted
        process = nil
        p.terminate()
        // The wrapper takes its python child down on TERM; that is asserted in
        // the suite. Waiting briefly keeps us from orphaning it on quit.
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
    }

    /// "Restart serve", and the overlay asking for a serve it needs. Either is
    /// a person asking, so it gets a fresh budget rather than inheriting one a
    /// crash loop already spent.
    func restart() {
        restartPending = false
        stop()
        restarts = 0
        start()
    }

    /// Starts one if there is none and none is on its way. A serve that is
    /// running, adopted, or about to be restarted is left alone.
    func ensureRunning() {
        guard process == nil, !restartPending else { return }
        if case .adopted = state, ServeSupervisor.portIsOpen(port) { return }
        restart()
    }

    var summary: String {
        switch state {
        case .notStarted: return "serve: not running"
        case .running(let pid): return "serve: running (pid \(pid))"
        case .adopted: return "serve: already running on \(port) — not started by this app"
        case .failed(let reason): return "serve: \(reason)"
        }
    }
}

// MARK: - the overlay

/// The always-on-top window, hosting the same `/map` the browser shows.
///
/// ⚠️ Every one of these four properties is load-bearing, and the obvious
/// subset does not work:
///   .statusBar rather than .floating — `.floating` sits UNDER a full-screen
///     app, which is exactly when you most want to see whether an agent is
///     blocked on you.
///   .canJoinAllSpaces — without it the panel stays on the Space it was opened
///     on and appears to have vanished.
///   .fullScreenAuxiliary — lets it show over a full-screen Space at all.
///   .nonactivatingPanel — clicking the overlay must not steal focus from the
///     terminal you are working in.
/// Hands a link that wants a new window to the real browser.
///
/// ⚠️ A WKWebView does NOTHING with `target="_blank"` unless its host
/// implements this: the click is swallowed in silence, which is the worst
/// possible outcome — the reader sees a link, clicks it, and nothing at all
/// happens. The overlay's "open in browser" is exactly such a link, and the
/// whole point of it is to leave this window.
final class OverlayUIDelegate: NSObject, WKUIDelegate {
    /// How a link leaves the panel. Injected, and that is not ceremony.
    ///
    /// ⚠️ This called `NSWorkspace.shared.open` directly, and the selftest
    /// drove the real delegate with a fixture URL — so EVERY `--selftest` run
    /// opened `http://127.0.0.1:8787/map?sid=abc` in the default browser, and
    /// the suite runs `--selftest` too. The reader watched that tab reappear
    /// all night and reported it. A test that reaches outside the process is
    /// not a test of this app, it is an action on somebody's machine.
    private let openExternally: (URL) -> Void

    init(openExternally: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.openExternally = openExternally
        super.init()
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openExternally(url)
        }
        // nil: no in-panel window is created. The overlay is one page, and a
        // second WKWebView stacked inside it would be a browser nobody asked
        // for and could not navigate.
        return nil
    }
}

final class OverlayPanel: NSPanel, WKNavigationDelegate {
    private let webView: WKWebView
    private let uiDelegate = OverlayUIDelegate()
    private static let frameKey = "CCWatchOverlayFrame"
    /// The page this panel exists to show. Kept here, not read back off the
    /// web view, because after a failed load `webView.url` is nil.
    ///
    /// ⚠️ `present()` used to reload `webView.url`. When serve was down on the
    /// first show, the load failed, the url stayed nil, and every later show
    /// reloaded nothing — the panel was a blank white window for good, even
    /// after serve came back.
    let home: URL
    /// What the menu says about serve, so the failure page can say it too.
    var serveStatus: () -> String = { "" }
    /// Set while the panel is showing why the map did not load. Exposed for
    /// the selftest.
    private(set) var failure: String?
    private var retry: DispatchWorkItem?
    static let retryEvery: TimeInterval = 3

    init(url: URL) {
        home = url
        let saved = UserDefaults.standard.string(forKey: OverlayPanel.frameKey)
        let rect = saved.flatMap { NSRectFromString($0) } ?? NSRect(x: 80, y: 120, width: 460, height: 620)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        // ⚠️ No `.fullSizeContentView`. With it the web view extended up under
        // the title bar, and a WKWebView takes every mouse-down it covers — so
        // the one strip you grab to move a window was the page's header, and
        // the overlay could be resized but not moved. Reported from real use.
        // `isMovableByWindowBackground` does not help: the web view is not
        // background. The title bar has to be a region the page is not in.
        super.init(contentRect: rect,
                   styleMask: [.nonactivatingPanel, .titled, .closable, .resizable,
                               .utilityWindow],
                   backing: .buffered, defer: false)
        // The saved value is a FRAME (see close()), and init takes a content
        // rect: without this the window grew by a title bar every launch.
        if saved != nil { setFrame(rect, display: false) }
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        title = "ccwatch"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        contentView = webView
        webView.uiDelegate = uiDelegate
        webView.navigationDelegate = self
        webView.load(URLRequest(url: url))
    }

    /// Reloaded on show rather than left running hidden: `serve` stops
    /// collecting 15s after the last read of /api/state, so a hidden overlay
    /// holding the feed open would keep the collector awake for nothing.
    func present() {
        webView.load(URLRequest(url: home))
        orderFrontRegardless()
    }

    override func close() {
        retry?.cancel()
        retry = nil
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: OverlayPanel.frameKey)
        super.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The failure page is a navigation too; only the real page clears it.
        if webView.url?.host == home.host, webView.url?.port == home.port { failure = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { loadFailed(error) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    /// The web content process can die (memory pressure, a WebKit crash), and
    /// what is left behind is — again — a white panel. Load the page afresh.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.load(URLRequest(url: home))
    }

    /// ⚠️ A failed load must never be a blank page. A white window says
    /// nothing, and read as "the overlay is broken" it hides the fact that
    /// matters: nothing is answering on the port. So the panel says so, with
    /// the reason WebKit gave and what the menu knows about serve, and keeps
    /// trying while it is on screen — serve being down is usually temporary.
    private func loadFailed(_ error: Error) {
        let ns = error as NSError
        // A load we replaced ourselves (present() during a load) is not a failure.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        failure = ns.localizedDescription
        webView.loadHTMLString(OverlayPanel.failurePage(url: home, reason: ns.localizedDescription,
                                                        serve: serveStatus()),
                               baseURL: nil)
        retry?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.webView.load(URLRequest(url: self.home))
        }
        retry = w
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayPanel.retryEvery, execute: w)
    }

    static func failurePage(url: URL, reason: String, serve: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let serveLine = serve.isEmpty ? "" : "<p><code>\(esc(serve))</code></p>"
        return """
        <!doctype html><meta charset="utf-8"><title>ccwatch — map not loading</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, system-ui, sans-serif; margin: 28px 20px;
                 background: Canvas; color: CanvasText; }
          h1 { font-size: 15px; margin: 0 0 10px; }
          code { font: 12px ui-monospace, Menlo, monospace; }
          p { margin: 0 0 10px; line-height: 1.45; }
          .dim { opacity: .7; }
        </style>
        <h1>The map is not loading</h1>
        <p>Nothing answered at <code>\(esc(url.absoluteString))</code>: \(esc(reason))</p>
        \(serveLine)
        <p class="dim">Trying again every \(Int(retryEvery))s while this window is open.
        If it does not come back, choose <b>Restart serve</b> from the menu.</p>
        """
    }
}

// MARK: - the app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var cli: CLILocator.Found?
    private var serve: ServeSupervisor?
    private var overlay: OverlayPanel?
    private var doc = BarDocument(title: "cc …", symbolName: nil, items: [])
    private var timer: Timer?
    private let port = Int(ProcessInfo.processInfo.environment["CCWATCH_PORT"] ?? "") ?? 8787
    private let refresh = Double(ProcessInfo.processInfo.environment["CCWATCH_BAR_REFRESH"] ?? "") ?? 10
    private let queue = DispatchQueue(label: "ccwatch.bar")

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "cc …"
        statusItem.menu = NSMenu()

        cli = CLILocator.locate()
        if let found = cli {
            serve = ServeSupervisor(cli: found.url, port: port)
            serve?.onChange = { [weak self] in self?.rebuildMenu() }
            serve?.start()
        }
        refreshNow()
        // Same cadence as the plugin, and for the same reason: `ccwatch` walks
        // the transcript tree on every snapshot, so a repaint nobody is watching
        // is not worth a filesystem traversal every two seconds.
        timer = Timer.scheduledTimer(withTimeInterval: refresh, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        rebuildMenu()
    }

    func applicationWillTerminate(_ note: Notification) {
        // Ours to clean up. A leaked serve holds a port with no visible owner,
        // and this repository has already paid for that once: 1686 orphaned
        // servers, ~5GB, read as the host merely being short of memory.
        serve?.stop()
    }

    private func refreshNow() {
        guard let cli = cli else {
            // ⚠️ Not "cc 0". "I cannot find ccwatch" and "nothing is running"
            // are different facts and the menu bar is where they look
            // identical: both are a calm item with nothing under it.
            doc = BarDocument(title: "cc !", symbolName: "exclamationmark.triangle",
                              items: [BarItem(text: "ccwatch not found", color: "red"),
                                      BarItem(text: "Looked in ~/.local/bin, /opt/homebrew/bin, "
                                                  + "/usr/local/bin and /usr/bin.", size: 11)])
            render()
            return
        }
        queue.async { [weak self] in
            let out = CLILocator.run(cli.url, ["bar", "--no-actions"], timeout: 120)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let out = out, !out.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.doc = BarDocument.parse(out)
                } else {
                    // A snapshot that failed must not render as a calm machine.
                    self.doc = BarDocument(title: "cc ?", symbolName: "questionmark.circle",
                        items: [BarItem(text: "ccwatch produced no output", color: "red"),
                                BarItem(text: "This is NOT \"nothing is running\".", size: 11)])
                }
                self.render()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        // Monospaced digits so the item does not jitter as the percentage
        // changes width.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize,
                                                    weight: .regular)
        var attrs: [NSAttributedString.Key: Any] = [.font: font]
        // ⚠️ attributedTitle, because `button.title` renders in the menu bar's
        // own template colour and would silently throw the CLI's colour away —
        // the emphasis would be gone with no sign it had ever been asked for.
        if let c = color(doc.titleColor) { attrs[.foregroundColor] = c }
        button.attributedTitle = NSAttributedString(string: doc.title, attributes: attrs)
        if let name = doc.symbolName {
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: doc.title)
            button.imagePosition = .imageLeading
        } else {
            button.image = nil
        }
        rebuildMenu()
    }

    /// Named colours, `#rrggbb`, and SwiftBar's `light,dark` pair.
    ///
    /// ⚠️ Hex is supported because a named colour cannot express "readable on
    /// both a light and a dark menu bar", and the title's pink has to be. An
    /// unparseable value returns nil and the label keeps its default colour,
    /// which loses an emphasis but never a word.
    private func color(_ spec: String?) -> NSColor? {
        guard let spec = spec, !spec.isEmpty else { return nil }
        if spec.contains(",") {
            let parts = spec.split(separator: ",").map(String.init)
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(dark && parts.count > 1 ? parts[1] : parts[0])
        }
        if spec.hasPrefix("#") {
            var hex = String(spec.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                           green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        switch spec {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "green": return .systemGreen
        case "purple": return .systemPurple
        case "teal": return .systemTeal
        case "pink": return .systemPink
        case "gray", "grey": return .secondaryLabelColor
        default: return nil
        }
    }

    /// Exposed for the selftest only: colour parsing is the one piece of
    /// rendering here with enough branches to be worth checking directly.
    func testColor(_ spec: String?) -> NSColor? { color(spec) }

    private func rebuildMenu() {
        let menu = NSMenu()
        for item in doc.items {
            if item.isSeparator { menu.addItem(.separator()); continue }
            let mi = NSMenuItem(title: item.text, action: nil, keyEquivalent: "")
            let size = item.size ?? NSFont.systemFontSize
            let font = item.monospaced
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size)
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            if let c = self.color(item.color) { attrs[.foregroundColor] = c }
            // ⚠️ The status lines are not clickable and must still be legible.
            // A disabled NSMenuItem renders grey, which would throw away the
            // severity colour the CLI chose, so the colour is set on an
            // attributed title instead of relying on the enabled state.
            mi.attributedTitle = NSAttributedString(string: item.text, attributes: attrs)
            mi.isEnabled = false
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let show = NSMenuItem(title: overlay?.isVisible == true ? "Hide Overlay" : "Show Overlay",
                              action: #selector(toggleOverlay), keyEquivalent: "o")
        show.target = self
        menu.addItem(show)
        let web = NSMenuItem(title: "Open Dashboard in Browser",
                             action: #selector(openDashboard), keyEquivalent: "d")
        web.target = self
        menu.addItem(web)

        menu.addItem(.separator())
        let serveLine = NSMenuItem(title: serve?.summary ?? "serve: no ccwatch found",
                                   action: nil, keyEquivalent: "")
        serveLine.isEnabled = false
        serveLine.attributedTitle = NSAttributedString(
            string: serve?.summary ?? "serve: no ccwatch found",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(serveLine)
        if serve != nil {
            let restart = NSMenuItem(title: "Restart serve", action: #selector(restartServe),
                                     keyEquivalent: "")
            restart.target = self
            menu.addItem(restart)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        if let found = cli {
            let which = NSMenuItem(title: "\(found.version) — \(found.how)", action: nil,
                                   keyEquivalent: "")
            which.isEnabled = false
            which.attributedTitle = NSAttributedString(
                string: "\(found.version) — \(found.how)",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])
            menu.addItem(which)
        }
        let quit = NSMenuItem(title: "Quit ccwatch", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private var mapURL: URL { URL(string: "http://127.0.0.1:\(port)/map")! }

    @objc private func toggleOverlay() {
        if let o = overlay, o.isVisible {
            o.close()
            rebuildMenu()
            return
        }
        // The overlay is nothing without serve, so asking for one is asking
        // for the other — including after the supervisor gave up on it.
        serve?.ensureRunning()
        if overlay == nil {
            let o = OverlayPanel(url: mapURL)
            o.serveStatus = { [weak self] in self?.serve?.summary ?? "serve: no ccwatch found" }
            overlay = o
        }
        overlay?.present()
        rebuildMenu()
    }

    @objc private func openDashboard() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/")!)
    }

    @objc private func restartServe() {
        serve?.restart()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Said, not swallowed: a toggle that silently does nothing is worse
            // than one that reports why it could not.
            let a = NSAlert()
            a.messageText = "Could not change the login item"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        rebuildMenu()
    }
}

// MARK: - entry point

/// A navigation action carrying a URL, for the selftest. `WKNavigationAction`
/// has no public initialiser, so the request is overridden on a subclass —
/// which is enough to prove the delegate reads the URL and returns nil.
final class TestNavigationAction: WKNavigationAction {
    private let req: URLRequest
    init(_ req: URLRequest) { self.req = req; super.init() }
    override var request: URLRequest { req }
}

/// `--selftest` exercises the real AppKit objects and prints what it checked.
///
/// ⚠️ It exists because a menu bar and a floating panel are the two things a
/// test suite here cannot look at: `verify-ui` drives headless Chrome, which
/// knows nothing about NSPanel, and every UI bug this project has had was found
/// by somebody opening the thing. This is not a substitute for looking — it
/// asserts the properties that are silently wrong rather than visibly wrong,
/// which is exactly the set a human glance does not catch. A panel at the wrong
/// LEVEL looks perfect until a full-screen app covers it.
func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print(ok ? "  ✓ \(what)" : "  ✗ \(what)")
        if !ok { failures += 1 }
    }
    print("ccwatch-menu selftest")

    let doc = BarDocument.parse("""
    37% · resets in 2h · 1 waiting | sfimage=bell.badge color=#ff6fb5
    ---
    3 live · 1 waiting on you | size=12
    ---
    * asking      repo  waiting  1h   permission to run rm 4m | font=Menlo size=12 color=purple
    ! hung-one    repo  HUNG?    1h   quiet 20m | font=Menlo size=12 color=red
    """)
    check(doc.title == "37% · resets in 2h · 1 waiting",
          "the title is the CLI's, parameters stripped")
    // ⚠️ The words have to survive the colour. Pink is an addition; "waiting"
    // is the carrier, and a title reading only "5h 37%" in pink would put the
    // whole claim into a hue (constitution VII).
    check(doc.title.contains("waiting"),
          "and the condition is still spelled out, not left to the colour")
    check(doc.symbolName == "bell.badge", "and its sfimage is read")
    check(doc.titleColor == "#ff6fb5", "and the colour it asked for on the title")
    check(doc.items.filter { $0.isSeparator }.count == 2, "both separators survive")
    check(doc.items.contains { $0.text.contains("quiet 20m") },
          "the measurement travels with the verdict into the menu")
    check(doc.items.contains { $0.color == "red" }, "severity colour is carried, not recomputed")
    check(doc.items.contains { $0.monospaced }, "a Menlo row is rendered monospaced")

    // ⚠️ The pipe strip is the CLI's job, but the parser must not undo it: a row
    // whose text contains ¦ has to stay text, and splitting on the LAST " | "
    // instead of the first would hand the parameter list back to the name.
    let inj = BarDocument.parse("cc 1\n---\n* evil ¦ bash=/bin/sh param1=-c  repo  idle | color=gray")
    check(inj.items.contains { $0.text.contains("evil ¦ bash=/bin/sh") },
          "a neutralised pipe stays in the text where the CLI put it")
    check(inj.items.allSatisfy { $0.unhandledParams["bash"] == nil },
          "and no bash= parameter is ever parsed out of a row")

    _ = NSApplication.shared
    let delegate = AppDelegate()
    check(delegate.testColor("#ff6fb5") != nil, "a hex colour parses")
    check(delegate.testColor("red") != nil, "and a named one")
    check(delegate.testColor("not-a-colour") == nil,
          "and nonsense parses to no colour rather than to black")

    let empty = BarDocument.parse("")
    check(empty.title == "cc ?", "empty CLI output is a question mark, never a count")

    let panel = OverlayPanel(url: URL(string: "http://127.0.0.1:8787/map")!)
    check(panel.level == .statusBar, "the overlay sits above full-screen apps (.statusBar)")
    check(panel.collectionBehavior.contains(.canJoinAllSpaces), "and follows you across Spaces")
    check(panel.collectionBehavior.contains(.fullScreenAuxiliary), "and may show over one")
    check(panel.isFloatingPanel, "and is a floating panel")
    check(panel.styleMask.contains(.nonactivatingPanel), "and does not steal focus when clicked")
    check(!panel.hidesOnDeactivate, "and does not vanish when another app activates")
    // ⚠️ Whatever the content view covers, the web view swallows the mouse in.
    // If it reaches the top edge there is no title bar left to drag by.
    let contentH = panel.contentView?.frame.height ?? panel.frame.height
    check(panel.frame.height - contentH > 0,
          "and leaves the title bar clear of the page, so it can be dragged")

    check(!ServeSupervisor.portIsOpen(1), "the port probe reports a closed port as closed")
    check(!ServeSupervisor.budgetResets(afterRunning: 5),
          "a serve dying seconds after start spends the restart budget")
    check(ServeSupervisor.budgetResets(afterRunning: 2 * 86400),
          "but one that ran for days gets a fresh one, rather than being given up on")

    // ⚠️ The white panel. Load against a port nothing listens on and wait for
    // WebKit to give up: the panel must say so in words and still know which
    // page it is for, or the next show reloads nothing.
    // ⚠️ Not port 1, which the port-probe check above uses: WebKit refuses
    // its blocked ports by loading about:blank and reporting SUCCESS, so the
    // check could never have failed there. A closed ordinary port gives the
    // real case — -1004, "Could not connect to the server".
    var deadPort = 18990
    while ServeSupervisor.portIsOpen(deadPort) { deadPort += 1 }
    let dead = URL(string: "http://127.0.0.1:\(deadPort)/map")!
    let down = OverlayPanel(url: dead)
    down.serveStatus = { "serve: exited 2 — gave up after 3 restarts" }
    let until = Date().addingTimeInterval(15)
    while down.failure == nil && Date() < until {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check(down.failure != nil, "a map that cannot load is reported as a failure, not left blank")
    check(down.home == dead, "and the panel still knows which page to reload on the next show")
    let page = OverlayPanel.failurePage(url: dead, reason: "Could not connect <b>",
                                        serve: "serve: exited 2 — gave up after 3 restarts")
    check(page.contains(dead.absoluteString) && page.contains("gave up after 3 restarts"),
          "and the failure page names the url and what the menu knows about serve")
    check(!page.contains("connect <b>") && page.contains("connect &lt;b&gt;"),
          "and escapes what it quotes")

    // ⚠️ The delegate has to exist and has to return nil. A WKWebView with no
    // UI delegate drops `target="_blank"` silently — the reader clicks "open
    // in browser" and nothing happens at all — and one that returns a new
    // WKWebView would stack a second, un-navigable page inside the panel.
    // ⚠️ A RECORDER, not the real opener. Driving the live delegate here
    // opened a browser tab every time this ran — see OverlayUIDelegate. The
    // recorder also makes the check stronger: it asserts WHICH url would be
    // handed out, which the old version could not see at all.
    var opened: [URL] = []
    let ui = OverlayUIDelegate(openExternally: { opened.append($0) })
    let cfg = WKWebViewConfiguration()
    let host = WKWebView(frame: .zero, configuration: cfg)
    let deep = URL(string: "http://127.0.0.1:8787/map?sid=abc")!
    check(host.uiDelegate == nil, "a bare WKWebView has no new-window handling of its own")
    host.uiDelegate = ui
    check(host.uiDelegate != nil, "and the overlay installs one")
    check(ui.webView(host, createWebViewWith: cfg,
                     for: TestNavigationAction(URLRequest(url: deep)),
                     windowFeatures: WKWindowFeatures()) == nil,
          "which creates no window inside the panel, so the link leaves it")
    check(opened == [deep],
          "and hands exactly that url out, once, to be opened elsewhere")
    check(opened.allSatisfy { $0.host == "127.0.0.1" },
          "and nothing but loopback is ever handed out")

    print(failures == 0 ? "\nselftest: all checks passed" : "\nselftest: \(failures) FAILED")
    return failures == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--selftest") {
    exit(selftest())
}

let app = NSApplication.shared
// LSUIElement in Info.plist keeps it out of the Dock; this is the runtime half.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
