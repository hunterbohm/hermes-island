import Foundation

/// The talk's agent is kept running between talks with its session open, so a double tap doesn't wait for the agent to
/// start and the session to open: over ssh to Hermes that is about 6 to 9 s. These are the rules for keeping it ready.
public enum Standby {
    /// How long to wait before starting the agent again after it stopped, or failed to start, `failures` times in a row:
    /// soon after the first, as after a dropped link, then longer while it keeps failing, as when the other Mac is asleep.
    public static func retryDelay(afterFailures failures: Int) -> Double {
        let steps: [Double] = [2, 10, 30, 60, 300]
        return steps[min(max(failures, 1), steps.count) - 1]
    }

    /// A kept agent idle this long is asked whether it still answers before a talk uses it, since a link can die without
    /// a word while the Mac sleeps or changes network.
    public static let checkAfterIdle = 30.0
    /// How long that check waits. A live agent turns it down in well under a second.
    public static let checkTimeout = 2.0
    /// The request the check sends: no agent offers it, so a live one answers at once that it doesn't.
    public static let checkMethod = "$/ping"
}

/// From the double tap to a talk that hears you, for the log and the end-to-end test, so a slow start says which part
/// was slow.
public struct ConnectClock: Equatable, Sendable {
    public enum Step: String, CaseIterable, Sendable {
        /// The microphone and the speakers were running.
        case audio
        /// The agent was running and had answered `initialize`.
        case agent
        /// The talk's session was open, with its options set. The talk hears you from here.
        case session
        /// The voice was loaded.
        case voice
    }

    public let start: Instant
    public private(set) var marks: [Step: Instant] = [:]

    public init(start: Instant) { self.start = start }

    /// Records a step the first time it happens.
    public mutating func mark(_ step: Step, at time: Instant) {
        if marks[step] == nil { marks[step] = time }
    }

    public func seconds(_ step: Step) -> Double? { marks[step].map { $0 - start } }

    /// "audio 0.05 s, agent 0.00 s, session 0.01 s, voice 0.31 s after the key"
    public var summary: String {
        let parts = Step.allCases.compactMap { step in seconds(step).map { step.rawValue + String(format: " %.2f s", $0) } }
        return parts.joined(separator: ", ") + " after the key"
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        for step in Step.allCases {
            if let value = seconds(step) { object[step.rawValue] = .number((value * 1000).rounded() / 1000) }
        }
        return .object(object)
    }
}

/// Lip Service, which Hermes Island grew out of, still has a live talk of its own on the same double tap of Left
/// Control. With both on, one double tap starts two talks with the agent and each says the reply, so the agent is heard
/// twice. Hermes Island stays out of the way while Lip Service's is on, and says how to move the talks here.
public enum TalkRival {
    public static let name = "Lip Service"

    /// Whether Lip Service's settings, the JSON it keeps under `settings`, would have it start a talk on a double tap: its
    /// Live talk is on, it has an agent to talk with, and none of its own keys is Left Control alone, which turns its talk
    /// off. The JSON reads as Hermes Island's own, since the island's keys are Lip Service's.
    public static func talks(settings: Data?) -> Bool {
        guard let settings, let read = try? JSONDecoder().decode(IslandSettings.self, from: settings),
              read.liveTalk.enabled, read.talkAgent != nil
        else { return false }
        guard let keys = try? JSONDecoder().decode(Keys.self, from: settings) else { return true }
        // Its Ghostwrite and Hand off keys count only once it has an agent, which it has here.
        let capture = CaptureKeys(dictation: keys.hotkeys ?? [], ghostwrite: keys.ghostwriteKey, handOff: keys.handOffKey)
        return LiveTalkKey.conflict(with: capture) == nil
    }

    /// Lip Service's own keys, which the island doesn't keep.
    private struct Keys: Decodable {
        var hotkeys: [Shortcut]?
        var ghostwriteKey: Shortcut?
        var handOffKey: Shortcut?
    }

    public static let title = "\(name) took this talk"
    public static let detail = "Its Live talk is on, so it answers the double tap too, and you'd hear the agent twice. "
        + "Turn off Live talk in \(name)'s settings to talk here."
}
