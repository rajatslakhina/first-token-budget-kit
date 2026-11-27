/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Equatable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// An incremental, byte-level parser for the WHATWG `text/event-stream` format.
///
/// The network delivers bytes in chunks that have nothing to do with event boundaries: an
/// event, a line, even a single UTF-8 scalar can be split across two reads. A parser that
/// splits each chunk on `"\n\n"` works on every fixture recorded over a fast connection and
/// loses the first token on a slow one. This parser buffers bytes until a line terminator,
/// so decoding only ever sees complete lines.
///
/// Implemented from the spec: `LF`, `CR` and `CRLF` all terminate a line (including a `CRLF`
/// split across two chunks); a leading UTF-8 BOM is dropped; a line starting with `:` is a
/// comment; one leading space after the field colon is stripped; multiple `data:` lines are
/// joined with `"\n"`; an event with no data is not dispatched; an unterminated event at the
/// end of the stream is discarded. `retry:` is parsed and ignored, because this client does not
/// auto-reconnect a generation.
///
/// Memory is bounded: a line, or an event's accumulated data, longer than `maxEventBytes`
/// poisons that event. The rest of it is skipped and the event is dropped whole rather than
/// delivered truncated (truncated JSON would decode as garbage, which is worse than a gap).
public struct SSEParser: Sendable {
    public let maxEventBytes: Int

    private var line: [UInt8] = []
    private var discardingLine = false
    private var previousWasCR = false
    private var atStreamStart = true
    private var eventType = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var eventPoisoned = false
    private var lastEventID: String?

    /// Events dropped because a line or the event's data exceeded `maxEventBytes`.
    public private(set) var oversizeEventsDropped: UInt64 = 0

    public init(maxEventBytes: Int = 1 << 20) {
        self.maxEventBytes = max(1, maxEventBytes)
    }

    /// Feed the next chunk. Returns every event that the chunk completed, in order.
    public mutating func feed<Bytes: Sequence>(_ bytes: Bytes) -> [SSEEvent] where Bytes.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if previousWasCR {
                previousWasCR = false
                if byte == 0x0A { continue } // second half of a CRLF
            }
            switch byte {
            case 0x0D:
                previousWasCR = true
                endLine(into: &events)
            case 0x0A:
                endLine(into: &events)
            default:
                if discardingLine { continue }
                if line.count >= maxEventBytes {
                    discardingLine = true
                    line.removeAll(keepingCapacity: false)
                    continue
                }
                line.append(byte)
            }
        }
        return events
    }

    /// Signal the end of the stream. Returns `true` if bytes of an unfinished line or event
    /// were pending: the stream was cut mid-event, and the caller should treat it as truncated.
    public mutating func finish() -> Bool {
        let truncated = !line.isEmpty || discardingLine || !dataLines.isEmpty || eventPoisoned
        line.removeAll()
        discardingLine = false
        resetEvent()
        return truncated
    }

    private mutating func endLine(into events: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        if discardingLine {
            discardingLine = false
            eventPoisoned = true
            return
        }
        var bytes = line[...]
        if atStreamStart {
            atStreamStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        }
        if bytes.isEmpty {
            dispatch(into: &events)
            return
        }
        if bytes.first == 0x3A { return } // ":" comment line

        let field: ArraySlice<UInt8>
        var value: ArraySlice<UInt8>
        if let colon = bytes.firstIndex(of: 0x3A) {
            field = bytes[bytes.startIndex..<colon]
            value = bytes[bytes.index(after: colon)...]
            if value.first == 0x20 { value = value.dropFirst() }
        } else {
            field = bytes
            value = ArraySlice()
        }
        let text = String(decoding: value, as: UTF8.self)
        switch String(decoding: field, as: UTF8.self) {
        case "event":
            eventType = text
        case "data":
            // Charge the "\n" join separator too, so a flood of empty `data:` lines is bounded.
            let cost = value.count + (dataLines.isEmpty ? 0 : 1)
            eventBytes = eventBytes > maxEventBytes - min(cost, maxEventBytes)
                ? maxEventBytes + 1
                : eventBytes + cost
            if eventBytes > maxEventBytes {
                eventPoisoned = true
                dataLines.removeAll()
            } else if !eventPoisoned {
                dataLines.append(text)
            }
        case "id":
            if !text.contains("\u{0}") { lastEventID = text }
        default:
            break // "retry" and unknown fields are ignored, as the spec requires
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer { resetEvent() }
        if eventPoisoned {
            oversizeEventsDropped = Saturating.add(oversizeEventsDropped, 1)
            return
        }
        guard !dataLines.isEmpty else { return }
        events.append(SSEEvent(
            event: eventType.isEmpty ? "message" : eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID
        ))
    }

    private mutating func resetEvent() {
        eventType = ""
        dataLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        eventPoisoned = false
    }
}
