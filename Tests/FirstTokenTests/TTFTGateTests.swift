@testable import FirstToken
import XCTest

/// The CI regression gate. Each test replays a configuration and gates it against the
/// committed baseline; the regressions below are deliberate, to prove the gate fails on them.
final class TTFTGateTests: XCTestCase {
    private let seeds = ReplayBaseline.seeds
    /// Every run must produce a breakdown: a regression that loses runs fails on sample count.
    private let gate = RegressionGate(minimumSamples: ReplayBaseline.sampleCount)

    private func breakdowns(_ config: ReplayConfiguration) -> [TTFTBreakdown] {
        FixtureReplayer.breakdowns(StreamFixture.standard, configuration: config, seeds: seeds)
    }

    private func failingStages(_ config: ReplayConfiguration) -> Set<Stage> {
        let results = gate.evaluate(stageBaselines: ReplayBaseline.stages, candidate: breakdowns(config))
        return Set(results.filter { !$0.value.passed }.map(\.key))
    }

    private func totalPasses(_ config: ReplayConfiguration) -> Bool {
        gate.evaluate(baseline: ReplayBaseline.total, candidate: breakdowns(config).map(\.total)).passed
    }

    func testARegressionThatLosesRunsFailsOnSampleCount() {
        let survivors = Array(breakdowns(.shipped).map(\.total).prefix(ReplayBaseline.sampleCount - 1))
        XCTAssertEqual(gate.evaluate(baseline: ReplayBaseline.total, candidate: survivors).status, .insufficientSamples)
    }

    func testShippedPipelineHoldsTheCommittedBaseline() {
        let b = breakdowns(.shipped)
        XCTAssertEqual(b.count, 40)
        XCTAssertTrue(totalPasses(.shipped))
        XCTAssertEqual(failingStages(.shipped), [])
        XCTAssertEqual(GateBaseline(samples: b.map(\.total)), ReplayBaseline.total, "replay is deterministic: the baseline is exact")
        for (stage, baseline) in ReplayBaseline.stages {
            XCTAssertEqual(GateBaseline(samples: b.map { $0.duration(of: stage) }), baseline, "\(stage)")
        }
    }

    func testTheNaivePipelineFailsTheTotalAndEveryClientStage() {
        let result = gate.evaluate(baseline: ReplayBaseline.total, candidate: breakdowns(.naive).map(\.total))
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

    func testLosingPromptSpeculationFailsTheTotalAndNamesTheRequestBuildStage() {
        var config = ReplayConfiguration.shipped
        config.speculativePromptHit = false
        XCTAssertFalse(totalPasses(config))
        XCTAssertEqual(failingStages(config), [.requestBuild])
    }

    /// Why client stages get their own gates: a one-frame render regression (trailing-edge
    /// commits) sits inside the total's tolerance (5% + 2 ms at p50, 10% + 2 ms at p95), so a
    /// total-only gate waves it through. The render-stage gate catches it.
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
