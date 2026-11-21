/// One dictation's audio: 16 kHz mono, in memory only. Nothing in the app writes it to disk.
public struct Recording: Sendable {
    public static let sampleRate = 16_000.0
    public var samples: [Float]
    /// Key-up, or the press that stopped hands-free. Latency counts from here.
    public var releasedAt: Instant

    public init(samples: [Float], releasedAt: Instant) {
        self.samples = samples
        self.releasedAt = releasedAt
    }

    public var seconds: Double { Double(samples.count) / Self.sampleRate }
}

/// One piece of the speech model's output and when it was heard, in seconds from the start of the audio.
public struct TimedToken: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { (self.text, self.start, self.end) = (text, start, end) }
}

public struct Dictation: Equatable, Sendable {
    /// The only thing inserted.
    public var text: String
    public var raw: String
    /// Nil when vocabulary is off or the rescorer changed nothing.
    public var boosted: String?
    /// Release until the worker started the job. Long only behind a model load.
    public var waited: Double
    public var decode: Double
    public var rescore: Double
    public var finish: Double
    /// Names from the screen boosted on top of the vocabulary.
    public var screenTerms: Int
    /// The decoder's pieces of `raw`, with their times. Empty when the model gave none.
    public var tokens: [TimedToken]

    public init(text: String, raw: String, boosted: String?, waited: Double, decode: Double, rescore: Double,
                finish: Double, screenTerms: Int = 0, tokens: [TimedToken] = []) {
        (self.text, self.raw, self.boosted) = (text, raw, boosted)
        (self.waited, self.decode, self.rescore, self.finish) = (waited, decode, rescore, finish)
        self.screenTerms = screenTerms
        self.tokens = tokens
    }
}

public enum LoadPhase: Equatable, Sendable {
    case downloading(fraction: Double)
    /// Silent during each blocking CoreML compile, about 41 s on the first launch.
    case compiling
    /// The CTC model behind vocabulary boosting. FluidAudio reports no progress for it.
    case preparingVocabulary
}

public enum EngineStatus: Equatable, Sendable {
    case loading(LoadPhase)
    case ready(boosting: Boosting)
    /// Queued dictations stay in memory until Retry succeeds.
    case failed(String)

    public enum Boosting: Equatable, Sendable { case on(terms: Int), off, unavailable(String) }
}

public enum BarEdge: String, CaseIterable, Codable, Sendable {
    case bottom, top, left, right

    /// On a side edge the idle pill stands upright.
    public var isSide: Bool { self == .left || self == .right }

    /// Where a body of this size sits in `area`, `inset` points in from this edge. Along the top and bottom it is
    /// centered. On a side it is vertically centered and flush with that side, so it grows away from it.
    public func place(width: Double, height: Double, in area: BarRect, inset: Double) -> BarRect {
        let centeredX = (area.midX - width / 2).rounded(), centeredY = (area.midY - height / 2).rounded()
        return switch self {
        case .bottom: BarRect(x: centeredX, y: area.minY + inset, width: width, height: height)
        case .top: BarRect(x: centeredX, y: area.maxY - inset - height, width: width, height: height)
        case .left: BarRect(x: area.minX + inset, y: centeredY, width: width, height: height)
        case .right: BarRect(x: area.maxX - inset - width, y: centeredY, width: width, height: height)
        }
    }

    /// A toast attached to `body`: above it, or below it on the top edge, aligned the way the body is.
    public func placeToast(width: Double, height: Double, against body: BarRect, gap: Double) -> BarRect {
        let x = switch self {
        case .left: body.minX
        case .right: body.maxX - width
        case .top, .bottom: (body.midX - width / 2).rounded()
        }
        return BarRect(x: x, y: self == .top ? body.minY - gap - height : body.maxY + gap, width: width, height: height)
    }

    /// The edge whose snap spot, the middle of that edge of `area`, is nearest to the point.
    public static func nearest(x: Double, y: Double, in area: BarRect) -> BarEdge {
        allCases.min { a, b in a.distanceSquared(x: x, y: y, in: area) < b.distanceSquared(x: x, y: y, in: area) }!
    }

    private func distanceSquared(x: Double, y: Double, in area: BarRect) -> Double {
        let spot = switch self {
        case .bottom: (area.midX, area.minY)
        case .top: (area.midX, area.maxY)
        case .left: (area.minX, area.midY)
        case .right: (area.maxX, area.midY)
        }
        return (x - spot.0) * (x - spot.0) + (y - spot.1) * (y - spot.1)
    }
}

/// A rectangle in screen points with the origin at the bottom left, as AppKit has it. IslandCore stays free of
/// CoreGraphics, so it has its own.
public struct BarRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = (x, y, width, height)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Moved, not resized, to lie inside `area` as far as it fits.
    public func moved(into area: BarRect) -> BarRect {
        BarRect(x: min(max(x, area.minX), area.maxX - width), y: min(max(y, area.minY), area.maxY - height),
                width: width, height: height)
    }

    /// This area less the strips that other apps' bars cover along its edges, such as the top bar of a tiling window
    /// manager like OmniWM or SketchyBar, which macOS leaves out of the visible frame. A window counts as a bar when
    /// it touches an edge, runs along at least half of it, and is at most `maxThickness` deep. Anything else, like a
    /// floating window or a full-screen overlay, is ignored. `touch` is how far from an edge a bar may sit and still count
    /// as touching it, for an area that reaches under the macOS menu bar, where a bar can sit just below it.
    public func clear(of windows: [BarRect], maxThickness: Double = 80, touch: Double = 2) -> BarRect {
        var (top, bottom, left, right) = (maxY, minY, minX, maxX)
        for window in windows {
            let alongX = Swift.min(window.maxX, maxX) - Swift.max(window.minX, minX)
            let alongY = Swift.min(window.maxY, maxY) - Swift.max(window.minY, minY)
            if alongX >= width / 2, window.height <= maxThickness {
                if window.maxY >= maxY - touch, window.minY < maxY { top = Swift.min(top, window.minY) }
                if window.minY <= minY + touch, window.maxY > minY { bottom = Swift.max(bottom, window.maxY) }
            }
            if alongY >= height / 2, window.width <= maxThickness {
                if window.minX <= minX + touch, window.maxX > minX { left = Swift.max(left, window.maxX) }
                if window.maxX >= maxX - touch, window.minX < maxX { right = Swift.min(right, window.minX) }
            }
        }
        return BarRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}

public enum MicrophoneChoice: Equatable, Codable, Sendable {
    /// The best microphone connected now. Unless the user set `Settings.automaticOrder`, the order is by kind and
    /// follows what records soonest and best: a wired one, then the Mac's own, then a Bluetooth headset, whose
    /// microphone takes a second or more to start.
    case automatic
    case systemDefault
    /// A CoreAudio device UID, which survives unplugging and reboots. The name is for display while it is absent.
    case device(uid: String, name: String)

    /// Where to capture from, given the inputs connected now, the system default's UID, and whether the lid is closed,
    /// which disconnects a MacBook's own microphone. `order` is the user's order for Automatic, and unset it is the
    /// kind order alone.
    public func source(among inputs: [MicrophoneInput], systemDefault: String?, lidClosed: Bool,
                       order: AutomaticOrder = AutomaticOrder()) -> MicrophoneSource {
        switch self {
        case .systemDefault:
            return .systemDefault
        case .device(let uid, let name):
            return inputs.contains { $0.uid == uid } ? .device(uid: uid) : .fallback(missing: name)
        case .automatic:
            return order.pick(among: inputs, systemDefault: systemDefault, lidClosed: lidClosed).map { .device(uid: $0) } ?? .systemDefault
        }
    }
}

/// An input as the microphone choice sees it.
public struct MicrophoneInput: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// USB, Thunderbolt, FireWire, PCI and display microphones.
        case wired
        /// The Mac's own microphone.
        case builtIn
        /// A Bluetooth headset. Recording from it drops its playback to call quality.
        case bluetooth
        /// Virtual and aggregate devices and iPhone microphones.
        case other
    }

    public let uid: String
    public let kind: Kind
    /// For listing only. Picking goes by UID and kind.
    public let name: String

    public init(uid: String, kind: Kind, name: String = "") {
        self.uid = uid
        self.kind = kind
        self.name = name
    }
}

public enum MicrophoneSource: Equatable, Sendable {
    /// The Mac's default input: System Default, or Automatic with no microphone it would pick.
    case systemDefault
    case device(uid: String)
    /// The chosen device is not connected, so capture uses the system default.
    case fallback(missing: String)
}

/// An unplugged chosen microphone is mentioned once, then again only after it was seen connected or the choice
/// changed. Only a mention that showed counts, so a fn chord that ends before the bar does not use it up.
public struct MissingMicrophone: Sendable {
    private var shown: String?

    public init() {}

    /// The missing device to mention for a capture's source, if any.
    public mutating func toMention(for source: MicrophoneSource) -> String? {
        guard case .fallback(let missing) = source else {
            shown = nil
            return nil
        }
        return missing == shown ? nil : missing
    }

    public mutating func didMention(_ missing: String) { shown = missing }
}

/// The color of a notice's icon: green for information, amber for something degraded, red for a failure.
public enum NoticeTone: Equatable, Sendable { case info, warning, failure }

/// The agent's round mark and name, as the bar and the card show them.
public struct BarAgent: Equatable, Sendable {
    public var initial: String
    public var name: String
    public init(initial: String, name: String) { (self.initial, self.name) = (initial, name) }
}
