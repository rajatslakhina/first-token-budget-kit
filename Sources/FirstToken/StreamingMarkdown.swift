import Foundation

/// Splits a growing Markdown answer into closed blocks and one open tail block.
///
/// A block closes at a blank line outside a fenced code block. Once closed, a block's source
/// never changes, so its rendered form can be cached forever; only the open tail is
/// re-rendered as tokens arrive. Without this split, every delta re-parses the whole answer
/// and a long reply gets slower to update the longer it gets.
///
/// Segmentation is incremental and linear: the newline search resumes where the previous
/// append stopped (even in the middle of an unterminated line), so each appended byte is
/// searched once, and each completed line is classified once (tested via `scannedBytes`).
///
/// Fences follow CommonMark's rule: a fence opened with N backticks (or tildes) closes only on
/// a line of at least N of the same marker followed by nothing but whitespace, so a
/// "```python" line inside a ``` block does not close it.
///
/// Conservation (tested): `closed.joined() + tail` is exactly the text appended so far.
/// Separators stay inside the block that precedes them.
public struct IncrementalMarkdownDocument: Sendable, Equatable {
    public private(set) var closed: [String] = []
    public private(set) var tail: String = ""

    // Scanner state for the tail. `scanOffset` is the UTF-8 offset of the first byte of the
    // first unscanned line.
    private var scanOffset = 0
    // UTF-8 offset of the first byte the newline search has not looked at yet.
    private var searchOffset = 0
    private struct Fence: Sendable, Equatable {
        let marker: UInt8
        let length: Int
    }

    private var openFence: Fence?
    private var blockHasContent = false

    /// Bytes the newline search has examined in total. Internal: used by tests to prove the
    /// scan is linear.
    private(set) var scannedBytes = 0

    public init() {}

    public var text: String { closed.joined() + tail }

    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        tail += text
        scan()
    }

    /// Close the tail as a final block (if it has any content).
    public mutating func finish() {
        if tail.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) {
            closed.append(tail)
        } else if !tail.isEmpty, let last = closed.popLast() {
            closed.append(last + tail) // keep trailing whitespace: conservation
        } else if !tail.isEmpty {
            closed.append(tail)
        }
        tail = ""
        scanOffset = 0
        searchOffset = 0
        openFence = nil
        blockHasContent = false
    }

    private mutating func scan() {
        let utf8 = tail.utf8
        func index(_ offset: Int) -> String.Index {
            utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex) ?? utf8.endIndex
        }
        var lineStart = index(scanOffset)
        var searchFrom = index(max(searchOffset, scanOffset))
        var blockStart = utf8.startIndex
        var cut = false

        func countSearched(_ from: String.Index, _ to: String.Index) {
            let n = utf8.distance(from: from, to: to)
            scannedBytes = scannedBytes > Int.max - n ? Int.max : scannedBytes + n
        }

        while let newline = utf8[searchFrom...].firstIndex(of: 0x0A) {
            let afterLine = utf8.index(after: newline)
            countSearched(searchFrom, afterLine)
            let lineBytes = utf8[lineStart..<newline]

            if let fence = openFence {
                if Self.closesFence(lineBytes, marker: fence.marker, length: fence.length) {
                    openFence = nil
                }
                blockHasContent = true
            } else if let opening = Self.fenceOpening(lineBytes) {
                openFence = opening
                blockHasContent = true
            } else if lineBytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                if blockHasContent {
                    // Cuts are made directly after an ASCII newline, which is always a
                    // scalar and grapheme boundary, so this slice never splits a character.
                    closed.append(String(tail[blockStart..<afterLine]))
                    blockStart = afterLine
                    blockHasContent = false
                    cut = true
                }
            } else {
                blockHasContent = true
            }
            lineStart = afterLine
            searchFrom = afterLine
        }
        countSearched(searchFrom, utf8.endIndex)

        scanOffset = utf8.distance(from: blockStart, to: lineStart)
        searchOffset = utf8.distance(from: blockStart, to: utf8.endIndex)
        if cut {
            tail = String(tail[blockStart...])
        }
    }

    /// An opening fence: up to three spaces, then at least three backticks or tildes.
    private static func fenceOpening<Line: Collection>(_ line: Line) -> Fence? where Line.Element == UInt8 {
        let indent = line.prefix(while: { $0 == 0x20 }).count
        guard indent <= 3, let first = line.dropFirst(indent).first, first == 0x60 || first == 0x7E else { return nil }
        let run = line.dropFirst(indent).prefix(while: { $0 == first }).count
        return run >= 3 ? Fence(marker: first, length: run) : nil
    }

    /// A closing fence: up to three spaces, at least `length` of `marker`, then only whitespace.
    private static func closesFence<Line: Collection>(_ line: Line, marker: UInt8, length: Int) -> Bool where Line.Element == UInt8 {
        let indent = line.prefix(while: { $0 == 0x20 }).count
        guard indent <= 3 else { return false }
        let rest = line.dropFirst(indent)
        let run = rest.prefix(while: { $0 == marker }).count
        guard run >= length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }
}

/// Renders one Markdown block. Injected so tests can count calls.
public protocol MarkdownBlockRenderer: Sendable {
    func render(_ source: String) -> AttributedString
}

/// Foundation's Markdown parser, inline syntax only, whitespace preserved. A parse failure
/// falls back to the plain text rather than dropping the block.
public struct FoundationMarkdownRenderer: MarkdownBlockRenderer {
    public init() {}

    public func render(_ source: String) -> AttributedString {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: trimmed, options: options)) ?? AttributedString(trimmed)
    }
}

/// A rendered block with an identity that is stable for the life of the answer, so SwiftUI
/// can diff by id and leave closed blocks untouched.
public struct RenderedBlock: Sendable, Identifiable, Equatable {
    public let id: Int
    public let content: AttributedString
    public let isOpen: Bool
}

/// An incrementally rendered Markdown answer: every closed block is rendered exactly once,
/// the open tail once per update.
public struct StreamingMarkdown<Renderer: MarkdownBlockRenderer>: Sendable {
    public private(set) var document = IncrementalMarkdownDocument()
    private var renderedClosed: [AttributedString] = []
    private var renderedTail = AttributedString()
    private let renderer: Renderer

    /// Calls made to the renderer, and the source bytes passed to it, since creation.
    public private(set) var renderCalls = 0
    public private(set) var renderedBytes = 0

    public init(renderer: Renderer) {
        self.renderer = renderer
    }

    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        document.append(text)
        refresh()
    }

    public mutating func finish() {
        document.finish()
        refresh()
    }

    public var blocks: [RenderedBlock] {
        var out = renderedClosed.enumerated().map { RenderedBlock(id: $0.offset, content: $0.element, isOpen: false) }
        if !document.tail.isEmpty {
            out.append(RenderedBlock(id: renderedClosed.count, content: renderedTail, isOpen: true))
        }
        return out
    }

    private mutating func refresh() {
        let closed = document.closed
        if renderedClosed.count < closed.count {
            for index in renderedClosed.count..<closed.count {
                renderedClosed.append(render(closed[index]))
            }
        }
        renderedTail = document.tail.isEmpty ? AttributedString() : render(document.tail)
    }

    private mutating func render(_ source: String) -> AttributedString {
        renderCalls = renderCalls == Int.max ? Int.max : renderCalls + 1
        let count = source.utf8.count
        renderedBytes = renderedBytes > Int.max - count ? Int.max : renderedBytes + count
        return renderer.render(source)
    }
}

extension StreamingMarkdown where Renderer == FoundationMarkdownRenderer {
    public init() { self.init(renderer: FoundationMarkdownRenderer()) }
}
