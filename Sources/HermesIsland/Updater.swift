import AppKit
import IslandCore
import os

/// Offers and installs signed releases, in the signed app only. `scripts/release.sh` stamps the update feed and the
/// developer's team id into the signed app's Info.plist; a source build has neither, so it has no `Updater` and never
/// asks the network anything.
///
/// It asks the feed (a file on the repository's latest GitHub release) at most once a day, and only while "Check for
/// Updates Automatically" is on. An update downloads the zip, checks its size and hash, unpacks it, and installs it only
/// if the app inside is this app, at the version the feed offers, signed by the same Apple developer team, and accepted
/// by Gatekeeper, which for a downloaded app means notarized. It then starts a one-shot launchd job that waits for this
/// app to quit and runs the release's own `install-update.sh`.
@MainActor final class Updater {
    static let automaticKey = "checkForUpdates"
    static let jobLabel = "dev.hermes-island.app.update"
    static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let feedLimit = 1 << 20
    private static let log = Logger(subsystem: "dev.hermes-island.app", category: "update")

    private struct Check: Codable { var checked_at: Date; var feed: ReleaseFeed? }
    struct Refusal: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let channel: UpdateChannel
    /// The release this app offers now, from the last answer of the feed. Nil when there is none.
    private(set) var offered: ReleaseFeed?
    private(set) var busy = false
    var onChange: (() -> Void)?
    private let folder: URL
    private let defaults: UserDefaults
    private let session: URLSession
    private var timer: Timer?

    /// Nil for a source build, a half-stamped one, or a test run, which has no business on the network.
    init?(bundle: Bundle = .main, root: URL = SupportFolder.url, defaults: UserDefaults = SettingsStore.defaults) {
        guard SettingsStore.isReal, let channel = UpdateChannel(info: bundle.infoDictionary, app: bundle.bundleURL) else { return nil }
        self.channel = channel
        folder = root.appending(path: "update", directoryHint: .isDirectory)
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        offered = Self.offer((try? readCheck())?.feed, to: channel)
    }

    /// The feed's release, if it is newer than this app and this Mac can run it.
    private static func offer(_ feed: ReleaseFeed?, to channel: UpdateChannel) -> ReleaseFeed? {
        feed?.offer(current: channel.current, system: .running) == nil ? nil : feed
    }

    var automatic: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    var logURL: URL { folder.appending(path: "update.log") }
    private var statusURL: URL { folder.appending(path: "status") }
    private var checkURL: URL { folder.appending(path: "release-check.json") }
    private var work: URL { folder.appending(path: "download", directoryHint: .isDirectory) }

    /// Whether the last install ended without success: the job left a status that is not 0.
    var lastInstallFailed: Bool {
        guard let text = try? String(contentsOf: statusURL, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    /// Checks when the app starts and then hourly, and asks the feed only when a day has passed since the last answer.
    func start() {
        // A finished install's leftovers: the job's status stays so the menu can say that it failed.
        try? FileManager.default.removeItem(at: work)
        Task { await checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard automatic, !busy else { return }
        if let last = try? readCheck(), last.checked_at <= .now, Date.now.timeIntervalSince(last.checked_at) < Self.checkInterval {
            return
        }
        _ = await fetch()
    }

    /// Asks the feed now. False means it could not be read; the answer is kept so a failed ask is not repeated for a day.
    @discardableResult func fetch() async -> Bool {
        let data = try? await download(channel.feed)
        let feed = data.flatMap(ReleaseFeed.parse)
        try? makeFolder()
        try? writePrivate(JSONEncoder.dated.encode(Check(checked_at: .now, feed: feed)), to: checkURL)
        offered = Self.offer(feed, to: channel)
        onChange?()
        return feed != nil
    }

    /// Downloads the offered release, checks it, and hands the install to a launchd job, then quits the app so the job can
    /// replace it. The last check for a talk and the quit happen in one step, so no call starts between them.
    func install(_ feed: ReleaseFeed, canQuit: () -> Bool, thenQuit quit: () -> Void) async throws {
        guard !busy else { throw Refusal(message: "An update is already being prepared.") }
        let waitForCall = Refusal(message: "Finish your talk first. The update restarts Hermes Island.")
        guard canQuit() else { throw waitForCall }
        let parent = channel.app.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw Refusal(message: "Hermes Island can't replace itself in \(parent). Download the new version from its releases page and move it there by hand.")
        }
        busy = true
        onChange?()
        defer { busy = false; onChange?() }
        do {
            try makeFolder()
            try? FileManager.default.removeItem(at: statusURL)
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The feed may have moved on since the menu showed it; install only what it offers now.
            guard await fetch(), let current = offered, current.version == feed.version else {
                throw ReleaseCheckFailure.changed(offered?.version)
            }
            let archive = work.appending(path: "update.zip")
            try await download(current.url, to: archive)
            let unpacked = work.appending(path: "unpacked", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let app = try await ReleaseCheck.verify(archive: archive, feed: current, channel: channel, folder: unpacked, run: Self.run)
            try? FileManager.default.removeItem(at: archive)

            // The download took a while; a talk or call back may have started since.
            guard canQuit() else { throw waitForCall }
            // The installer runs from outside the bundle it replaces.
            let installer = folder.appending(path: "install-update.sh")
            try? FileManager.default.removeItem(at: installer)
            try FileManager.default.copyItem(at: app.appending(path: ReleaseCheck.installerPath), to: installer)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installer.path)
            let plist = Self.job(installer: installer, app: app, destination: channel.app, pid: getpid(), work: work, status: statusURL, log: logURL)
            try await launch(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            guard canQuit() else {
                // The job gives up on its own after 30 seconds if this app has not quit; end it now.
                _ = try? await Self.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Self.jobLabel)"])
                throw waitForCall
            }
            quit()
        } catch {
            note("Couldn't update to \(feed.version.tag): \(error)")
            throw error
        }
    }

    /// The one-shot job: it waits for this app (`pid`) to quit, then runs the installer, which swaps the bundle and
    /// starts the new copy, writing its exit code to `status`.
    static func job(installer: URL, app: URL, destination: URL, pid: Int32, work: URL, status: URL, log: URL) -> [String: Any] {
        [
            "Label": jobLabel,
            "ProgramArguments": ["/bin/bash", installer.path, app.path, destination.path, String(pid), work.path, status.path],
            "RunAtLoad": true,
            "StandardOutPath": log.path,
            "StandardErrorPath": log.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            "Umask": 63,
        ]
    }

    private func launch(_ job: Data) async throws {
        let plist = folder.appending(path: "\(Self.jobLabel).plist")
        try writePrivate(job, to: plist)
        let domain = "gui/\(getuid())"
        // A finished job stays loaded until it is booted out; booting out one that is not loaded fails harmlessly.
        _ = try? await Self.run("/bin/launchctl", ["bootout", "\(domain)/\(Self.jobLabel)"])
        var started = try await Self.run("/bin/launchctl", ["bootstrap", domain, plist.path])
        if started.status != 0 {
            // launchd can still be tearing down the old job just after bootout.
            try await Task.sleep(for: .seconds(1))
            started = try await Self.run("/bin/launchctl", ["bootstrap", domain, plist.path])
        }
        guard started.status == 0 else { throw Refusal(message: "launchd would not start the update: \(started.text)") }
    }

    /// Runs a program, with its error output joined to its output.
    static let run: ReleaseToolRunner = { executable, arguments in
        let done = try await Process.runToEnd(executable, arguments, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                                              input: Data(), timeout: 300)
        // Whole, never cut short: the archive listing is checked line by line before anything is unpacked.
        let all = done.output + done.errors
        guard all.count <= 8 << 20 else { return (1, "the output was too long to check") }
        let text = String(decoding: all, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (done.timedOut ? 124 : done.status, text.isEmpty ? "exit \(done.status)" : text)
    }

    /// `HermesIsland --verify-update FEED ZIP`: runs the checks an update goes through on files already downloaded, as
    /// release.sh does before it uploads them. Needs a signed app, since the team and bundle id come from its Info.plist.
    static func verifyFiles(feed feedFile: URL, archive: URL) async -> Int32 {
        guard let channel = UpdateChannel(info: Bundle.main.infoDictionary, app: Bundle.main.bundleURL) else {
            FileHandle.standardError.write(Data("This build has no update channel; run it from a signed release build.\n".utf8))
            return 2
        }
        guard let feed = FileManager.default.contents(atPath: feedFile.path).flatMap(ReleaseFeed.parse) else {
            FileHandle.standardError.write(Data("\(ReleaseCheckFailure.feed)\n".utf8))
            return 1
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "hermes-island-verify-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try await ReleaseCheck.verify(archive: archive, feed: feed, channel: channel, folder: folder, run: run)
            print("ok \(feed.version.tag)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    private func readCheck() throws -> Check {
        try JSONDecoder.dated.decode(Check.self, from: Data(contentsOf: checkURL))
    }

    private func makeFolder() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func note(_ line: String) {
        Self.log.error("\(line, privacy: .public)")
        try? makeFolder()
        let previous = FileManager.default.contents(atPath: logURL.path) ?? Data()
        try? writePrivate(previous + Data((line + "\n").utf8), to: logURL)
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        guard data.count <= Self.feedLimit else { throw ReleaseCheckFailure.feed }
        return data
    }

    private func download(_ url: URL, to file: URL) async throws {
        let (temporary, response) = try await session.download(from: url)
        try Self.check(response)
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private static func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Refusal(message: "the server answered \(status)") }
    }
}

private extension JSONEncoder {
    static var dated: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var dated: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
