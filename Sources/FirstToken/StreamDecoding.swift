import Foundation

/// The subset of the Anthropic Messages streaming protocol that matters for first-token
/// latency, decoded from one `SSEEvent`.
public enum StreamDelta: Sendable, Equatable {
    case messageStart
    /// A `text_delta` for the content block at `index`.
    case text(index: Int, String)
    case blockStop(index: Int)
    case messageStop
    case ping
    /// An `error` event delivered inside a 200 stream (for example `overloaded_error`).
    case serverError(type: String, message: String)
    /// A well-formed event this pipeline does not render (`content_block_start`,
    /// `message_delta`, `thinking_delta`, `input_json_delta`, ...).
    case ignored(event: String)
    /// The event's data was not the JSON its name promised.
    case malformed(event: String)

    /// The text this delta contributes to the rendered answer, if any.
    public var text: String? {
        if case let .text(_, value) = self { return value }
        return nil
    }
}

/// Decodes `SSEEvent`s from the Anthropic Messages API stream into `StreamDelta`s.
public struct AnthropicEventDecoder: Sendable {
    private struct Envelope: Decodable {
        struct Delta: Decodable {
            // Optional: `message_delta`'s delta carries `stop_reason`, not a `type`.
            let type: String?
            let text: String?
        }

        struct ErrorBody: Decodable {
            let type: String
            let message: String
        }

        let type: String
        let index: Int?
        let delta: Delta?
        let error: ErrorBody?
    }

    /// One decoder for the life of the stream, not one per event on the hot path.
    private let json = JSONDecoder()

    public init() {}

    public func decode(_ event: SSEEvent) -> StreamDelta {
        guard let envelope = try? json.decode(Envelope.self, from: Data(event.data.utf8)) else {
            return .malformed(event: event.event)
        }
        switch envelope.type {
        case "message_start":
            return .messageStart
        case "ping":
            return .ping
        case "message_stop":
            return .messageStop
        case "content_block_stop":
            guard let index = envelope.index else { return .malformed(event: event.event) }
            return .blockStop(index: index)
        case "content_block_delta":
            guard let index = envelope.index, let delta = envelope.delta, let deltaType = delta.type else {
                return .malformed(event: event.event)
            }
            guard deltaType == "text_delta" else { return .ignored(event: "content_block_delta/\(deltaType)") }
            guard let text = delta.text else { return .malformed(event: event.event) }
            return .text(index: index, text)
        case "error":
            guard let body = envelope.error else { return .malformed(event: event.event) }
            return .serverError(type: body.type, message: body.message)
        default:
            return .ignored(event: envelope.type)
        }
    }
}

public enum StreamPipelineError: Error, Sendable, Equatable {
    /// The byte stream ended in the middle of an event.
    case truncated
}

/// Turns a byte stream into a stream of decoded deltas.
public enum StreamPipeline {
    /// Deltas from any `AsyncSequence` of byte chunks (a fixture, a socket reader, a test).
    ///
    /// Parsing and JSON decoding run on a detached task, never on the caller's actor, so a
    /// burst of deltas cannot hitch the main thread. Cancelling the consumer (or dropping the
    /// stream) cancels the parsing task, which stops pulling from the source.
    ///
    /// The returned stream buffers without bound. That is deliberate: dropping a text delta is
    /// data loss, and the intended consumer (a coalescer that appends to a string) drains far
    /// faster than any network delivers. A consumer that blocks for seconds should not be
    /// attached to this stream.
    public static func deltas<Chunks: AsyncSequence & Sendable>(
        from chunks: Chunks,
        maxEventBytes: Int = 1 << 20,
        decoder: AnthropicEventDecoder = AnthropicEventDecoder()
    ) -> AsyncThrowingStream<StreamDelta, any Error> where Chunks.Element == [UInt8] {
        deltas(from: chunks, maxEventBytes: maxEventBytes, decoder: decoder, parseObserver: nil)
    }

    /// Deltas from a byte-at-a-time sequence such as `URLSession.AsyncBytes`.
    ///
    /// The sequence is created by `makeBytes` inside the parsing task, so the request starts
    /// off the caller's actor and the closure is the natural place to stamp `headersReceived`.
    /// (`URLSession.AsyncBytes` is `Sendable`, as the constraint requires.)
    ///
    /// ```swift
    /// StreamPipeline.deltas(bytes: {
    ///     let (bytes, _) = try await session.bytes(for: request)
    ///     await instrument.mark(.headersReceived)
    ///     return bytes
    /// })
    /// ```
    ///
    /// Bytes are fed to the parser as they arrive, so an event is decoded the moment its
    /// terminating blank line is read; nothing waits for a buffer to fill.
    public static func deltas<Bytes: AsyncSequence & Sendable>(
        bytes makeBytes: @escaping @Sendable () async throws -> Bytes,
        maxEventBytes: Int = 1 << 20,
        decoder: AnthropicEventDecoder = AnthropicEventDecoder()
    ) -> AsyncThrowingStream<StreamDelta, any Error> where Bytes.Element == UInt8 {
        deltas(bytes: makeBytes, maxEventBytes: maxEventBytes, decoder: decoder, parseObserver: nil)
    }

    /// Test seam: `parseObserver` runs inside the parse step, once per dispatched event.
    static func deltas<Chunks: AsyncSequence & Sendable>(
        from chunks: Chunks,
        maxEventBytes: Int,
        decoder: AnthropicEventDecoder,
        parseObserver: (@Sendable () -> Void)?
    ) -> AsyncThrowingStream<StreamDelta, any Error> where Chunks.Element == [UInt8] {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var parser = SSEParser(maxEventBytes: maxEventBytes)
                do {
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        for event in parser.feed(chunk) {
                            parseObserver?()
                            continuation.yield(decoder.decode(event))
                        }
                    }
                    if parser.finish() {
                        continuation.finish(throwing: StreamPipelineError.truncated)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func deltas<Bytes: AsyncSequence & Sendable>(
        bytes makeBytes: @escaping @Sendable () async throws -> Bytes,
        maxEventBytes: Int,
        decoder: AnthropicEventDecoder,
        parseObserver: (@Sendable () -> Void)?
    ) -> AsyncThrowingStream<StreamDelta, any Error> where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var parser = SSEParser(maxEventBytes: maxEventBytes)
                do {
                    let bytes = try await makeBytes()
                    for try await byte in bytes {
                        let events = parser.feed(CollectionOfOne(byte))
                        guard !events.isEmpty else { continue }
                        try Task.checkCancellation()
                        for event in events {
                            parseObserver?()
                            continuation.yield(decoder.decode(event))
                        }
                    }
                    if parser.finish() {
                        continuation.finish(throwing: StreamPipelineError.truncated)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
