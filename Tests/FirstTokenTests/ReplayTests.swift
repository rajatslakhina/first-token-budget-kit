@testable import FirstToken
import Foundation
import XCTest

final class ReplayTests: XCTestCase {
    private let seeds: Range<UInt64> = 0..<10

    func testReplayIsDeterministicPerSeedAndVariesAcrossSeeds() {
        let a = FixtureReplayer.run(.steady, configuration: .shipped, seed: 4)
        let b = FixtureReplayer.run(.steady, configuration: .shipped, seed: 4)
        let c = FixtureReplayer.run(.steady, configuration: .shipped, seed: 5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a.breakdown?.total, c.breakdown?.total)
    }

    func testEveryFixtureAndStrategyCommitsTheWholeAnswerWithoutTruncation() {
        for fixture in StreamFixture.standard {
            for kind in CoalescerKind.allCases {
                let config = ReplayConfiguration(prewarmConnection: false, speculativePromptHit: false, coalescer: kind)
                let result = FixtureReplayer.run(fixture, configuration: config, seed: 1)
                let expected = fixture.name == "whitespace-lead" ? "\n" + StreamFixture.sampleAnswer : StreamFixture.sampleAnswer
                XCTAssertEqual(result.committedText, expected, "\(fixture.name) \(kind)")
                XCTAssertFalse(result.truncated)
                XCTAssertNotNil(result.breakdown)
                XCTAssertEqual(result.deltas.last, .messageStop)
            }
        }
    }

    func testTheSplitFirstDeltaIsOnlyAvailableWhenItsSecondHalfArrives() throws {
        let config = ReplayConfiguration(profile: .init(requestBuild: 0, coldConnect: 0, warmConnect: 0, serverQueue: 0, jitterPermille: 0),
                                         prewarmConnection: false, speculativePromptHit: false, coalescer: .leadingEdge)
        let split = try XCTUnwrap(FixtureReplayer.run(.splitFirstDelta, configuration: config, seed: 0).breakdown)
        XCTAssertEqual(split.duration(of: .firstToken), Nanos.milliseconds(190), "150 ms + the 40 ms gap")
    }

    /// A whitespace-only first delta is server pacing: the wait for the first visible delta is
    /// charged to `firstToken` (the API), and `render` (the client) stays under one frame.
    func testWhitespaceLeadIsChargedToFirstTokenNotRender() throws {
        let config = ReplayConfiguration(profile: .init(requestBuild: 0, coldConnect: 0, warmConnect: 0, serverQueue: 0, jitterPermille: 0),
                                         prewarmConnection: false, speculativePromptHit: false, coalescer: .leadingEdge)
        let lead = try XCTUnwrap(FixtureReplayer.run(.whitespaceLead, configuration: config, seed: 0).breakdown)
        XCTAssertEqual(lead.duration(of: .firstToken), Nanos.milliseconds(182), "160 ms + one 22 ms delta")
        XCTAssertLessThanOrEqual(lead.duration(of: .render), config.frameInterval)
    }

    func testLeadingEdgeNeverRendersLaterThanTrailingEdgeOnTheSameRun() throws {
        for fixture in StreamFixture.standard {
            for seed in seeds {
                var config = ReplayConfiguration.naive
                let trailing = try XCTUnwrap(FixtureReplayer.run(fixture, configuration: config, seed: seed).breakdown)
                config.coalescer = .leadingEdge
                let leading = try XCTUnwrap(FixtureReplayer.run(fixture, configuration: config, seed: seed).breakdown)
                XCTAssertLessThanOrEqual(leading.duration(of: .render), trailing.duration(of: .render))
                XCTAssertEqual(leading.duration(of: .serverQueue), trailing.duration(of: .serverQueue), "same seed, same network")
            }
        }
    }

    /// Configurations replayed with the same seed must see the same network, or a comparison
    /// between them measures the random draws instead of the client.
    func testAllConfigurationsSeeTheSameNetworkForTheSameSeed() throws {
        let configs: [ReplayConfiguration] = [
            .naive,
            ReplayConfiguration(prewarmConnection: false, speculativePromptHit: false, coalescer: .leadingEdge),
            ReplayConfiguration(prewarmConnection: true, speculativePromptHit: false, coalescer: .leadingEdge),
            .shipped,
        ]
        for fixture in StreamFixture.standard {
            for seed in seeds {
                let runs = try configs.map { try XCTUnwrap(FixtureReplayer.run(fixture, configuration: $0, seed: seed).breakdown) }
                XCTAssertEqual(Set(runs.map { $0.duration(of: .serverQueue) }).count, 1, "\(fixture.name) seed \(seed)")
                XCTAssertEqual(Set(runs.map { $0.duration(of: .firstToken) }).count, 1, "\(fixture.name) seed \(seed)")
            }
        }
    }

    func testBurstDeltasAreCoalescedIntoFewerCommits() {
        let result = FixtureReplayer.run(.burst, configuration: .shipped, seed: 0)
        let textDeltas = result.deltas.filter { $0.text != nil }.count
        XCTAssertEqual(result.committedText, StreamFixture.sampleAnswer)
        XCTAssertLessThan(result.commits * 2, textDeltas, "4 ms deltas against 16.7 ms frames")
    }

    func testSpeculativeHitPrepaysRequestBuild() throws {
        let b = try XCTUnwrap(FixtureReplayer.run(.steady, configuration: .shipped, seed: 0).breakdown)
        XCTAssertTrue(b.isPrepaid(.requestBuild))
        XCTAssertEqual(b.duration(of: .requestBuild), 0)
        XCTAssertTrue(b.orderingViolations.isEmpty)
    }

    func testFullJitterAndZeroFrameIntervalDoNotTrap() {
        let config = ReplayConfiguration(profile: .init(requestBuild: .max, coldConnect: .max, warmConnect: 0, serverQueue: .max, jitterPermille: 5_000),
                                         prewarmConnection: false, speculativePromptHit: false, coalescer: .trailingEdge, frameInterval: 0)
        let result = FixtureReplayer.run(.steady, configuration: config, seed: 1)
        XCTAssertEqual(config.frameInterval, 1)
        XCTAssertEqual(result.committedText, StreamFixture.sampleAnswer)
    }

    func testAFrameIntervalSetToZeroAfterInitDoesNotTrap() {
        var config = ReplayConfiguration.shipped
        config.frameInterval = 0
        XCTAssertEqual(FixtureReplayer.run(.steady, configuration: config, seed: 0).committedText, StreamFixture.sampleAnswer)
    }

    func testAFixtureWithNoVisibleTextHasNoBreakdown() {
        let empty = StreamFixture(name: "empty", chunks: [FixtureChunk(offset: 0, bytes: Array("event: ping\ndata: {\"type\":\"ping\"}\n\n".utf8))])
        let result = FixtureReplayer.run(empty, configuration: .shipped, seed: 0)
        XCTAssertNil(result.breakdown)
        XCTAssertEqual(result.timeline.missing, [.firstTextDelta, .firstGlyphRendered])
        XCTAssertTrue(FixtureReplayer.totals([empty], configuration: .shipped, seeds: seeds).isEmpty)
    }

    func testPlaybackDeadlinesAreOriginPlusScaledOffset() {
        let origin = ContinuousClock.now
        XCTAssertEqual(FixtureByteStream.deadline(forOffset: Nanos.milliseconds(30), scale: 1_000, origin: origin),
                       origin.advanced(by: .milliseconds(30)))
        XCTAssertEqual(FixtureByteStream.deadline(forOffset: Nanos.milliseconds(30), scale: 500, origin: origin),
                       origin.advanced(by: .milliseconds(15)))
        XCTAssertEqual(FixtureByteStream.deadline(forOffset: .max, scale: 1_000, origin: origin),
                       origin.advanced(by: .nanoseconds(Int.max)), "saturates instead of trapping")
    }

    /// Lateness must not accumulate: a consumer that is 100 ms slow to pull the second chunk
    /// (due at 200 ms) gets it at ~200 ms from the first pull, not 100 ms + 200 ms. A
    /// relative-sleep player takes ~300 ms.
    func testPlaybackDoesNotAccumulateLateness() async throws {
        let fixture = StreamFixture(name: "two", chunks: [
            FixtureChunk(offset: 0, bytes: [0x61]),
            FixtureChunk(offset: Nanos.milliseconds(200), bytes: [0x62]),
        ])
        var iterator = FixtureByteStream(fixture).makeAsyncIterator()
        let clock = ContinuousClock()
        let first = clock.now
        _ = try await iterator.next()
        try await Task.sleep(nanoseconds: Nanos.milliseconds(100))
        _ = try await iterator.next()
        let elapsed = clock.now - first
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(200))
        XCTAssertLessThan(elapsed, .milliseconds(270), "lateness accumulated: \(elapsed)")
    }

    func testRealTimePlaybackPreservesBytesAndOrder() async throws {
        var collected: [UInt8] = []
        for try await chunk in FixtureByteStream(.crlfWithKeepAlives, timeScalePermille: 10) { collected += chunk }
        XCTAssertEqual(collected, StreamFixture.crlfWithKeepAlives.chunks.flatMap(\.bytes))
    }

    /// Prints fresh baseline numbers. Run with FIRSTTOKEN_PRINT_BASELINE=1 after an
    /// intentional pipeline change, review the diff, and update `ReplayBaseline`.
    func testPrintBaselineWhenRequested() {
        guard ProcessInfo.processInfo.environment["FIRSTTOKEN_PRINT_BASELINE"] == "1" else { return }
        var trailing = ReplayConfiguration.shipped
        trailing.coalescer = .trailingEdge
        var noSpeculation = ReplayConfiguration.shipped
        noSpeculation.speculativePromptHit = false
        for (name, config) in [("shipped", ReplayConfiguration.shipped), ("naive", ReplayConfiguration.naive),
                               ("shipped-trailing", trailing), ("shipped-no-speculation", noSpeculation)] {
            let b = FixtureReplayer.breakdowns(StreamFixture.standard, configuration: config, seeds: seeds)
            let totals = b.map(\.total)
            print("BASELINE \(name) total p50=\(Percentile.nearestRank(totals, percentile: 50) ?? 0) p95=\(Percentile.nearestRank(totals, percentile: 95) ?? 0) n=\(b.count)")
            for stage in Stage.allCases {
                let values = b.map { $0.duration(of: stage) }
                print("BASELINE \(name) \(stage) p50=\(Percentile.nearestRank(values, percentile: 50) ?? 0) p95=\(Percentile.nearestRank(values, percentile: 95) ?? 0)")
            }
        }
    }
}
