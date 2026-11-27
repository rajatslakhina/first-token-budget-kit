import Foundation

/// One network read: bytes that arrived `offset` nanoseconds after the response headers.
public struct FixtureChunk: Sendable, Equatable {
    public let offset: UInt64
    public let bytes: [UInt8]

    public init(offset: UInt64, bytes: [UInt8]) {
        self.offset = offset
        self.bytes = bytes
    }
}

/// A recorded (or synthesised) streaming response: the exact bytes and their arrival times.
public struct StreamFixture: Sendable, Equatable {
    public let name: String
    public let chunks: [FixtureChunk]

    public init(name: String, chunks: [FixtureChunk]) {
        self.name = name
        self.chunks = chunks
    }
}

/// Stage costs that the client does not control in a replay. Jitter is applied per stage as a
/// uniform factor in `[1 - j, 1 + j]`, where `j = jitterPermille / 1000` (capped at 1).
public struct NetworkProfile: Sendable, Equatable {
    public var requestBuild: UInt64
    public var coldConnect: UInt64
    public var warmConnect: UInt64
    public var serverQueue: UInt64
    public var jitterPermille: UInt64

    public init(requestBuild: UInt64, coldConnect: UInt64, warmConnect: UInt64,
                serverQueue: UInt64, jitterPermille: UInt64) {
        self.requestBuild = requestBuild
        self.coldConnect = coldConnect
        self.warmConnect = warmConnect
        self.serverQueue = serverQueue
        self.jitterPermille = jitterPermille
    }

    /// Illustrative mobile numbers, not measurements: a cold TLS 1.3 connection over a
    /// cellular link plus a short server queue.
    public static let cellular = NetworkProfile(
        requestBuild: Nanos.milliseconds(35),
        coldConnect: Nanos.milliseconds(240),
        warmConnect: Nanos.milliseconds(4),
        serverQueue: Nanos.milliseconds(310),
        jitterPermille: 250
    )
}

public enum CoalescerKind: String, Sendable, Equatable, CaseIterable {
    case leadingEdge
    case trailingEdge

    public func make(frameInterval: UInt64) -> any CoalescingStrategy {
        switch self {
        case .leadingEdge: LeadingEdgeCoalescer(frameInterval: frameInterval)
        case .trailingEdge: TrailingEdgeCoalescer()
        }
    }
}

public struct ReplayConfiguration: Sendable, Equatable {
    public var profile: NetworkProfile
    /// The connection was pre-warmed on composer focus, so the connection stage costs
    /// `warmConnect` instead of `coldConnect`.
    public var prewarmConnection: Bool
    /// The prompt was assembled speculatively on a typing pause and matched the sent draft,
    /// so the request-build stage is prepaid.
    public var speculativePromptHit: Bool
    public var coalescer: CoalescerKind
    public var frameInterval: UInt64

    public init(profile: NetworkProfile = .cellular, prewarmConnection: Bool, speculativePromptHit: Bool,
                coalescer: CoalescerKind, frameInterval: UInt64 = 16_666_667) {
        self.profile = profile
        self.prewarmConnection = prewarmConnection
        self.speculativePromptHit = speculativePromptHit
        self.coalescer = coalescer
        self.frameInterval = max(1, frameInterval)
    }

    /// No pre-warm, no speculation, trailing-edge commits: what most first implementations ship.
    public static let naive = ReplayConfiguration(prewarmConnection: false, speculativePromptHit: false, coalescer: .trailingEdge)
    /// Everything this package recommends.
    public static let shipped = ReplayConfiguration(prewarmConnection: true, speculativePromptHit: true, coalescer: .leadingEdge)
}

public struct ReplayResult: Sendable, Equatable {
    public let timeline: TTFTTimeline
    public let breakdown: TTFTBreakdown?
    public let committedText: String
    public let commits: Int
    public let deltas: [StreamDelta]
    /// The fixture ended in the middle of an event.
    public let truncated: Bool
}

/// Replays a fixture through the real parser, decoder and coalescer under virtual time.
///
/// What is real: SSE framing and chunk boundaries (a delta split across two reads is only
/// parsed when the second arrives), JSON decoding, which deltas carry visible text, and the
/// coalescer's commit timing against display frames. What is modelled: the pre-stream stage
/// costs (from `NetworkProfile`), and "first glyph" as the first display refresh strictly
/// after the commit that carried a visible character. CPU cost is not modelled; it is zero
/// in virtual time. That is what makes the result deterministic for a CI gate, and also why
/// the gate cannot catch a slow parser: use the signposts for that.
public enum FixtureReplayer {
    /// The virtual time of `sendCommitted`. Large enough that prepaid milestones before it are
    /// still positive.
    static let sendTime: UInt64 = 10_000_000_000

    public static func run(_ fixture: StreamFixture, configuration: ReplayConfiguration, seed: UInt64) -> ReplayResult {
        var rng = SplitMix64(seed: seed &+ PromptDigest.fnv1a(fixture.name))
        let profile = configuration.profile
        let jitter = min(profile.jitterPermille, 1_000)
        func jittered(_ value: UInt64) -> UInt64 {
            let factor = 1_000 - jitter + rng.next() % (2 * jitter + 1)
            return Saturating.scale(value, by: factor, over: 1_000)
        }

        var timeline = TTFTTimeline()
        let send = sendTime
        timeline.mark(.sendCommitted, at: send)

        let built = configuration.speculativePromptHit
            ? Saturating.sub(send, Nanos.milliseconds(1))
            : Saturating.add(send, jittered(profile.requestBuild))
        timeline.mark(.requestBuilt, at: built)

        let connectCost = configuration.prewarmConnection ? profile.warmConnect : profile.coldConnect
        let ready = Saturating.add(max(built, send), jittered(connectCost))
        timeline.mark(.connectionReady, at: ready)

        let headers = Saturating.add(ready, jittered(profile.serverQueue))
        timeline.mark(.headersReceived, at: headers)

        let streamFactor = 1_000 - jitter + rng.next() % (2 * jitter + 1)
        let frame = configuration.frameInterval
        let phase = rng.next() % frame
        // Display refreshes happen at phase + k * frame.
        func firstTick(after time: UInt64) -> UInt64 {
            Saturating.add(phase, Saturating.mul(Saturating.add(Saturating.sub(time, phase) / frame, 1), frame))
        }
        var nextTick = firstTick(after: Saturating.sub(headers, 1)) // first refresh at or after the headers

        var parser = SSEParser()
        let decoder = AnthropicEventDecoder()
        var coalescer = configuration.coalescer.make(frameInterval: frame)
        var committed = ""
        var commits = 0
        var deltas: [StreamDelta] = []
        var sawFirstText = false

        func commit(_ text: String?, at time: UInt64) {
            guard let text else { return }
            committed += text
            commits += 1
            if timeline.raw[.firstGlyphRendered] == nil, text.containsGlyph {
                // The first refresh strictly after the commit.
                timeline.mark(.firstGlyphRendered, at: firstTick(after: time))
            }
        }

        for chunk in fixture.chunks {
            let arrival = Saturating.add(headers, Saturating.scale(chunk.offset, by: streamFactor, over: 1_000))
            while nextTick <= arrival {
                guard coalescer.isHoldingText else {
                    // Refreshes with nothing held are no-ops for every strategy: skip them.
                    nextTick = firstTick(after: arrival)
                    break
                }
                commit(coalescer.frame(at: nextTick), at: nextTick)
                guard nextTick < .max else { break } // saturated clock: no later refresh exists
                nextTick = Saturating.add(nextTick, frame)
            }
            for event in parser.feed(chunk.bytes) {
                let delta = decoder.decode(event)
                deltas.append(delta)
                guard let text = delta.text else { continue }
                if !sawFirstText {
                    sawFirstText = true
                    timeline.mark(.firstTextDelta, at: arrival)
                }
                commit(coalescer.ingest(text, at: arrival), at: arrival)
            }
        }
        var remainingTicks = 10_000 // bounded: a strategy that never releases cannot hang the replay
        while coalescer.isHoldingText, remainingTicks > 0 {
            commit(coalescer.frame(at: nextTick), at: nextTick)
            nextTick = Saturating.add(nextTick, frame)
            remainingTicks -= 1
        }
        commit(coalescer.drain(), at: nextTick)

        return ReplayResult(
            timeline: timeline,
            breakdown: timeline.breakdown(),
            committedText: committed,
            commits: commits,
            deltas: deltas,
            truncated: parser.finish()
        )
    }

    /// TTFT totals for every fixture × seed whose replay produced a complete breakdown.
    public static func totals(_ fixtures: [StreamFixture], configuration: ReplayConfiguration,
                              seeds: Range<UInt64>) -> [UInt64] {
        breakdowns(fixtures, configuration: configuration, seeds: seeds).map(\.total)
    }

    public static func breakdowns(_ fixtures: [StreamFixture], configuration: ReplayConfiguration,
                                  seeds: Range<UInt64>) -> [TTFTBreakdown] {
        var out: [TTFTBreakdown] = []
        for fixture in fixtures {
            for seed in seeds {
                if let breakdown = run(fixture, configuration: configuration, seed: seed).breakdown {
                    out.append(breakdown)
                }
            }
        }
        return out
    }
}

/// Plays a fixture back as an `AsyncSequence` of byte chunks in real time (scaled by
/// `timeScalePermille`; 1,000 = recorded speed). The demo feeds this into `StreamPipeline`
/// exactly as it would feed `URLSession` bytes.
public struct FixtureByteStream: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    public let fixture: StreamFixture
    public let timeScalePermille: UInt64

    public init(_ fixture: StreamFixture, timeScalePermille: UInt64 = 1_000) {
        self.fixture = fixture
        self.timeScalePermille = timeScalePermille
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [FixtureChunk]
        let scale: UInt64
        var index = 0
        var elapsed: UInt64 = 0

        public mutating func next() async throws -> [UInt8]? {
            guard chunks.indices.contains(index) else { return nil }
            let chunk = chunks[index]
            index += 1
            let target = Saturating.scale(chunk.offset, by: scale, over: 1_000)
            let wait = Saturating.sub(target, elapsed)
            elapsed = Swift.max(elapsed, target)
            if wait > 0 { try await Task.sleep(nanoseconds: wait) }
            return chunk.bytes
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: fixture.chunks, scale: timeScalePermille)
    }
}
