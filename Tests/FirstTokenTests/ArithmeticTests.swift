@testable import FirstToken
import XCTest

final class ArithmeticTests: XCTestCase {
    func testSaturatingAddAndMulClampAtMax() {
        XCTAssertEqual(Saturating.add(.max, 1), .max)
        XCTAssertEqual(Saturating.add(2, 3), 5)
        XCTAssertEqual(Saturating.mul(.max, 2), .max)
        XCTAssertEqual(Saturating.mul(6, 7), 42)
    }

    func testSaturatingSubFloorsAtZeroInsteadOfTrapping() {
        XCTAssertEqual(Saturating.sub(3, 5), 0)
        XCTAssertEqual(Saturating.sub(5, 3), 2)
    }

    func testScaleUsesFullWidthAndNeverTraps() {
        // .max * 1000 / 1000 overflows a naive (a * n) / d but not a full-width one.
        XCTAssertEqual(Saturating.scale(.max, by: 1_000, over: 1_000), .max)
        XCTAssertEqual(Saturating.scale(1_000_000, by: 1_250, over: 1_000), 1_250_000)
        XCTAssertEqual(Saturating.scale(.max, by: 2, over: 1), .max, "quotient overflow saturates")
        XCTAssertEqual(Saturating.scale(5, by: 1, over: 0), .max, "zero denominator saturates")
    }

    func testNanosConversionsSaturate() {
        XCTAssertEqual(Nanos.milliseconds(3), 3_000_000)
        XCTAssertEqual(Nanos.milliseconds(.max), .max)
    }

    func testManualClockAdvancesAndSaturates() {
        let clock = ManualClock(start: .max - 1)
        clock.advance(by: 10)
        XCTAssertEqual(clock.now(), .max)
    }

    func testSplitMixIsReproducibleForTheSameSeedAndDiffersAcrossSeeds() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        var c = SplitMix64(seed: 43)
        let first = (0..<5).map { _ in a.next() }
        XCTAssertEqual(first, (0..<5).map { _ in b.next() })
        XCTAssertNotEqual(first, (0..<5).map { _ in c.next() })
    }
}
