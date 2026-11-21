import Foundation

/// What the island keeps: who you talk with, the voice, the microphone and the cues. Its keys match Lip Service's
/// settings, so the first launch can take over a Lip Service user's agents and voice as they are.
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

    /// `HermesIsland agent --hermes`: talks go to Hermes over ACP, on this Mac, or over ssh on `host`. A Hermes already
    /// set up keeps its command, note and options; only where it runs changes.
    public mutating func useHermes(host: String?) {
        let host = host?.trimmingCharacters(in: .whitespaces)
        let remoteHost = host?.isEmpty == false ? host : nil
        if let index = agents.agents.firstIndex(where: { $0.presetID == "hermes" }) {
            agents.agents[index].remoteHost = remoteHost
            liveTalk.agentID = agents.agents[index].id
        } else if let hermes = AgentPreset.with(id: "hermes") {
            var agent = hermes.connection()
            agent.remoteHost = remoteHost
            agents.agents.append(agent)
            liveTalk.agentID = agent.id
            if agents.defaultAgent == nil { agents.defaultAgent = agent.id }
        }
    }
}
