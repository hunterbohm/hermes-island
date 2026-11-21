import AppKit
import SwiftUI

/// A short note under the top of the screen for what the island can't show itself: a talk that failed, or no agent to
/// talk with. It goes after a few seconds and never takes focus or the mouse.
@MainActor final class Toast {
    private static let seconds = 7.0
    private let panel: NSPanel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var serial = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        host.sizingOptions = [.intrinsicContentSize]
    }

    func show(_ title: String, detail: String? = nil) {
        host.rootView = AnyView(ToastView(title: title, detail: detail))
        let size = host.fittingSize
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let top = screen.visibleFrame.maxY - 12
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: true)
        panel.orderFrontRegardless()
        serial += 1
        let current = serial
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.seconds))
            guard let self, self.serial == current else { return }
            self.hide()
        }
    }

    func hide() {
        serial += 1
        panel.orderOut(nil)
    }
}

private struct ToastView: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            if let detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
        .padding(8)
    }
}
