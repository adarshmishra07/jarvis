import AppKit
import SwiftUI

/// Jarvis's live activity: a black island that grows out of the notch while Jarvis is active (top centre on Macs without
/// one), in the app's HUD style. It shows on every Space and over full-screen apps, never takes focus, and clicking
/// it stops Jarvis.
@MainActor
final class FloatingStatus {
    enum State: Equatable {
        case listening, thinking, speaking, notes
        var label: String { switch self { case .listening: "LISTENING"; case .thinking: "THINKING"; case .speaking: "SPEAKING"; case .notes: "TAKING NOTES" } }
    }

    final class Shown: ObservableObject {
        @Published var state: State = .listening
        @Published var open = false
        var notch: CGFloat = 0
    }

    private static let ear: CGFloat = 150
    private let panel: NSPanel
    private let shown = Shown()
    private var hiding: DispatchWorkItem?

    init(onStop: @escaping () -> Void) {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .statusBar // above the menu bar, which the island sits in
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: Island(shown: shown, onStop: onStop))
    }

    /// Shows the state, or folds the island back into the notch for nil.
    func show(_ state: State?) {
        guard let state else {
            guard shown.open else { return }
            shown.open = false
            let hide = DispatchWorkItem { [panel] in panel.orderOut(nil) }
            hiding = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: hide)
            return
        }
        hiding?.cancel(); hiding = nil
        if shown.state != state { shown.state = state }
        guard !shown.open else { return }
        place()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [shown] in shown.open = true } // after the first frame, so it grows out of the notch
    }

    /// Centred on the notch of the screen that has one, else at the top centre of the main screen.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let f = screen.frame
        let notched = screen.safeAreaInsets.top > 0
        var notch: CGFloat = 0, centre = f.midX
        if notched, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = right.minX - left.maxX
            centre = f.minX + (left.maxX + right.minX) / 2
        }
        let height = notched ? screen.safeAreaInsets.top : NSStatusBar.system.thickness + 8
        shown.notch = notch
        let width = notch + Self.ear * 2
        panel.setFrame(NSRect(x: centre - width / 2, y: f.maxY - height, width: width, height: height), display: true)
    }
}

private struct Island: View {
    @ObservedObject var shown: FloatingStatus.Shown
    let onStop: () -> Void

    var body: some View {
        GeometryReader { geo in
            let full = geo.size.width
            let width = shown.open ? full : max(shown.notch, 1)
            Button(action: onStop) {
                HStack(spacing: 0) {
                    Indicator(state: shown.state).frame(width: 22, height: 18).frame(maxWidth: .infinity)
                    Spacer().frame(width: shown.notch)
                    HStack(spacing: 8) {
                        Text(shown.state.label)
                            .font(Theme.mono(11, .semibold)).tracking(Theme.track(11))
                            .foregroundStyle(shown.state == .notes ? Theme.red : Theme.white)
                            .lineLimit(1).fixedSize()
                        // The stop button: clicking anywhere on the island stops, this says so.
                        RoundedRectangle(cornerRadius: 1.5).fill(Theme.red).frame(width: 8, height: 8)
                            .padding(5).overlay(Circle().stroke(Theme.red.opacity(0.6), lineWidth: 1))
                    }
                    .frame(maxWidth: .infinity)
                }
                .opacity(shown.open ? 1 : 0)
                .frame(width: width, height: geo.size.height)
                .background(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(.black))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.red.opacity(shown.open ? 0.55 : 0)).frame(width: max(0, width - 24), height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: full, height: geo.size.height)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shown.open)
            .animation(.easeInOut(duration: 0.2), value: shown.state)
        }
        .help("Jarvis is \(shown.state.label.lowercased()). Click to stop.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Jarvis is \(shown.state.label.lowercased())")
        .accessibilityAddTraits(.isButton)
    }
}

/// The arc reactor while listening (slow) and thinking (fast), red bars while speaking, a blinking dot for notes.
private struct Indicator: View {
    let state: FloatingStatus.State

    var body: some View {
        switch state {
        case .listening: ArcOrb(active: false)
        case .thinking: ArcOrb(active: true)
        case .speaking:
            TimelineView(.animation) { time in
                let t = time.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2.5) {
                    ForEach(0..<5) { i in
                        Capsule().fill(Theme.red).frame(width: 2.5, height: 18 * (0.25 + 0.75 * abs(sin(t * 7 + Double(i) * 0.8))))
                    }
                }
            }
        case .notes:
            TimelineView(.animation) { time in
                Circle().fill(Theme.red).frame(width: 8, height: 8)
                    .opacity(0.4 + 0.6 * (sin(time.date.timeIntervalSinceReferenceDate * 3) + 1) / 2)
            }
        }
    }
}
