import Foundation

/// Splits a growing Markdown answer into closed blocks and one open tail block.
///
/// A block closes at a blank line outside a fenced code block. Once closed, a block's source
/// never changes, so its rendered form can be cached forever; only the open tail is
/// re-rendered as tokens arrive. Without this split, every delta re-parses the whole answer
/// and a long reply gets slower to update the longer it gets.
///
/// Segmentation is incremental: the scanner resumes at the first line it has not yet
/// classified, so each appended byte is scanned once (tested via `scannedBytes`).
///
/// Conservation (tested): `closed.joined() + tail` is exactly the text appended so far.
/// Separators stay inside the block that precedes them.
public struct IncrementalMarkdownDocument: Sendable, Equatable {
    public private(set) var closed: [String] = []
    public private(set) var tail: String = ""

    // Scanner state for the tail. `scanOffset` is the UTF-8 offset of the first byte of the
    // first unscanned line.
    private var scanOffset = 0
    private var fenceByte: UInt8?
    private var blockHasContent = false

    /// Bytes the scanner has examined in total. Internal: used by tests to prove the scan is
    /// incremental.
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
        fenceByte = nil
        blockHasContent = false
    }

    private mutating func scan() {
        let utf8 = tail.utf8
        var lineStart = utf8.index(utf8.startIndex, offsetBy: scanOffset, limitedBy: utf8.endIndex) ?? utf8.endIndex
        var blockStart = utf8.startIndex
        var cut = false

        while let newline = utf8[lineStart...].firstIndex(of: 0x0A) {
            let lineBytes = utf8[lineStart..<newline]
            let afterLine = utf8.index(after: newline)
            let length = utf8.distance(from: lineStart, to: afterLine)
            scannedBytes = scannedBytes > Int.max - length ? Int.max : scannedBytes + length

            if let marker = Self.fenceMarker(lineBytes) {
                if fenceByte == nil {
                    fenceByte = marker
                } else if fenceByte == marker {
                    fenceByte = nil
                }
                blockHasContent = true
            } else if lineBytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                if fenceByte == nil, blockHasContent {
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
        }

        scanOffset = utf8.distance(from: blockStart, to: lineStart)
        if cut {
            tail = String(tail[blockStart...])
        }
    }

    /// The fence byte (` or ~) if the line opens or closes a fenced code block: up to three
    /// spaces of indentation, then at least three of the same marker.
    private static func fenceMarker<Line: Collection>(_ line: Line) -> UInt8? where Line.Element == UInt8 {
        let indent = line.prefix(while: { $0 == 0x20 }).count
        guard indent <= 3 else { return nil }
        let head = Array(line.dropFirst(indent).prefix(3))
        guard head.count == 3, let first = head.first, first == 0x60 || first == 0x7E,
              head.allSatisfy({ $0 == first }) else { return nil }
        return first
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
