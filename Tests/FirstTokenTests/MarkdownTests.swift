@testable import FirstToken
import Synchronization
import XCTest

/// Counts and records every block the renderer is asked to render.
final class CountingRenderer: MarkdownBlockRenderer {
    let sources = Mutex<[String]>([])
    func render(_ source: String) -> AttributedString {
        sources.withLock { $0.append(source) }
        return AttributedString(source)
    }
}

struct ForwardingRenderer: MarkdownBlockRenderer {
    let inner: CountingRenderer
    func render(_ source: String) -> AttributedString { inner.render(source) }
}

final class MarkdownTests: XCTestCase {
    func testBlocksCloseAtBlankLines() {
        var doc = IncrementalMarkdownDocument()
        doc.append("one\n\ntwo\n")
        XCTAssertEqual(doc.closed, ["one\n\n"])
        XCTAssertEqual(doc.tail, "two\n")
        doc.append("\nthree")
        XCTAssertEqual(doc.closed, ["one\n\n", "two\n\n"])
        XCTAssertEqual(doc.tail, "three")
    }

    func testABlankLineInsideAFencedCodeBlockDoesNotCloseIt() {
        var doc = IncrementalMarkdownDocument()
        doc.append("```swift\nlet a = 1\n\nlet b = 2\n```\n\nafter")
        XCTAssertEqual(doc.closed, ["```swift\nlet a = 1\n\nlet b = 2\n```\n\n"])
        XCTAssertEqual(doc.tail, "after")
    }

    func testTildeFencesNeedTheMatchingMarkerToClose() {
        var doc = IncrementalMarkdownDocument()
        doc.append("~~~\n```\n\nstill code\n~~~\n\nx")
        XCTAssertEqual(doc.closed.count, 1)
        XCTAssertTrue(doc.closed[0].hasSuffix("~~~\n\n"))
    }

    func testFourSpaceIndentedBackticksAreNotAFence() {
        var doc = IncrementalMarkdownDocument()
        doc.append("    ```\n\nnext")
        XCTAssertEqual(doc.closed, ["    ```\n\n"])
    }

    func testAnIncompleteLineIsNeverJudgedBlank() {
        var doc = IncrementalMarkdownDocument()
        doc.append("para\n")
        doc.append("   ")
        XCTAssertTrue(doc.closed.isEmpty)
        doc.append("\n")
        XCTAssertEqual(doc.closed, ["para\n   \n"])
    }

    func testCRLFBlankLinesCloseBlocks() {
        var doc = IncrementalMarkdownDocument()
        doc.append("one\r\n\r\ntwo")
        XCTAssertEqual(doc.closed, ["one\r\n\r\n"])
        XCTAssertEqual(doc.tail, "two")
    }

    /// Conservation over every chunking of the sample answer: closed + tail is exactly what
    /// was appended, and the final segmentation does not depend on how the text was chunked.
    func testSegmentationIsChunkingIndependentAndLossless() {
        let text = StreamFixture.sampleAnswer + "\n\n- \u{1F680} done\n"
        var whole = IncrementalMarkdownDocument()
        whole.append(text)
        var rng = SplitMix64(seed: 3)
        for _ in 0..<200 {
            var doc = IncrementalMarkdownDocument()
            var rest = Substring(text)
            while !rest.isEmpty {
                let n = Int(rng.next() % 9) + 1
                doc.append(String(rest.prefix(n)))
                rest = rest.dropFirst(n)
                XCTAssertEqual(doc.text, String(text[..<rest.startIndex]))
            }
            XCTAssertEqual(doc.closed, whole.closed)
            XCTAssertEqual(doc.tail, whole.tail)
        }
    }

    func testScanningIsIncrementalEachByteScannedOnce() {
        var doc = IncrementalMarkdownDocument()
        var total = 0
        for i in 0..<2_000 {
            let piece = i % 7 == 0 ? "\n\n" : "word \n"
            doc.append(piece)
            total += piece.utf8.count
        }
        XCTAssertEqual(doc.scannedBytes, total, "a rescanning implementation scans the tail again on every append")
    }

    func testAnUnterminatedLineIsSearchedOnceNotOnEveryAppend() {
        var doc = IncrementalMarkdownDocument()
        for _ in 0..<2_000 { doc.append("a") }
        XCTAssertEqual(doc.scannedBytes, 2_000, "re-searching the open line on each append is quadratic")
        doc.append("\n\nnext")
        XCTAssertEqual(doc.closed.count, 1)
        XCTAssertEqual(doc.scannedBytes, 2_006)
    }

    func testAFenceLineWithAnInfoStringDoesNotCloseAnOpenFence() {
        var doc = IncrementalMarkdownDocument()
        doc.append("```\ncode\n```python\n\nstill code\n```\n\nafter")
        XCTAssertEqual(doc.closed.count, 1)
        XCTAssertTrue(doc.closed[0].hasSuffix("still code\n```\n\n"))
        XCTAssertEqual(doc.tail, "after")
    }

    func testAShorterFenceDoesNotCloseALongerOne() {
        var doc = IncrementalMarkdownDocument()
        doc.append("````\n```\n\nstill code\n````\n\nafter")
        XCTAssertEqual(doc.closed.count, 1)
        XCTAssertEqual(doc.tail, "after")
    }

    func testFinishClosesTheTailAndKeepsTrailingWhitespace() {
        var doc = IncrementalMarkdownDocument()
        doc.append("a\n\nb")
        doc.finish()
        XCTAssertEqual(doc.closed, ["a\n\n", "b"])
        var ws = IncrementalMarkdownDocument()
        ws.append("a\n\n  ")
        ws.finish()
        XCTAssertEqual(ws.text, "a\n\n  ")
        XCTAssertEqual(ws.closed.count, 1)
    }

    func testEachClosedBlockIsRenderedExactlyOnce() {
        let counter = CountingRenderer()
        var md = StreamingMarkdown(renderer: ForwardingRenderer(inner: counter))
        for delta in StreamFixture.deltas(of: StreamFixture.sampleAnswer) { md.append(delta) }
        md.finish()
        let rendered = counter.sources.withLock { $0 }
        for block in md.document.closed.dropLast() {
            XCTAssertEqual(rendered.filter { $0 == block }.count, 1, "closed block re-rendered: \(block.prefix(20))")
        }
        XCTAssertEqual(md.renderCalls, rendered.count)
        XCTAssertEqual(md.blocks.map(\.id), Array(0..<md.document.closed.count))
        XCTAssertFalse(md.blocks.contains { $0.isOpen })
    }

    func testRenderedBytesGrowLinearlyNotQuadratically() {
        // 200 short paragraphs streamed in 4-byte deltas. Re-rendering the whole answer on
        // every delta would pass ~O(n^2 / 4) bytes to the renderer; incremental rendering
        // passes each closed block once plus the open tail per delta.
        let paragraph = "Short paragraph text.\n\n"
        let text = String(repeating: paragraph, count: 200)
        let counter = CountingRenderer()
        var md = StreamingMarkdown(renderer: ForwardingRenderer(inner: counter))
        var rest = Substring(text)
        var appends = 0
        while !rest.isEmpty {
            md.append(String(rest.prefix(4)))
            rest = rest.dropFirst(4)
            appends += 1
        }
        let fullRerender = (1...appends).reduce(0) { $0 + min($1 * 4, text.utf8.count) }
        XCTAssertLessThan(md.renderedBytes * 20, fullRerender)
        XCTAssertLessThan(md.renderedBytes, text.utf8.count * 8)
    }

    func testFoundationRendererInterpretsInlineMarkdownAndFallsBackOnPlainText() {
        let rendered = FoundationMarkdownRenderer().render("**bold** text\n\n")
        XCTAssertEqual(String(rendered.characters), "bold text")
        XCTAssertEqual(String(FoundationMarkdownRenderer().render("**unclosed").characters), "**unclosed")
    }
}
