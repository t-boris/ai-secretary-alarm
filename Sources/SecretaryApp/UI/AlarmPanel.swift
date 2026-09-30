import AppKit
import SecretaryCore
import SwiftUI

/// Always-on-top, non-activating panels that stay until dismissed (DEC-025).
@MainActor
final class AlarmPanelController {
    private var panels: [NSPanel] = []
    private let width: CGFloat = 420

    func show(_ alarm: AlarmContent, snooze: @escaping (Int) -> Void,
              done: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        showNotice(heading: alarm.heading, body: alarm.body, symbol: symbol(for: alarm.kind),
                   snooze: snooze, done: done, onDismiss: onDismiss)
    }

    /// Generic persistent notice, e.g. Google sign-in expired (DEC-012).
    func showNotice(heading: String, body: String, symbol: String, action: (title: String, run: () -> Void)? = nil,
                    snooze: ((Int) -> Void)? = nil, done: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let view = AlarmPanelView(heading: heading, bodyText: body, symbol: symbol, action: action,
                                  snooze: snooze, done: done) { [weak self, weak panel] in
            guard let self, let panel else { return }
            onDismiss?()
            self.dismiss(panel)
        }
        let host = NSHostingView(rootView: view.frame(width: width))
        host.layout()
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        panels.append(panel)
        layout()
        panel.orderFrontRegardless()
    }

    private func dismiss(_ panel: NSPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for panel in panels {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 12, y: top - size.height))
            top -= size.height + 8
        }
    }

    private func symbol(for kind: ReminderKind) -> String {
        switch kind {
        case .standard: return "alarm.fill"
        case .getReady: return "tshirt.fill"
        case .leaveNow: return "figure.walk.departure"
        }
    }
}

private struct AlarmPanelView: View {
    let heading: String
    let bodyText: String
    let symbol: String
    let action: (title: String, run: () -> Void)?
    let snooze: ((Int) -> Void)?
    let done: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(heading).font(.headline)
                Text(bodyText).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let snooze {
                    HStack(spacing: 8) {
                        Text("Remind again").font(.caption).foregroundStyle(.secondary)
                        Button("5 min") { snooze(5); dismiss() }
                        Button("10 min") { snooze(10); dismiss() }
                        Button("1 hour") { snooze(60); dismiss() }
                    }
                    .controlSize(.small)
                }
                HStack {
                    Spacer()
                    if let done {
                        Button("Done today") { done(); dismiss() }
                    }
                    if let action {
                        Button(action.title) {
                            action.run()
                            dismiss()
                        }
                    }
                    Button("Dismiss", action: dismiss).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.6), lineWidth: 1))
    }
}
