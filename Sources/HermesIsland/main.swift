import AppKit
import IslandCore

// A write to a child that already exited fails with EPIPE instead of ending the app.
signal(SIGPIPE, SIG_IGN)

switch Mode(arguments: Array(CommandLine.arguments.dropFirst())) {
case .app:
    SupportFolder.makePrivate()
    guard LaunchAgent.claim() else { exit(0) }
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let coordinator = Coordinator()
        coordinator.start()
        withExtendedLifetime(coordinator) { app.run() }
    }
case .listInputs:
    exit(Headless.listInputs())
case .loginStatus:
    exit(LaunchAgent.report())
case .openAtLogin(let on):
    do {
        try LaunchAgent.set(on)
        exit(LaunchAgent.report())
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case .verifyUpdate(let feed, let archive):
    Task { exit(await Updater.verifyFiles(feed: feed, archive: archive)) }
    dispatchMain()
case .ttsCheck(let options):
    Task { exit(await Headless.ttsCheck(options)) }
    dispatchMain()
case .talkTest(let options):
    Task { @MainActor in exit(await TalkTest.run(options)) }
    dispatchMain()
case .call(let options):
    exit(MainActor.assumeIsolated { CallCommand.run(options) })
case .agent(let options):
    exit(MainActor.assumeIsolated { AgentCommand.run(options) })
case .usage(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
