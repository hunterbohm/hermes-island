import AppKit
import IslandCore
import Foundation

enum Mode {
    case app
    case listInputs
    case loginStatus
    case openAtLogin(Bool)
    case ttsCheck(Headless.TtsCheckOptions)
    case talkTest(TalkTest.Options)
    case call(CallCommand.Options)
    case agent(AgentCommand.Options)
    case usage(String)

    static let usage = """
        usage: HermesIsland
                   Runs the island in the menu bar. Double-tap Left Control to talk with your agent.
               HermesIsland --list-inputs
                   Prints the audio inputs, the system default, and what Automatic picks.
               HermesIsland --login-status
                   Prints whether macOS holds the launch agent that starts the app at login.
               HermesIsland --open-at-login on|off
                   Turns the launch agent on or off, as Open at Login in the menu does.
               HermesIsland --tts-check [--voice NAME] [--text TEXT] [--pack DIR | --directory DIR] [--out FILE.wav]
                   Says one sentence with the on-Mac Phonon voice and prints one JSON line of timings. Exits 1 if no
                   sound came out. The voice is en_us_Preston unless given.
               HermesIsland --test-talk [--preset ID] [--command 'hermes acp'] [--host HOST] [--voice MODEL:VOICE]
                         [--voice-server URL [--voice-name NAME]] [--option ID=VALUE]... [--note TEXT] [--out PATH.wav]
                         [--call-back ABOUT RESULT_FILE [--ring SECONDS]] [--thread FILE [--start-over]] [--warm]
                         [--models DIR] CLIP.wav...
                   Holds a live talk with no microphone or speakers: each clip is played in as your next turn, in real
                   time, and the agent's voice is made but not played. One JSON line per turn with its timings, then one
                   with the session and how long the talk took to start. --thread FILE remembers the session in FILE;
                   without it nothing is remembered. --warm gets the agent and its session ready first, as the running
                   app keeps them, so the start is timed as a double tap would find it.
                   --call-back starts the talk as a call back about ABOUT with the result in RESULT_FILE. --ring
                   SECONDS first readies the agent and the voice for that long, as the island does while it rings.
               HermesIsland call --about TEXT [--from NAME] [--agent ID_OR_NAME] [--ring SECONDS] [--result-file PATH] < RESULT
                   Calls you back with a finished job's result: the running app rings on the island, and when you answer,
                   a live talk starts in which the agent says the result. Prints one JSON line per status. Exits 0 when
                   the result was said, 3 when it should be texted instead, 4 when you are busy, 5 when it could not ring.
               HermesIsland call --check
                   Prints whether this Mac says you are busy now, as JSON, and exits 0 when free and 4 when busy.
               HermesIsland agent [--hermes [--host HOST]]
                   Prints the agent a talk goes to, as JSON. --hermes makes it Hermes over ACP, on this Mac or over ssh
                   on HOST; a Hermes already set up keeps its other settings. The running app applies it at once.
        """

    /// Anything that is not a headless flag runs the app, since LaunchServices can pass its own arguments.
    init(arguments: [String]) {
        var rest = arguments[...]
        do {
            switch rest.popFirst() {
            case "--list-inputs":
                self = .listInputs
            case "--login-status":
                self = .loginStatus
            case "--open-at-login":
                self = .openAtLogin(try Self.switchValue(of: "--open-at-login", from: &rest))
            case "--tts-check":
                var options = Headless.TtsCheckOptions()
                while let flag = rest.popFirst() {
                    switch flag {
                    case "--voice": options.voice = try Self.value(of: flag, from: &rest)
                    case "--text": options.text = try Self.value(of: flag, from: &rest)
                    case "--pack": options.pack = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--directory": options.directory = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    case "--out": options.out = URL(fileURLWithPath: try Self.value(of: flag, from: &rest))
                    default: throw IslandError("unknown option \(flag)")
                    }
                }
                self = .ttsCheck(options)
            case "--test-talk":
                var options = TalkTest.Options()
                var server: String?, serverVoice = ""
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--preset":
                        options.preset = try Self.value(of: argument, from: &rest)
                        guard AgentPreset.with(id: options.preset) != nil else { throw IslandError("--preset is one of \(AgentPreset.all.map(\.id).joined(separator: ", "))") }
                    case "--command": options.command = ShellWords.split(try Self.value(of: argument, from: &rest))
                    case "--host": options.remoteHost = try Self.value(of: argument, from: &rest)
                    case "--voice":
                        let parts = try Self.value(of: argument, from: &rest).split(separator: ":", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let model = OnMacVoice.Model(rawValue: parts[0]) else { throw IslandError("--voice takes MODEL:VOICE, such as phonon:en_us_Preston") }
                        options.voice = .onMac(OnMacVoice(model: model, voice: parts[1]))
                    case "--voice-server": server = try Self.value(of: argument, from: &rest)
                    case "--voice-name": serverVoice = try Self.value(of: argument, from: &rest)
                    case "--note": options.note = try Self.value(of: argument, from: &rest)
                    case "--thread": options.threadFile = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--start-over": options.startOver = true
                    case "--warm": options.warm = true
                    case "--call-back":
                        let about = try Self.value(of: argument, from: &rest)
                        let file = try Self.value(of: argument, from: &rest)
                        options.callBack = (about, try String(contentsOfFile: file, encoding: .utf8))
                    case "--ring": options.ring = try Self.number(of: argument, from: &rest, Double.init, in: 0...60)
                    case "--option":
                        let pair = try Self.value(of: argument, from: &rest).split(separator: "=", maxSplits: 1).map(String.init)
                        guard pair.count == 2 else { throw IslandError("--option takes ID=VALUE") }
                        options.talkOptions.append(.option(id: pair[0], value: pair[1]))
                    case "--out": options.out = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--models": options.models = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case let flag where flag.hasPrefix("--"): throw IslandError("unknown option \(flag)")
                    default: options.clips.append(URL(fileURLWithPath: argument))
                    }
                }
                if let server { options.voice = .server(url: server, voice: serverVoice) }
                if options.clips.isEmpty { throw IslandError("--test-talk needs at least one CLIP.wav") }
                self = .talkTest(options)
            case "agent":
                var options = AgentCommand.Options()
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--hermes": options.hermes = true
                    case "--host": options.host = try Self.value(of: argument, from: &rest)
                    default: throw IslandError("unknown option \(argument)")
                    }
                }
                if options.host != nil, !options.hermes { throw IslandError("--host goes with --hermes") }
                self = .agent(options)
            case "call":
                var options = CallCommand.Options()
                while let argument = rest.popFirst() {
                    switch argument {
                    case "--about": options.about = try Self.value(of: argument, from: &rest)
                    case "--from": options.from = try Self.value(of: argument, from: &rest)
                    case "--agent": options.agent = try Self.value(of: argument, from: &rest)
                    case "--ring": options.ring = try Self.number(of: argument, from: &rest, Double.init, in: 0...300)
                    case "--result-file": options.resultFile = URL(fileURLWithPath: try Self.value(of: argument, from: &rest))
                    case "--check": options.check = true
                    default: throw IslandError("unknown option \(argument)")
                    }
                }
                if options.from.trimmingCharacters(in: .whitespaces).isEmpty { throw IslandError("--from can't be empty") }
                self = .call(options)
            case "--help", "-h":
                self = .usage(Self.usage)
            default:
                self = .app
            }
        } catch {
            self = .usage("\(error.localizedDescription)\n\(Self.usage)")
        }
    }

    private static func value(of flag: String, from rest: inout ArraySlice<String>) throws -> String {
        guard let value = rest.popFirst() else { throw IslandError("\(flag) needs a value") }
        return value
    }

    private static func switchValue(of flag: String, from rest: inout ArraySlice<String>) throws -> Bool {
        switch try value(of: flag, from: &rest) {
        case "on": true
        case "off": false
        default: throw IslandError("\(flag) takes on or off")
        }
    }

    private static func number<N: Comparable>(of flag: String, from rest: inout ArraySlice<String>,
                                              _ parse: (String) -> N?, in range: ClosedRange<N>) throws -> N {
        guard let number = parse(try value(of: flag, from: &rest)), range.contains(number) else {
            throw IslandError("\(flag) takes a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return number
    }
}

/// The commands that run without the island.
enum Headless {
    static func listInputs() -> Int32 {
        let inputs = AudioDevices.inputs()
        for input in inputs { print("\(input.name)\t\(input.uid)") }
        print("default: \(AudioDevices.defaultInput().map { "\($0.name) (\($0.uid))" } ?? "none")")
        // What Automatic picks now, by the saved order, with the lid and the system default as they are.
        AudioDevices.automaticOrder = (SettingsStore.read(SettingsStore.defaults) ?? IslandSettings()).automaticOrder
        let automatic = if case .device(let uid) = AudioDevices.source(for: .automatic, among: inputs) {
            inputs.first { $0.uid == uid }.map { "\($0.name) (\($0.uid))" } ?? uid
        } else { "system default" }
        print("automatic: \(automatic)")
        if inputs.isEmpty { print("no audio inputs") }
        return 0
    }

    private static func emit(_ row: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
