#if canImport(os)
import os
#endif

/// Records TTFT milestones for one request against a monotonic clock, and mirrors them to
/// `os_signpost` so the same numbers appear in Instruments next to the main thread's work.
///
/// An actor, because milestones are marked from different places: the send button (main
/// actor), the networking layer, the parsing task and the render loop. Marking is first-write-
/// wins per milestone, so a retried request or a second render pass cannot move "first
/// glyph" later.
///
/// Signposts: one point event per milestone ("TTFT milestone") and one interval ("TTFT")
/// from `sendCommitted` to `firstGlyphRendered`. Per-stage intervals are not emitted, because
/// prepaid milestones arrive before the send and do not nest; the per-stage split is what
/// `breakdown()` is for.
public actor TTFTInstrument {
    private let clock: any MonotonicClock
    public private(set) var timeline = TTFTTimeline()

    #if canImport(os)
    private let signposter: OSSignposter
    private var interval: OSSignpostIntervalState?
    #endif

    public init(clock: any MonotonicClock = SystemClock(), subsystem: String = "FirstToken") {
        self.clock = clock
        #if canImport(os)
        signposter = OSSignposter(subsystem: subsystem, category: "TTFT")
        #endif
    }

    @discardableResult
    public func mark(_ milestone: Milestone) -> TTFTTimeline.MarkResult {
        let result = timeline.mark(milestone, at: clock.now())
        guard result == .recorded else { return result }
        #if canImport(os)
        signposter.emitEvent("TTFT milestone", "\(milestone.label, privacy: .public)")
        if milestone == .sendCommitted {
            interval = signposter.beginInterval("TTFT", id: signposter.makeSignpostID())
        } else if milestone == .firstGlyphRendered, let state = interval {
            signposter.endInterval("TTFT", state)
            interval = nil
        }
        #endif
        return result
    }

    public func breakdown() -> TTFTBreakdown? { timeline.breakdown() }

    /// Start a new measurement. An unfinished signpost interval is closed so Instruments
    /// does not show it as running forever.
    public func reset() {
        #if canImport(os)
        if let state = interval {
            signposter.endInterval("TTFT", state)
            interval = nil
        }
        #endif
        timeline = TTFTTimeline()
    }
}
