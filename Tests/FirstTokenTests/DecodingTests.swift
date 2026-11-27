@testable import FirstToken
import Synchronization
import XCTest

final class DecodingTests: XCTestCase {
    private let decoder = AnthropicEventDecoder()

    private func decode(_ json: String, event: String = "x") -> StreamDelta {
        decoder.decode(SSEEvent(event: event, data: json))
    }

    func testDecodesTextDeltasAndLifecycleEvents() {
        XCTAssertEqual(decode(#"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Hi"}}"#), .text(index: 2, "Hi"))
        XCTAssertEqual(decode(#"{"type":"message_start","message":{}}"#), .messageStart)
        XCTAssertEqual(decode(#"{"type":"ping"}"#), .ping)
        XCTAssertEqual(decode(#"{"type":"content_block_stop","index":0}"#), .blockStop(index: 0))
        XCTAssertEqual(decode(#"{"type":"message_stop"}"#), .messageStop)
    }

    func testNonTextDeltasAreIgnoredNotRendered() {
        XCTAssertEqual(decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#),
                       .ignored(event: "content_block_delta/thinking_delta"))
        XCTAssertEqual(decode(#"{"type":"message_delta","delta":{}}"#), .ignored(event: "message_delta"))
        XCTAssertNil(decode(#"{"type":"ping"}"#).text)
    }

    func testInStreamErrorsSurfaceWithTypeAndMessage() {
        XCTAssertEqual(decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
                       .serverError(type: "overloaded_error", message: "Overloaded"))
    }

    func testMalformedDataIsReportedNotCrashed() {
        XCTAssertEqual(decode("{not json", event: "content_block_delta"), .malformed(event: "content_block_delta"))
        XCTAssertEqual(decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}"#, event: "e"),
                       .malformed(event: "e"), "missing index")
        XCTAssertEqual(decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta"}}"#, event: "e"),
                       .malformed(event: "e"), "text_delta without text")
    }

    func testPipelineDeliversEveryTextDeltaInOrder() async throws {
        var texts: [String] = []
        for try await delta in StreamPipeline.deltas(from: FixtureByteStream(.crlfWithKeepAlives, timeScalePermille: 0)) {
            if let text = delta.text { texts.append(text) }
        }
        XCTAssertEqual(texts.joined(), StreamFixture.sampleAnswer)
    }

    func testPipelineThrowsTruncatedWhenTheStreamEndsMidEvent() async {
        let fixture = StreamFixture(name: "cut", chunks: [FixtureChunk(offset: 0, bytes: Array("data: {\"type\":\"pi".utf8))])
        do {
            for try await _ in StreamPipeline.deltas(from: FixtureByteStream(fixture, timeScalePermille: 0)) {}
            XCTFail("expected truncation")
        } catch {
            XCTAssertEqual(error as? StreamPipelineError, .truncated)
        }
    }

    /// The parse step must not run on the caller's actor. The observer runs inside the
    /// parse loop itself (not in the source), once per dispatched event.
    @MainActor
    func testParsingRunsOffTheMainThreadEvenWhenConsumedFromMainActor() async throws {
        let onMain = Mutex<[Bool]>([])
        let observer: @Sendable () -> Void = { onMain.withLock { $0.append(pthread_main_np() != 0) } }
        var count = 0
        for try await _ in StreamPipeline.deltas(from: FixtureByteStream(.steady, timeScalePermille: 0), maxEventBytes: 1 << 20,
                                                 decoder: AnthropicEventDecoder(), parseObserver: observer) {
            count += 1
        }
        let observed = onMain.withLock { $0 }
        XCTAssertEqual(observed.count, count)
        XCTAssertGreaterThan(count, 0)
        XCTAssertFalse(observed.contains(true))

        onMain.withLock { $0.removeAll() }
        for try await _ in StreamPipeline.deltas(bytes: { Self.byteStream(StreamFixture.steady) }, maxEventBytes: 1 << 20,
                                                 decoder: AnthropicEventDecoder(), parseObserver: observer) {}
        XCTAssertFalse(onMain.withLock { $0 }.isEmpty)
        XCTAssertFalse(onMain.withLock { $0 }.contains(true))
    }

    static func byteStream(_ fixture: StreamFixture) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in fixture.chunks.flatMap(\.bytes) { continuation.yield(byte) }
            continuation.finish()
        }
    }

    func testByteSequencePipelineDeliversTheWholeAnswer() async throws {
        var texts: [String] = []
        for try await delta in StreamPipeline.deltas(bytes: { Self.byteStream(.crlfWithKeepAlives) }) {
            if let text = delta.text { texts.append(text) }
        }
        XCTAssertEqual(texts.joined(), StreamFixture.sampleAnswer)
    }

    func testByteSequencePipelineReportsTruncation() async {
        let cut = StreamFixture(name: "cut", chunks: [FixtureChunk(offset: 0, bytes: Array("data: {".utf8))])
        do {
            for try await _ in StreamPipeline.deltas(bytes: { Self.byteStream(cut) }) {}
            XCTFail("expected truncation")
        } catch {
            XCTAssertEqual(error as? StreamPipelineError, .truncated)
        }
    }

    func testCancellingTheConsumerStopsPullingFromTheSource() async throws {
        let pulls = Mutex(0)
        let source = RecordingChunks(chunks: Array(repeating: Array("data: {\"type\":\"ping\"}\n\n".utf8), count: 10_000),
                                     record: { _ in pulls.withLock { $0 += 1 } }, delay: 1_000_000)
        let consumer = Task {
            var seen = 0
            for try await _ in StreamPipeline.deltas(from: source) {
                seen += 1
                if seen == 3 { break }
            }
        }
        try await consumer.value
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterStop = pulls.withLock { $0 }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pulls.withLock { $0 }, afterStop, "source keeps being pulled after the consumer left")
        XCTAssertLessThan(afterStop, 10_000)
    }
}

/// An async chunk source that reports the thread each `next()` runs on.
struct RecordingChunks: AsyncSequence, Sendable {
    typealias Element = [UInt8]
    let chunks: [[UInt8]]
    let record: @Sendable (Bool) -> Void
    var delay: UInt64 = 0

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [[UInt8]]
        let record: @Sendable (Bool) -> Void
        let delay: UInt64
        var index = 0

        mutating func next() async throws -> [UInt8]? {
            record(pthread_main_np() != 0)
            guard chunks.indices.contains(index) else { return nil }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            defer { index += 1 }
            return chunks[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(chunks: chunks, record: record, delay: delay) }
}
