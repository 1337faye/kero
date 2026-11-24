import SwiftUI

/// A session's status as the desktop sidebar draws it (view.go statusIconP):
/// a ring turning while it works, or filling with a program's progress; an
/// amber ring with a pulsing dot when it needs the user; a red disc when it
/// failed; a ring with a cross once exited; a filled check when it finished
/// unseen, a faint check once seen.
struct StatusIcon: View {
    var status: PaneStatus
    var unread: Bool
    var progress: Int = -1
    var size: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates || reduceMotion)) { ctx in
            Canvas { g, sz in draw(&g, sz, ctx.date) }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    private var animates: Bool { status == .waiting || (status == .working && progress < 0) }

    var label: String {
        switch status {
        case .working: progress >= 0 ? "Working, \(progress)%" : "Working"
        case .waiting: "Needs you"
        case .exited: "Exited"
        case .failed: "Failed"
        case .idle: unread ? "Done" : "Idle"
        }
    }

    private func draw(_ g: inout GraphicsContext, _ sz: CGSize, _ now: Date) {
        let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
        let r = min(sz.width, sz.height) / 2 - 1
        let ms = now.timeIntervalSince1970 * 1000
        func circle(_ rad: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - rad, y: c.y - rad, width: rad * 2, height: rad * 2)) }
        func arc(from: Double, to: Double) -> Path {
            var p = Path()
            p.addArc(center: c, radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
            return p
        }
        let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round)
        switch status {
        case .working where progress >= 0:
            g.stroke(circle(r), with: .color(Palette.text.opacity(0.13)), style: stroke)
            g.stroke(arc(from: -90, to: -90 + 360 * max(0.02, Double(progress) / 100)), with: .color(Palette.text), style: stroke)
        case .working:
            g.stroke(circle(r), with: .color(Palette.text.opacity(0.13)), style: stroke)
            let deg = reduceMotion ? 0 : (ms.truncatingRemainder(dividingBy: 1000)) / 1000 * 360
            g.stroke(arc(from: deg, to: deg + 108), with: .color(Palette.text), style: stroke)
        case .waiting:
            g.stroke(circle(r), with: .color(Palette.attention), style: stroke)
            let pulse = reduceMotion ? 1 : 0.5 + 0.5 * sin(ms.truncatingRemainder(dividingBy: 1600) / 1600 * 2 * .pi)
            g.fill(circle(r * 0.42), with: .color(Palette.attention.opacity(0.65 + 0.35 * pulse)))
        case .failed:
            g.fill(circle(r + 0.5), with: .color(unread ? Palette.danger : Palette.danger.opacity(0.75)))
            var bar = Path()
            bar.move(to: CGPoint(x: c.x, y: c.y - r * 0.45)); bar.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.08))
            g.stroke(bar, with: .color(Palette.onDone), style: stroke)
            g.fill(circle(1).offsetBy(dx: 0, dy: r * 0.42), with: .color(Palette.onDone))
        case .exited:
            let col = unread ? Palette.danger : Palette.textFaint
            g.stroke(circle(r), with: .color(col), lineWidth: 1.5)
            let k = r * 0.38
            var x = Path()
            x.move(to: CGPoint(x: c.x - k, y: c.y - k)); x.addLine(to: CGPoint(x: c.x + k, y: c.y + k))
            x.move(to: CGPoint(x: c.x + k, y: c.y - k)); x.addLine(to: CGPoint(x: c.x - k, y: c.y + k))
            g.stroke(x, with: .color(col), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        case .idle where unread:
            g.fill(circle(r + 0.5), with: .color(Palette.done))
            var ck = Path()
            ck.move(to: CGPoint(x: c.x - r * 0.42, y: c.y + 0.2))
            ck.addLine(to: CGPoint(x: c.x - r * 0.08, y: c.y + r * 0.36))
            ck.addLine(to: CGPoint(x: c.x + r * 0.46, y: c.y - r * 0.34))
            g.stroke(ck, with: .color(Palette.onDone), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        case .idle:
            var ck = Path()
            ck.move(to: CGPoint(x: c.x - r * 0.62, y: c.y + 0.4))
            ck.addLine(to: CGPoint(x: c.x - r * 0.12, y: c.y + r * 0.5))
            ck.addLine(to: CGPoint(x: c.x + r * 0.66, y: c.y - r * 0.46))
            g.stroke(ck, with: .color(Palette.textFaint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// A host's name, in its color, as the sidebar tags a host's projects.
struct HostTag: View {
    var name: String
    var colorName: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Palette.hostColors[colorName] ?? Palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((Palette.hostColors[colorName] ?? Palette.textMuted).opacity(0.13)))
            .accessibilityLabel("on \(name)")
    }
}
