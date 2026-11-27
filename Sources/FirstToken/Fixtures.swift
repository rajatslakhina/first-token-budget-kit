import Foundation

/// Synthesised Anthropic-Messages-shaped streams. They are built in code rather than recorded,
/// so every byte is reviewable and nothing in the repository came from a real account. Each
/// one isolates a framing case that changes when the first token can be parsed.
extension StreamFixture {
    /// The answer every fixture streams: a short Markdown reply with a list and a code block.
    public static let sampleAnswer = """
    Time-to-first-token is the latency people **feel**: the gap between tapping send and \
    seeing the first word.

    Split it into stages so each one has an owner:

    - request build (the feature team)
    - connection (the networking platform)
    - server queue (the API)
    - first token and render (the client)

    ```swift
    let budget = TTFTBudget.interactiveChat
    let report = budget.evaluate(breakdown)
    ```

    Then gate p50 *and* p95 in CI, because they regress for different reasons.
    """

    /// The four fixtures the regression gate replays.
    public static let standard: [StreamFixture] = [steady, splitFirstDelta, crlfWithKeepAlives, whitespaceLead]

    /// Clean LF framing, one event per read, first text 180 ms after the headers.
    public static let steady = make(name: "steady", firstText: Nanos.milliseconds(180))

    /// The first `content_block_delta` arrives split across two reads 40 ms apart. A parser
    /// that only handles whole events per chunk loses it; this one parses it on the second
    /// read, which is when the first token really becomes available.
    public static let splitFirstDelta = make(
        name: "split-first-delta", firstText: Nanos.milliseconds(150), splitFirstDeltaBy: Nanos.milliseconds(40)
    )

    /// CRLF line endings, SSE comment keep-alives and `ping` events before the first text.
    public static let crlfWithKeepAlives = make(
        name: "crlf-keepalives", firstText: Nanos.milliseconds(210), lineEnding: "\r\n", keepAlives: true
    )

    /// The first delta is a bare newline, so the first *visible* character arrives one delta
    /// later. That wait is server pacing: it belongs to the `firstToken` stage, not `render`.
    public static let whitespaceLead = make(
        name: "whitespace-lead", firstText: Nanos.milliseconds(160), leadingWhitespace: true
    )

    /// Deltas 4 ms apart, faster than a 60 Hz frame, so coalescing is visible: several
    /// deltas land in one commit. Not part of `standard` (the gate baselines don't include it).
    public static let burst = make(name: "burst", firstText: Nanos.milliseconds(170), interDelta: Nanos.milliseconds(4))

    /// Splits `text` into deltas of a repeating 3-11 character pattern, never inside a
    /// Character, so each delta is a valid string the way the API sends them.
    static func deltas(of text: String) -> [String] {
        let pattern = [4, 7, 3, 9, 5, 11, 6, 8]
        var out: [String] = []
        var current = ""
        var target = pattern[0]
        var step = 0
        for character in text {
            current.append(character)
            if current.count >= target {
                out.append(current)
                current = ""
                step += 1
                target = pattern[step % pattern.count]
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func event(_ name: String, _ json: String, lineEnding: String) -> [UInt8] {
        Array("event: \(name)\(lineEnding)data: \(json)\(lineEnding)\(lineEnding)".utf8)
    }

    static func jsonString(_ text: String) -> String {
        // Encoding a String cannot fail; the fallback keeps this non-throwing without a `!`.
        (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    static func make(
        name: String,
        firstText: UInt64,
        interDelta: UInt64 = Nanos.milliseconds(22),
        lineEnding: String = "\n",
        keepAlives: Bool = false,
        splitFirstDeltaBy: UInt64? = nil,
        leadingWhitespace: Bool = false
    ) -> StreamFixture {
        var chunks: [FixtureChunk] = []
        func add(_ offset: UInt64, _ bytes: [UInt8]) { chunks.append(FixtureChunk(offset: offset, bytes: bytes)) }

        add(0, event("message_start", #"{"type":"message_start","message":{"id":"msg_fixture","type":"message","role":"assistant","content":[]}}"#, lineEnding: lineEnding))
        add(0, event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#, lineEnding: lineEnding))
        if keepAlives {
            add(firstText / 3, Array(": keep-alive\(lineEnding)\(lineEnding)".utf8))
            add(firstText / 2, event("ping", #"{"type":"ping"}"#, lineEnding: lineEnding))
        }

        var texts = deltas(of: sampleAnswer)
        if leadingWhitespace { texts.insert("\n", at: 0) }
        var offset = firstText
        for (index, text) in texts.enumerated() {
            let json = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"# + jsonString(text) + "}}"
            let bytes = event("content_block_delta", json, lineEnding: lineEnding)
            if index == 0, let gap = splitFirstDeltaBy {
                let cut = bytes.count / 2
                add(offset, Array(bytes[..<cut]))
                offset = Saturating.add(offset, gap)
                add(offset, Array(bytes[cut...]))
            } else {
                add(offset, bytes)
            }
            offset = Saturating.add(offset, interDelta)
        }
        add(offset, event("content_block_stop", #"{"type":"content_block_stop","index":0}"#, lineEnding: lineEnding))
        add(offset, event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":96}}"#, lineEnding: lineEnding))
        add(offset, event("message_stop", #"{"type":"message_stop"}"#, lineEnding: lineEnding))
        return StreamFixture(name: name, chunks: chunks)
    }
}
