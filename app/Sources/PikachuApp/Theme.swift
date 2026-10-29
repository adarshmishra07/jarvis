import SwiftUI
import CoreText

enum Theme {
    static let black = Color(red: 0.02, green: 0.02, blue: 0.025)
    static let panel = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let line = Color(red: 0.2, green: 0.2, blue: 0.2)
    static let red = Color(red: 0.95, green: 0.14, blue: 0.12)
    static let redDim = Color(red: 0.55, green: 0.09, blue: 0.08)
    static let white = Color(red: 0.91, green: 0.91, blue: 0.92) // a touch below pure white: less glare on near-black
    static let dim = Color(red: 0.6, green: 0.6, blue: 0.63)
    /// "Your turn": Jarvis handed something over and needs you.
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.16)

    /// Geist Mono for HUD labels, numbers and code; Geist for reading text. Both OFL, bundled, registered at launch;
    /// if they are missing the system fonts are used.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist Mono", size: size).weight(weight) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Geist", size: size).weight(weight) }

    /// Tracking for uppercase HUD labels: about a tenth of the size (wide tracking at small sizes looks sparse).
    static func track(_ size: CGFloat) -> CGFloat { size * 0.1 }

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }

    static func label(_ text: String) -> some View {
        Text(text.uppercased()).font(mono(11, .medium)).tracking(track(11)).foregroundStyle(red)
    }
}

/// Faint grid and a red glow, drawn once behind everything.
struct HUDBackground: View {
    var body: some View {
        ZStack {
            Theme.black
            Canvas { ctx, size in
                var grid = Path()
                let step: CGFloat = 44
                var x: CGFloat = 0
                while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(grid, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            RadialGradient(colors: [Theme.red.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 700)
        }.ignoresSafeArea()
    }
}

/// Corner brackets and a tag, like a HUD panel.
struct HUDFrame: ViewModifier {
    let tag: String
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(Theme.panel.opacity(0.55))
            .overlay(alignment: .topLeading) { Text(tag).font(Theme.mono(9, .semibold)).tracking(2).foregroundStyle(Theme.red).padding(.horizontal, 6).background(Theme.black).offset(x: 14, y: -6) }
            .overlay(Brackets().stroke(Theme.red, lineWidth: 1.5))
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

extension View { func hud(_ tag: String) -> some View { modifier(HUDFrame(tag: tag)) } }

struct Brackets: Shape {
    var arm: CGFloat = 16
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            p.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y)); p.addLine(to: corner); p.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        }
        return p
    }
}

/// Arc-reactor style rings. `active` speeds them up and brightens the core.
struct ArcOrb: View {
    let active: Bool
    var body: some View {
        // Still when idle, so an always-open app costs no CPU; it spins up while listening or thinking.
        TimelineView(.animation(minimumInterval: nil, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let speed = active ? 3.0 : 0.6
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2 - 4
                func ring(_ radius: CGFloat, _ width: CGFloat, _ dash: [CGFloat], _ rot: Double, _ opacity: Double) {
                    var path = Path(); path.addArc(center: c, radius: radius, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                    var rc = ctx; rc.translateBy(x: c.x, y: c.y); rc.rotate(by: .radians(rot)); rc.translateBy(x: -c.x, y: -c.y)
                    rc.stroke(path, with: .color(Theme.red.opacity(opacity)), style: StrokeStyle(lineWidth: width, dash: dash))
                }
                ring(R, 1, [2, 6], t * 0.3 * speed, 0.7)
                ring(R * 0.82, 2, [40, 14, 8, 14], -t * 0.5 * speed, 0.9)
                ring(R * 0.62, 1, [], 0, 0.5)
                ring(R * 0.5, 3, [30, 20], t * 0.9 * speed, 0.95)
                let pulse = active ? 0.65 + 0.35 * sin(t * 6) : 0.5 + 0.1 * sin(t * 1.5)
                let core = R * 0.28
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)), with: .radialGradient(Gradient(colors: [.white.opacity(pulse), Theme.red.opacity(0.9), Theme.red.opacity(0)]), center: c, startRadius: 0, endRadius: core * 1.6))
            }
        }.accessibilityHidden(true)
    }
}

struct SpaceChip: View {
    let name: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(name.uppercased()).font(Theme.mono(11, .semibold)).tracking(1.4).padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Theme.dim)
                .background(on ? Theme.red.opacity(0.9) : Color.clear)
                .overlay(Rectangle().stroke(on ? Theme.red : Color.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name) space").accessibilityValue(on ? "on" : "off")
    }
}
