import SwiftUI
import UIKit

/// Shows a controller's terminal view inside a container of its own, so the
/// one terminal view can move between containers as layouts change (fold,
/// unfold, sidebar) without its connection or scrollback going anywhere.
struct TerminalSurface: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.clipsToBounds = true
        adopt(into: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {
        adopt(into: box)
    }

    /// A terminal takes whatever room it is given and asks for none: its
    /// scrollback is no size, and an arrangement would otherwise read the
    /// terminal's content as how wide it wants to be.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: proposal.height ?? 160)
    }

    static func dismantleUIView(_ box: UIView, coordinator: ()) {
        // The terminal stays the controller's; only this container goes.
        for v in box.subviews { v.removeFromSuperview() }
    }

    private func adopt(into box: UIView) {
        let v = controller.view
        guard v.superview !== box else { return }
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}

/// A pane as a card, the desktop app's look: a header with the pane's name
/// and status, the terminal under it, faded while the user is in another.
struct PaneCard: View {
    let pane: Pane
    let session: Session
    let host: HostConnection
    var focused: Bool
    var showsHeader: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader { header }
            content
        }
        .background(Palette.card)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(focused && session.panes.count > 1 ? Palette.accent.opacity(0.55) : Palette.cardBorder, lineWidth: focused && session.panes.count > 1 ? 1.5 : 1)
        }
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(pane.paneName(home: host.home))")
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusIcon(status: pane.status, unread: pane.unread, progress: pane.progress, size: 12)
            Text(pane.paneName(home: host.home))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Text(host.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.hostColors[host.colorName] ?? Palette.textMuted)
            Spacer(minLength: 4)
            if !pane.workDir.isEmpty {
                Text(KeroText.shortDir(pane.workDir, home: host.home))
                    .font(.caption2)
                    .foregroundStyle(Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.card)
        .contentShape(.rect)
        .onTapGesture { model.focus(pane: pane.id, in: session, host: host) }
    }

    @ViewBuilder private var content: some View {
        if pane.isBrowser {
            ContentUnavailableView {
                Label(pane.paneName(home: host.home), systemImage: "globe")
            } description: {
                Text("Browser panes show in Kero on the desktop.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let c = model.terminals.controller(host: host, pane: pane.id)
            ZStack {
                // Taps go to the terminal itself, which takes the keyboard and
                // tells the model (TerminalCache.controller's onFocus).
                TerminalSurface(controller: c)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                if !focused && session.panes.count > 1 {
                    // Ghostty's unfocused-split-opacity.
                    Palette.veil.allowsHitTesting(false)
                }
                PhaseOverlay(controller: c, host: host)
            }
            .background(Palette.card)
            .onChange(of: focused, initial: true) { _, f in
                if f { model.terminals.setActive(c) }
            }
        }
    }
}

/// What a terminal says while it is not live.
private struct PhaseOverlay: View {
    let controller: TerminalController
    let host: HostConnection

    var body: some View {
        switch controller.phase {
        case .live:
            EmptyView()
        case .connecting:
            ProgressView("Connecting…")
                .padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 10))
        case .offline:
            VStack(spacing: 8) {
                Label("\(host.name) is offline", systemImage: "wifi.slash").font(.callout.weight(.medium))
                Text("Kero reconnects on its own.").font(.caption).foregroundStyle(.secondary)
                Button("Reconnect Now") { host.reconnect() }.buttonStyle(.bordered)
            }
            .padding(14)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        case .ended(let why):
            VStack(spacing: 8) {
                Label("Detached", systemImage: "bolt.horizontal.circle").font(.callout.weight(.medium))
                Text(why).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let conn = host.remoteConnection {
                    Button("Attach Again") { controller.connect(conn) }.buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
    }
}

/// A session's panes as its layout splits them. Each split is an
/// ArrangementView, which arranges its two sides around the fold of an
/// iPhone Duo, and on any other display as the split's axis says.
struct PaneTree: View {
    let node: PaneLayout
    let session: Session
    let host: HostConnection
    let focus: String?
    /// The room this node has: each side of a split is told its share of
    /// it, so that an arrangement never takes a terminal's scrollback for
    /// how much room it wants.
    let size: CGSize

    @Environment(AppModel.self) private var model

    var body: some View {
        if node.isLeaf {
            leaf(node.pane)
        } else if let a = node.a, let b = node.b {
            let r = node.effectiveRatio
            ArrangementView {
                PaneTree(node: a, session: session, host: host, focus: focus, size: share(r))
                    .splitArrangementLayoutRatio(idealHorizontal: node.row ? r : nil, idealVertical: node.row ? nil : r)
                    .splitArrangementLayoutSize(minWidth: 120, minHeight: 80)
            } secondary: {
                PaneTree(node: b, session: session, host: host, focus: focus, size: share(1 - r))
                    .splitArrangementLayoutRatio(idealHorizontal: node.row ? 1 - r : nil, idealVertical: node.row ? nil : 1 - r)
                    .splitArrangementLayoutSize(minWidth: 120, minHeight: 80)
            }
            .arrangementViewStyle(.split.axes(axes))
        } else if let only = node.a ?? node.b {
            PaneTree(node: only, session: session, host: host, focus: focus, size: size)
        }
    }

    /// The room a side takes of this split.
    private func share(_ f: Double) -> CGSize {
        node.row ? CGSize(width: size.width * f, height: size.height) : CGSize(width: size.width, height: size.height * f)
    }

    /// The axes the split may take: its own, while each side keeps room to
    /// read along it; else either, and the system arranges the panes the way
    /// that fits, as side by side across the fold of an iPhone Duo held open.
    /// (A split arrangement with no room along its only axis shows its
    /// first side alone.)
    private var axes: Axis.Set {
        let along = node.row ? size.width : size.height
        if along * min(node.effectiveRatio, 1 - node.effectiveRatio) >= Self.roomyside { return node.row ? .horizontal : .vertical }
        return [.horizontal, .vertical]
    }

    /// The least a side needs along its split's axis before the split would
    /// rather turn: measured, an arrangement keeps both sides of a 314-point
    /// side and not of a 236-point one.
    static let roomyside: CGFloat = 320

    @ViewBuilder private func leaf(_ id: String) -> some View {
        if let p = session.pane(id) {
            PaneCard(pane: p, session: session, host: host, focused: p.id == focus, showsHeader: true)
                .padding(3)
                // Room it is given, not room it asks for.
                .frame(minWidth: 0, idealWidth: size.width, maxWidth: .infinity,
                       minHeight: 0, idealHeight: size.height, maxHeight: .infinity)
        }
    }
}

/// The layout a session shows: its own, else its panes side by side.
extension Session {
    var effectiveLayout: PaneLayout {
        if let layout, Set(layout.panes) == Set(panes.map(\.id)) { return layout }
        // Panes the layout misses (or none): a row of them, as kerod would
        // split each to the right.
        let ids = panes.map(\.id)
        guard var node = ids.last.map({ PaneLayout(pane: $0) }) else { return PaneLayout() }
        for (i, id) in ids.dropLast().enumerated().reversed() {
            let share = 1 / Double(ids.count - i)
            node = PaneLayout(row: true, ratio: share, a: PaneLayout(pane: id), b: node)
        }
        return node
    }
}
