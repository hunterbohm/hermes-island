import AppKit
import IslandCore
import os

/// Wires the owners together: the key that starts a talk, the talk, the island that shows it, the cards beside it,
/// and the call backs an agent rings in with.
@MainActor final class Coordinator {
    private let log = Logger(subsystem: "dev.hermes-island.app", category: "island")

    let preferences = Preferences()
    let agents = AgentPool(threadsAt: TalkThreadStore.defaultURL)
    private let microphone = Microphone()
    private let sounds = Sounds()
    private let keyTap = KeyTap()
    private let engine = SpeechEngine(vocabulary: nil)
    private let toast = Toast()
    private(set) var menu: StatusMenu!
    /// Nil in a source build, which never looks for updates.
    let updater = Updater()
    /// The voice the island's waves follow: the agent's while it talks, yours otherwise.
    private var meter: VoiceMeter!
    private var talk: Talk?
    private let talkCards = TalkCardPanel()
    private let island = TalkIslandPanel()
    /// A call back ringing on the island, until it is answered, declined or missed.
    private var ringing: RingingCall?
    /// The call back whose talk is under way, until the result is said or the talk ends.
    private var callInTalk: String?
    private var callObserver: (any NSObjectProtocol)?
    private var settingsObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private(set) var engineStatus = EngineStatus.loading(.compiling)

    init() {
        meter = VoiceMeter(feed: { [weak self] in self?.talk?.voiceTap ?? self?.microphone.voice })
        menu = StatusMenu(coordinator: self)
    }

    var accessibilityGranted: Bool { keyTap.isRunning }
    var talkRunning: Bool { talk != nil }
    /// A talk is under way or a call back is ringing, so an update that quits the app must wait.
    var inCall: Bool { talk != nil || ringing != nil }

    func start() {
        keyTap.onDoubleTap = { [unowned self] in toggleTalk() }
        keyTap.onMuteKey = { [unowned self] in toggleMute() }
        keyTap.onRunning = { [unowned self] in menu.refresh() }
        talkCards.onPermission = { [unowned self] allowed in talk?.answerPermission(allowed) }
        island.model.level = { [unowned self] in
            // Muted, your voice doesn't move the island; the agent's still does.
            if let talk, talk.muted, talk.bar.phase != .speaking { return 0 }
            return meter.reading(at: Date.timeIntervalSinceReferenceDate).level(delay: 0)
        }
        island.model.onEnd = { [unowned self] in
            log.notice("the island's End button ends the talk")
            talk?.end(.byYou)
        }
        island.model.onMute = { [unowned self] in toggleMute() }
        island.model.onAnswer = { [unowned self] in answerCall() }
        island.model.onDecline = { [unowned self] in endRinging(.declined) }
        island.model.onAction = { [unowned self] words in talk?.choose(words) ?? false }
        island.onMoved = { [unowned self] rect in talkCards.move(under: (rect, .top)) }
        preferences.onChange = { [unowned self] old, new in apply(old, new) }
        microphone.onFailure = { [unowned self] error in
            talk?.end(.failed(error.localizedDescription))
        }
        Task { [unowned self] in
            for await status in engine.statuses {
                engineStatus = status
                menu.refresh()
            }
        }
        // `HermesIsland call` runs in another process, often over SSH from the agent's Mac, and asks for a call back.
        callObserver = DistributedNotificationCenter.default().addObserver(
            forName: CallChannel.request, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated { if let id { self?.incomingCall(id) } }
        }
        // A change made with `defaults write` while the app runs applies at once.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferences.reload() }
        }
        // A link to an agent on another Mac may have died while this one slept.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.agents.ready() }
        }
        Microphone.requestAccessIfNeeded()
        microphone.prepare(preferences.current.microphone)
        engine.prepare()
        keepTalkAgentReady(preferences.current)
        keyTap.start(prompting: true)
        menu.refresh()
        updater?.onChange = { [unowned self] in menu.refresh() }
        updater?.start()
    }

    /// The agent a double tap would talk with is kept running with its session open, so the talk starts at once.
    private func keepTalkAgentReady(_ settings: IslandSettings) {
        agents.keepReady(settings.liveTalk.enabled ? settings.talkAgent : nil)
    }

    private func apply(_ old: IslandSettings, _ new: IslandSettings) {
        for agent in old.agents.agents where new.agents.agent(id: agent.id)?.shellCommand != agent.shellCommand {
            agents.stop(agent.id)
        }
        if old.microphone != new.microphone || old.automaticOrder != new.automaticOrder, talk == nil {
            microphone.prepare(new.microphone)
        }
        keepTalkAgentReady(new)
        menu.refresh()
    }

    /// The island's mute button or ⌃⌥M: mutes or unmutes your microphone for the talk running.
    private func toggleMute() {
        guard let talk else { return }
        talk.setMuted(!talk.muted)
    }

    /// Double-tapping Left Control, or Talk in the menu: answers a call back that is ringing, starts a talk, or ends the
    /// one running.
    func toggleTalk() {
        if ringing != nil { return answerCall() }
        if let talk {
            log.notice("Left Control or the menu ends the talk")
            return talk.end(.byYou)
        }
        let settings = preferences.current
        guard settings.liveTalk.enabled else { return }
        guard let agent = settings.talkAgent else {
            return toast.show("No agent to talk with", detail: "Add one to the settings file. The menu opens it.")
        }
        if lipServiceTalks() {
            log.notice("Lip Service's live talk took the double tap")
            return toast.show(TalkRival.title, detail: TalkRival.detail)
        }
        startTalk(with: agent)
    }

    private func startTalk(with agent: AgentConnection, opening: String? = nil) {
        let settings = preferences.current
        let talk = Talk(agent: agent, pool: agents, engine: engine, voice: Voices.provider(for: settings.liveTalk.voice),
                        input: MicTalkInput(microphone, choice: settings.microphone), speaker: SpeakerOut(), opening: opening,
                        cue: settings.sounds ? sounds.talkStartLength : 0)
        let barAgent = BarAgent(initial: agent.initial, name: agent.name)
        talk.onBar = { [unowned self] _ in render() }
        talk.onNotice = { [unowned self] why in toast.show("The voice failed", detail: why) }
        // A short line, such as what the agent just did, shows inside the island; links, images and visuals are cards.
        talk.onCard = { [unowned self] event in
            if !island.take(event) { talkCards.handle(event, agent: barAgent, under: (island.islandRect, .top)) }
        }
        talk.onOpening = { [unowned self] said in
            guard let id = callInTalk else { return }
            callInTalk = nil
            CallChannel.post(CallbackUpdate(id: id, status: said ? .delivered : .failed,
                                            detail: said ? nil : "\(agent.name) couldn't say the result"))
        }
        talk.onEnd = { [unowned self, weak talk] reason in
            guard let talk, self.talk === talk else { return }
            self.talk = nil
            keyTap.talking = false
            if let id = callInTalk {
                callInTalk = nil
                let detail = if case .failed(let why) = reason { why } else { "the talk ended before the result was said" }
                CallChannel.post(CallbackUpdate(id: id, status: .hungUp, detail: detail))
            }
            // What the agent showed was for the talk, so it goes with it.
            talkCards.closeAll()
            microphone.prepare(preferences.current.microphone)
            if preferences.current.sounds { sounds.play(talk: .end) }
            if case .failed(let why) = reason {
                toast.show("The talk with \(agent.name) stopped", detail: agent.hint(forTrouble: why) ?? why)
            }
            render()
        }
        self.talk = talk
        keyTap.talking = true
        toast.hide()
        if settings.sounds { sounds.play(talk: .start) }
        render()
        talk.start()
    }

    // MARK: Call back

    /// `HermesIsland call` asked for a call back. It rings unless you are busy, and says why when it won't.
    private func incomingCall(_ id: String) {
        guard let request = CallChannel.take(id) else {
            return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "Hermes Island couldn't read the call"))
        }
        let settings = preferences.current
        let agent: AgentConnection
        if let wanted = request.agent?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty {
            guard let named = settings.agents.agents.first(where: { $0.id.lowercased() == wanted || $0.name.lowercased() == wanted }) else {
                return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "no agent named \(request.agent ?? "")"))
            }
            agent = named
        } else {
            guard let live = settings.talkAgent else {
                return CallChannel.post(CallbackUpdate(id: id, status: .failed, detail: "no agent is set up for live talk"))
            }
            agent = live
        }
        if let busy = CallSignals.busy(talking: talk != nil || ringing != nil, dictating: false) {
            log.info("call back from \(request.from, privacy: .public) not rung: \(busy.detail, privacy: .public)")
            return CallChannel.post(CallbackUpdate(id: id, status: .busy, detail: busy.detail))
        }
        log.info("call back from \(request.from, privacy: .public)")
        let call = RingingCall(request: request, agent: agent)
        ringing = call
        // Nothing is said before the agent's first words, so the agent and the voice get ready while the island rings.
        agents.warmUp(agent)
        Task { try? await Voices.provider(for: settings.liveTalk.voice).prepare() }
        if request.ringSeconds <= 0 { return answerCall() }
        CallChannel.post(CallbackUpdate(id: id, status: .ringing))
        call.ring = Task { [unowned self, sounds] in
            let ends = Instant.now + request.ringSeconds
            while !Task.isCancelled, Instant.now < ends {
                sounds.play(talk: .start)
                try? await Task.sleep(for: .milliseconds(650))
                sounds.play(talk: .start)
                try? await Task.sleep(for: .seconds(2.5))
            }
            guard !Task.isCancelled else { return }
            endRinging(.missed)
        }
        render()
    }

    /// Double-tapping Left Control or Answer on the island: the talk starts and says the result first.
    private func answerCall() {
        guard let call = ringing else { return }
        call.ring?.cancel()
        ringing = nil
        let request = call.request
        CallChannel.post(CallbackUpdate(id: request.id, status: .answered))
        callInTalk = request.id
        startTalk(with: call.agent,
                  opening: CallbackPrompt.opening(from: request.from, about: request.about, result: request.result))
    }

    /// Decline on the island, or the ring ran out.
    private func endRinging(_ status: CallbackStatus) {
        guard let call = ringing else { return }
        call.ring?.cancel()
        ringing = nil
        log.info("call back \(status.rawValue, privacy: .public)")
        CallChannel.post(CallbackUpdate(id: call.request.id, status: status))
        // The voice loaded while it rang goes after its usual wait, as after a talk.
        Task { await OnMacVoices.shared.idle() }
        render()
    }

    /// Lip Service is running with its own live talk on, so it starts a talk on this double tap too: a second one here
    /// would say every reply again.
    private func lipServiceTalks() -> Bool {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Migration.lipServiceDomain).isEmpty else { return false }
        return TalkRival.talks(settings: UserDefaults(suiteName: Migration.lipServiceDomain)?.data(forKey: "settings"))
    }

    private func render() {
        let bar = talk?.bar ?? ringing?.bar
        meter.listen(talk != nil)
        island.show(bar)
        menu.refresh()
    }
}

/// A call back that is ringing, and the agent its talk goes to.
@MainActor final class RingingCall {
    let request: CallbackRequest
    let agent: AgentConnection
    var ring: Task<Void, Never>?

    init(request: CallbackRequest, agent: AgentConnection) { (self.request, self.agent) = (request, agent) }

    var bar: TalkBar {
        TalkBar(agent: BarAgent(initial: agent.initial, name: request.from), phase: .ringing, line: CallbackPrompt.cleanAbout(request.about))
    }
}
