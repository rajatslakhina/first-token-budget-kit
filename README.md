# FirstToken

**Treat time-to-first-token as an engineering budget, not a model property.**

[![CI](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 18+ · macOS 15+](https://img.shields.io/badge/platforms-iOS%2018%2B%20%C2%B7%20macOS%2015%2B-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

When an LLM feature feels slow, the number users feel is the gap between tapping send and seeing the first word. Most iOS teams can't tell you where that time goes, so "make it faster" ends up as a ticket for the model team. This package splits time-to-first-token (TTFT) into five stages, gives each one an owner and a budget, removes the client-side costs that are avoidable, and fails CI when a stage regresses.

In the replay harness (cellular profile, 4 streams × 10 seeds), the naive client lands at **p50 800 ms / p95 902 ms**. The pipeline in this package lands at **p50 521 ms / p95 601 ms** without touching the server. Those numbers come from a deterministic simulation, not a device measurement; [Honest limits](#honest-limits) says exactly what is real and what is modelled.

Demo app: **[first-token-budget-demo-app](https://github.com/rajatslakhina/first-token-budget-demo-app)**. It pulls this package from GitHub as a version-pinned dependency and runs the whole pipeline on a Simulator: a replayed waterfall, a live stream, and the speculation policy.

## Why this matters

Anthropic's 25 Nov 2026 write-up on moving the Messages API from Python to Rust credits the move with roughly 20% lower median TTFT for Claude Code. When a provider rewrites its serving stack over a latency number, that number is the one users feel. On a phone, though, much of the TTFT is spent before the request reaches the provider, or after the first byte comes back:

| Stage | From → to | Who owns it |
|---|---|---|
| request build | send tapped → request encoded | feature team (prompt assembly, retrieval, encoding) |
| connection | request built → connection ready | networking platform (DNS, TCP, TLS, reuse) |
| server queue | connection ready → response headers | the API; the client can only observe it |
| first token | headers → first `text_delta` parsed | client parser + the API's stream framing |
| render | first delta → first visible glyph committed | client UI |

The deliverable is a split you can assign. "TTFT regressed 30 ms" is not actionable; "the render stage regressed one frame, and the CI gate named it" is.

## What's in it

| Type | Job |
|---|---|
| `TTFTTimeline`, `TTFTBreakdown`, `Milestone`, `Stage` | Six milestones → five stage durations. First write wins per milestone. Prepaid milestones (`requestBuilt` / `connectionReady` reached *before* the tap) cost zero and are flagged. A post-send milestone stamped earlier than its predecessor is clamped and reported as an ordering violation. **Invariant (tested over 2,000 random timelines): the stages sum exactly to the total.** |
| `TTFTInstrument` | An actor that stamps milestones from a `MonotonicClock` and mirrors them to `os_signpost`: one point event per milestone and one interval per request, so TTFT shows up in Instruments next to main-thread work. |
| `TTFTBudget`, `BudgetReport` | A total plus per-stage caps. Reports overruns, the excess over the total, and the dominant stage. `serverQueue` is left unbudgeted on purpose. |
| `SSEParser` | Incremental, byte-level `text/event-stream` parser, written from the WHATWG spec: LF/CR/CRLF (including a CRLF split across reads), BOM, comments, multi-line `data:`, last-event-ID, and bounded memory (an oversize event is dropped whole, never delivered truncated). |
| `AnthropicEventDecoder`, `StreamDelta` | Messages-API stream events → `text`, `messageStart`, `ping`, `blockStop`, `messageStop`, in-stream `serverError`, `ignored` (thinking/tool deltas), `malformed`. |
| `StreamPipeline.deltas(from:)` | Any `AsyncSequence` of byte chunks → `AsyncThrowingStream<StreamDelta>`. Parsing runs on a detached task, never on the caller's actor (tested from `@MainActor`). Cancelling the consumer stops the source being pulled (tested). |
| `LeadingEdgeCoalescer` (+ `TrailingEdgeCoalescer` baseline) | Coalesces token deltas to the display refresh **without holding the first one**. |
| `IncrementalMarkdownDocument`, `StreamingMarkdown` | Splits the growing answer into closed blocks and one open tail. Blank lines inside fenced code don't close the block. Each closed block is rendered exactly once; only the tail re-renders. Every byte is scanned once. |
| `PrewarmPolicy`, `TokenBucket`, `PromptDigest` | Speculation under a budget: warms the connection on composer focus, assembles the prompt on a typing pause, discards it on the next edit, and reports hit rate and waste. |
| `RegressionGate`, `GateBaseline`, `Percentile` | Nearest-rank p50/p95 gate against a committed baseline, on the total **and per stage**. Too few samples is a failure, not a pass. |
| `FixtureReplayer`, `StreamFixture`, `FixtureByteStream` | Replays byte-exact streams through the real parser, decoder and coalescer in virtual time, deterministically, so the gate can run in CI. `FixtureByteStream` plays the same fixtures in real time for the demo. |

## Design decisions (and what was rejected)

**1. Speculation stops at the network boundary.** The policy pre-warms the connection and assembles the prompt locally, but it never sends a request before the tap. *Rejected:* speculative API calls. They bill tokens for drafts the user never sends and ship text the user may not have meant to share. Prompt assembly (system prompt, retrieval, encoding) is local work, so throwing it away costs CPU, not money or privacy. Both kinds of speculation run under token buckets, and `Stats.hitRatePermille` exists so the feature has to justify itself with data.

**2. Leading-edge coalescing, not "flush on the next display tick."** Committing every delta re-lays out the answer at token rate, so coalescing to the display refresh is right. But the common implementation (buffer everything, flush on the tick) delays the very first token by up to a frame, and the first token is the one this whole package exists for. `LeadingEdgeCoalescer` commits a delta immediately when nothing has been committed for a full frame, holds deltas that arrive inside the window, and flushes early once the buffer passes a byte cap. *Tested:* the first delta is never held; commits are at least one frame apart (outside buffer-cap flushes); concatenated commits equal concatenated input over 600 random streams.

**3. A byte-level parser, because chunk boundaries are adversarial.** A delta split across two reads is only usable when its second half arrives. `testTheNaivePerChunkParserLosesTheSplitFirstDelta` runs the obvious split-on-blank-line parser against the same fixture and shows that it silently loses the first token. The real parser's output is identical whether the stream arrives in one read or one byte at a time (tested on every fixture).

**4. Stage gates, not just a total gate.** The gate allows p50 to slip 5% and p95 10%, plus 2 ms. On a ~520 ms total, that tolerance swallows losing prompt speculation (about 35 ms) and a one-frame render regression (about 15 ms). `TTFTGateTests` shows both pass the total gate and fail their stage gate. *Rejected:* tightening the total until it catches them. That makes the gate flaky on the stages nobody on the client team controls.

**5. Deterministic replay in CI, not wall-clock benchmarks.** CI runners are noisy, shared and slow. A wall-clock TTFT gate there is a random-number generator with a red badge. The replayer runs the real parsing and coalescing code under virtual time with seeded jitter, so the committed baseline is exact (`GateBaseline(samples:) == TTFTBaseline.total` is asserted). *The trade-off:* it cannot see CPU cost (see limits).

**6. Saturating arithmetic everywhere.** Timestamps come from three sources (a monotonic clock, fixtures, tests), and a latency library that traps on `a - b` when a mark arrives early is worse than none. All nanosecond arithmetic goes through `Saturating` (`add` / `sub` / `mul`, and a full-width `scale` that cannot overflow in the middle of a calculation). There are no force-unwraps in the library.

## Verification

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build`: 0 warnings, 0 errors (Swift 6.4.2, Xcode 27.2, on the author's Mac).
- `swift test`: **89 tests, 0 failures**. They include the regression gate against the committed baseline, and deliberately broken configurations that must fail it.
- **Mutation check** (`Scripts/mutation_check.py`, also a CI job): 10 mutants, each removing one guard (leading-edge commit, CRLF join, oversize-event drop, stage clamping, fence tracking, render-once cache, stale-speculation discard, nearest-rank ceiling, digest matching, insufficient-samples-is-not-a-pass). Each mutant must compile, and its test class must then fail. All 10 are killed.
- CI ([Actions](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml)) has three `macos-15` jobs: build and test with warnings as errors; an iOS Simulator SDK build (`generic/platform=iOS Simulator`); and the mutation check.
- The companion demo app was built against this package, resolved from GitHub at the released tag, and run on an iOS 27.2 Simulator. The demo README has the screenshots and the exact run record.

## Honest limits

- **The replay models the pre-stream stages.** Request build, connection and server queue costs come from `NetworkProfile.cellular`, whose numbers are illustrative, not measured. What the replay runs for real is SSE framing, chunk boundaries, JSON decoding, which deltas carry visible text, and coalescer timing against display frames.
- **CPU cost is zero in virtual time**, so the CI gate cannot catch a parser that got slower. That is what the signposts are for: profile on a device in Instruments.
- **"First glyph" is a model in the replay** (the first display refresh after the commit). In a live app it is stamped when the committed text reaches the view model. Pixels land on the next refresh, so a live render stage reads up to one frame short.
- **No networking client is shipped.** The seam is "any `AsyncSequence` of byte chunks" (for example `URLSession.bytes(for:)` mapped to chunks), and the app marks `connectionReady` / `headersReceived` from its own networking layer. Mapping `URLSessionTaskTransactionMetrics` onto milestones is left to the integrator.
- **No MetricKit integration**, and no XCTest `measure` baselines. Field percentiles need your own telemetry pipeline.
- `StreamPipeline`'s output stream buffers without bound, by design (a dropped text delta is data loss). Don't attach a consumer that can stall for seconds.
- The Markdown splitter knows paragraphs and fenced code. Inside a block, rendering is Foundation's inline parser. A very long fenced code block is one open block, so it re-renders on every commit until it closes.
- The open tail block is re-rendered on every commit. That cost is bounded by block size, not answer size, but it is not zero.

## Use it

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/first-token-budget-kit.git", from: "1.0.0"),
]
```

```swift
import FirstToken

let instrument = TTFTInstrument()             // SystemClock + os_signpost
await instrument.mark(.sendCommitted)
// ... your networking layer marks .requestBuilt, .connectionReady, .headersReceived

var coalescer = LeadingEdgeCoalescer()
var markdown = StreamingMarkdown()
var sawText = false
for try await delta in StreamPipeline.deltas(from: chunks) {   // chunks: AsyncSequence of [UInt8]
    guard let text = delta.text else { continue }
    if !sawText { sawText = true; await instrument.mark(.firstTextDelta) }
    if let ready = coalescer.ingest(text, at: SystemClock().now()) {
        markdown.append(ready)                 // also call coalescer.frame(at:) on each display refresh
        // when `ready` contains a visible character: await instrument.mark(.firstGlyphRendered)
    }
}
if let breakdown = await instrument.breakdown() {
    let report = TTFTBudget.interactiveChat.evaluate(breakdown)
}
```

## License

MIT
