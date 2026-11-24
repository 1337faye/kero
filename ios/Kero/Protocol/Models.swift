import Foundation

// The wire types of kerod's protocol (internal/proto/proto.go and remote.go),
// as JSON. Fields kerod leaves out (omitempty) decode to their zero values,
// and fields this client doesn't know are skipped, as the Go side does.

enum KeroProtocol {
    /// proto.Version: a daemon of another version refuses the connection.
    static let version = 3
    /// proto.MuxVersion.
    static let muxVersion = 1
    /// remote.MuxPath: where kerod's network listeners take a remote connection.
    static let muxPath = "/kero/mux"
    /// remote.ClientHeader: browsers can't send it, so no web page reaches kerod.
    static let clientHeader = "Kero-Client"
    /// remote.DefaultPort.
    static let defaultPort = 7373
    /// proto.MaxLine: kerod's state comes whole on one line.
    static let maxLine = 64 << 20
}

// MARK: - Status

/// proto.Status: what a session is doing, as the sidebar shows it.
enum PaneStatus: String, Codable, Sendable, CaseIterable {
    case idle, working, waiting
    case failed = "error"
    case exited

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PaneStatus(rawValue: raw) ?? .idle
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .waiting: "Needs You"
        case .failed: "Failed"
        case .exited: "Exited"
        }
    }
}

// MARK: - Layout

/// proto.Layout: a binary tree of splits; a leaf is a pane.
final class PaneLayout: Codable, Sendable, Equatable {
    let pane: String
    let row: Bool
    let ratio: Double
    let a: PaneLayout?
    let b: PaneLayout?

    init(pane: String = "", row: Bool = false, ratio: Double = 0, a: PaneLayout? = nil, b: PaneLayout? = nil) {
        self.pane = pane; self.row = row; self.ratio = ratio; self.a = a; self.b = b
    }

    enum CodingKeys: String, CodingKey { case pane, row, ratio, a, b }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decodeIfPresent(String.self, forKey: .pane) ?? ""
        row = try c.decodeIfPresent(Bool.self, forKey: .row) ?? false
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio) ?? 0
        a = try c.decodeIfPresent(PaneLayout.self, forKey: .a)
        b = try c.decodeIfPresent(PaneLayout.self, forKey: .b)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if !pane.isEmpty { try c.encode(pane, forKey: .pane) }
        if row { try c.encode(row, forKey: .row) }
        if ratio != 0 { try c.encode(ratio, forKey: .ratio) }
        try c.encodeIfPresent(a, forKey: .a)
        try c.encodeIfPresent(b, forKey: .b)
    }

    var isLeaf: Bool { a == nil && b == nil }

    /// The ratio A takes, 0.5 when it is out of range, as Layout.rects does.
    var effectiveRatio: Double { ratio > 0 && ratio < 1 ? ratio : 0.5 }

    /// Layout.Panes: left to right, top to bottom.
    var panes: [String] {
        if isLeaf { return [pane] }
        return (a?.panes ?? []) + (b?.panes ?? [])
    }

    static func == (l: PaneLayout, r: PaneLayout) -> Bool {
        l.pane == r.pane && l.row == r.row && l.ratio == r.ratio && l.a == r.a && l.b == r.b
    }
}

// MARK: - Pane, Session, Project, State

struct ProgramRecord: Codable, Sendable, Hashable {
    var id: String
    var state: String
    var kind: String
    var progress: Int
    var app: String
    var title: String
    var msg: String
    var updated: Int64

    enum CodingKeys: String, CodingKey { case id, state, kind, progress, app, title, msg, updated }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        progress = try c.decodeIfPresent(Int.self, forKey: .progress) ?? -1
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        msg = try c.decodeIfPresent(String.self, forKey: .msg) ?? ""
        updated = try c.decodeIfPresent(Int64.self, forKey: .updated) ?? 0
    }
}

struct GitInfo: Codable, Sendable, Hashable {
    var root: String = ""
    var branch: String = ""
    var head: String = ""
    var files: Int = 0
    var added: Int = 0
    var removed: Int = 0
    var state: String = ""

    enum CodingKeys: String, CodingKey { case root, branch, head, files, added, removed, state }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decodeIfPresent(String.self, forKey: .root) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch) ?? ""
        head = try c.decodeIfPresent(String.self, forKey: .head) ?? ""
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        added = try c.decodeIfPresent(Int.self, forKey: .added) ?? 0
        removed = try c.decodeIfPresent(Int.self, forKey: .removed) ?? 0
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? ""
    }
}

/// proto.Pane: a terminal kerod keeps running, or a browser pane (URL set),
/// which this client shows as a placeholder: browser panes are the desktop
/// app's.
struct Pane: Codable, Sendable, Hashable, Identifiable {
    var id: String = ""
    var title: String = ""
    var url: String = ""
    var dir: String = ""
    var command: [String] = []
    var process: String = ""
    var processDir: String = ""
    var agent: String = ""
    var runtime: String = ""
    var shell: String = ""
    var status: PaneStatus = .idle
    var unread: Bool = false
    var message: String = ""
    var kind: String = ""
    var progress: Int = -1
    var records: [ProgramRecord] = []
    var since: Int64 = 0
    var activity: Int64 = 0
    var created: Int64 = 0
    var exitCode: Int = 0
    var restored: Bool = false
    var cols: Int = 0
    var rows: Int = 0
    var git: GitInfo?

    enum CodingKeys: String, CodingKey {
        case id, title, url, dir, command, process, processDir, agent, runtime, shell, status, unread, message,
             kind, progress, records, since, activity, created, exitCode, restored, cols, rows, git
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
        command = try c.decodeIfPresent([String].self, forKey: .command) ?? []
        process = try c.decodeIfPresent(String.self, forKey: .process) ?? ""
        processDir = try c.decodeIfPresent(String.self, forKey: .processDir) ?? ""
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? ""
        shell = try c.decodeIfPresent(String.self, forKey: .shell) ?? ""
        status = try c.decodeIfPresent(PaneStatus.self, forKey: .status) ?? .idle
        unread = try c.decodeIfPresent(Bool.self, forKey: .unread) ?? false
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        progress = try c.decodeIfPresent(Int.self, forKey: .progress) ?? -1
        records = try c.decodeIfPresent([ProgramRecord].self, forKey: .records) ?? []
        since = try c.decodeIfPresent(Int64.self, forKey: .since) ?? 0
        activity = try c.decodeIfPresent(Int64.self, forKey: .activity) ?? 0
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode) ?? 0
        restored = try c.decodeIfPresent(Bool.self, forKey: .restored) ?? false
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        git = try c.decodeIfPresent(GitInfo.self, forKey: .git)
    }

    var isBrowser: Bool { !url.isEmpty }

    var workDir: String { processDir.isEmpty ? dir : processDir }

    /// Pane.PaneName: the title a foreground program set, else the program,
    /// else the shell, else the directory's name.
    func paneName(home: String) -> String {
        if isBrowser {
            let t = title.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
            if url == "about:blank" { return "browser" }
            return URLComponents(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
        }
        if !process.isEmpty {
            let t = KeroText.cleanTitle(title)
            if !t.isEmpty && !KeroText.looksLikePath(t) { return t }
            return process
        }
        if !shell.isEmpty { return shell }
        if !dir.isEmpty { return dir == home ? "~" : KeroText.dirName(dir) }
        return "shell"
    }
}

/// proto.Session: a row of the sidebar. Go embeds the lead pane's fields in
/// it, so the same JSON object carries both; its `id` is the session's.
struct Session: Codable, Sendable, Hashable, Identifiable {
    var lead: Pane
    var id: String
    var project: String
    var name: String
    var agentNamed: Bool
    var panes: [Pane]
    var layout: PaneLayout?
    var leadID: String
    var focus: String
    var zoomed: String

    enum CodingKeys: String, CodingKey { case id, project, name, agentNamed, panes, layout, lead, focus, zoomed }

    init(from decoder: Decoder) throws {
        lead = try Pane(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        agentNamed = try c.decodeIfPresent(Bool.self, forKey: .agentNamed) ?? false
        panes = try c.decodeIfPresent([Pane].self, forKey: .panes) ?? []
        layout = try c.decodeIfPresent(PaneLayout.self, forKey: .layout)
        leadID = try c.decodeIfPresent(String.self, forKey: .lead) ?? ""
        focus = try c.decodeIfPresent(String.self, forKey: .focus) ?? ""
        zoomed = try c.decodeIfPresent(String.self, forKey: .zoomed) ?? ""
        // The embedded pane's own id is shadowed by the session's.
        lead.id = leadID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(project, forKey: .project)
    }

    static func == (l: Session, r: Session) -> Bool {
        l.id == r.id && l.project == r.project && l.name == r.name && l.panes == r.panes && l.layout == r.layout &&
            l.focus == r.focus && l.zoomed == r.zoomed && l.lead == r.lead && l.leadID == r.leadID
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    var status: PaneStatus { lead.status }
    var unread: Bool { lead.unread }

    func pane(_ id: String) -> Pane? { panes.first { $0.id == id } }

    /// Session.FocusPane: the pane the user was in last, else the first.
    var focusPane: Pane? { pane(focus) ?? panes.first }

    /// The panes as the layout orders them; panes the layout misses go last.
    var orderedPanes: [Pane] {
        guard let layout else { return panes }
        let order = layout.panes
        var out = order.compactMap { pane($0) }
        out += panes.filter { !order.contains($0.id) }
        return out
    }

    /// Session.DisplayName with the "focused" setting, the desktop app's
    /// default.
    func displayName(home: String) -> String {
        if !name.isEmpty { return name }
        var p = lead
        if let f = focusPane, !f.process.isEmpty { p = f }
        if !p.process.isEmpty {
            let t = KeroText.cleanTitle(p.title)
            if !t.isEmpty && !KeroText.looksLikePath(t) { return t }
            if !p.agent.isEmpty { return p.agent }
        }
        if p.isBrowser && !panes.contains(where: { !$0.isBrowser }) { return p.paneName(home: home) }
        if !p.dir.isEmpty { return p.dir == home ? "~" : KeroText.dirName(p.dir) }
        return "shell"
    }
}

struct Project: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var dir: String

    enum CodingKeys: String, CodingKey { case id, name, dir }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        dir = try c.decodeIfPresent(String.self, forKey: .dir) ?? ""
    }
}

/// proto.State: everything kerod knows, sent whole on every change.
struct DaemonState: Decodable, Sendable {
    var projects: [Project] = []
    var sessions: [Session] = []
    var viewed: String = ""
    var started: Int64 = 0

    enum CodingKeys: String, CodingKey { case projects, sessions, viewed, started }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        viewed = try c.decodeIfPresent(String.self, forKey: .viewed) ?? ""
        started = try c.decodeIfPresent(Int64.self, forKey: .started) ?? 0
    }
}

/// proto.Notice.
struct Notice: Decodable, Sendable {
    var session: String
    var pane: String
    var title: String
    var body: String

    enum CodingKeys: String, CodingKey { case session, pane, title, body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decodeIfPresent(String.self, forKey: .session) ?? ""
        pane = try c.decodeIfPresent(String.self, forKey: .pane) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

// MARK: - Handshakes

/// proto.Hello: opens a stream to kerod.
struct Hello: Encodable, Sendable {
    var kind: String
    var version: Int = KeroProtocol.version
    var session: String?
    var cols: Int?
    var rows: Int?
    var client: String?
}

/// proto.Welcome.
struct Welcome: Decodable, Sendable {
    var version: Int
    var pid: Int
    var started: Int64
    var app: String
    var error: String
    var cols: Int
    var rows: Int

    enum CodingKeys: String, CodingKey { case version, pid, started, app, error, cols, rows }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        pid = try c.decodeIfPresent(Int.self, forKey: .pid) ?? 0
        started = try c.decodeIfPresent(Int64.self, forKey: .started) ?? 0
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
    }
}

/// proto.MuxHello: opens a remote connection.
struct MuxHello: Encodable, Sendable {
    var kind = "mux"
    var mux = KeroProtocol.muxVersion
    var version = KeroProtocol.version
    var app: String
    /// What the client reads, best first. This client offers none: both sides
    /// then write plain yamux frames (see RemoteConnection).
    var compress: [String]?
    var client: String
}

/// proto.HostInfo.
struct HostInfo: Codable, Sendable, Hashable {
    var hostname: String = ""
    var os: String = ""
    var arch: String = ""
    var user: String = ""
    var home: String = ""
    var kero: String = ""
    var version: Int = 0
    var server: Bool = false
    var updates: Bool = false
    var peer: String = ""

    enum CodingKeys: String, CodingKey { case hostname, os, arch, user, home, kero, version, server, updates, peer }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname) ?? ""
        os = try c.decodeIfPresent(String.self, forKey: .os) ?? ""
        arch = try c.decodeIfPresent(String.self, forKey: .arch) ?? ""
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
        kero = try c.decodeIfPresent(String.self, forKey: .kero) ?? ""
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        server = try c.decodeIfPresent(Bool.self, forKey: .server) ?? false
        updates = try c.decodeIfPresent(Bool.self, forKey: .updates) ?? false
        peer = try c.decodeIfPresent(String.self, forKey: .peer) ?? ""
    }
}

/// proto.MuxWelcome.
struct MuxWelcome: Decodable, Sendable {
    var mux: Int
    var compress: String
    var host: HostInfo
    var error: String

    enum CodingKeys: String, CodingKey { case mux, compress, host, error }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mux = try c.decodeIfPresent(Int.self, forKey: .mux) ?? 0
        compress = try c.decodeIfPresent(String.self, forKey: .compress) ?? ""
        host = try c.decodeIfPresent(HostInfo.self, forKey: .host) ?? HostInfo()
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
    }
}

// MARK: - Method params

struct CreateParams: Encodable, Sendable {
    var split: String?
    var direction: String?
    var ratio: Double?
    var project: String?
    var name: String?
    var dir: String?
    var after: String?
    var cols: Int?
    var rows: Int?
}

struct IDParams: Encodable, Sendable { var id: String }
struct CloseParams: Encodable, Sendable { var id: String }
struct RenameParams: Encodable, Sendable { var id: String; var name: String }
struct FocusParams: Encodable, Sendable { var session: String; var pane: String }
struct ViewParams: Encodable, Sendable { var id: String }
struct SendParams: Encodable, Sendable { var id: String; var data: String }

// MARK: - Text helpers (proto.CleanTitle, DirName, looksLikePath, Ago)

enum KeroText {
    static func dirName(_ dir: String) -> String {
        var t = dir
        while let last = t.last, last == "/" || last == "\\" { t.removeLast() }
        if let i = t.lastIndex(where: { $0 == "/" || $0 == "\\" }), t.index(after: i) < t.endIndex, !t.hasSuffix(":") {
            return String(t[t.index(after: i)...])
        }
        if !t.isEmpty && !t.hasSuffix(":") { return t }
        return dir
    }

    private static func isTitleGlyph(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x2800...0x28FF, 0x2700...0x27BF, 0x25A0...0x25FF, 0x2600...0x26FF: return true
        default: return "·•*✦✧⏺⏵>»".unicodeScalars.contains(s)
        }
    }

    static func cleanTitle(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = t.unicodeScalars.first, isTitleGlyph(first) {
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: t.unicodeScalars.dropFirst())
            t = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    static func looksLikePath(_ t: String) -> Bool {
        if t.hasPrefix("/") || t.hasPrefix("~") || (t.contains("@") && t.contains(":")) { return true }
        let chars = Array(t)
        if chars.count > 2 && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/") { return true }
        return t.lowercased().contains(".exe") && t.contains(":\\")
    }

    /// proto.Ago: "now", "4m", "2h", "3d", "1w".
    static func ago(_ ms: Int64, now: Date = .now) -> String {
        guard ms > 0 else { return "" }
        let d = now.timeIntervalSince(Date(timeIntervalSince1970: Double(ms) / 1000))
        switch d {
        case ..<60: return "now"
        case ..<3600: return "\(Int(d / 60))m"
        case ..<86400: return "\(Int(d / 3600))h"
        case ..<(7 * 86400): return "\(Int(d / 86400))d"
        default: return "\(Int(d / (7 * 86400)))w"
        }
    }

    /// ShortDir, for a host's home.
    static func shortDir(_ dir: String, home: String) -> String {
        guard !home.isEmpty, dir.hasPrefix(home) else { return dir }
        let rest = dir.dropFirst(home.count)
        if rest.isEmpty || rest.hasPrefix("/") || rest.hasPrefix("\\") { return "~" + rest }
        return dir
    }
}
