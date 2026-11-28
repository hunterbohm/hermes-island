import CryptoKit
import Foundation
import Testing
@testable import IslandCore

@Suite("Release versions") struct ReleaseVersionTests {
    @Test func tagsParseWithOrWithoutTheV() {
        #expect(ReleaseVersion(tag: "v0.2.0")?.tag == "v0.2.0")
        #expect(ReleaseVersion(tag: "1.10.3")?.tag == "v1.10.3")
    }

    @Test func nonVersionsAreRefused() {
        for text in ["", "v1", "1.2", "1.2.3.4", "v1.2.x", "1..3", "latest", "v1.2.3-beta", "1.2.-3", "1.2.1234567"] {
            #expect(ReleaseVersion(tag: text) == nil, "\(text)")
        }
    }

    @Test func versionsCompareByNumberNotText() {
        #expect(ReleaseVersion(tag: "v0.10.0")! > ReleaseVersion(tag: "v0.9.9")!)
        #expect(ReleaseVersion(tag: "v1.0.0")! > ReleaseVersion(tag: "v0.99.99")!)
        #expect(!(ReleaseVersion(tag: "v0.1.0")! > ReleaseVersion(tag: "0.1.0")!))
    }
}

@Suite("Release feed") struct ReleaseFeedTests {
    static let hash = String(repeating: "ab", count: 32)

    static func feed(version: String = "v0.2.0", url: String = "https://github.com/o/r/releases/download/v0.2.0/HermesIsland-v0.2.0.zip",
                     length: Int = 10, sha256: String = hash, minimum: String = "26.0") -> Data {
        Data("""
            {"version": "\(version)", "url": "\(url)", "length": \(length), "sha256": "\(sha256)", "minimum_system_version": "\(minimum)"}
            """.utf8)
    }

    @Test func aGoodFeedParsesAndRoundTrips() throws {
        let feed = try #require(ReleaseFeed.parse(Self.feed()))
        #expect(feed.version.tag == "v0.2.0")
        #expect(ReleaseFeed.parse(try feed.encoded()) == feed)
    }

    @Test func aFeedThatCouldNotBeTrustedToDownloadIsRefused() {
        #expect(ReleaseFeed.parse(Self.feed(url: "http://example.com/a.zip")) == nil)
        #expect(ReleaseFeed.parse(Self.feed(url: "file:///tmp/a.zip")) == nil)
        #expect(ReleaseFeed.parse(Self.feed(length: 0)) == nil)
        #expect(ReleaseFeed.parse(Self.feed(sha256: "abc")) == nil)
        #expect(ReleaseFeed.parse(Self.feed(sha256: String(repeating: "AB", count: 32))) == nil)
        #expect(ReleaseFeed.parse(Self.feed(version: "latest")) == nil)
        #expect(ReleaseFeed.parse(Self.feed(minimum: "soon")) == nil)
        #expect(ReleaseFeed.parse(Data("not json".utf8)) == nil)
    }

    @Test func offersOnlyANewerReleaseThisMacCanRun() throws {
        let feed = try #require(ReleaseFeed.parse(Self.feed(minimum: "26.1")))
        let older = ReleaseVersion(tag: "v0.1.0")!, same = ReleaseVersion(tag: "v0.2.0")!, newer = ReleaseVersion(tag: "v0.3.0")!
        let mac = SystemVersion("26.2")!
        #expect(feed.offer(current: older, system: mac) == feed.version)
        #expect(feed.offer(current: same, system: mac) == nil)
        #expect(feed.offer(current: newer, system: mac) == nil)
        #expect(feed.offer(current: older, system: SystemVersion("26.0.1")!) == nil)
    }
}

@Suite("Update channel") struct UpdateChannelTests {
    static var info: [String: Any] { [
        UpdateChannel.feedKey: "https://github.com/o/r/releases/latest/download/appcast.json",
        UpdateChannel.teamKey: "ABCDE12345",
        "CFBundleIdentifier": "dev.example.app",
        "CFBundleShortVersionString": "0.1.0",
    ] }

    @Test func aSignedAppHasAChannelWithTheRequirementItsUpdatesMeet() throws {
        let channel = try #require(UpdateChannel(info: Self.info, app: URL(fileURLWithPath: "/Applications/App.app")))
        #expect(channel.current.tag == "v0.1.0")
        #expect(channel.requirement == "anchor apple generic and identifier \"dev.example.app\" and certificate leaf[subject.OU] = \"ABCDE12345\"")
    }

    @Test func aSourceBuildHasNoChannel() {
        var source = Self.info
        source[UpdateChannel.feedKey] = nil
        source[UpdateChannel.teamKey] = nil
        #expect(UpdateChannel(info: source, app: URL(fileURLWithPath: "/x")) == nil)
        #expect(UpdateChannel(info: nil, app: URL(fileURLWithPath: "/x")) == nil)
    }

    @Test func aHalfStampedOrOddAppHasNoChannel() {
        func channel(_ key: String, _ value: Any?) -> UpdateChannel? {
            var info = Self.info
            info[key] = value
            return UpdateChannel(info: info, app: URL(fileURLWithPath: "/x"))
        }
        #expect(channel(UpdateChannel.feedKey, "http://example.com/appcast.json") == nil)
        #expect(channel(UpdateChannel.teamKey, nil) == nil)
        #expect(channel(UpdateChannel.teamKey, "short") == nil)
        #expect(channel(UpdateChannel.teamKey, "ABCDE1234\" or anchor apple") == nil)
        #expect(channel("CFBundleIdentifier", "bad id\" or true") == nil)
        #expect(channel("CFBundleShortVersionString", "dev") == nil)
    }
}

@Suite("Checking a downloaded release") struct ReleaseCheckTests {
    struct Run: Error {}

    /// Folders for one test: a fake zip, an empty unpack folder, and the channel and feed for the zip.
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-check-\(UUID().uuidString)")
        let archive: URL
        let unpacked: URL
        let channel = UpdateChannel(feed: URL(string: "https://example.com/appcast.json")!, teamID: "ABCDE12345",
                                    bundleID: "dev.example.app", current: ReleaseVersion(tag: "v0.1.0")!,
                                    app: URL(fileURLWithPath: "/Applications/App.app"))
        let bytes = Data("a zip".utf8)

        init() throws {
            unpacked = root.appendingPathComponent("unpacked")
            archive = root.appendingPathComponent("a.zip")
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try bytes.write(to: archive)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func feed(length: Int? = nil, sha256: String? = nil, version: String = "v0.2.0") -> ReleaseFeed {
            ReleaseFeed(version: ReleaseVersion(tag: version)!, url: URL(string: "https://example.com/a.zip")!,
                        length: length ?? bytes.count, sha256: sha256 ?? SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                        minimum_system_version: "26.0")
        }

        /// A runner whose `ditto` unpacks an app with these Info.plist values; codesign and spctl answer as given.
        func runner(id: String = "dev.example.app", shown: String = "0.2.0", installer: Bool = true, apps: [String] = ["App.app"],
                    codesign: Int32 = 0, spctl: Int32 = 0, link: Bool = false, names: [String] = ["App.app/", "App.app/Contents/Info.plist"],
                    listing: String = "-rw-r--r--  3.0 unx  10 bX  10 defN 26-Nov-26 21:00 App.app/Contents/Info.plist", calls: Calls = Calls()) -> ReleaseToolRunner {
            let unpacked = unpacked
            return { executable, arguments in
                calls.add(executable, arguments)
                switch executable {
                case "/usr/bin/zipinfo":
                    return (0, arguments.first == "-1" ? names.joined(separator: "\n") : listing)
                case "/usr/bin/ditto":
                    for name in apps {
                        let contents = unpacked.appendingPathComponent(name).appendingPathComponent("Contents")
                        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources/scripts"), withIntermediateDirectories: true)
                        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": shown]
                        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                            .write(to: contents.appendingPathComponent("Info.plist"))
                        if link { try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("escape").path, withDestinationPath: "/tmp") }
                        if installer {
                            let script = contents.appendingPathComponent("Resources/scripts/install-update.sh")
                            try Data("#!/bin/bash\n".utf8).write(to: script)
                            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                        }
                    }
                    return (0, "")
                case "/usr/bin/codesign": return (codesign, codesign == 0 ? "" : "a signature problem")
                case "/usr/sbin/spctl": return (spctl, spctl == 0 ? "" : "rejected")
                default: throw Run()
                }
            }
        }
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(String, [String])] = []
        func add(_ executable: String, _ arguments: [String]) { lock.withLock { all.append((executable, arguments)) } }
        var names: [String] { lock.withLock { all.map { ($0.0 as NSString).lastPathComponent } } }
        var arguments: [String: [String]] { lock.withLock { Dictionary(all.map { (($0.0 as NSString).lastPathComponent, $0.1) }, uniquingKeysWith: { $1 }) } }
    }

    func fail(_ fixture: Fixture, feed: ReleaseFeed? = nil, _ run: ReleaseToolRunner) async -> ReleaseCheckFailure? {
        do {
            _ = try await ReleaseCheck.verify(archive: fixture.archive, feed: feed ?? fixture.feed(), channel: fixture.channel, folder: fixture.unpacked, run: run)
            return nil
        } catch { return error as? ReleaseCheckFailure }
    }

    @Test func aReleaseThatMeetsEveryCheckComesBackAsTheUnpackedApp() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        let app = try await ReleaseCheck.verify(archive: fixture.archive, feed: fixture.feed(), channel: fixture.channel,
                                                folder: fixture.unpacked, run: fixture.runner(calls: calls))
        #expect(app.lastPathComponent == "App.app")
        #expect(calls.names == ["zipinfo", "zipinfo", "ditto", "codesign", "spctl"])
        #expect(calls.arguments["codesign"]?.contains("=" + fixture.channel.requirement) == true)
    }

    @Test func aDownloadOfTheWrongSizeIsRefusedBeforeAnythingIsUnpacked() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        #expect(await fail(fixture, feed: fixture.feed(length: 3), fixture.runner(calls: calls)) == .length(expected: 3, got: fixture.bytes.count))
        #expect(calls.names.isEmpty)
    }

    @Test func aDownloadWithAnotherHashIsRefusedBeforeAnythingIsUnpacked() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        #expect(await fail(fixture, feed: fixture.feed(sha256: String(repeating: "0", count: 64)), fixture.runner(calls: calls)) == .hash)
        #expect(calls.names.isEmpty)
    }

    @Test func anArchiveThatReachesOutsideItsFolderOrHoldsALinkIsRefusedBeforeUnpacking() async throws {
        let link = "lrwxr-xr-x  3.0 unx  10 bx  10 stor 26-Nov-26 21:00 App.app/Contents/escape"
        let cases: [(names: [String], listing: String?)] = [
            (["../outside"], nil), (["App.app/../../outside"], nil), (["/etc/passwd"], nil), (["other.txt"], nil),
            (["A.app/x", "B.app/x"], nil), ([], nil), (["App.app/x", "App.app/escape"], link),
        ]
        for entry in cases {
            let fixture = try Fixture()
            let calls = Calls()
            let runner = entry.listing.map { fixture.runner(names: entry.names, listing: $0, calls: calls) }
                ?? fixture.runner(names: entry.names, calls: calls)
            guard case .archive = await fail(fixture, runner) else { Issue.record("\(entry.names) was accepted"); continue }
            #expect(!calls.names.contains("ditto"), "\(entry.names)")
        }
    }

    @Test func aLinkThatUnpackingMadeIsRefusedWhateverTheListingSaid() async throws {
        let fixture = try Fixture()
        guard case .archive = await fail(fixture, fixture.runner(link: true)) else { Issue.record("accepted"); return }
    }

    @Test func aMacArchiveWithItsResourceForkFolderStillPasses() {
        #expect(ReleaseCheck.entryProblem(names: "App.app/\nApp.app/Contents/Info.plist\n__MACOSX/App.app/._x", listing: "-rw-r--r-- 3.0 unx 1 b- 1 stor d App.app/Contents/Info.plist") == nil)
    }

    @Test func anotherAppIsRefused() async throws {
        let fixture = try Fixture()
        #expect(await fail(fixture, fixture.runner(id: "dev.example.other")) == .identity("dev.example.other"))
    }

    @Test func anOlderAppUnderANewerFeedIsRefused() async throws {
        let fixture = try Fixture()
        #expect(await fail(fixture, fixture.runner(shown: "0.1.5")) == .version("0.1.5"))
    }

    @Test func anArchiveWithoutExactlyOneAppIsRefused() async throws {
        for apps in [[], ["A.app", "B.app"]] {
            let fixture = try Fixture()
            guard case .archive = await fail(fixture, fixture.runner(apps: apps)) else { Issue.record("\(apps) was accepted"); continue }
        }
    }

    @Test func aReleaseWithoutItsInstallerIsRefused() async throws {
        let fixture = try Fixture()
        guard case .archive = await fail(fixture, fixture.runner(installer: false)) else { Issue.record("accepted"); return }
    }

    @Test func aSignatureFromAnotherTeamIsRefusedAndNeverReachesGatekeeper() async throws {
        let fixture = try Fixture()
        let calls = Calls()
        guard case .codeSignature = await fail(fixture, fixture.runner(codesign: 3, calls: calls)) else { Issue.record("accepted"); return }
        #expect(!calls.names.contains("spctl"))
    }

    @Test func anAppGatekeeperRejectsIsRefused() async throws {
        let fixture = try Fixture()
        guard case .gatekeeper = await fail(fixture, fixture.runner(spctl: 3)) else { Issue.record("accepted"); return }
    }
}
