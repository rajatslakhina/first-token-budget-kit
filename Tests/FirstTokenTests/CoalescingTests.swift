@testable import FirstToken
import XCTest

final class CoalescingTests: XCTestCase {
    private let frame: UInt64 = 16_000_000

    func testLeadingEdgeCommitsTheFirstDeltaTheMomentItArrives() {
        var c = LeadingEdgeCoalescer(frameInterval: frame)
        XCTAssertEqual(c.ingest("Hel", at: 1_000), "Hel")
        XCTAssertFalse(c.isHoldingText)
    }

    func testAWhitespaceLeadDoesNotMakeTheFirstVisibleDeltaWait() {
        var c = LeadingEdgeCoalescer(frameInterval: frame)
        XCTAssertEqual(c.ingest("\n", at: 0), "\n")
        XCTAssertEqual(c.ingest("Hi", at: 1_000), "Hi", "the newline must not spend the frame")
        XCTAssertNil(c.ingest("!", at: 2_000), "the glyph commit did spend it")
    }

    func testTrailingEdgeHoldsTheFirstDeltaUntilTheNextFrame() {
        var c = TrailingEdgeCoalescer()
        XCTAssertNil(c.ingest("Hel", at: 1_000))
        XCTAssertTrue(c.isHoldingText)
        XCTAssertEqual(c.frame(at: 1_000 + frame), "Hel")
    }

    func testLeadingEdgeHoldsDeltasInsideTheFrameWindowAndReleasesThemTogether() {
        var c = LeadingEdgeCoalescer(frameInterval: frame)
        _ = c.ingest("a", at: 0)
        XCTAssertNil(c.ingest("b", at: 1_000))
        XCTAssertNil(c.ingest("c", at: 2_000))
        XCTAssertNil(c.frame(at: frame - 1), "window still closed")
        XCTAssertEqual(c.frame(at: frame), "bc")
    }

    func testLeadingEdgeCommitsImmediatelyAgainAfterAnIdleFrame() {
        var c = LeadingEdgeCoalescer(frameInterval: frame)
        _ = c.ingest("a", at: 0)
        XCTAssertEqual(c.ingest("b", at: frame * 3), "b")
    }

    func testBufferLimitForcesAFlushInsideTheWindow() {
        var c = LeadingEdgeCoalescer(frameInterval: frame, maxBufferedBytes: 4)
        _ = c.ingest("a", at: 0)
        XCTAssertNil(c.ingest("bc", at: 1))
        XCTAssertEqual(c.ingest("de", at: 2), "bcde")
    }

    func testEmptyDeltasAreIgnoredAndDrainReturnsHeldText() {
        var c = LeadingEdgeCoalescer(frameInterval: frame)
        XCTAssertNil(c.ingest("", at: 0))
        XCTAssertEqual(c.ingest("x", at: 0), "x", "an empty delta must not consume the leading edge")
        _ = c.ingest("y", at: 1)
        XCTAssertEqual(c.drain(), "y")
        XCTAssertNil(c.drain())
    }

    func testDegenerateParametersAreClampedNotTrapped() {
        let c = LeadingEdgeCoalescer(frameInterval: 0, maxBufferedBytes: -5)
        XCTAssertEqual(c.frameInterval, 1)
        XCTAssertEqual(c.maxBufferedBytes, 1)
    }

    /// For 300 random delta streams per strategy: nothing is lost or reordered (every delta is
    /// distinct), and outside buffer-limit flushes the leading-edge coalescer commits at most
    /// once per frame interval.
    func testConservationAndCommitRateOverRandomStreams() {
        var rng = SplitMix64(seed: 99)
        for kind in CoalescerKind.allCases {
            for _ in 0..<300 {
                var c = kind.make(frameInterval: frame)
                var input = ""
                var output = ""
                var commitTimes: [UInt64] = []
                var now: UInt64 = 0
                var nextFrame = frame
                for _ in 0..<(rng.next() % 60 + 1) {
                    now += rng.next() % 12_000_000
                    while nextFrame <= now {
                        if let s = c.frame(at: nextFrame) { output += s; commitTimes.append(nextFrame) }
                        nextFrame += frame
                    }
                    let length = Int(rng.next() % 5)
                    let text = length == 0 ? "" : "<\(input.count)" + String(repeating: "-", count: length) + ">"
                    input += text
                    if let s = c.ingest(text, at: now) { output += s; commitTimes.append(now) }
                }
                if let rest = c.drain() { output += rest }
                XCTAssertEqual(output, input, "\(kind)")
                if kind == .leadingEdge {
                    for (a, b) in zip(commitTimes, commitTimes.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(b - a, frame)
                    }
                }
            }
        }
    }
}
