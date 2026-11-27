/// A TTFT budget: a total plus an optional cap per stage.
///
/// The per-stage caps are how a lead turns one product number ("first token under 800 ms")
/// into numbers each owning team can be held to. A stage with no cap is unbudgeted, which is
/// the honest setting for `serverQueue`: the client cannot change it, only observe it.
public struct TTFTBudget: Sendable, Equatable {
    public var total: UInt64
    public var perStage: [Stage: UInt64]

    public init(total: UInt64, perStage: [Stage: UInt64]) {
        self.total = total
        self.perStage = perStage
    }

    /// The budget the demo uses for an interactive chat surface.
    public static let interactiveChat = TTFTBudget(
        total: Nanos.milliseconds(800),
        perStage: [
            .requestBuild: Nanos.milliseconds(40),
            .connection: Nanos.milliseconds(150),
            .firstToken: Nanos.milliseconds(250),
            .render: Nanos.milliseconds(34),
        ]
    )

    public func evaluate(_ breakdown: TTFTBreakdown) -> BudgetReport {
        var overruns: [BudgetReport.Overrun] = []
        for duration in breakdown.stages {
            guard let cap = perStage[duration.stage], duration.nanoseconds > cap else { continue }
            overruns.append(.init(
                stage: duration.stage,
                actual: duration.nanoseconds,
                budget: cap,
                excess: Saturating.sub(duration.nanoseconds, cap)
            ))
        }
        // Largest stage wins; ties go to the earliest stage so the answer is deterministic.
        let dominant = breakdown.stages.max { lhs, rhs in
            lhs.nanoseconds != rhs.nanoseconds
                ? lhs.nanoseconds < rhs.nanoseconds
                : lhs.stage.rawValue > rhs.stage.rawValue
        }
        return BudgetReport(
            overruns: overruns,
            totalExcess: Saturating.sub(breakdown.total, total),
            dominantStage: (dominant?.nanoseconds ?? 0) > 0 ? dominant?.stage : nil
        )
    }
}

public struct BudgetReport: Sendable, Equatable {
    public struct Overrun: Sendable, Equatable {
        public let stage: Stage
        public let actual: UInt64
        public let budget: UInt64
        public let excess: UInt64
    }

    public let overruns: [Overrun]
    /// How far the total is over its budget; zero when within it.
    public let totalExcess: UInt64
    /// The stage that cost the most, or `nil` if every stage was zero.
    public let dominantStage: Stage?

    public var withinBudget: Bool { overruns.isEmpty && totalExcess == 0 }
}
