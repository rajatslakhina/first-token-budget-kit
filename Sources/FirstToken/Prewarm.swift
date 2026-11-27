/// A token bucket over a monotonic clock: `capacity` tokens, one more every `refillInterval`.
public struct TokenBucket: Sendable, Equatable {
    public let capacity: UInt64
    public let refillInterval: UInt64
    public private(set) var tokens: UInt64
    private var lastRefill: UInt64?

    public init(capacity: UInt64, refillInterval: UInt64) {
        self.capacity = capacity
        self.refillInterval = max(1, refillInterval)
        tokens = capacity
    }

    /// Takes one token if available. A clock reading earlier than the last one refills
    /// nothing rather than trapping.
    public mutating func take(at now: UInt64) -> Bool {
        refill(at: now)
        guard tokens > 0 else { return false }
        tokens -= 1
        return true
    }

    private mutating func refill(at now: UInt64) {
        guard let last = lastRefill else {
            lastRefill = now
            return
        }
        let earned = Saturating.sub(now, last) / refillInterval
        guard earned > 0 else { return }
        tokens = min(capacity, Saturating.add(tokens, earned))
        lastRefill = Saturating.add(last, Saturating.mul(earned, refillInterval))
    }
}

/// Stable 64-bit FNV-1a. Used to fingerprint a draft so a speculative prompt can be matched to
/// what is finally sent. `Hasher` is seeded per process and cannot be used for this.
public enum PromptDigest {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// What the composer is telling us about the user's intent.
public enum IntentSignal: Sendable, Equatable {
    case composerFocused
    /// A keystroke changed the draft to the text with this digest.
    case draftEdited(digest: UInt64)
    /// The user stopped typing; the draft has this digest.
    case typingPaused(digest: UInt64)
    case composerDismissed
}

/// Work the policy asks the app to do. None of it sends the draft anywhere.
public enum PrewarmAction: Sendable, Equatable {
    /// Open (or touch) the connection to the API host, with no request on it.
    case warmConnection
    /// Assemble and encode the prompt for this draft locally (system prompt, retrieval,
    /// tokenisation), ready to send.
    case assemblePrompt(digest: UInt64)
    /// Throw away a speculative prompt that no longer matches the draft.
    case discardSpeculativePrompt(digest: UInt64)
}

public struct SendResult: Sendable, Equatable {
    public enum Prompt: Sendable, Equatable {
        /// The speculative prompt matched the sent draft: the request-build stage is prepaid.
        case hit
        /// A speculative prompt existed but was for a different draft.
        case miss
        /// Nothing was speculated.
        case notSpeculated
    }

    public let prompt: Prompt
    /// Whether the policy believes a warm connection exists at send time.
    public let connectionWarm: Bool
    public let actions: [PrewarmAction]
}

/// Decides when to pre-warm the connection and speculatively assemble the prompt.
///
/// The design line: speculation stops at the network boundary. The policy never sends a
/// request before the user taps send, because a speculative API call bills tokens and ships a
/// draft the user may never have meant to send. What it does do, under a budget:
///
/// - opens the connection when the composer gains focus (DNS + TCP + TLS is often the
///   largest client-controllable stage on a cold request), at most `maxWarmups` per window;
/// - assembles the prompt locally when typing pauses, at most `maxAssemblies` per window,
///   and discards it the moment the draft changes;
/// - tracks hits, misses and waste, so the hit rate can justify (or kill) the feature.
public struct PrewarmPolicy: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long a connection is assumed to stay warm after it was opened or used.
        public var connectionIdleTimeout: UInt64
        public var maxWarmups: UInt64
        public var warmupWindow: UInt64
        public var maxAssemblies: UInt64
        public var assemblyWindow: UInt64

        public init(
            connectionIdleTimeout: UInt64 = Nanos.milliseconds(30_000),
            maxWarmups: UInt64 = 4,
            warmupWindow: UInt64 = Nanos.milliseconds(60_000),
            maxAssemblies: UInt64 = 6,
            assemblyWindow: UInt64 = Nanos.milliseconds(60_000)
        ) {
            self.connectionIdleTimeout = connectionIdleTimeout
            self.maxWarmups = maxWarmups
            self.warmupWindow = warmupWindow
            self.maxAssemblies = maxAssemblies
            self.assemblyWindow = assemblyWindow
        }
    }

    public struct Stats: Sendable, Equatable {
        public var warmups: UInt64 = 0
        public var assemblies: UInt64 = 0
        public var hits: UInt64 = 0
        public var misses: UInt64 = 0
        /// Speculative prompts thrown away before any send.
        public var discarded: UInt64 = 0
        /// Warm-ups or assemblies refused because the budget was spent.
        public var deniedByBudget: UInt64 = 0

        /// Hits per 1,000 sends that had a speculative prompt; `nil` before any such send.
        public var hitRatePermille: UInt64? {
            let attempts = Saturating.add(hits, misses)
            guard attempts > 0 else { return nil }
            return Saturating.scale(hits, by: 1_000, over: attempts)
        }
    }

    public let configuration: Configuration
    public private(set) var stats = Stats()
    private var warmUntil: UInt64?
    private var speculativeDigest: UInt64?
    private var warmupBudget: TokenBucket
    private var assemblyBudget: TokenBucket

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        warmupBudget = TokenBucket(
            capacity: configuration.maxWarmups,
            refillInterval: configuration.maxWarmups == 0 ? .max
                : configuration.warmupWindow / max(1, configuration.maxWarmups)
        )
        assemblyBudget = TokenBucket(
            capacity: configuration.maxAssemblies,
            refillInterval: configuration.maxAssemblies == 0 ? .max
                : configuration.assemblyWindow / max(1, configuration.maxAssemblies)
        )
    }

    /// The digest of the currently held speculative prompt, if any.
    public var speculatedDigest: UInt64? { speculativeDigest }

    public func isConnectionWarm(at now: UInt64) -> Bool {
        guard let warmUntil else { return false }
        return now < warmUntil
    }

    public mutating func handle(_ signal: IntentSignal, at now: UInt64) -> [PrewarmAction] {
        switch signal {
        case .composerFocused:
            return warmIfNeeded(at: now)
        case let .draftEdited(digest):
            return discardIfStale(keeping: digest)
        case let .typingPaused(digest):
            var actions = warmIfNeeded(at: now)
            if speculativeDigest == digest { return actions }
            actions += discardIfStale(keeping: digest)
            if assemblyBudget.take(at: now) {
                speculativeDigest = digest
                stats.assemblies = Saturating.add(stats.assemblies, 1)
                actions.append(.assemblePrompt(digest: digest))
            } else {
                stats.deniedByBudget = Saturating.add(stats.deniedByBudget, 1)
            }
            return actions
        case .composerDismissed:
            return discardIfStale(keeping: nil)
        }
    }

    /// The user tapped send with a draft whose digest is `digest`.
    public mutating func send(digest: UInt64, at now: UInt64) -> SendResult {
        let warm = isConnectionWarm(at: now)
        let prompt: SendResult.Prompt
        var actions: [PrewarmAction] = []
        switch speculativeDigest {
        case .some(digest):
            prompt = .hit
            stats.hits = Saturating.add(stats.hits, 1)
        case let .some(stale):
            prompt = .miss
            stats.misses = Saturating.add(stats.misses, 1)
            stats.discarded = Saturating.add(stats.discarded, 1)
            actions.append(.discardSpeculativePrompt(digest: stale))
        case .none:
            prompt = .notSpeculated
        }
        speculativeDigest = nil
        // Sending uses the connection, which keeps it warm whether or not it was before.
        warmUntil = Saturating.add(now, configuration.connectionIdleTimeout)
        return SendResult(prompt: prompt, connectionWarm: warm, actions: actions)
    }

    private mutating func warmIfNeeded(at now: UInt64) -> [PrewarmAction] {
        guard !isConnectionWarm(at: now) else { return [] }
        guard warmupBudget.take(at: now) else {
            stats.deniedByBudget = Saturating.add(stats.deniedByBudget, 1)
            return []
        }
        stats.warmups = Saturating.add(stats.warmups, 1)
        warmUntil = Saturating.add(now, configuration.connectionIdleTimeout)
        return [.warmConnection]
    }

    private mutating func discardIfStale(keeping digest: UInt64?) -> [PrewarmAction] {
        guard let current = speculativeDigest, current != digest else { return [] }
        speculativeDigest = nil
        stats.discarded = Saturating.add(stats.discarded, 1)
        return [.discardSpeculativePrompt(digest: current)]
    }
}
