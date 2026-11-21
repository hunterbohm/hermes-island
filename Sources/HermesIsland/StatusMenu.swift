import AppKit
import IslandCore

/// The menu bar item: who you talk with, how to start, whether the speech model and Accessibility are ready, the voice,
/// open at login, the settings file, and Quit. Everything else lives in the settings file.
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let coordinator: Coordinator

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
        super.init()
        item.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Hermes Island")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    /// Called when anything the menu or its icon shows may have changed.
    func refresh() {
        item.button?.image = NSImage(systemSymbolName: coordinator.talkRunning ? "waveform.circle.fill" : "waveform.circle",
                                     accessibilityDescription: "Hermes Island")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = coordinator.preferences.current
        let agent = settings.talkAgent
        let where_ = agent.map { $0.hostName.map { " on \($0)" } ?? " on this Mac" } ?? ""
        menu.addItem(disabled(agent.map { "Talking with \($0.name)\(where_)" } ?? "No agent set up"))
        if !coordinator.accessibilityGranted {
            menu.addItem(action("Allow Accessibility to use Left Control…", #selector(openAccessibility)))
        }
        switch coordinator.engineStatus {
        case .loading(.downloading(let fraction)): menu.addItem(disabled("Downloading the speech model, \(Int(fraction * 100))%"))
        case .loading: menu.addItem(disabled("Loading the speech model…"))
        case .failed(let why): menu.addItem(disabled("Speech model failed: \(why)"))
        case .ready: break
        }
        menu.addItem(.separator())
        let talk = action(coordinator.talkRunning ? "End Talk" : "Talk", #selector(toggleTalk))
        menu.addItem(talk)
        menu.addItem(disabled("Double-tap \(LiveTalkKey.name) to talk · \(LiveTalkKey.muteName) mutes"))
        menu.addItem(.separator())

        let voices = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for voice in OnMacVoice.offered {
            let entry = action(voice.title, #selector(pickVoice(_:)))
            entry.representedObject = voice
            entry.state = settings.liveTalk.voice == .onMac(voice) ? .on : .off
            voiceMenu.addItem(entry)
        }
        voices.submenu = voiceMenu
        menu.addItem(voices)
        let sounds = action("Sounds", #selector(toggleSounds))
        sounds.state = settings.sounds ? .on : .off
        menu.addItem(sounds)
        let login = action("Open at Login", #selector(toggleLogin))
        login.state = LaunchAgent.isOn(LaunchAgent.service.status) ? .on : .off
        menu.addItem(login)
        let startOver = action("Start a New Conversation", #selector(startOver))
        startOver.isEnabled = agent.map(coordinator.agents.hasConversation) ?? false
        menu.addItem(startOver)
        menu.addItem(action("Edit Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Hermes Island", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func toggleTalk() { coordinator.toggleTalk() }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let voice = sender.representedObject as? OnMacVoice else { return }
        coordinator.preferences.change { $0.liveTalk.voice = .onMac(voice) }
    }

    @objc private func toggleSounds() { coordinator.preferences.change { $0.sounds.toggle() } }

    @objc private func toggleLogin() {
        do { try LaunchAgent.set(!LaunchAgent.isOn(LaunchAgent.service.status)) } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// The next talk with the agent starts a new session instead of going on in the last one.
    @objc private func startOver() {
        guard let agent = coordinator.preferences.current.talkAgent else { return }
        coordinator.agents.startOver(agent.id)
    }

    /// Writes the settings to a JSON file, opens it, and reads it back when it is saved.
    @objc private func openSettings() { SettingsFile.open(coordinator.preferences) }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
