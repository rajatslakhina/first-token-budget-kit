/// The six instants that define time-to-first-token, in the order they happen on a cold request.
///
/// TTFT is measured from `sendCommitted` (the user's tap) to `firstGlyphRendered` (the first
/// non-whitespace character reaching the screen). `firstTextDelta` is the first text delta
/// that carries a visible character: whitespace-only deltas before it are server pacing, so
/// they count toward the API's `firstToken` stage, not the client's `render` stage. The two milestones that can legitimately be
/// reached *before* the tap are `requestBuilt` and `connectionReady`: that is what speculative
/// prompt assembly and connection pre-warming buy you.
public enum Milestone: Int, CaseIterable, Sendable, Codable, Comparable {
    case sendCommitted
    case requestBuilt
    case connectionReady
    case headersReceived
    case firstTextDelta
    case firstGlyphRendered

    public static func < (lhs: Milestone, rhs: Milestone) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether this milestone may be reached before `sendCommitted` without that being an
    /// instrumentation bug.
    public var canBePrepaid: Bool { self == .requestBuilt || self == .connectionReady }

    public var label: String {
        switch self {
        case .sendCommitted: "send committed"
        case .requestBuilt: "request built"
        case .connectionReady: "connection ready"
        case .headersReceived: "headers received"
        case .firstTextDelta: "first visible text delta"
        case .firstGlyphRendered: "first glyph rendered"
        }
    }
}

/// The five intervals between consecutive milestones. Each one has a different owner in a
/// real organisation, which is the point of splitting them: "TTFT regressed" is not
/// actionable, "the connection stage regressed" is.
public enum Stage: Int, CaseIterable, Sendable, Codable {
    /// Prompt assembly and encoding. Owner: the feature team.
    case requestBuild
    /// DNS, TCP and TLS, or reuse of a warm connection. Owner: the networking platform.
    case connection
    /// Request sent until response headers. Owner: the API; the client cannot change it.
    case serverQueue
    /// Headers until the first text delta carrying a visible character is parsed. Includes
    /// `message_start`, `ping`, whitespace-only deltas and any delta that arrived split across
    /// chunks. Owner: the API and its stream framing; the client parser can only add to it.
    case firstToken
    /// That delta parsed until its first glyph is committed for display. Owner: the client UI.
    case render

    public var start: Milestone {
        switch self {
        case .requestBuild: .sendCommitted
        case .connection: .requestBuilt
        case .serverQueue: .connectionReady
        case .firstToken: .headersReceived
        case .render: .firstTextDelta
        }
    }

    public var end: Milestone {
        switch self {
        case .requestBuild: .requestBuilt
        case .connection: .connectionReady
        case .serverQueue: .headersReceived
        case .firstToken: .firstTextDelta
        case .render: .firstGlyphRendered
        }
    }

    public var label: String {
        switch self {
        case .requestBuild: "request build"
        case .connection: "connection"
        case .serverQueue: "server queue"
        case .firstToken: "first token"
        case .render: "render"
        }
    }
}

/// One stage's measured share of TTFT.
public struct StageDuration: Sendable, Equatable {
    public let stage: Stage
    public let nanoseconds: UInt64
    /// The stage's end milestone was reached before the user tapped send, so it cost the
    /// user nothing.
    public let prepaid: Bool
}

/// A complete TTFT measurement, split by stage.
///
/// Invariant (tested): the stage durations sum exactly to `total`. Stages telescope over
/// "effective" milestone times, so no time is double-counted or lost, even when milestones
/// were prepaid or recorded out of order.
public struct TTFTBreakdown: Sendable, Equatable {
    public let total: UInt64
    public let stages: [StageDuration]
    /// Milestones whose raw timestamp was earlier than their predecessor's after the send, or
    /// earlier than the send when they cannot be prepaid. Each one is clamped to its
    /// predecessor, and each one is an instrumentation bug worth fixing.
    public let orderingViolations: [Milestone]

    public func duration(of stage: Stage) -> UInt64 {
        stages.first { $0.stage == stage }?.nanoseconds ?? 0
    }

    public func isPrepaid(_ stage: Stage) -> Bool {
        stages.first { $0.stage == stage }?.prepaid ?? false
    }
}

/// Raw milestone timestamps for one request. A value type: cheap to copy, trivially `Sendable`.
public struct TTFTTimeline: Sendable, Equatable {
    public enum MarkResult: Sendable, Equatable {
        case recorded
        /// The milestone was already recorded. First write wins: a retry or a second render
        /// pass must not move "first glyph" later.
        case duplicateIgnored
    }

    public private(set) var raw: [Milestone: UInt64] = [:]

    public init() {}

    @discardableResult
    public mutating func mark(_ milestone: Milestone, at time: UInt64) -> MarkResult {
        if raw[milestone] != nil { return .duplicateIgnored }
        raw[milestone] = time
        return .recorded
    }

    public var missing: [Milestone] { Milestone.allCases.filter { raw[$0] == nil } }

    public var isComplete: Bool { missing.isEmpty }

    /// The per-stage split, or `nil` until every milestone has been recorded.
    public func breakdown() -> TTFTBreakdown? {
        guard let sendTime = raw[.sendCommitted] else { return nil }
        var effectivePrevious = sendTime
        var stages: [StageDuration] = []
        var violations: [Milestone] = []

        for stage in Stage.allCases {
            guard let rawEnd = raw[stage.end] else { return nil }
            var prepaid = false
            if rawEnd < sendTime {
                if stage.end.canBePrepaid {
                    prepaid = true
                } else {
                    violations.append(stage.end)
                }
            } else if rawEnd < effectivePrevious {
                violations.append(stage.end)
            }
            let effectiveEnd = max(rawEnd, effectivePrevious)
            stages.append(StageDuration(
                stage: stage,
                nanoseconds: Saturating.sub(effectiveEnd, effectivePrevious),
                prepaid: prepaid
            ))
            effectivePrevious = effectiveEnd
        }
        return TTFTBreakdown(
            total: Saturating.sub(effectivePrevious, sendTime),
            stages: stages,
            orderingViolations: violations
        )
    }
}
