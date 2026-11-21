import AppKit
import IslandCore
import Foundation

/// Settings > Edit Settings: the settings as a JSON file in the support folder, opened in the user's text editor.
/// While the app runs, a save applies at once; a file that doesn't read is left alone and the settings stay as they were.
@MainActor enum SettingsFile {
    static let url = SupportFolder.url.appending(path: "settings.json")
    private static var watch: Timer?
    private static var stamp: Date?

    static func open(_ preferences: Preferences) {
        SupportFolder.makePrivate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(preferences.current), (try? data.write(to: url, options: .atomic)) != nil else { return }
        stamp = modified()
        NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { check(preferences) }
        }
    }

    private static func check(_ preferences: Preferences) {
        guard let now = modified(), now != stamp else { return }
        stamp = now
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(IslandSettings.self, from: data) else { return }
        preferences.change { $0 = settings }
    }

    private static func modified() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
