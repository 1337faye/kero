import SwiftUI

/// The window: the sidebar and the workspace in a split view, which on a
/// compact width (an iPhone Duo's outer display, or a narrow window) shows
/// one at a time, and on the inner display both, the same views and the
/// same terminals either way.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            WorkspaceView()
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Palette.accent)
        .overlay { ReservedRegionAware { ToastView() } }
        .sheet(isPresented: $model.showingSettings) {
            SettingsView()
        }
        .alert("Rename Session", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let ref = model.renaming { model.rename(ref, to: renameText) }
                model.renaming = nil
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        } message: {
            Text("Leave it empty to go by what runs in it.")
        }
        .onChange(of: model.renaming) { _, ref in
            renameText = model.session(ref)?.name ?? ""
        }
        .onChange(of: model.selection, initial: true) { _, sel in
            if sel != nil { compactColumn = .detail }
        }
        .onChange(of: model.store.hosts) { _, _ in model.syncHosts() }
    }
}

/// Places its content in the widest part of the view that no reserved
/// region covers, and below any cutout at the top: on an iPhone Duo held
/// open, never across the fold.
struct ReservedRegionAware<Content: View>: View {
    var alignment: Alignment = .top
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let area = freeArea(proxy)
            content
                .frame(width: area.width, height: area.height, alignment: alignment)
                .offset(x: area.minX, y: area.minY)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func freeArea(_ proxy: GeometryProxy) -> CGRect {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        let regions = (proxy.reservedRegions(kind: .division) + proxy.reservedRegions(kind: .occlusion)).filter(\.isActive)
        var top: CGFloat = 0
        var spans: [ClosedRange<CGFloat>] = []
        for r in regions {
            let f = r.frame.insetBy(dx: -(r.margins.leading + r.margins.trailing) / 2, dy: -(r.margins.top + r.margins.bottom) / 2)
            guard f.intersects(bounds) || f.width < 1 else { continue }
            if f.width >= bounds.width * 0.8 {
                // Across the whole width, as a cutout's band at the top.
                if f.minY < 80 { top = max(top, f.maxY) }
            } else {
                spans.append(max(0, f.minX)...min(bounds.width, f.maxX))
            }
        }
        // The widest stretch between spans.
        var best = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        if !spans.isEmpty {
            var x: CGFloat = 0
            var widest: (CGFloat, CGFloat) = (0, 0)
            for s in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if s.lowerBound - x > widest.1 - widest.0 { widest = (x, s.lowerBound) }
                x = max(x, s.upperBound)
            }
            if bounds.width - x > widest.1 - widest.0 { widest = (x, bounds.width) }
            best = CGRect(x: widest.0, y: top, width: widest.1 - widest.0, height: bounds.height - top)
        }
        return best
    }
}

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let t = model.toast {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: t.symbol).font(.body.weight(.semibold)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.subheadline.weight(.semibold))
                    if !t.detail.isEmpty {
                        Text(t.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { model.toast = nil }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .id(t.id)
        }
    }
}
