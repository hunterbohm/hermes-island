import IslandCore
import Foundation

/// `HermesIsland agent`: which agent a talk goes to, and `--hermes` to point talks at Hermes. The Hermes plugin's
/// `hermes island setup` and `status` run it, so the app stays the only writer of its settings.
@MainActor enum AgentCommand {
    struct Options {
        var hermes = false
        var host: String?
    }

    static func run(_ options: Options) -> Int32 {
        let preferences = Preferences()
        if options.hermes { preferences.change { $0.useHermes(host: options.host) } }
        SettingsStore.defaults.synchronize()
        guard let agent = preferences.current.talkAgent else {
            print(#"{"agent":null}"#)
            return 1
        }
        let row: [String: Any] = ["id": agent.id, "name": agent.name, "preset": agent.presetID, "command": agent.command,
                                  "host": agent.hostName ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: ["agent": row], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        return 0
    }
}
