@testable import FirstToken
import XCTest

final class TimelineTests: XCTestCase {
    private func ms(_ v: UInt64) -> UInt64 { Nanos.milliseconds(v) }

    private func timeline(_ times: [Milestone: UInt64]) -> TTFTTimeline {
        var t = TTFTTimeline()
        for (milestone, time) in times { t.mark(milestone, at: time) }
        return t
    }

    func testColdRequestSplitsIntoTheFiveStages() throws {
        let t = timeline([
            .sendCommitted: ms(1_000), .requestBuilt: ms(1_030), .connectionReady: ms(1_250),
            .headersReceived: ms(1_560), .firstTextDelta: ms(1_740), .firstGlyphRendered: ms(1_750),
        ])
        let b = try XCTUnwrap(t.breakdown())
        XCTAssertEqual(b.total, ms(750))
        XCTAssertEqual(b.stages.map(\.stage), Stage.allCases)
        XCTAssertEqual(b.stages.map(\.nanoseconds), [ms(30), ms(220), ms(310), ms(180), ms(10)])
        XCTAssertTrue(b.orderingViolations.isEmpty)
        XCTAssertFalse(b.stages.contains { $0.prepaid })
    }

    func testPrepaidMilestonesCostZeroAndAreFlaggedAsPrepaid() throws {
        let t = timeline([
            .sendCommitted: ms(1_000), .requestBuilt: ms(990), .connectionReady: ms(800),
            .headersReceived: ms(1_300), .firstTextDelta: ms(1_480), .firstGlyphRendered: ms(1_490),
        ])
        let b = try XCTUnwrap(t.breakdown())
        XCTAssertEqual(b.duration(of: .requestBuild), 0)
        XCTAssertEqual(b.duration(of: .connection), 0)
        XCTAssertTrue(b.isPrepaid(.requestBuild))
        XCTAssertTrue(b.isPrepaid(.connection))
        XCTAssertEqual(b.duration(of: .serverQueue), ms(300))
        XCTAssertEqual(b.total, ms(490))
        XCTAssertTrue(b.orderingViolations.isEmpty, "prepaid is not a violation")
    }

    func testAPostSendMilestoneBeforeTheSendIsAViolationNotPrepaid() throws {
        let t = timeline([
            .sendCommitted: ms(1_000), .requestBuilt: ms(1_010), .connectionReady: ms(1_020),
            .headersReceived: ms(500), .firstTextDelta: ms(1_100), .firstGlyphRendered: ms(1_110),
        ])
        let b = try XCTUnwrap(t.breakdown())
        XCTAssertEqual(b.orderingViolations, [.headersReceived])
        XCTAssertFalse(b.isPrepaid(.serverQueue))
        XCTAssertEqual(b.duration(of: .serverQueue), 0)
    }

    func testOutOfOrderAfterSendIsClampedAndReported() throws {
        let t = timeline([
            .sendCommitted: ms(1_000), .requestBuilt: ms(1_100), .connectionReady: ms(1_050),
            .headersReceived: ms(1_300), .firstTextDelta: ms(1_400), .firstGlyphRendered: ms(1_410),
        ])
        let b = try XCTUnwrap(t.breakdown())
        XCTAssertEqual(b.orderingViolations, [.connectionReady])
        XCTAssertEqual(b.duration(of: .connection), 0)
        XCTAssertEqual(b.duration(of: .serverQueue), ms(200), "measured from the clamped predecessor")
    }

    /// The conservation law, over random timelines including prepaid, clamped and extreme
    /// timestamps: stage durations always sum exactly to the total.
    func testStageDurationsAlwaysSumToTotal() throws {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<2_000 {
            var t = TTFTTimeline()
            let send = rng.next() % 1_000_000 + 1_000_000
            t.mark(.sendCommitted, at: send)
            for milestone in Milestone.allCases.dropFirst() {
                let r = rng.next()
                let time: UInt64 = switch r % 5 {
                case 0: send - (r % 1_000)
                case 1: UInt64.max - (r % 3)
                default: send + (r % 2_000_000)
                }
                t.mark(milestone, at: time)
            }
            let b = try XCTUnwrap(t.breakdown())
            let sum = b.stages.reduce(UInt64(0)) { Saturating.add($0, $1.nanoseconds) }
            XCTAssertEqual(sum, b.total)
        }
    }

    func testDuplicateMarksAreIgnoredFirstWriteWins() {
        var t = TTFTTimeline()
        XCTAssertEqual(t.mark(.firstGlyphRendered, at: 10), .recorded)
        XCTAssertEqual(t.mark(.firstGlyphRendered, at: 99), .duplicateIgnored)
        XCTAssertEqual(t.raw[.firstGlyphRendered], 10)
    }

    func testIncompleteTimelineHasNoBreakdownAndListsWhatIsMissing() {
        var t = TTFTTimeline()
        t.mark(.sendCommitted, at: 1)
        t.mark(.requestBuilt, at: 2)
        XCTAssertNil(t.breakdown())
        XCTAssertEqual(t.missing, [.connectionReady, .headersReceived, .firstTextDelta, .firstGlyphRendered])
        XCTAssertNil(TTFTTimeline().breakdown())
    }

    func testInstrumentRecordsAgainstItsClock() async throws {
        let clock = ManualClock(start: 100)
        let instrument = TTFTInstrument(clock: clock)
        for milestone in Milestone.allCases {
            await instrument.mark(milestone)
            clock.advance(by: 10)
        }
        let duplicate = await instrument.mark(.firstGlyphRendered)
        XCTAssertEqual(duplicate, .duplicateIgnored)
        let measured = await instrument.breakdown()
        let b = try XCTUnwrap(measured)
        XCTAssertEqual(b.total, 50)
        XCTAssertEqual(b.stages.map(\.nanoseconds), [10, 10, 10, 10, 10])
        await instrument.reset()
        let afterReset = await instrument.breakdown()
        XCTAssertNil(afterReset)
    }

    func testInstrumentCanStampWithACallerTakenReading() async throws {
        let instrument = TTFTInstrument(clock: ManualClock(start: 999))
        for (offset, milestone) in Milestone.allCases.enumerated() {
            await instrument.mark(milestone, at: UInt64(offset) * 7)
        }
        let measured = await instrument.breakdown()
        XCTAssertEqual(try XCTUnwrap(measured).total, 35, "the actor's own clock (999) is not used")
    }

    func testBudgetReportsOverrunsAndTheDominantStage() throws {
        let t = timeline([
            .sendCommitted: ms(0) + 1, .requestBuilt: ms(50) + 1, .connectionReady: ms(250) + 1,
            .headersReceived: ms(600) + 1, .firstTextDelta: ms(700) + 1, .firstGlyphRendered: ms(710) + 1,
        ])
        let report = TTFTBudget.interactiveChat.evaluate(try XCTUnwrap(t.breakdown()))
        XCTAssertEqual(report.overruns.map(\.stage), [.requestBuild, .connection])
        XCTAssertEqual(report.overruns.first?.excess, ms(10))
        XCTAssertEqual(report.dominantStage, .serverQueue, "unbudgeted stages still count as dominant")
        XCTAssertEqual(report.totalExcess, 0)
        XCTAssertFalse(report.withinBudget)
    }

    func testBudgetDominantStageTieGoesToTheEarliestStageAndZeroMeansNone() throws {
        let tie = timeline([
            .sendCommitted: 0, .requestBuilt: 5, .connectionReady: 10,
            .headersReceived: 10, .firstTextDelta: 10, .firstGlyphRendered: 10,
        ])
        let report = TTFTBudget.interactiveChat.evaluate(try XCTUnwrap(tie.breakdown()))
        XCTAssertEqual(report.dominantStage, .requestBuild)
        XCTAssertTrue(report.withinBudget)

        let zero = timeline(Dictionary(uniqueKeysWithValues: Milestone.allCases.map { ($0, UInt64(7)) }))
        XCTAssertNil(TTFTBudget.interactiveChat.evaluate(try XCTUnwrap(zero.breakdown())).dominantStage)
    }
}
