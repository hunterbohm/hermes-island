import IslandCore
import Foundation

/// What a talk adds to an agent's session besides its own settings: MCP servers, session options, and a line for the
/// note that goes with each turn. The island adds none today; the hook stays so a later one can give a talk tools.
struct TalkExtras: Sendable {
    var servers: [JSONValue] = []
    /// Set on the session first. If the agent turns one down, the talk starts without these extras.
    var options: [ConfigChoice] = []
    var note = ""
    /// The name of a project, for the question asked before a thread starts there.
    var projectName: (@Sendable (String) async -> String?)?
}
