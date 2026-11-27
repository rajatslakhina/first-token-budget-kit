@testable import FirstToken
import XCTest

/// Baselines recorded from `ReplayConfiguration.shipped` over `StreamFixture.standard` and
/// seeds 0..<10 (40 runs). Regenerate with `FIRSTTOKEN_PRINT_BASELINE=1 swift test --filter
/// ReplayTests/testPrintBaselineWhenRequested` after an intentional change, and review the
/// diff like any other code change.
enum TTFTBaseline {
    static let total = GateBaseline(p50: 521_359_150, p95: 601_208_880)
    /// The client-owned stages. `serverQueue` and `firstToken` are the API's and the
    /// fixtures'; gating them would gate the fixture, not the client.
    static let stages: [Stage: GateBaseline] = [
        .requestBuild: GateBaseline(p50: 0, p95: 0),
        .connection: GateBaseline(p50: 4_060_000, p95: 4_908_000),
        .render: GateBaseline(p50: 10_669_856, p95: 38_891_150),
    ]
}

/// The CI regression gate. Each test replays a configuration and gates it against the
/// committed baseline; the regressions below are deliberate, to prove the gate fails on them.
final class TTFTGateTests: XCTestCase {
    private let seeds: Range<UInt64> = 0..<10
    private let gate = RegressionGate()

    private func breakdowns(_ config: ReplayConfiguration) -> [TTFTBreakdown] {
        FixtureReplayer.breakdowns(StreamFixture.standard, configuration: config, seeds: seeds)
    }

    private func failingStages(_ config: ReplayConfiguration) -> Set<Stage> {
        let results = gate.evaluate(stageBaselines: TTFTBaseline.stages, candidate: breakdowns(config))
        return Set(results.filter { !$0.value.passed }.map(\.key))
    }

    private func totalPasses(_ config: ReplayConfiguration) -> Bool {
        gate.evaluate(baseline: TTFTBaseline.total, candidate: breakdowns(config).map(\.total)).passed
    }

    func testShippedPipelineHoldsTheCommittedBaseline() {
        let b = breakdowns(.shipped)
        XCTAssertEqual(b.count, 40)
        XCTAssertTrue(totalPasses(.shipped))
        XCTAssertEqual(failingStages(.shipped), [])
        XCTAssertEqual(GateBaseline(samples: b.map(\.total)), TTFTBaseline.total, "replay is deterministic: the baseline is exact")
    }

    func testTheNaivePipelineFailsTheTotalAndEveryClientStage() {
        let result = gate.evaluate(baseline: TTFTBaseline.total, candidate: breakdowns(.naive).map(\.total))
        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.metrics.filter(\.breached).map(\.name), ["p50", "p95"])
        XCTAssertEqual(failingStages(.naive), [.requestBuild, .connection, .render])
    }

    func testLosingConnectionPrewarmFailsTheTotalAndNamesTheConnectionStage() {
        var config = ReplayConfiguration.shipped
        config.prewarmConnection = false
        XCTAssertFalse(totalPasses(config))
        XCTAssertEqual(failingStages(config), [.connection])
    }

    /// Why client stages get their own gates: losing prompt speculation (~35 ms) and a
    /// one-frame render regression both sit inside the total's tolerance (5% + 2 ms of
    /// ~520 ms), so a total-only gate waves them through. The stage gates catch both, and
    /// say which team owns the fix.
    func testLosingPromptSpeculationHidesInTheTotalButFailsItsStageGate() {
        var config = ReplayConfiguration.shipped
        config.speculativePromptHit = false
        XCTAssertTrue(totalPasses(config), "if this starts failing, the total gate got tighter: update the premise")
        XCTAssertEqual(failingStages(config), [.requestBuild])
    }

    func testAOneFrameRenderRegressionHidesInTheTotalButFailsItsStageGate() {
        var config = ReplayConfiguration.shipped
        config.coalescer = .trailingEdge
        XCTAssertTrue(totalPasses(config), "if this starts failing, the total gate got tighter: update the premise")
        XCTAssertEqual(failingStages(config), [.render])
    }

    func testTheBudgetFlagsTheNaivePipelinesConnectionStage() throws {
        let b = try XCTUnwrap(FixtureReplayer.run(.steady, configuration: .naive, seed: 0).breakdown)
        let report = TTFTBudget.interactiveChat.evaluate(b)
        XCTAssertTrue(report.overruns.contains { $0.stage == .connection })
        let shipped = try XCTUnwrap(FixtureReplayer.run(.steady, configuration: .shipped, seed: 0).breakdown)
        XCTAssertFalse(TTFTBudget.interactiveChat.evaluate(shipped).overruns.contains { $0.stage == .connection })
    }
}
