import Foundation
import Testing
@testable import IslandCore

@Suite("Standby") struct StandbyTests {
    @Test func retriesSoonThenBackOff() {
        #expect(Standby.retryDelay(afterFailures: 0) == 2)
        #expect(Standby.retryDelay(afterFailures: 1) == 2)
        #expect(Standby.retryDelay(afterFailures: 2) == 10)
        #expect(Standby.retryDelay(afterFailures: 5) == 300)
        #expect(Standby.retryDelay(afterFailures: 40) == 300)
    }

    @Test func connectClockSaysEachStepAfterTheKey() {
        let start = Instant.now
        var clock = ConnectClock(start: start)
        clock.mark(.audio, at: start + 0.05)
        clock.mark(.session, at: start + 0.012)
        clock.mark(.session, at: start + 9)
        clock.mark(.voice, at: start + 0.31)
        #expect(clock.summary == "audio 0.05 s, session 0.01 s, voice 0.31 s after the key")
        #expect(clock.json == .object(["audio": .number(0.05), "session": .number(0.012), "voice": .number(0.31)]))
    }
}

@Suite("Lip Service's own live talk") struct TalkRivalTests {
    /// Lip Service's settings as it stores them, cut to the keys that matter here, with others it has that the island
    /// doesn't read. Its agents are stored as the island stores its own.
    private func lipService(liveTalk: String?, agents: [AgentConnection] = [AgentPreset.with(id: "hermes")!.connection()],
                            dictationKey: Int = 62) -> Data {
        let stored = String(decoding: try! JSONEncoder().encode(agents), as: UTF8.self)
        var json = #"{"smartSpacing":true,"hotkeys":[{"key":\#(dictationKey),"modifiers":0}],"ghostwriteKey":{"key":63,"modifiers":262144},"#
            + #""agents":{"agents":\#(stored),"defaultAgent":"hermes"}"#
        if let liveTalk { json += #","liveTalk":\#(liveTalk)"# }
        return Data((json + "}").utf8)
    }

    @Test func liveTalkOnWithAnAgentTakesTheDoubleTap() {
        #expect(TalkRival.talks(settings: lipService(liveTalk: #"{"enabled":true,"voice":{"onMac":{"_0":{"voice":"en_us_Preston","model":"phonon"}}}}"#)))
        // Lip Service's Live talk is on unless it was turned off, as the island's is.
        #expect(TalkRival.talks(settings: lipService(liveTalk: nil)))
    }

    @Test func liveTalkOffOrNoAgentLeavesItToTheIsland() {
        #expect(!TalkRival.talks(settings: lipService(liveTalk: #"{"enabled":false}"#)))
        #expect(!TalkRival.talks(settings: lipService(liveTalk: #"{"enabled":true}"#, agents: [])))
        // Its dictation key on Left Control alone takes the double tap for hands-free dictation, so it doesn't talk.
        #expect(!TalkRival.talks(settings: lipService(liveTalk: #"{"enabled":true}"#, dictationKey: 59)))
        #expect(!TalkRival.talks(settings: nil))
        #expect(!TalkRival.talks(settings: Data("not json".utf8)))
    }
}
