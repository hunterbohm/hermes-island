import Foundation

/// A release number like `v0.2.0`, as the repository tags it and as `CFBundleShortVersionString` spells it without the v.
public struct ReleaseVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let parts: [Int]

    /// Nil unless `tag` is three whole numbers with dots between, with or without a leading v.
    public init?(tag: String) {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 6, piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers
    }

    public var tag: String { "v" + parts.map(String.init).joined(separator: ".") }
    public var description: String { tag }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ReleaseVersion(tag: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a release version: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(tag)
    }
}

/// A macOS version like `26.0` or `26.1.2`.
public struct SystemVersion: Comparable, Sendable, Equatable {
    public var parts: [Int]

    public init?(_ text: String) {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.count <= 4, piece.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(piece) else { return nil }
            numbers.append(number)
        }
        parts = numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    public static var running: SystemVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

/// The newest release, as `appcast.json` on the release page describes it. `scripts/release.sh` writes it; the app reads
/// it. The feed names the download and its SHA-256, which catches a damaged download. It does not make the download
/// trusted: that rests on the code signature `ReleaseCheck` demands, which only the developer's Apple certificate can make.
public struct ReleaseFeed: Codable, Sendable, Equatable {
    public var version: ReleaseVersion
    /// The notarized, stapled app, zipped with `ditto -c -k --keepParent`.
    public var url: URL
    public var length: Int
    /// Lowercase hex.
    public var sha256: String
    public var minimum_system_version: String

    public init(version: ReleaseVersion, url: URL, length: Int, sha256: String, minimum_system_version: String) {
        self.version = version; self.url = url; self.length = length
        self.sha256 = sha256; self.minimum_system_version = minimum_system_version
    }

    /// Nil for a feed that does not parse, names a download that is not https, or has a bad length or hash.
    public static func parse(_ data: Data) -> ReleaseFeed? {
        guard let feed = try? JSONDecoder().decode(ReleaseFeed.self, from: data), feed.url.scheme == "https",
              feed.url.host?.isEmpty == false, feed.length > 0, isSHA256(feed.sha256),
              SystemVersion(feed.minimum_system_version) != nil else { return nil }
        return feed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The release to offer an app at `current` on `system`: newer, and runnable here.
    public func offer(current: ReleaseVersion, system: SystemVersion) -> ReleaseVersion? {
        guard version > current, let minimum = SystemVersion(minimum_system_version), system >= minimum else { return nil }
        return version
    }

    static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

/// Where a signed app finds its updates, and what an update must be. `scripts/release.sh` stamps the two keys into the
/// signed app's Info.plist; a source build has neither, so it never asks the network for an update.
public struct UpdateChannel: Sendable, Equatable {
    public static let feedKey = "HermesIslandUpdateFeed"
    public static let teamKey = "HermesIslandTeamID"

    public var feed: URL
    public var teamID: String
    public var bundleID: String
    public var current: ReleaseVersion
    /// The installed app, which the update replaces.
    public var app: URL

    public init(feed: URL, teamID: String, bundleID: String, current: ReleaseVersion, app: URL) {
        self.feed = feed; self.teamID = teamID; self.bundleID = bundleID; self.current = current; self.app = app
    }

    /// Nil unless every key is present and well formed, so a source build, or a half-stamped one, offers nothing.
    public init?(info: [String: Any]?, app: URL) {
        guard let info, let text = info[Self.feedKey] as? String, let feed = URL(string: text), feed.scheme == "https",
              let team = info[Self.teamKey] as? String, Self.isTeamID(team),
              let bundleID = info["CFBundleIdentifier"] as? String, Self.isBundleID(bundleID),
              let version = (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init(tag:)) else { return nil }
        self.init(feed: feed, teamID: team, bundleID: bundleID, current: version, app: app)
    }

    /// What every update's signature must meet: issued through Apple, to this team, for this bundle id. macOS keys the
    /// microphone and Accessibility grants to the same signer, so an update that meets it keeps them.
    public var requirement: String {
        "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    static func isTeamID(_ text: String) -> Bool {
        text.count == 10 && text.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    static func isBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// Why a downloaded release was not installed. The update log carries the description.
public enum ReleaseCheckFailure: Error, Equatable, CustomStringConvertible {
    case feed
    case changed(ReleaseVersion?)
    case length(expected: Int, got: Int)
    case hash
    case archive(String)
    case identity(String)
    case version(String)
    case codeSignature(String)
    case gatekeeper(String)

    public var description: String {
        switch self {
        case .feed: "the update feed could not be read"
        case .changed(let version): "the update feed now offers \(version?.tag ?? "nothing"); check again"
        case .length(let expected, let got): "the download is \(got) bytes, the feed says \(expected)"
        case .hash: "the download does not match the feed's SHA-256"
        case .archive(let why): "the download is not a usable app: \(why)"
        case .identity(let id): "the downloaded app is \(id), not this app"
        case .version(let version): "the downloaded app says it is \(version), not the version the feed offers"
        case .codeSignature(let output): "the downloaded app is not signed by this app's developer: \(output)"
        case .gatekeeper(let output): "macOS would not open the downloaded app (not notarized?): \(output)"
        }
    }
}

/// Runs a program and returns its exit status and what it printed. The app runs real programs; a test fakes them.
public typealias ReleaseToolRunner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> (status: Int32, text: String)

/// What a downloaded release must be before anything installs it: the size and hash the feed names, one app inside,
/// this app's bundle id at the version the feed offers, a code signature from this app's developer team, and
/// Gatekeeper's acceptance, which for a downloaded app means Apple's notarization.
public enum ReleaseCheck {
    /// The installer a release carries, which runs from outside the bundle it replaces.
    public static let installerPath = "Contents/Resources/scripts/install-update.sh"

    public static func unzipArguments(_ archive: URL, into folder: URL) -> [String] { ["-x", "-k", archive.path, folder.path] }
    public static func verifyArguments(_ app: URL, requirement: String) -> [String] {
        ["--verify", "--deep", "--strict", "-R", "=" + requirement, app.path]
    }
    public static func assessArguments(_ app: URL) -> [String] { ["--assess", "--type", "execute", app.path] }

    /// What is wrong with a zip's entries, or nil. `names` is one path per line (`zipinfo -1`); `listing` is the default
    /// `zipinfo` listing, where a link's line starts with `l`. Every path must sit under the same single `*.app` folder, with
    /// no absolute path and no `..`, and nothing may be a link: the app has none, and a link could carry a later entry
    /// out of the folder it is unpacked into.
    public static func entryProblem(names: String, listing: String) -> String? {
        let paths = names.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !paths.isEmpty else { return "the archive is empty" }
        var top: String?
        for path in paths {
            if path.hasPrefix("/") || path.contains("\\") { return "\(path) is not a relative path" }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.contains("..") { return "\(path) leaves the folder" }
            guard let first = parts.first, first.hasSuffix(".app"), !first.hasPrefix(".") else {
                if path.hasPrefix("__MACOSX/") { continue }
                return "\(path) is not inside an app"
            }
            if let top, top != first { return "more than one app: \(top) and \(first)" }
            top = first
        }
        guard top != nil else { return "no app in the archive" }
        for line in listing.split(separator: "\n") where line.first == "l" {
            return "the archive holds a link: \(line.suffix(80))"
        }
        return nil
    }

    /// The first symbolic link under `folder`, as a path relative to it, or nil.
    static func firstLink(under folder: URL) -> String? {
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in true }) else { return nil }
        for case let item as URL in walk where (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return String(item.path.dropFirst(folder.path.count))
        }
        return nil
    }

    /// Unpacks `archive` into `folder` (which must exist and be empty) and returns the checked app inside it.
    public static func verify(archive: URL, feed: ReleaseFeed, channel: UpdateChannel, folder: URL,
                              run: ReleaseToolRunner) async throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? -1
        guard size == feed.length else { throw ReleaseCheckFailure.length(expected: feed.length, got: size) }
        guard ModelCheck.sha256(of: archive) == feed.sha256 else { throw ReleaseCheckFailure.hash }

        // The signature is checked on the unpacked app, so unpacking comes first. Look at what the archive holds before
        // anything is written: only paths under one app folder, and no links that a later entry could write through.
        let names = try await run("/usr/bin/zipinfo", ["-1", archive.path])
        guard names.status == 0 else { throw ReleaseCheckFailure.archive(names.text) }
        let details = try await run("/usr/bin/zipinfo", [archive.path])
        guard details.status == 0 else { throw ReleaseCheckFailure.archive(details.text) }
        if let problem = entryProblem(names: names.text, listing: details.text) { throw ReleaseCheckFailure.archive(problem) }

        let unzip = try await run("/usr/bin/ditto", unzipArguments(archive, into: folder))
        guard unzip.status == 0 else { throw ReleaseCheckFailure.archive(unzip.text) }
        // The listing above is zipinfo's reading of the archive; this is what unpacking actually made.
        if let link = firstLink(under: folder) { throw ReleaseCheckFailure.archive("the unpacked app holds a link: \(link)") }
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
        guard items.count == 1, let name = items.first, name.hasSuffix(".app") else {
            throw ReleaseCheckFailure.archive("expected one app, found \(items.sorted())")
        }
        let app = folder.appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: app.appendingPathComponent("Contents/Info.plist").path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReleaseCheckFailure.archive("no Info.plist")
        }
        let id = info["CFBundleIdentifier"] as? String ?? "unknown"
        guard id == channel.bundleID else { throw ReleaseCheckFailure.identity(id) }
        let shown = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard ReleaseVersion(tag: shown) == feed.version else { throw ReleaseCheckFailure.version(shown) }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(installerPath).path) else {
            throw ReleaseCheckFailure.archive("no installer in the app")
        }

        let signature = try await run("/usr/bin/codesign", verifyArguments(app, requirement: channel.requirement))
        guard signature.status == 0 else { throw ReleaseCheckFailure.codeSignature(signature.text) }
        let gatekeeper = try await run("/usr/sbin/spctl", assessArguments(app))
        guard gatekeeper.status == 0 else { throw ReleaseCheckFailure.gatekeeper(gatekeeper.text) }
        return app
    }
}
