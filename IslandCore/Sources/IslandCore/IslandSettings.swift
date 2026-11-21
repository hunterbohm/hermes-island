import Foundation

/// What the island keeps: who you talk with, the voice, the microphone and the cues. Its keys match Hermes Island's
/// settings, so the first launch can take over a Hermes Island user's agents and voice as they are.
public struct IslandSettings: Equatable, Codable, Sendable {
    public var agents = AgentSettings()
    public var liveTalk = LiveTalkSettings()
    public var microphone = MicrophoneChoice.automatic
    /// The microphones placed in order for Automatic. Empty means the kind order.
    public var automaticOrder = AutomaticOrder()
    public var sounds = true

    public init() {}

    /// A value that doesn't read keeps its default, so a newer or older store never loses the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = IslandSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        agents = value(.agents, defaults.agents)
        liveTalk = value(.liveTalk, defaults.liveTalk)
        microphone = value(.microphone, defaults.microphone)
        automaticOrder = value(.automaticOrder, defaults.automaticOrder)
        sounds = value(.sounds, defaults.sounds)
    }

    /// The agent a talk goes to, or nil when none is set up.
    public var talkAgent: AgentConnection? { liveTalk.agent(in: agents) }

    /// Settings for a first launch with nothing to take over: Hermes over ACP on this Mac, which a user changes in the
    /// settings file when Hermes runs on another Mac.
    public static var firstRun: IslandSettings {
        var settings = IslandSettings()
        if let hermes = AgentPreset.with(id: "hermes") {
            let agent = hermes.connection()
            settings.agents.agents = [agent]
            settings.agents.defaultAgent = agent.id
        }
        return settings
    }
}
