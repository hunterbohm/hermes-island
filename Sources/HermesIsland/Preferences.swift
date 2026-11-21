import IslandCore
import Foundation
import os

/// The single owner of the island's settings, kept as JSON under `settings` in the app's UserDefaults. Edit them with
/// `defaults` or Settings > Open settings file, which the app reads again when it changes.
@MainActor final class Preferences {
    private(set) var current: IslandSettings
    var onChange: ((_ old: IslandSettings, _ new: IslandSettings) -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = SettingsStore.defaults) {
        self.defaults = defaults
        if let stored = SettingsStore.read(defaults) {
            current = stored
        } else {
            current = SettingsStore.isReal ? (Migration.fromLipService() ?? .firstRun) : .firstRun
            SettingsStore.write(current, to: defaults)
        }
        AudioDevices.automaticOrder = current.automaticOrder
    }

    func change(_ edit: (inout IslandSettings) -> Void) {
        var next = current
        edit(&next)
        apply(next)
    }

    /// Reads the store again, for a change made with `defaults write` while the app runs.
    func reload() {
        defaults.synchronize()
        if let stored = SettingsStore.read(defaults) { apply(stored, save: false) }
    }

    private func apply(_ next: IslandSettings, save: Bool = true) {
        guard next != current else { return }
        if save { SettingsStore.write(next, to: defaults) }
        let old = current
        current = next
        AudioDevices.automaticOrder = next.automaticOrder
        onChange?(old, next)
    }
}

/// Where the settings live in UserDefaults.
enum SettingsStore {
    static let settingsKey = "settings"

    /// `ISLAND_DEFAULTS` names a suite to keep the settings in instead, so a test never touches the real ones.
    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["ISLAND_DEFAULTS"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static var isReal: Bool { ProcessInfo.processInfo.environment["ISLAND_DEFAULTS"] == nil }

    static func read(_ defaults: UserDefaults) -> IslandSettings? {
        defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(IslandSettings.self, from: $0) }
    }

    static func write(_ settings: IslandSettings, to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(settings) { defaults.set(data, forKey: settingsKey) }
    }
}

/// The first launch takes over what a Lip Service user already set up for live talk: the agents, the talk's agent and
/// voice, the microphone and the cues, and the session each agent's last talk ended in. Lip Service's own settings and
/// files are only read, never changed.
@MainActor enum Migration {
    static let lipServiceDomain = "com.hunterbohm.dictation"
    private static let log = Logger(subsystem: "com.hunterbohm.hermesisland", category: "settings")

    static func fromLipService() -> IslandSettings? {
        guard let data = UserDefaults(suiteName: lipServiceDomain)?.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(IslandSettings.self, from: data), !settings.agents.agents.isEmpty
        else { return nil }
        let threads = URL.applicationSupportDirectory.appending(path: "Dictation/talk-threads.json")
        let mine = TalkThreadStore.defaultURL
        if FileManager.default.fileExists(atPath: threads.path), !FileManager.default.fileExists(atPath: mine.path) {
            SupportFolder.makePrivate()
            try? FileManager.default.copyItem(at: threads, to: mine)
        }
        log.info("took over Lip Service's live talk settings: \(settings.agents.agents.count) agents")
        return settings
    }
}
