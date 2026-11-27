import Foundation
import Synchronization

/// Saturating arithmetic on `UInt64` nanosecond quantities.
///
/// Every duration in this package is a `UInt64` count of nanoseconds. Timestamps come from
/// different sources (a monotonic clock, a replayed fixture, a test's manual clock), and a
/// latency library that traps on `a - b` when a mark arrives "early" is worse than useless,
/// so all arithmetic on them goes through these helpers instead of `+`, `-` and `*`.
enum Saturating {
    static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? .max : result
    }

    /// `a - b`, floored at zero instead of trapping.
    static func sub(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a >= b ? a - b : 0
    }

    static func mul(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        return overflow ? .max : result
    }

    /// `a * numerator / denominator` computed at full width, so the intermediate product
    /// cannot overflow. Saturates to `.max` when the quotient does not fit, and treats a
    /// zero denominator as "unbounded" (`.max`) rather than trapping.
    static func scale(_ a: UInt64, by numerator: UInt64, over denominator: UInt64) -> UInt64 {
        guard denominator > 0 else { return .max }
        let product = a.multipliedFullWidth(by: numerator)
        // `dividingFullWidth` traps when the quotient overflows, which happens exactly when
        // the high word is >= the divisor. Check that first.
        guard product.high < denominator else { return .max }
        return denominator.dividingFullWidth((high: product.high, low: product.low)).quotient
    }
}

/// Conversions into the package's nanosecond unit. Saturating, never trapping.
public enum Nanos {
    public static func milliseconds(_ value: UInt64) -> UInt64 { Saturating.mul(value, 1_000_000) }
    public static func microseconds(_ value: UInt64) -> UInt64 { Saturating.mul(value, 1_000) }

    /// Nanoseconds to milliseconds as a `Double`, for display only.
    public static func toMilliseconds(_ nanos: UInt64) -> Double { Double(nanos) / 1_000_000 }
}

/// A monotonic time source. Only differences between two readings are meaningful.
public protocol MonotonicClock: Sendable {
    func now() -> UInt64
}

/// The production clock: `mach_absolute_time`-backed uptime via `DispatchTime`.
///
/// Uptime does not advance while the device sleeps. That is the right behaviour for a
/// foreground request measured in milliseconds; it would be wrong for anything that spans
/// a suspension, which TTFT does not.
public struct SystemClock: MonotonicClock {
    public init() {}
    public func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// A clock that only moves when told to. Used by tests and by the deterministic replayer.
public final class ManualClock: MonotonicClock {
    private let current: Mutex<UInt64>

    public init(start: UInt64 = 0) {
        current = Mutex(start)
    }

    public func now() -> UInt64 { current.withLock { $0 } }

    public func advance(by delta: UInt64) {
        current.withLock { $0 = Saturating.add($0, delta) }
    }
}

/// SplitMix64: a tiny, fast, seedable PRNG. The replayer needs reproducible jitter so that a
/// CI gate over replayed samples gives the same answer on every machine.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
