import SwiftUI

/// The sidebar: sessions grouped by project and host, each with its status,
/// as the desktop app's.
struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            hostProblems
            ForEach(model.groups) { group in
                Section(isExpanded: expanded(group.id)) {
                    ForEach(group.sessions) { s in
                        SessionRow(session: s, host: group.host)
                            .tag(SessionRef(host: group.host.id, session: s.id))
                            .contextMenu { menu(for: s, host: group.host) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.closeSession(SessionRef(host: group.host.id, session: s.id))
                                } label: { Label("Close", systemImage: "xmark") }
                            }
                    }
                } header: {
                    GroupHeader(group: group) {
                        model.newSession(on: group.host, project: group.projectID.isEmpty ? nil : group.projectID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .navigationTitle("Kero")
        .overlay {
            if model.store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a machine that runs kerod to see its sessions here.")
                } actions: {
                    Button("Add Host…") { model.showingSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.groups.isEmpty && model.hosts.allSatisfy({ $0.loaded || !$0.isConnected }) && model.hosts.contains(where: \.isConnected) {
                ContentUnavailableView {
                    Label("No Sessions", systemImage: "terminal")
                } actions: {
                    Button("New Session") { model.newSession() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { model.showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.newSession() } label: { Label("New Session", systemImage: "plus") }
            }
        }
        .safeAreaInset(edge: .bottom) { AttentionFooter() }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !model.collapsed.contains(id) },
                set: { if $0 { model.collapsed.remove(id) } else { model.collapsed.insert(id) } })
    }

    /// A host gets a row of its own only when it needs the user: when Kero
    /// can't reach it, or it speaks another version.
    @ViewBuilder private var hostProblems: some View {
        let troubled = model.hosts.filter { h in
            switch h.link {
            case .failed, .version: return true
            case .connecting: return !h.loaded
            default: return false
            }
        }
        if !troubled.isEmpty {
            Section("Hosts") {
                ForEach(troubled) { h in HostProblemRow(host: h) }
            }
        }
    }

    @ViewBuilder private func menu(for s: Session, host: HostConnection) -> some View {
        let ref = SessionRef(host: host.id, session: s.id)
        Button { model.renaming = ref } label: { Label("Rename…", systemImage: "pencil") }
        Button { model.newSession(on: host, project: s.project) } label: { Label("New Session in Project", systemImage: "plus") }
        Divider()
        Button(role: .destructive) { model.closeSession(ref) } label: { Label("Close Session", systemImage: "xmark") }
    }
}

private struct GroupHeader: View {
    var group: SidebarGroup
    var add: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(group.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.textMuted)
                .lineLimit(1)
            HostTag(name: group.host.name, colorName: group.host.colorName)
            Spacer(minLength: 4)
            Button(action: add) {
                Label("New Session in \(group.name)", systemImage: "plus")
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textMuted)
            }
            .buttonStyle(.borderless)
            .disabled(!group.host.isConnected)
        }
        .textCase(nil)
    }
}

/// A session's row: its status, its name, what its lead pane last said or
/// where it works, and when it last changed.
struct SessionRow: View {
    var session: Session
    var host: HostConnection
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(alignment: .top, spacing: 10) {
                StatusIcon(status: session.status, unread: session.unread, progress: session.lead.progress)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.displayName(home: host.home))
                            .font(.body.weight(session.unread || session.status == .waiting ? .semibold : .regular))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(KeroText.ago(session.lead.since, now: ctx.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Palette.textFaint)
                    }
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(session.status == .waiting ? Palette.attention : Palette.textMuted)
                            .lineLimit(1)
                    }
                    if session.panes.count > 1 {
                        Label("\(session.panes.count) panes", systemImage: "rectangle.split.2x1")
                            .font(.caption2)
                            .foregroundStyle(Palette.textFaint)
                    }
                }
            }
            .padding(.vertical, 3)
            .opacity(host.isConnected ? 1 : 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        let lead = session.lead
        if !lead.message.isEmpty { return lead.message }
        if let b = lead.git?.branch, !b.isEmpty {
            var s = b
            if let g = lead.git, g.files > 0 { s += "  +\(g.added) −\(g.removed)" }
            return s
        }
        let d = lead.workDir
        return d.isEmpty ? nil : KeroText.shortDir(d, home: host.home)
    }
}

private struct HostProblemRow: View {
    var host: HostConnection
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            switch host.link {
            case .connecting:
                ProgressView().controlSize(.small)
            default:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(host.name).font(.body.weight(.medium))
                    HostTag(name: host.config.address, colorName: host.colorName)
                }
                Text(status).font(.caption).foregroundStyle(Palette.textMuted).lineLimit(3)
            }
            Spacer()
            if host.link != .connecting {
                Button("Retry") { host.reconnect() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch host.link {
        case .connecting: return host.loaded ? "Reconnecting…" : "Connecting…"
        case .failed(let s), .version(let s): return s
        default: return ""
        }
    }
}

/// The desktop sidebar's footer chips: how many sessions need the user,
/// and a tap goes to the next.
private struct AttentionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let waiting = model.hosts.flatMap(\.state.sessions).filter { $0.status == .waiting }.count
        let failed = model.hosts.flatMap(\.state.sessions).filter { $0.status == .failed }.count
        if waiting + failed > 0 {
            HStack(spacing: 8) {
                if waiting > 0 {
                    chip("\(waiting) need\(waiting == 1 ? "s" : "") you", color: Palette.attention, status: .waiting) {
                        model.jump { $0.status == .waiting }
                    }
                }
                if failed > 0 {
                    chip("\(failed) failed", color: Palette.danger, status: .failed) {
                        model.jump { $0.status == .failed }
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func chip(_ text: String, color: Color, status: PaneStatus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StatusIcon(status: status, unread: true, size: 12)
                Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the next one")
    }
}
