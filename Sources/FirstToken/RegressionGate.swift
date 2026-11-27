/// Order statistics over latency samples.
public enum Percentile {
    /// The nearest-rank percentile: the smallest sample such that at least `percentile`% of
    /// samples are less than or equal to it. Always an observed value, never interpolated, so
    /// a gate built on it cannot be argued with ("p95 was 812 ms" is a run you can find).
    ///
    /// Returns `nil` for an empty input or a percentile outside `1...100`.
    public static func nearestRank(_ samples: [UInt64], percentile: Int) -> UInt64? {
        guard !samples.isEmpty, (1...100).contains(percentile) else { return nil }
        let sorted = samples.sorted()
        // rank = ceil(percentile * n / 100), computed without overflow for any n.
        let n = UInt64(sorted.count)
        // The high word of n * percentile is < 100 because percentile <= 100, so the
        // full-width division below cannot overflow; the quotient is <= n.
        let product = n.multipliedFullWidth(by: UInt64(percentile))
        let (quotient, remainder) = UInt64(100).dividingFullWidth(product)
        let rank = remainder == 0 ? quotient : quotient + 1
        let index = Int(min(max(rank, 1), n)) - 1
        return sorted.indices.contains(index) ? sorted[index] : nil
    }
}

/// Fails a build when TTFT slips against a baseline.
///
/// Both p50 and p95 are gated, because they fail differently: a slower render path moves
/// p50, a lost connection pre-warm moves p95 (the cold tail). The allowance is relative plus
/// an absolute floor, so a 1 ms baseline stage does not fail on 0.2 ms of noise.
public struct RegressionGate: Sendable, Equatable {
    public var minimumSamples: Int
    /// Allowed relative slip, in parts per thousand (50 = 5%).
    public var p50TolerancePermille: UInt64
    public var p95TolerancePermille: UInt64
    /// Absolute slip always allowed, in nanoseconds.
    public var absoluteSlack: UInt64

    public init(
        minimumSamples: Int = 20,
        p50TolerancePermille: UInt64 = 50,
        p95TolerancePermille: UInt64 = 100,
        absoluteSlack: UInt64 = Nanos.milliseconds(2)
    ) {
        self.minimumSamples = max(1, minimumSamples)
        self.p50TolerancePermille = p50TolerancePermille
        self.p95TolerancePermille = p95TolerancePermille
        self.absoluteSlack = absoluteSlack
    }

    public func allowed(baseline: UInt64, tolerancePermille: UInt64) -> UInt64 {
        Saturating.add(
            Saturating.add(baseline, Saturating.scale(baseline, by: tolerancePermille, over: 1_000)),
            absoluteSlack
        )
    }

    /// Compare two sample sets.
    public func evaluate(baseline: [UInt64], candidate: [UInt64]) -> GateResult {
        guard baseline.count >= minimumSamples, let recorded = GateBaseline(samples: baseline) else {
            return GateResult(status: .insufficientSamples, metrics: [])
        }
        return evaluate(baseline: recorded, candidate: candidate)
    }

    /// Gate each stage that has a committed baseline. A stage-level regression that is small
    /// next to the total (one display frame, one skipped speculation) sits inside the total's
    /// tolerance; gating the stage separately is how it gets caught, and the failing stage
    /// names the team that owns the fix.
    public func evaluate(stageBaselines: [Stage: GateBaseline], candidate: [TTFTBreakdown]) -> [Stage: GateResult] {
        var results: [Stage: GateResult] = [:]
        for (stage, baseline) in stageBaselines {
            results[stage] = evaluate(baseline: baseline, candidate: candidate.map { $0.duration(of: stage) })
        }
        return results
    }

    /// Compare a candidate sample set against a committed baseline: the CI shape, where the
    /// baseline is two numbers in the repository rather than a second benchmark run.
    public func evaluate(baseline: GateBaseline, candidate: [UInt64]) -> GateResult {
        guard candidate.count >= minimumSamples,
              let c50 = Percentile.nearestRank(candidate, percentile: 50),
              let c95 = Percentile.nearestRank(candidate, percentile: 95)
        else {
            return GateResult(status: .insufficientSamples, metrics: [])
        }
        let b50 = baseline.p50
        let b95 = baseline.p95
        let metrics = [
            GateResult.Metric(name: "p50", baseline: b50, candidate: c50,
                              allowed: allowed(baseline: b50, tolerancePermille: p50TolerancePermille)),
            GateResult.Metric(name: "p95", baseline: b95, candidate: c95,
                              allowed: allowed(baseline: b95, tolerancePermille: p95TolerancePermille)),
        ]
        return GateResult(status: metrics.contains { $0.breached } ? .fail : .pass, metrics: metrics)
    }
}

/// A recorded p50/p95 pair.
public struct GateBaseline: Sendable, Equatable {
    public let p50: UInt64
    public let p95: UInt64

    public init(p50: UInt64, p95: UInt64) {
        self.p50 = p50
        self.p95 = p95
    }

    /// `nil` for an empty sample set.
    public init?(samples: [UInt64]) {
        guard let p50 = Percentile.nearestRank(samples, percentile: 50),
              let p95 = Percentile.nearestRank(samples, percentile: 95) else { return nil }
        self.init(p50: p50, p95: p95)
    }
}

public struct GateResult: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case pass
        case fail
        /// Too few samples to say anything. Treated as a failure by `passed`: a gate that
        /// passes when it has no data is a gate that passes when the benchmark broke.
        case insufficientSamples
    }

    public struct Metric: Sendable, Equatable {
        public let name: String
        public let baseline: UInt64
        public let candidate: UInt64
        public let allowed: UInt64
        public var breached: Bool { candidate > allowed }
    }

    public let status: Status
    public let metrics: [Metric]

    public var passed: Bool { status == .pass }
}
