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
        if let updater = coordinator.updater, let offer = updater.offered {
            menu.addItem(action("Update to \(offer.version.tag)…", #selector(installUpdate)))
        }
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
        if let updater = coordinator.updater {
            menu.addItem(.separator())
            if updater.lastInstallFailed { menu.addItem(action("The last update didn't install. Show Log", #selector(showUpdateLog))) }
            let check = action("Check for Updates…", #selector(checkForUpdates))
            check.isEnabled = !updater.busy
            menu.addItem(check)
            let automatic = action("Check for Updates Automatically", #selector(toggleAutomaticUpdates))
            automatic.state = updater.automatic ? .on : .off
            menu.addItem(automatic)
        }
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
        coordinator.agents.ready()
    }

    /// Writes the settings to a JSON file, opens it, and reads it back when it is saved.
    @objc private func openSettings() { SettingsFile.open(coordinator.preferences) }

    @objc private func openAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func checkForUpdates() {
        guard let updater = coordinator.updater else { return }
        Task {
            let readable = await updater.fetch()
            if let offer = updater.offered { return confirmAndInstall(offer) }
            let alert = NSAlert()
            alert.messageText = readable ? "Hermes Island is up to date" : "Couldn't check for updates"
            alert.informativeText = readable ? "You have \(updater.channel.current.tag), the newest release."
                : "The update server did not answer. Try again later."
            alert.runModal()
        }
    }

    @objc private func installUpdate() {
        guard let offer = coordinator.updater?.offered else { return }
        confirmAndInstall(offer)
    }

    @objc private func toggleAutomaticUpdates() { coordinator.updater?.automatic.toggle() }

    @objc private func showUpdateLog() {
        guard let updater = coordinator.updater else { return }
        NSWorkspace.shared.open(updater.logURL)
    }

    /// Asks once, then downloads and checks the release and quits so it can be installed. Hermes Island starts again by
    /// itself when the install is done.
    private func confirmAndInstall(_ offer: ReleaseFeed) {
        guard let updater = coordinator.updater else { return }
        let alert = NSAlert()
        alert.messageText = "Update Hermes Island to \(offer.version.tag)?"
        alert.informativeText = "You have \(updater.channel.current.tag). It downloads the new version, checks that it is signed by the same developer, then quits and starts again."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await updater.install(offer, canQuit: !coordinator.inCall)
                NSApp.terminate(nil)
            } catch {
                let failed = NSAlert()
                failed.messageText = "Couldn't update to \(offer.version.tag)"
                failed.informativeText = "\((error as? LocalizedError)?.errorDescription ?? "\(error)") You still have \(updater.channel.current.tag)."
                failed.runModal()
            }
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
