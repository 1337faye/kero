import Foundation
import Observation
import UIKit

/// How the app stands with a host (hosts.go's conn states).
enum HostLink: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
    /// The host speaks another protocol: it, or this app, needs updating.
    case version(String)
}

/// One host: its connection, kept up while the app is in front, and what its
/// kerod last said. When the link drops, its sessions stay, faded, and it
/// reconnects on its own, waiting longer between tries up to a minute, as
/// the desktop app does.
@MainActor
@Observable
final class HostConnection: Identifiable {
    let id: UUID
    private(set) var config: HostConfig
    private(set) var link: HostLink = .idle
    private(set) var info = HostInfo()
    private(set) var state = DaemonState()
    /// A state came since the app started: the sidebar shows the host's
    /// sessions, faded while the link is down.
    private(set) var loaded = false
    private(set) var latency: TimeInterval?

    @ObservationIgnored private var connection: RemoteConnection?
    @ObservationIgnored private var control: ControlClient?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backoff: TimeInterval = 1
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let decoder = JSONDecoder()

    /// Called on a notification a program on the host posted.
    @ObservationIgnored var onNotice: ((HostConnection, Notice) -> Void)?
    /// Called whenever the link changes, as to reattach terminals.
    @ObservationIgnored var onLinkChange: ((HostConnection) -> Void)?
    /// Called after each new state.
    @ObservationIgnored var onState: ((HostConnection) -> Void)?

    init(config: HostConfig) {
        id = config.id
        self.config = config
    }

    var name: String { config.name }
    var colorName: String { config.colorName }
    var isConnected: Bool { link == .connected }
    var home: String { info.home }
    var remoteConnection: RemoteConnection? { isConnected ? connection : nil }

    static var clientName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Kero iOS \(version)"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Takes a changed configuration: a new address reconnects.
    func update(_ c: HostConfig) {
        let readdress = c.address != config.address
        config = c
        if readdress && wanted { reconnect() }
    }

    // MARK: Connecting

    func start() {
        wanted = true
        if connection == nil && connectTask == nil { connect() }
    }

    /// Drops the link, as the app goes to the background: iOS would cut it
    /// anyway, and a clean end lets kerod forget this client at once.
    func stop() {
        wanted = false
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        generation += 1
        teardown()
        if link != .idle { link = .idle; onLinkChange?(self) }
    }

    func reconnect() {
        wanted = true
        retryTask?.cancel(); retryTask = nil
        connectTask?.cancel(); connectTask = nil
        generation += 1
        teardown()
        backoff = 1
        connect()
    }

    private func teardown() {
        control?.onClose = nil
        control?.onEvent = nil
        control?.close()
        control = nil
        connection?.onClose = nil
        connection?.close()
        connection = nil
    }

    private func connect() {
        link = .connecting
        onLinkChange?(self)
        let gen = generation
        let config = config
        connectTask = Task { [weak self] in
            do {
                let addr = try HostAddress.parse(config.address)
                let conn = try await RemoteConnection.connect(to: addr, clientName: Self.clientName, appVersion: Self.appVersion)
                let ctl = ControlClient(connection: conn)
                _ = try await ctl.start(clientName: Self.clientName)
                guard let self, gen == self.generation, !Task.isCancelled else { conn.close(); return }
                self.up(conn, ctl, gen: gen)
                try await ctl.call("subscribe")
            } catch is CancellationError {
            } catch {
                guard let self, gen == self.generation else { return }
                self.down(error, gen: gen)
            }
        }
    }

    private func up(_ conn: RemoteConnection, _ ctl: ControlClient, gen: Int) {
        connectTask = nil
        connection = conn
        control = ctl
        info = conn.welcome?.host ?? HostInfo()
        backoff = 1
        conn.onClose = { [weak self] err in
            Task { @MainActor in self?.down(err ?? RemoteError.closed, gen: gen) }
        }
        ctl.onClose = { [weak self] err in
            Task { @MainActor in self?.down(err ?? RemoteError.closed, gen: gen) }
        }
        let decoder = self.decoder
        ctl.onEvent = { [weak self] event, line in
            // Decoded on the connection's queue: a state can be large.
            switch event {
            case "state":
                struct M: Decodable { var state: DaemonState? }
                guard let st = (try? decoder.decode(M.self, from: line))?.state else { return }
                Task { @MainActor in self?.took(st, gen: gen) }
            case "notice":
                struct M: Decodable { var notice: Notice? }
                guard let n = (try? decoder.decode(M.self, from: line))?.notice else { return }
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.onNotice?(self, n)
                }
            default:
                // "select" and "action" drive the app from the host: Remote
                // Control, which this client never allows. "browser" asks of
                // browser panes, which are the desktop app's.
                break
            }
        }
        link = .connected
        onLinkChange?(self)
        Task { [weak self] in
            let rtt = await conn.ping()
            self?.latency = rtt
        }
    }

    private func took(_ st: DaemonState, gen: Int) {
        guard gen == generation else { return }
        state = st
        loaded = true
        onState?(self)
    }

    private func down(_ err: Error, gen: Int) {
        guard gen == generation else { return }
        connectTask = nil
        generation += 1
        teardown()
        let msg = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
        if case RemoteError.protocolVersion = err {
            link = .version(msg)
        } else if case RemoteError.version = err {
            link = .version(msg)
        } else {
            link = .failed(msg)
        }
        onLinkChange?(self)
        guard wanted else { return }
        let wait = backoff
        backoff = min(backoff * 2, 60)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, self.wanted else { return }
            self.retryTask = nil
            self.connect()
        }
    }

    // MARK: Methods

    private func ctl() throws -> ControlClient {
        guard let control, isConnected else { throw RemoteError.closed }
        return control
    }

    /// Starts a session in a project, or the first; returns nothing, as the
    /// next state shows it.
    func createSession(project: String?, dir: String? = nil, after: String? = nil, cols: Int? = nil, rows: Int? = nil) async throws {
        try await ctl().call("create", CreateParams(project: project, dir: dir, after: after, cols: cols, rows: rows))
    }

    /// Splits a pane: right, down, left or up of it.
    func split(pane: String, direction: String) async throws {
        try await ctl().call("split", CreateParams(split: pane, direction: direction))
    }

    func closeSession(_ id: String) async throws {
        try await ctl().call("close", CloseParams(id: id))
    }

    func closePane(_ id: String) async throws {
        try await ctl().call("pane.close", IDParams(id: id))
    }

    func restartPane(_ id: String) async throws {
        try await ctl().call("restart", IDParams(id: id))
    }

    func rename(session: String, to name: String) async throws {
        try await ctl().call("rename", RenameParams(id: session, name: name))
    }

    func focus(session: String, pane: String) async throws {
        try await ctl().call("focus", FocusParams(session: session, pane: pane))
    }

    func zoom(session: String, pane: String) async throws {
        try await ctl().call("zoom", FocusParams(session: session, pane: pane))
    }

    /// Tells kerod the session a window shows, which marks it read.
    func view(session: String) async throws {
        try await ctl().call("view", ViewParams(id: session))
    }

    func send(pane: String, text: String) async throws {
        try await ctl().call("send", SendParams(id: pane, data: text))
    }

    func ping() async {
        latency = await connection?.ping()
    }
}
