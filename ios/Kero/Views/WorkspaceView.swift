import SwiftUI

/// The detail column: the selected session's panes, the terminal keys, and
/// the session's toolbar.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let s = model.selectedSession, let h = model.selectedHost {
                SessionWorkspace(session: s, host: h)
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "terminal")
                } description: {
                    Text(model.attentionCount > 0 ? "\(model.attentionCount) session\(model.attentionCount == 1 ? "" : "s") need you." : "Choose a session in the sidebar.")
                } actions: {
                    if model.attentionCount > 0 {
                        Button { model.jumpToAttention() } label: { Label("Quick Jump", systemImage: "bolt.fill") }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .background(Palette.sidebar)
            }
        }
    }
}

private struct SessionWorkspace: View {
    let session: Session
    let host: HostConnection

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    /// On a compact width every pane would be too narrow to read: the
    /// focused pane fills the column unless the user asks for all.
    @State private var showAll = false
    @State private var treeSize: CGSize = .zero

    private var focusID: String? { model.focusPane(of: session)?.id }
    private var compact: Bool { hSize == .compact }

    var body: some View {
        content
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .background(Palette.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { KeyAccessoryBar() }
            .navigationTitle(session.displayName(home: host.home))
            .navigationSubtitle(subtitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
            .onChange(of: session.id, initial: true) { _, _ in model.markViewed() }
    }

    /// What the pane tree is built anew for: the session, the shape of its
    /// layout, and the room it has, in steps of 80 points.
    private var treeIdentity: String {
        let shape = session.effectiveLayout.panes.joined(separator: ",")
        return "\(session.id)|\(shape)|\(Int(treeSize.width / 80))x\(Int(treeSize.height / 80))"
    }

    private var subtitle: String {
        var parts = [host.name]
        if session.panes.count > 1 { parts.append("\(session.panes.count) panes") }
        if !host.isConnected { parts.append("offline") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        let zoomed = session.zoomed.isEmpty ? nil : session.pane(session.zoomed)
        if let zoomed {
            PaneCard(pane: zoomed, session: session, host: host, focused: true, showsHeader: session.panes.count > 1)
        } else if session.panes.count > 1 && (!compact || showAll) {
            // An arrangement settles which of its sides it shows as it is
            // first laid out: one laid out before the column has its size
            // (as the split view settles at launch, or on unfolding) can keep
            // a side hidden. It starts anew once the room is known, and when
            // the room changes much.
            Color.clear
                .onGeometryChange(for: CGSize.self, of: \.size) { treeSize = $0 }
                .overlay {
                    if treeSize.width > 160 && treeSize.height > 120 {
                        PaneTree(node: session.effectiveLayout, session: session, host: host, focus: focusID, size: treeSize)
                            .id(treeIdentity)
                    }
                }
        } else if let p = model.focusPane(of: session) {
            PaneCard(pane: p, session: session, host: host, focused: true, showsHeader: session.panes.count > 1)
                .id(p.id)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { model.jumpToAttention() } label: { Label("Quick Jump", systemImage: "bolt.fill") }
                .badge(model.attentionCount)
        }
        .visibilityPriority(.high)

        ToolbarItem(placement: .primaryAction) {
            Button { model.splitFocused(direction: compact ? "down" : "right") } label: {
                Label("New Pane", systemImage: compact ? "rectangle.split.1x2" : "rectangle.split.2x1")
            }
            .disabled(!host.isConnected)
        }
        .visibilityPriority(.high)

        ToolbarItem(placement: .primaryAction) {
            Button { model.newSession() } label: { Label("New Session", systemImage: "plus.rectangle.on.rectangle") }
                .disabled(!host.isConnected)
        }

        if session.panes.count > 1 {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Pane", selection: Binding(get: { focusID ?? "" }, set: { model.focus(pane: $0, in: session, host: host) })) {
                        ForEach(session.orderedPanes) { p in
                            Label(p.paneName(home: host.home), systemImage: p.isBrowser ? "globe" : "terminal").tag(p.id)
                        }
                    }
                    if compact {
                        Toggle(isOn: $showAll) { Label("Show All Panes", systemImage: "square.grid.2x2") }
                    }
                } label: {
                    Label("Panes", systemImage: "square.split.2x2")
                }
            }
        }

        ToolbarOverflowMenu {
            Button { model.splitFocused(direction: compact ? "right" : "down") } label: {
                Label(compact ? "Split Right" : "Split Down", systemImage: compact ? "rectangle.split.2x1" : "rectangle.split.1x2")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!host.isConnected)
            if session.panes.count > 1 {
                Button { model.toggleZoom() } label: {
                    Label(session.zoomed.isEmpty ? "Zoom Pane" : "Unzoom Pane", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            Button { model.terminals.active?.clearScreen() } label: { Label("Clear Screen", systemImage: "eraser") }
                .keyboardShortcut("k", modifiers: .command)
            Button { model.restartFocusedPane() } label: { Label("Restart Pane", systemImage: "arrow.clockwise") }
                .disabled(!host.isConnected)
            Button { model.renaming = SessionRef(host: host.id, session: session.id) } label: {
                Label("Rename Session…", systemImage: "pencil")
            }
            Divider()
            Button { host.reconnect() } label: { Label("Reconnect \(host.name)", systemImage: "arrow.triangle.2.circlepath") }
            Divider()
            if session.panes.count > 1 {
                Button(role: .destructive) { model.closeFocusedPane() } label: { Label("Close Pane", systemImage: "xmark.square") }
                    .keyboardShortcut("w", modifiers: .command)
            }
            Button(role: .destructive) { model.closeSession(SessionRef(host: host.id, session: session.id)) } label: {
                Label("Close Session", systemImage: "xmark")
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }
}
