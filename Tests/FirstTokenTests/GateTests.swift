@testable import FirstToken
import XCTest

final class GateTests: XCTestCase {
    func testNearestRankPercentiles() {
        let values: [UInt64] = [10, 1, 9, 2, 8, 3, 7, 4, 6, 5]
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 50), 5)
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 95), 10)
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 90), 9)
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 91), 10, "ceil, not floor")
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 1), 1)
        XCTAssertEqual(Percentile.nearestRank(values, percentile: 100), 10)
        XCTAssertEqual(Percentile.nearestRank([42], percentile: 95), 42)
    }

    func testPercentileRejectsEmptyInputAndOutOfRangePercentiles() {
        XCTAssertNil(Percentile.nearestRank([], percentile: 50))
        XCTAssertNil(Percentile.nearestRank([1], percentile: 0))
        XCTAssertNil(Percentile.nearestRank([1], percentile: 101))
        XCTAssertNil(Percentile.nearestRank([1], percentile: -3))
    }

    func testGatePassesWithinToleranceAndFailsWhenOnlyTheTailSlips() {
        let gate = RegressionGate(minimumSamples: 10, p50TolerancePermille: 50, p95TolerancePermille: 100, absoluteSlack: 0)
        let baseline = (1...100).map { UInt64($0) * 1_000 }
        XCTAssertTrue(gate.evaluate(baseline: baseline, candidate: baseline.map { $0 + $0 / 25 }).passed, "+4%")
        var tail = baseline
        for i in 90..<100 { tail[i] *= 2 }
        let result = gate.evaluate(baseline: baseline, candidate: tail)
        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.metrics.filter(\.breached).map(\.name), ["p95"])
    }

    func testAbsoluteSlackAbsorbsNoiseOnTinyBaselines() {
        let gate = RegressionGate(minimumSamples: 1, p50TolerancePermille: 0, p95TolerancePermille: 0, absoluteSlack: 5)
        XCTAssertTrue(gate.evaluate(baseline: [10], candidate: [15]).passed)
        XCTAssertFalse(gate.evaluate(baseline: [10], candidate: [16]).passed)
    }

    func testTooFewSamplesIsNotAPass() {
        let gate = RegressionGate(minimumSamples: 20)
        let result = gate.evaluate(baseline: Array(repeating: 1, count: 20), candidate: [1, 1])
        XCTAssertEqual(result.status, .insufficientSamples)
        XCTAssertFalse(result.passed)
        XCTAssertFalse(gate.evaluate(baseline: [], candidate: []).passed)
    }

    func testAllowanceSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(RegressionGate().allowed(baseline: .max, tolerancePermille: 1_000), .max)
    }
}
