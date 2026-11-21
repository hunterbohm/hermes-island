import AppKit
import IslandCore
import SwiftUI

/// Bars other apps draw along a screen's edges, which macOS leaves inside the visible frame: the top bar of a tiling
/// window manager such as OmniWM or AeroSpace with SketchyBar, or a strip another app keeps at a side. Read from the
/// window list, whose bounds need no permission.
@MainActor enum OtherBars {
    static func clear(_ screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        guard let bars = windows() else { return visible }
        return NSRect(BarRect(visible).clear(of: bars))
    }

    /// The whole screen less the strips other apps' bars cover, for the live-talk island, which sits above the macOS menu
    /// bar and so measures from the top of the screen, not from under the menu bar. A bar just under a visible menu bar
    /// counts too. The menu bar itself is not another app's bar.
    static func clearOfFrame(_ screen: NSScreen) -> NSRect {
        let frame = screen.frame
        guard let bars = windows() else { return frame }
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 0)
        return NSRect(BarRect(frame).clear(of: bars, touch: menuBar + 2))
    }

    /// Other apps' windows that could be a bar, in AppKit's coordinates, or nil when the window list cannot be read.
    private static func windows() -> [BarRect]? {
        guard let primary = NSScreen.screens.first?.frame,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        let normal = Int(CGWindowLevelForKey(.normalWindow)), saver = Int(CGWindowLevelForKey(.screenSaverWindow))
        return list.compactMap { window in
            // Above ordinary windows but under the screen saver, and more than a hairline such as a window border.
            // The Dock, already outside the visible frame, and the hidden menu bar, which slides over everything only
            // while the mouse is at the top, are not bars to avoid.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer > normal, layer < saver,
                  window[kCGWindowOwnerPID as String] as? Int32 != me,
                  !["Dock", "Window Server"].contains(window[kCGWindowOwnerName as String] as? String ?? ""),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 4, rect.height >= 4
            else { return nil }
            // The window list measures from the top of the main screen, AppKit from its bottom.
            return BarRect(x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
    }
}

extension BarRect {
    init(_ rect: NSRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}

extension NSRect {
    init(_ rect: BarRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
}

struct AgentAvatar: View {
    let initial: String
    let size: CGFloat

    var body: some View {
        Circle().fill(Theme.blue).frame(width: size, height: size)
            .overlay(Text(initial).font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(.white))
    }
}
