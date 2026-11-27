@testable import FirstToken
import XCTest

final class PrewarmTests: XCTestCase {
    private func ms(_ v: UInt64) -> UInt64 { Nanos.milliseconds(v) }

    func testFocusWarmsTheConnectionOnceWhileItStaysWarm() {
        var p = PrewarmPolicy()
        XCTAssertEqual(p.handle(.composerFocused, at: ms(1)), [.warmConnection])
        XCTAssertEqual(p.handle(.composerFocused, at: ms(2)), [])
        XCTAssertTrue(p.isConnectionWarm(at: ms(2)))
        XCTAssertFalse(p.isConnectionWarm(at: ms(1) + p.configuration.connectionIdleTimeout))
        XCTAssertEqual(p.handle(.composerFocused, at: ms(40_000)), [.warmConnection], "re-warms after the idle timeout")
        XCTAssertEqual(p.stats.warmups, 2)
    }

    func testWarmupsAreCappedByTheBudget() {
        var p = PrewarmPolicy(configuration: .init(connectionIdleTimeout: 1, maxWarmups: 2, warmupWindow: ms(60_000)))
        XCTAssertEqual(p.handle(.composerFocused, at: ms(1)), [.warmConnection])
        XCTAssertEqual(p.handle(.composerFocused, at: ms(2)), [.warmConnection])
        XCTAssertEqual(p.handle(.composerFocused, at: ms(3)), [], "third warm-up in the window is refused")
        XCTAssertEqual(p.stats.deniedByBudget, 1)
        XCTAssertEqual(p.handle(.composerFocused, at: ms(31_000)), [.warmConnection], "one token refilled after window/2")
    }

    func testTypingPauseAssemblesAndAnEditDiscards() {
        var p = PrewarmPolicy()
        let actions = p.handle(.typingPaused(digest: 1), at: ms(1))
        XCTAssertEqual(actions, [.warmConnection, .assemblePrompt(digest: 1)])
        XCTAssertEqual(p.handle(.typingPaused(digest: 1), at: ms(2)), [], "same draft is not re-assembled")
        XCTAssertEqual(p.handle(.draftEdited(digest: 2), at: ms(3)), [.discardSpeculativePrompt(digest: 1)])
        XCTAssertNil(p.speculatedDigest)
        XCTAssertEqual(p.stats.discarded, 1)
    }

    func testAnEditBackToTheSpeculatedDraftKeepsIt() {
        var p = PrewarmPolicy()
        _ = p.handle(.typingPaused(digest: 5), at: ms(1))
        XCTAssertEqual(p.handle(.draftEdited(digest: 5), at: ms(2)), [])
        XCTAssertEqual(p.speculatedDigest, 5)
    }

    func testSendReportsHitMissAndNoSpeculation() {
        var p = PrewarmPolicy()
        XCTAssertEqual(p.send(digest: 9, at: ms(1)).prompt, .notSpeculated)
        _ = p.handle(.typingPaused(digest: 1), at: ms(2))
        let hit = p.send(digest: 1, at: ms(3))
        XCTAssertEqual(hit.prompt, .hit)
        XCTAssertTrue(hit.connectionWarm)
        _ = p.handle(.typingPaused(digest: 2), at: ms(4))
        let miss = p.send(digest: 3, at: ms(5))
        XCTAssertEqual(miss.prompt, .miss)
        XCTAssertEqual(miss.actions, [.discardSpeculativePrompt(digest: 2)])
        XCTAssertEqual(p.stats.hitRatePermille, 500)
    }

    func testDismissDiscardsSpeculationAndAssemblyBudgetIsEnforced() {
        var p = PrewarmPolicy(configuration: .init(maxAssemblies: 1))
        _ = p.handle(.typingPaused(digest: 1), at: ms(1))
        XCTAssertEqual(p.handle(.composerDismissed, at: ms(2)), [.discardSpeculativePrompt(digest: 1)])
        XCTAssertEqual(p.handle(.typingPaused(digest: 2), at: ms(3)), [], "assembly budget spent")
        XCTAssertEqual(p.stats.deniedByBudget, 1)
    }

    func testZeroBudgetsNeverActAndHitRateIsNilWithoutAttempts() {
        var p = PrewarmPolicy(configuration: .init(maxWarmups: 0, maxAssemblies: 0))
        XCTAssertEqual(p.handle(.typingPaused(digest: 1), at: 0), [])
        XCTAssertNil(p.stats.hitRatePermille)
    }

    func testTokenBucketRefillsAndToleratesAClockGoingBackwards() {
        var b = TokenBucket(capacity: 2, refillInterval: 10)
        XCTAssertTrue(b.take(at: 100))
        XCTAssertTrue(b.take(at: 100))
        XCTAssertFalse(b.take(at: 105))
        XCTAssertFalse(b.take(at: 50), "backwards clock refills nothing")
        XCTAssertTrue(b.take(at: 115))
        XCTAssertFalse(b.take(at: 115))
        XCTAssertTrue(b.take(at: .max))
        XCTAssertLessThanOrEqual(b.tokens, b.capacity)
    }

    func testDigestMatchesPublishedFNV1aVectorsAndIsStable() {
        XCTAssertEqual(PromptDigest.fnv1a(""), 0xCBF2_9CE4_8422_2325)
        XCTAssertEqual(PromptDigest.fnv1a("a"), 0xAF63_DC4C_8601_EC8C)
        XCTAssertEqual(PromptDigest.fnv1a("foobar"), 0x8594_4171_F739_67E8)
    }
}
