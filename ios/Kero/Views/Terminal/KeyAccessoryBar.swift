import SwiftUI

/// The keys an on-screen keyboard lacks: Esc, Tab, a sticky Ctrl, the
/// arrows, and Paste. On an iPhone Duo held open, the keys part around the
/// fold (a reserved region of kind .division) and around a camera cutout
/// (.occlusion), so none sits where a finger can't press it.
struct KeyAccessoryBar: View {
    @Environment(AppModel.self) private var model

    private struct Key: Identifiable {
        let id: String
        let label: String
        let symbol: String?
        let action: (TerminalController) -> Void
        var repeats = false
        var isCtrl = false
    }

    private var keys: [Key] {
        [
            Key(id: "esc", label: "Esc", symbol: nil) { $0.sendBytes([0x1b]) },
            Key(id: "tab", label: "Tab", symbol: "arrow.right.to.line") { $0.sendBytes([0x09]) },
            Key(id: "ctrl", label: "Ctrl", symbol: nil, action: { $0.controlLatched.toggle() }, isCtrl: true),
            Key(id: "left", label: "Left", symbol: "arrow.left", action: { $0.arrow("left") }, repeats: true),
            Key(id: "down", label: "Down", symbol: "arrow.down", action: { $0.arrow("down") }, repeats: true),
            Key(id: "up", label: "Up", symbol: "arrow.up", action: { $0.arrow("up") }, repeats: true),
            Key(id: "right", label: "Right", symbol: "arrow.right", action: { $0.arrow("right") }, repeats: true),
            Key(id: "paste", label: "Paste", symbol: "doc.on.clipboard") { $0.paste() },
        ]
    }

    var body: some View {
        GeometryReader { proxy in
            let blocked = blockedSpans(proxy)
            let segments = freeSegments(width: proxy.size.width, blocked: blocked)
            let groups = distribute(keys, over: segments)
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(segments.indices, segments)), id: \.0) { i, seg in
                    HStack(spacing: 6) {
                        ForEach(groups[i]) { key in button(key) }
                    }
                    .frame(width: seg.width, height: proxy.size.height)
                    .offset(x: seg.minX)
                }
            }
        }
        .frame(height: 44)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(model.terminals.active == nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal keys")
    }

    @ViewBuilder private func button(_ key: Key) -> some View {
        let latched = key.isCtrl && (model.terminals.active?.controlLatched ?? false)
        KeyCap(label: key.label, symbol: key.symbol, highlighted: latched, repeats: key.repeats) {
            guard let t = model.terminals.active else { return }
            UIDevice.current.playInputClick()
            key.action(t)
        }
        .accessibilityAddTraits(latched ? .isSelected : [])
    }

    /// The horizontal spans of the bar that reserved regions cover: the fold,
    /// and cutouts, with their margins.
    private func blockedSpans(_ proxy: GeometryProxy) -> [ClosedRange<CGFloat>] {
        let local = CGRect(origin: .zero, size: proxy.size)
        let regions = proxy.reservedRegions(kind: .division) + proxy.reservedRegions(kind: .occlusion)
        var spans: [ClosedRange<CGFloat>] = []
        for r in regions where r.isActive {
            let f = r.frame
            guard f.intersects(local) || (f.width < 1 && f.minX > local.minX && f.minX < local.maxX) else { continue }
            // A region that spans the bar's width (as a fold across a
            // display held the other way) leaves nothing to part around.
            guard f.width < local.width * 0.8 else { continue }
            let lo = max(0, f.minX - r.margins.leading - 8)
            let hi = min(local.width, f.maxX + r.margins.trailing + 8)
            if hi > lo { spans.append(lo...hi) }
        }
        return spans.sorted { $0.lowerBound < $1.lowerBound }
    }

    private struct Segment { var minX: CGFloat; var width: CGFloat }

    private func freeSegments(width: CGFloat, blocked: [ClosedRange<CGFloat>]) -> [Segment] {
        var out: [Segment] = []
        var x: CGFloat = 0
        for b in blocked {
            if b.lowerBound - x > 44 { out.append(Segment(minX: x, width: b.lowerBound - x)) }
            x = max(x, b.upperBound)
        }
        if width - x > 44 { out.append(Segment(minX: x, width: width - x)) }
        return out.isEmpty ? [Segment(minX: 0, width: width)] : out
    }

    /// Hands the keys out to the segments in order, by their widths.
    private func distribute(_ keys: [Key], over segs: [Segment]) -> [[Key]] {
        let total = segs.reduce(0) { $0 + $1.width }
        var out: [[Key]] = []
        var start = 0
        for (i, s) in segs.enumerated() {
            let n = i == segs.count - 1 ? keys.count - start : Int((Double(keys.count) * Double(s.width / total)).rounded())
            let end = min(keys.count, start + max(0, n))
            out.append(Array(keys[start..<end]))
            start = end
        }
        return out
    }
}

/// One key of the bar: a keyboard key's look, auto-repeating while held
/// for the arrows.
private struct KeyCap: View {
    var label: String
    var symbol: String?
    var highlighted: Bool
    var repeats: Bool
    var action: () -> Void

    @State private var timer: Timer?

    var body: some View {
        Button {
            if !repeats { action() }
        } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                } else {
                    Text(label).font(.system(size: 14, weight: .medium, design: .rounded))
                }
            }
            .frame(minWidth: 36, maxWidth: 56, minHeight: 36)
            .foregroundStyle(highlighted ? Palette.onDone : Palette.text)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(highlighted ? Palette.done : Palette.control))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.kbdBorder))
            .shadow(color: .black.opacity(0.08), radius: 0.5, y: 1)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .simultaneousGesture(repeats ? DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard timer == nil else { return }
                action()
                let t = Timer(timeInterval: 0.45, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let r = Timer(timeInterval: 0.08, repeats: true) { _ in MainActor.assumeIsolated { action() } }
                        RunLoop.main.add(r, forMode: .common)
                        timer = r
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            .onEnded { _ in timer?.invalidate(); timer = nil } : nil)
        .accessibilityAction { action() }
    }
}
