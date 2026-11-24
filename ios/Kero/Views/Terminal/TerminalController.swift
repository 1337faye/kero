import Foundation
import Observation
import SwiftTerm
import UIKit

/// SwiftTerm's view, which tells the controller when it takes the keyboard.
final class KeroTerminalView: TerminalView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

/// One pane's terminal: a SwiftTerm view showing what an attach connection
/// to the pane brings, and sending what the user types. Controllers outlive
/// the views that show them, so that folding or unfolding the device, or
/// the sidebar coming and going, never drops a connection or a scrollback.
@MainActor
@Observable
final class TerminalController: NSObject, TerminalViewDelegate {
    enum Phase: Equatable { case connecting, live, ended(String), offline }

    let host: UUID
    let pane: String
    private(set) var phase: Phase = .connecting
    private(set) var title = ""
    /// The Ctrl key of the accessory bar is held for the next key.
    var controlLatched = false {
        didSet { if view.controlModifier != controlLatched { view.controlModifier = controlLatched } }
    }

    @ObservationIgnored let view: KeroTerminalView
    @ObservationIgnored private var attach: AttachClient?
    @ObservationIgnored private var remoteSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var lastAsked: (cols: Int, rows: Int)?
    /// The size SwiftTerm's terminal has, as it last told.
    @ObservationIgnored private var termSize: (cols: Int, rows: Int)?
    @ObservationIgnored var lastUsed = Date()
    @ObservationIgnored var onFocus: (() -> Void)?
    @ObservationIgnored private weak var lastConnection: RemoteConnection?
    @ObservationIgnored private var drops = 0
    /// This client asked for the pane's size last and claimed it, so the
    /// pane follows this view's size.
    @ObservationIgnored private var claimed = false
    /// The pane is the one the user is at, in a window in front.
    @ObservationIgnored var isShown = false
    @ObservationIgnored private var applyingRemote = false
    /// The size SwiftTerm fits the view's bounds to, as its layout last did.
    @ObservationIgnored private var viewFit: (cols: Int, rows: Int)?

    init(host: UUID, pane: String, fontSize: CGFloat) {
        self.host = host
        self.pane = pane
        view = KeroTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240),
                                font: TerminalFont.font(TerminalFont.regular, size: fontSize))
        super.init()
        view.setFonts(normal: TerminalFont.font(TerminalFont.regular, size: fontSize),
                      bold: TerminalFont.font(TerminalFont.bold, size: fontSize),
                      italic: TerminalFont.font(TerminalFont.italic, size: fontSize),
                      boldItalic: TerminalFont.font(TerminalFont.boldItalic, size: fontSize))
        view.terminalDelegate = self
        // The accessory bar is the app's own, in SwiftUI (KeyAccessoryBar).
        view.inputAccessoryView = nil
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.onFocus = { [weak self] in self?.focused() }
        view.accessibilityLabel = "Terminal"
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (v: KeroTerminalView, _: UITraitCollection) in
            self?.applyTheme()
        }
        NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controlLatched = false }
        }
        applyTheme()
    }

    var key: String { TerminalCache.key(host, pane) }

    // MARK: Theme and font

    func applyTheme() {
        let theme = TerminalTheme.forStyle(view.traitCollection.userInterfaceStyle)
        view.nativeForegroundColor = theme.foreground
        // SwiftTerm paints the default background with the view's layer and
        // leaves default cells clear (its setupOptions): an opaque native
        // background would paint them over it.
        view.nativeBackgroundColor = .clear
        view.layer.backgroundColor = theme.background.cgColor
        view.caretColor = theme.cursor
        view.selectedTextBackgroundColor = theme.selection
        view.keyboardAppearance = view.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        view.installColors(theme.palette.map { c in
            let p = c.rgba8
            return SwiftTerm.Color(red: UInt16(p[0]) * 257, green: UInt16(p[1]) * 257, blue: UInt16(p[2]) * 257)
        })
        // kerod answers programs' questions about the colors with these.
        attach?.theme(theme.framePayload)
    }

    func setFontSize(_ size: CGFloat) {
        view.setFonts(normal: TerminalFont.font(TerminalFont.regular, size: size),
                      bold: TerminalFont.font(TerminalFont.bold, size: size),
                      italic: TerminalFont.font(TerminalFont.italic, size: size),
                      boldItalic: TerminalFont.font(TerminalFont.boldItalic, size: size))
    }

    // MARK: Connection

    /// Attaches over a host's connection, starting the terminal over from
    /// what the pane shows.
    func connect(_ conn: RemoteConnection) {
        if conn !== lastConnection { drops = 0 }
        lastConnection = conn
        attach?.close()
        phase = .connecting
        let a = AttachClient(connection: conn)
        attach = a
        a.onEvent = { [weak self, weak a] e in
            guard let self, let a, a === self.attach else { return }
            self.handle(e)
        }
        let size = currentSize()
        a.start(pane: pane, cols: size.cols, rows: size.rows, clientName: HostConnection.clientName)
    }

    func disconnect(offline: Bool) {
        attach?.close()
        attach = nil
        if offline { phase = .offline }
    }

    private func handle(_ e: AttachClient.Event) {
        switch e {
        case .welcome(let cols, let rows):
            phase = .live
            if drops > 0 { drops -= 1 }
            applyTheme()
            // The snapshot that follows is of the pane's size: the terminal
            // takes it, then asks for its own.
            if cols > 0 && rows > 0 { takeRemoteSize(cols, rows) }
            claimed = false
            if isShown { claim() } else { askSize(force: true) }
        case .output(let data):
            view.feed(byteArray: ArraySlice([UInt8](data)))
        case .resized(let cols, let rows):
            takeRemoteSize(cols, rows)
        case .closed:
            phase = .ended("The pane closed.")
            attach = nil
        case .dropped:
            // kerod let go of a client that fell behind: attach again, a few
            // times in a row at most.
            attach = nil
            drops += 1
            if drops <= 5, let conn = lastConnection {
                connect(conn)
            } else {
                phase = .ended("The host stopped sending this pane.")
            }
        case .failed(let err):
            phase = .ended((err as? LocalizedError)?.errorDescription ?? err.localizedDescription)
            attach = nil
        }
    }

    private func takeRemoteSize(_ cols: Int, _ rows: Int) {
        // A size other than the one this client asked for: another client
        // has the pane now.
        if let l = lastAsked, l.cols != cols || l.rows != rows { claimed = false }
        remoteSize = (cols, rows)
        let cur = currentSize()
        if cur.cols != cols || cur.rows != rows { applyRemote(cols, rows) }
    }

    /// Gives SwiftTerm's terminal the pane's size, which kerod's frames are
    /// of. (SwiftTerm's resize also soft-resets the terminal; the frames that
    /// follow from kerod set its modes again.)
    private func applyRemote(_ cols: Int, _ rows: Int) {
        applyingRemote = true
        view.resize(cols: cols, rows: rows)
        applyingRemote = false
    }

    /// The size the view holds, in cells.
    private func currentSize() -> (cols: Int, rows: Int) {
        termSize ?? fittedSize()
    }

    /// Asks kerod for the size this view fits, with a cell's size in
    /// pixels, which programs asking the size in pixels need.
    private func askSize(force: Bool = false) {
        guard let attach else { return }
        // SwiftTerm's own fit of its bounds, which its layout keeps.
        let size = viewFit ?? fittedSize()
        guard size.cols > 0, size.rows > 0 else { return }
        if !force, let l = lastAsked, l == size { return }
        lastAsked = size
        let scale = view.traitCollection.displayScale
        let cw = Int((view.bounds.width / CGFloat(size.cols)) * scale)
        let ch = Int((view.bounds.height / CGFloat(size.rows)) * scale)
        attach.resize(cols: size.cols, rows: size.rows, cellWidth: cw, cellHeight: ch)
    }

    /// The cells the view's bounds hold at the font's size.
    private func fittedSize() -> (cols: Int, rows: Int) {
        let font = view.font
        let cellW = ("W" as NSString).size(withAttributes: [.font: font]).width
        let cellH = ceil(font.lineHeight)
        guard cellW > 0, cellH > 0, view.bounds.width > 0, view.bounds.height > 0 else { return (0, 0) }
        return (max(1, Int(view.bounds.width / cellW)), max(1, Int(view.bounds.height / cellH)))
    }

    /// The user is at this terminal: the pane takes this view's size, as it
    /// does once they type.
    func claim() {
        guard attach != nil else { return }
        askSize(force: true)
        attach?.claim()
        claimed = true
    }

    func clearScreen() { attach?.clearScreen() }

    private func focused() {
        lastUsed = Date()
        claim()
        onFocus?()
    }

    // MARK: Accessory keys

    func sendBytes(_ bytes: [UInt8]) { view.send(bytes) }
    func sendText(_ s: String) { view.send(Array(s.utf8)) }
    func arrow(_ dir: String) {
        switch dir {
        case "up": view.sendKeyUp()
        case "down": view.sendKeyDown()
        case "left": view.sendKeyLeft()
        default: view.sendKeyRight()
        }
    }

    func paste() {
        // SwiftTerm's paste wraps the text in bracketed paste when the
        // program asked for it.
        guard UIPasteboard.general.hasStrings else { return }
        view.paste(nil)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        lastUsed = Date()
        attach?.input(Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        termSize = (newCols, newRows)
        if !applyingRemote { viewFit = (newCols, newRows) }
        // A size kerod sent is no new ask.
        if let r = remoteSize, r.cols == newCols, r.rows == newRows { return }
        askSize()
        // While another client has the pane, its frames are of the pane's
        // size: the terminal keeps that size, whatever room the view has,
        // until this client claims it.
        if !claimed, let r = remoteSize {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.claimed, let t = self.termSize, t.cols != r.cols || t.rows != r.rows else { return }
                self.applyRemote(r.cols, r.rows)
            }
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) { self.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }

    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        // Only web links: a path printed on the host means nothing here.
        guard let url = URL(string: request.link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        source.window?.windowScene?.open(url, options: nil, completionHandler: nil)
    }

    func bell(source: TerminalView) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// The terminals the app keeps, by host and pane.
@MainActor
@Observable
final class TerminalCache {
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private var controllers: [String: TerminalController] = [:]
    /// How many panes keep their connection while not shown.
    @ObservationIgnored let keep = 12

    var fontSize: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "kero.fontSize")
        return v > 0 ? v : 12
    }() {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: "kero.fontSize")
            for c in controllers.values { c.setFontSize(fontSize) }
        }
    }

    /// The terminal that has the keyboard, for the accessory bar.
    private(set) var active: TerminalController?

    static func key(_ host: UUID, _ pane: String) -> String { "\(host.uuidString)/\(pane)" }

    func controller(host: HostConnection, pane: String) -> TerminalController {
        let k = Self.key(host.id, pane)
        if let c = controllers[k] {
            c.lastUsed = Date()
            if c.phase == .offline, let conn = host.remoteConnection { c.connect(conn) }
            return c
        }
        let c = TerminalController(host: host.id, pane: pane, fontSize: fontSize)
        c.onFocus = { [weak self, weak c] in
            guard let self, let c else { return }
            if self.active !== c { self.active?.isShown = false; self.active = c; c.isShown = true }
            self.model?.terminalFocused(host: c.host, pane: c.pane)
        }
        controllers[k] = c
        if let conn = host.remoteConnection { c.connect(conn) } else { c.disconnect(offline: true) }
        // Not while a view asks for it: pruning changes what views observe.
        Task { @MainActor [weak self] in self?.prune() }
        return c
    }

    /// The terminal the user is at: it has the key bar, and the pane takes
    /// its size (FrameClaim), as kerod does for the client a user uses.
    func setActive(_ c: TerminalController?) {
        guard active !== c else { return }
        active?.isShown = false
        active = c
        c?.isShown = true
        c?.claim()
    }

    /// A host's link changed: its terminals reattach once it is up, and wait
    /// otherwise.
    func linkChanged(_ h: HostConnection) {
        for c in controllers.values where c.host == h.id {
            if let conn = h.remoteConnection { c.connect(conn) } else { c.disconnect(offline: true) }
        }
    }

    func dropHost(_ id: UUID) {
        for (k, c) in controllers where c.host == id {
            c.disconnect(offline: false)
            controllers[k] = nil
        }
    }

    /// Lets go of the terminals of panes that are gone, and of the least
    /// recently used beyond `keep`.
    func prune() {
        guard let model else { return }
        var live = Set<String>()
        for h in model.hosts where h.loaded {
            for s in h.state.sessions { for p in s.panes { live.insert(Self.key(h.id, p.id)) } }
        }
        for (k, c) in controllers where !live.contains(k) && model.host(c.host)?.loaded == true {
            c.disconnect(offline: false)
            controllers[k] = nil
            if active === c { active = nil }
        }
        if controllers.count > keep {
            let shown = Set(model.selectedSession.map { s in s.panes.map { Self.key(model.selection!.host, $0.id) } } ?? [])
            let old = controllers.values.filter { !shown.contains($0.key) }.sorted { $0.lastUsed < $1.lastUsed }
            for c in old.prefix(controllers.count - keep) {
                c.disconnect(offline: false)
                controllers[c.key] = nil
                if active === c { active = nil }
            }
        }
    }
}
