import AppKit
import ApplicationServices
import CoreGraphics
import IslandCore
import os

/// Watches the keyboard for the two keys the island answers to: a double tap of Left Control alone, which starts and
/// ends a talk, and ⌃⌥M while a talk runs, which mutes it. Every other key passes untouched; the island never listens
/// on fn or Right Control. The tap is active, not listen-only, so it can keep ⌃⌥M from also typing into the app in
/// front, and that needs Accessibility rather than Input Monitoring.
@MainActor final class KeyTap {
    var onDoubleTap: (() -> Void)?
    /// ⌃⌥M while a talk runs.
    var onMuteKey: (() -> Void)?
    /// A talk runs, so ⌃⌥M is taken.
    var talking = false
    var isRunning: Bool { tap != nil }

    private let log = Logger(subsystem: "dev.hermes-island.app", category: "keys")
    private var tap: CFMachPort?
    private var trustTimer: Timer?
    private var doubleTap = DoubleTapDetector()
    /// The mute key, swallowed going down, so its repeats and its release are swallowed too.
    private var swallowedKey: Int?
    /// A click while Left Control is down, as in Control-click, means the press was not a tap. Watched only while it is
    /// down, by a monitor that never holds up the click.
    private var clickWatch: Any?

    /// Creates the tap once Accessibility allows it, checking every 2 s. `prompting` shows the system's prompt now.
    func start(prompting: Bool) {
        guard tap == nil else { return }
        if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompting] as CFDictionary), createTap() {
            return log.notice("key tap on")
        }
        log.notice("key tap waits for Accessibility")
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryTap() }
        }
    }

    var onRunning: (() -> Void)?

    private func retryTap() {
        guard AXIsProcessTrusted(), createTap() else { return }
        trustTimer?.invalidate()
        trustTimer = nil
        log.notice("key tap on")
        onRunning?()
    }

    private func createTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
            | 1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyTapCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    /// One key event. Returns whether to swallow it.
    fileprivate func handle(kind: KeyInput.EventKind, keyCode: Int, flags: UInt64, isRepeat: Bool) -> Bool {
        if let input = DoubleTapDetector.input(kind: kind, keyCode: keyCode, flags: flags) {
            if input == .down { watchClicks() } else { stopWatchingClicks() }
            if doubleTap.feed(input, at: .now) {
                log.notice("Left Control double-tapped")
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onDoubleTap?() } }
            }
        }
        if talking, kind == .keyDown, LiveTalkKey.isMute(keyCode: keyCode, flags: flags) {
            if !isRepeat { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onMuteKey?() } } }
            swallowedKey = keyCode
            return true
        }
        guard kind != .flagsChanged, swallowedKey == keyCode else { return false }
        if kind == .keyUp { swallowedKey = nil }
        return true
    }

    private func watchClicks() {
        guard clickWatch == nil else { return }
        clickWatch = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                _ = self.doubleTap.feed(.other, at: .now)
                self.stopWatchingClicks()
            }
        }
    }

    private func stopWatchingClicks() {
        if let clickWatch { NSEvent.removeMonitor(clickWatch) }
        clickWatch = nil
    }

    /// The system disables a tap whose callback was slow.
    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log.info("key tap was switched off by the system and is back on")
    }
}

/// Runs on the main run loop, where the tap's source is installed.
private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let keyTap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    let kind: KeyInput.EventKind
    switch type {
    case .keyDown: kind = .keyDown
    case .keyUp: kind = .keyUp
    case .flagsChanged: kind = .flagsChanged
    default:
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { keyTap.reenable() }
        }
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let swallow = MainActor.assumeIsolated {
        keyTap.handle(kind: kind, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
