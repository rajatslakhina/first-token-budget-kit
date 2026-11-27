/// Decides when buffered token deltas are committed to the screen.
///
/// Committing every delta re-lays out the answer at token rate (50-150 deltas a second on a
/// fast model), which is more layout passes than the display can show. Coalescing to the
/// display refresh fixes that. The trap is *how*: the common implementation buffers
/// everything and flushes on the next display tick, which delays the very first token by up
/// to a frame and makes the metric the user feels the one you made worse.
public protocol CoalescingStrategy: Sendable {
    /// A text delta arrived at `now`. Returns text to commit immediately, or `nil` to hold it.
    mutating func ingest(_ text: String, at now: UInt64) -> String?
    /// A display frame at `now`. Returns buffered text to commit, or `nil`.
    mutating func frame(at now: UInt64) -> String?
    /// The stream ended. Returns anything still held.
    mutating func drain() -> String?
    /// Whether text is currently held back.
    var isHoldingText: Bool { get }
}

/// Leading-edge throttle: when nothing has been committed for a full frame, a delta is
/// committed the moment it arrives; deltas inside the frame window are held and committed
/// together on the next frame.
///
/// Guarantees (tested): the first delta is never held; at most one commit per frame interval
/// except for buffer-limit flushes; the concatenation of commits equals the concatenation of
/// inputs; held text is flushed as soon as it reaches `maxBufferedBytes`.
public struct LeadingEdgeCoalescer: CoalescingStrategy {
    public let frameInterval: UInt64
    public let maxBufferedBytes: Int

    private var buffer = ""
    private var bufferedBytes = 0
    private var lastCommit: UInt64?

    /// - Parameters:
    ///   - frameInterval: nanoseconds per frame; clamped to at least 1.
    ///   - maxBufferedBytes: flush early once this much text is held; clamped to at least 1.
    public init(frameInterval: UInt64 = 16_666_667, maxBufferedBytes: Int = 4_096) {
        self.frameInterval = max(1, frameInterval)
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    public var isHoldingText: Bool { !buffer.isEmpty }

    public mutating func ingest(_ text: String, at now: UInt64) -> String? {
        guard !text.isEmpty else { return nil }
        if buffer.isEmpty, windowIsOpen(at: now) {
            lastCommit = now
            return text
        }
        buffer += text
        let count = text.utf8.count
        bufferedBytes = bufferedBytes > Int.max - count ? Int.max : bufferedBytes + count
        return bufferedBytes >= maxBufferedBytes ? take(at: now) : nil
    }

    public mutating func frame(at now: UInt64) -> String? {
        guard !buffer.isEmpty, windowIsOpen(at: now) else { return nil }
        return take(at: now)
    }

    public mutating func drain() -> String? {
        guard !buffer.isEmpty else { return nil }
        let out = buffer
        buffer = ""
        bufferedBytes = 0
        return out
    }

    private func windowIsOpen(at now: UInt64) -> Bool {
        guard let lastCommit else { return true }
        return Saturating.sub(now, lastCommit) >= frameInterval
    }

    private mutating func take(at now: UInt64) -> String {
        let out = buffer
        buffer = ""
        bufferedBytes = 0
        lastCommit = now
        return out
    }
}

/// The common baseline: hold every delta and commit whatever is buffered on each display
/// frame. Shipped so the replayer and the demo can measure what leading-edge commits buy;
/// not recommended for production.
public struct TrailingEdgeCoalescer: CoalescingStrategy {
    public let maxBufferedBytes: Int
    private var buffer = ""
    private var bufferedBytes = 0

    public init(maxBufferedBytes: Int = 4_096) {
        self.maxBufferedBytes = max(1, maxBufferedBytes)
    }

    public var isHoldingText: Bool { !buffer.isEmpty }

    public mutating func ingest(_ text: String, at now: UInt64) -> String? {
        guard !text.isEmpty else { return nil }
        buffer += text
        let count = text.utf8.count
        bufferedBytes = bufferedBytes > Int.max - count ? Int.max : bufferedBytes + count
        return bufferedBytes >= maxBufferedBytes ? drain() : nil
    }

    public mutating func frame(at now: UInt64) -> String? { drain() }

    public mutating func drain() -> String? {
        guard !buffer.isEmpty else { return nil }
        let out = buffer
        buffer = ""
        bufferedBytes = 0
        return out
    }
}

extension String {
    /// Whether committing this text puts at least one visible character on screen.
    var containsGlyph: Bool { unicodeScalars.contains { !$0.properties.isWhitespace } }
}
