@testable import FirstToken
import XCTest

final class SSEParserTests: XCTestCase {
    private func parseWhole(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        return parser.feed(Array(text.utf8))
    }

    private func parseByteByByte(_ bytes: [UInt8]) -> [SSEEvent] {
        var parser = SSEParser()
        return bytes.flatMap { parser.feed([$0]) }
    }

    func testParsesNamedEventsAndDefaultsTheTypeToMessage() {
        let events = parseWhole("event: ping\ndata: {}\n\ndata: plain\n\n")
        XCTAssertEqual(events, [SSEEvent(event: "ping", data: "{}"), SSEEvent(event: "message", data: "plain")])
    }

    func testJoinsMultipleDataLinesWithNewline() {
        XCTAssertEqual(parseWhole("data: a\ndata: b\n\n").first?.data, "a\nb")
    }

    func testIgnoresCommentsAndDoesNotDispatchAnEventWithoutData() {
        XCTAssertEqual(parseWhole(": keep-alive\n\nevent: x\n\n"), [])
    }

    func testStripsOnlyOneLeadingSpaceAndAcceptsAFieldWithoutColon() {
        XCTAssertEqual(parseWhole("data:  two\n\n").first?.data, " two")
        XCTAssertEqual(parseWhole("data\n\n").first?.data, "")
    }

    func testAcceptsLFCRAndCRLFTerminators() {
        let expected = [SSEEvent(event: "e", data: "1")]
        XCTAssertEqual(parseWhole("event: e\ndata: 1\n\n"), expected)
        XCTAssertEqual(parseWhole("event: e\rdata: 1\r\r"), expected)
        XCTAssertEqual(parseWhole("event: e\r\ndata: 1\r\n\r\n"), expected)
    }

    func testCRLFSplitAcrossTwoChunksIsOneTerminatorNotTwo() {
        var parser = SSEParser()
        var events = parser.feed(Array("data: a\r".utf8))
        events += parser.feed(Array("\ndata: b\r\n\r\n".utf8))
        XCTAssertEqual(events.map(\.data), ["a\nb"], "a CR then LF in the next read must not end the event early")
    }

    func testEveryChunkBoundaryGivesTheSameEventsAsOneRead() {
        for fixture in StreamFixture.standard {
            let all = fixture.chunks.flatMap(\.bytes)
            var whole = SSEParser()
            XCTAssertEqual(parseByteByByte(all), whole.feed(all), fixture.name)
        }
    }

    func testAMultibyteScalarSplitAcrossReadsDecodesIntact() {
        let bytes = Array("data: caf\u{E9} \u{1F680}\n\n".utf8)
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for chunk in stride(from: 0, to: bytes.count, by: 3) {
            events += parser.feed(bytes[chunk..<min(chunk + 3, bytes.count)])
        }
        XCTAssertEqual(events.first?.data, "caf\u{E9} \u{1F680}")
    }

    func testDropsALeadingBOMOnlyAtStreamStart() {
        XCTAssertEqual(parseByteByByte([0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8)).first?.data, "x")
    }

    func testTracksTheLastEventIDAndRejectsNUL() {
        let events = parseWhole("id: 7\ndata: a\n\nid: bad\u{0}\ndata: b\n\n")
        XCTAssertEqual(events.map(\.id), ["7", "7"])
    }

    func testOversizeLinePoisonsOnlyItsOwnEvent() {
        var parser = SSEParser(maxEventBytes: 16)
        let events = parser.feed(Array("data: \(String(repeating: "x", count: 40))\n\ndata: ok\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["ok"])
        XCTAssertEqual(parser.oversizeEventsDropped, 1)
    }

    func testManyDataLinesOverTheEventLimitAreDroppedWhole() {
        var parser = SSEParser(maxEventBytes: 10)
        let events = parser.feed(Array("data: 12345\ndata: 67890\ndata: x\n\ndata: ok\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["ok"], "truncated data is never delivered")
        XCTAssertEqual(parser.oversizeEventsDropped, 1)
    }

    func testFinishReportsAStreamCutMidEvent() {
        var cut = SSEParser()
        _ = cut.feed(Array("data: half".utf8))
        XCTAssertTrue(cut.finish())
        var clean = SSEParser()
        _ = clean.feed(Array("data: whole\n\n".utf8))
        XCTAssertFalse(clean.finish())
    }

    /// Proof that the boundary test discriminates: the common shortcut (split each read on
    /// a blank line and parse what is inside) loses the delta that arrives split.
    func testTheNaivePerChunkParserLosesTheSplitFirstDelta() {
        func naive(_ chunks: [[UInt8]]) -> [String] {
            chunks.flatMap { chunk in
                String(decoding: chunk, as: UTF8.self).components(separatedBy: "\n\n").compactMap { block in
                    block.split(separator: "\n").first { $0.hasPrefix("data: ") }.map { String($0.dropFirst(6)) }
                }
            }
        }
        let fixture = StreamFixture.splitFirstDelta
        let decoder = AnthropicEventDecoder()
        let naiveTexts = naive(fixture.chunks.map(\.bytes)).compactMap {
            decoder.decode(SSEEvent(event: "content_block_delta", data: $0)).text
        }
        var parser = SSEParser()
        let realTexts = fixture.chunks.flatMap { parser.feed($0.bytes) }.compactMap { decoder.decode($0).text }
        XCTAssertEqual(realTexts.joined(), StreamFixture.sampleAnswer)
        XCTAssertNotEqual(naiveTexts.joined(), StreamFixture.sampleAnswer)
        XCTAssertNotEqual(naiveTexts.first, realTexts.first)
    }
}
