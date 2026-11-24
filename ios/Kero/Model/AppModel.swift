import Foundation
import Observation
import SwiftUI
import UIKit

/// A session of a host: what the sidebar selects.
struct SessionRef: Hashable, Codable, Sendable {
    var host: UUID
    var session: String
}

/// A group of the sidebar: one project of one host, as the desktop app
/// tags a host's projects with its name.
struct SidebarGroup: Identifiable {
    var id: String { "\(host.id)/\(projectID)" }
    var host: HostConnection
    var projectID: String
    var name: String
    var dir: String
    var sessions: [Session]
}

@MainActor
@Observable
final class AppModel {
    let store: HostStore
    private(set) var hosts: [HostConnection] = []
    var selection: SessionRef? {
        didSet {
            if selection != oldValue { selectionChanged() }
        }
    }
    /// The pane the user is in, per session, as this client last chose:
    /// kerod's Focus otherwise.
    var focusedPane: [String: String] = [:]
    var collapsed: Set<String> = []
    var toast: Toast?
    var showingSettings = false
    var renaming: SessionRef?

    let terminals: TerminalCache

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var detail: String = ""
        var symbol: String = "info.circle"
    }

    init(store: HostStore) {
        self.store = store
        terminals = TerminalCache()
        terminals.model = self
        syncHosts()
        if let data = UserDefaults.standard.data(forKey: "kero.selection"),
           let ref = try? JSONDecoder().decode(SessionRef.self, from: data) {
            selection = ref
        }
    }

    // MARK: Hosts

    /// Matches the connections to the saved hosts: new ones connect, removed
    /// ones close, changed ones take their settings.
    func syncHosts() {
        var next: [HostConnection] = []
        for cfg in store.hosts {
            if let h = hosts.first(where: { $0.id == cfg.id }) {
                h.update(cfg)
                next.append(h)
            } else {
                let h = HostConnection(config: cfg)
                h.onNotice = { [weak self] h, n in self?.notice(n, from: h) }
                h.onState = { [weak self] _ in self?.terminals.prune() }
                h.onLinkChange = { [weak self] h in
                    self?.terminals.linkChanged(h)
                    // A new connection is a new viewer: tell it what is shown.
                    if h.isConnected, self?.selection?.host == h.id { self?.markViewed() }
                }
                next.append(h)
                if active { h.start() }
            }
        }
        for h in hosts where !next.contains(where: { $0.id == h.id }) {
            h.stop()
            terminals.dropHost(h.id)
        }
        hosts = next
    }

    private var active = false

    /// The scene came to the front: connect every host.
    func activate() {
        active = true
        for h in hosts { h.start() }
    }

    /// The scene went to the background.
    func deactivate() {
        active = false
        for h in hosts { h.stop() }
    }

    func host(_ id: UUID) -> HostConnection? { hosts.first { $0.id == id } }

    // MARK: Sessions

    func session(_ ref: SessionRef?) -> Session? {
        guard let ref, let h = host(ref.host) else { return nil }
        return h.state.sessions.first { $0.id == ref.session }
    }

    var selectedSession: Session? { session(selection) }
    var selectedHost: HostConnection? { selection.flatMap { host($0.host) } }

    /// The sidebar's groups: each host's projects in its kerod's order,
    /// hosts in the order of Settings › Hosts. A session of no project its
    /// host knows goes in a group of the host's own.
    var groups: [SidebarGroup] {
        var out: [SidebarGroup] = []
        for h in hosts where h.loaded {
            var byProject: [String: [Session]] = [:]
            for s in h.state.sessions { byProject[s.project, default: []].append(s) }
            for p in h.state.projects {
                guard let ss = byProject.removeValue(forKey: p.id), !ss.isEmpty else { continue }
                out.append(SidebarGroup(host: h, projectID: p.id, name: p.name.isEmpty ? KeroText.dirName(p.dir) : p.name, dir: p.dir, sessions: ss))
            }
            let known = Set(h.state.projects.map(\.id))
            let rest = h.state.sessions.filter { !known.contains($0.project) }
            if !rest.isEmpty {
                out.append(SidebarGroup(host: h, projectID: "", name: h.name, dir: "", sessions: rest))
            }
        }
        return out
    }

    /// The pane a session shows the keyboard in: the one chosen here, else
    /// kerod's focus.
    func focusPane(of s: Session) -> Pane? {
        if let id = focusedPane[s.id], let p = s.pane(id) { return p }
        return s.focusPane
    }

    func focus(pane: String, in s: Session, host: HostConnection) {
        focusedPane[s.id] = pane
        Task { try? await host.focus(session: s.id, pane: pane) }
    }

    /// A terminal took the keyboard: its pane becomes its session's focus.
    func terminalFocused(host id: UUID, pane: String) {
        guard let h = host(id), let s = h.state.sessions.first(where: { $0.pane(pane) != nil }) else { return }
        if focusedPane[s.id] != pane || s.focus != pane { focus(pane: pane, in: s, host: h) }
    }

    private func selectionChanged() {
        if let selection, let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: "kero.selection")
        }
        markViewed()
    }

    /// Tells the host the session is shown, which marks it read.
    func markViewed() {
        guard let ref = selection, let h = host(ref.host), h.isConnected else { return }
        Task { try? await h.view(session: ref.session) }
    }

    /// app.go's jumpTo: the next session want takes, after the one shown,
    /// in the sidebar's order.
    @discardableResult
    func jump(where want: (Session) -> Bool) -> Bool {
        var refs: [(SessionRef, Session, String)] = []
        for g in groups {
            for s in g.sessions { refs.append((SessionRef(host: g.host.id, session: s.id), s, g.id)) }
        }
        guard !refs.isEmpty else { return false }
        let i = refs.firstIndex { $0.0 == selection } ?? -1
        for k in 1...refs.count {
            let (ref, s, group) = refs[(i + k + refs.count) % refs.count]
            if ref != selection && want(s) {
                collapsed.remove(group)
                selection = ref
                return true
            }
        }
        return false
    }

    /// ⌘J: the next session that needs the user, else the next with
    /// something unseen (app.go's jumpToAttention).
    func jumpToAttention() {
        if jump(where: { $0.status == .waiting }) || jump(where: { $0.unread }) {
            UIAccessibility.post(notification: .announcement, argument: "Jumped to \(selectedSession.map { displayName($0) } ?? "session")")
            return
        }
        show(Toast(title: "Nothing needs you", symbol: "checkmark.circle"))
    }

    var attentionCount: Int {
        hosts.reduce(0) { $0 + $1.state.sessions.filter { $0.status == .waiting || $0.unread }.count }
    }

    func displayName(_ s: Session) -> String {
        guard let ref = selection, let h = host(ref.host) else { return s.displayName(home: "") }
        return s.displayName(home: h.home)
    }

    // MARK: Actions

    func newSession(on host: HostConnection? = nil, project: String? = nil) {
        guard let h = host ?? selectedHost ?? hosts.first(where: \.isConnected) else {
            show(Toast(title: "No host connected", detail: "Add one in Settings › Hosts.", symbol: "network.slash"))
            return
        }
        let project = project ?? selectedSession?.project
        let after = selectedSession?.id
        let before = Set(h.state.sessions.map(\.id))
        Task {
            do {
                try await h.createSession(project: project, after: after)
                // Select it once the state that has it comes.
                for _ in 0..<40 {
                    if let s = h.state.sessions.first(where: { !before.contains($0.id) }) {
                        selection = SessionRef(host: h.id, session: s.id)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                fail("Could not start a session", error)
            }
        }
    }

    func splitFocused(direction: String) {
        guard let s = selectedSession, let h = selectedHost, let p = focusPane(of: s) else { return }
        let before = Set(s.panes.map(\.id))
        Task {
            do {
                try await h.split(pane: p.id, direction: direction)
                for _ in 0..<40 {
                    if let ns = session(selection), let np = ns.panes.first(where: { !before.contains($0.id) }) {
                        focusedPane[ns.id] = np.id
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                fail("Could not split the pane", error)
            }
        }
    }

    func closeFocusedPane() {
        guard let s = selectedSession, let h = selectedHost, let p = focusPane(of: s) else { return }
        if s.panes.count <= 1 { closeSession(SessionRef(host: h.id, session: s.id)); return }
        Task {
            do { try await h.closePane(p.id) } catch { fail("Could not close the pane", error) }
        }
    }

    func closeSession(_ ref: SessionRef) {
        guard let h = host(ref.host) else { return }
        if selection == ref {
            // Show the next one, as the desktop app does.
            let ids = h.state.sessions.map(\.id)
            if let i = ids.firstIndex(of: ref.session), ids.count > 1 {
                selection = SessionRef(host: h.id, session: ids[i + 1 < ids.count ? i + 1 : i - 1])
            } else {
                selection = nil
            }
        }
        Task {
            do { try await h.closeSession(ref.session) } catch { fail("Could not close the session", error) }
        }
    }

    func rename(_ ref: SessionRef, to name: String) {
        guard let h = host(ref.host) else { return }
        Task {
            do { try await h.rename(session: ref.session, to: name) } catch { fail("Could not rename the session", error) }
        }
    }

    func restartFocusedPane() {
        guard let s = selectedSession, let h = selectedHost, let p = focusPane(of: s) else { return }
        Task {
            do { try await h.restartPane(p.id) } catch { fail("Could not restart the pane", error) }
        }
    }

    func toggleZoom() {
        guard let s = selectedSession, let h = selectedHost, let p = focusPane(of: s) else { return }
        Task { try? await h.zoom(session: s.id, pane: s.zoomed == p.id ? "" : p.id) }
    }

    // MARK: Feedback

    func show(_ t: Toast) {
        toast = t
        let id = t.id
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast?.id == id { toast = nil }
        }
    }

    func fail(_ what: String, _ error: Error) {
        show(Toast(title: what, detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                   symbol: "exclamationmark.triangle"))
    }

    private func notice(_ n: Notice, from h: HostConnection) {
        // A host's notifications carry its name, so a remote program can't
        // pass for anything else.
        let title = n.title.isEmpty ? h.name : "\(n.title) — \(h.name)"
        show(Toast(title: title, detail: n.body, symbol: "bell"))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
