# FirstToken

**Treat time-to-first-token as an engineering budget, not a model property.**

[![CI](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![iOS 18+ · macOS 15+](https://img.shields.io/badge/platforms-iOS%2018%2B%20%C2%B7%20macOS%2015%2B-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

When an LLM feature feels slow, the number users feel is the gap between tapping send and seeing the first word. Most iOS teams can't tell you where that time goes, so "make it faster" ends up as a ticket for the model team. This package splits time-to-first-token (TTFT) into five stages, gives each one an owner and a budget, removes the client-side costs that are avoidable, and fails CI when a stage regresses.

In the replay harness (cellular profile, 4 streams × 10 seeds, the same network draws for every configuration), the naive client lands at **p50 800 ms / p95 902 ms**. The pipeline in this package lands at **p50 500 ms / p95 591 ms**, with the server unchanged. Those numbers come from a deterministic simulation, not a device measurement; [Honest limits](#honest-limits) says exactly what is real and what is modelled.

<p align="center"><img src="https://raw.githubusercontent.com/rajatslakhina/first-token-budget-demo-app/main/Demo/Screenshots/1-waterfall.png" width="300" alt="The demo's waterfall: four client configurations with per-stage bars, p50/p95 and regression-gate verdicts"></p>

Demo app: **[first-token-budget-demo-app](https://github.com/rajatslakhina/first-token-budget-demo-app)**. It pulls this package from GitHub as a remote dependency (1.3.1 up to the next major) and runs the whole pipeline on a Simulator: a replayed waterfall, a live stream, and the speculation policy.

## Why this matters

Model providers now rewrite serving stacks to shave first-token latency: Anthropic's [write-up on migrating its Messages API to Rust](https://www.anthropic.com/research/migrating-api-to-rust) reports about 20% lower median time to first token. That is the number users feel. On a phone, though, much of the TTFT is spent before the request reaches the provider, or after the first byte comes back:

| Stage | From → to | Who owns it |
|---|---|---|
| request build | send tapped → request encoded | feature team (prompt assembly, retrieval, encoding) |
| connection | request built → connection ready | networking platform (DNS, TCP, TLS, reuse) |
| server queue | connection ready → response headers | the API; the client can only observe it |
| first token | headers → first `text_delta` with a visible character parsed | the API (including whitespace-only pacing deltas) and its stream framing |
| render | that delta → its first glyph committed for display | client UI |

The deliverable is a split you can assign. "TTFT regressed 30 ms" is not actionable; "the render stage regressed one frame, and the CI gate named it" is.

## What's in it

| Type | Job |
|---|---|
| `TTFTTimeline`, `TTFTBreakdown`, `Milestone`, `Stage` | Six milestones → five stage durations. First write wins per milestone. Prepaid milestones (`requestBuilt` / `connectionReady` reached *before* the tap) cost zero and are flagged. A post-send milestone stamped earlier than its predecessor is clamped and reported as an ordering violation. **Invariant (tested over 2,000 random timelines): the stages sum exactly to the total.** |
| `TTFTInstrument` | An actor that stamps milestones from a `MonotonicClock` (or takes a caller's synchronous reading via `mark(_:at:)`, so the actor hop isn't charged to a stage) and mirrors them to `os_signpost`: one point event per milestone and one interval per request, so TTFT shows up in Instruments next to main-thread work. |
| `TTFTBudget`, `BudgetReport` | A total plus per-stage caps. Reports overruns, the excess over the total, and the dominant stage. `serverQueue` is left unbudgeted on purpose. |
| `SSEParser` | Incremental, byte-level `text/event-stream` parser, written from the WHATWG spec: LF/CR/CRLF (including a CRLF split across reads), BOM, comments, multi-line `data:`, last-event-ID, and bounded memory. A line or an event (join separators included) longer than `maxEventBytes` drops the whole event; it is never delivered truncated. |
| `AnthropicEventDecoder`, `StreamDelta` | Messages-API stream events → `text`, `messageStart`, `ping`, `blockStop`, `messageStop`, in-stream `serverError`, `ignored` (thinking/tool deltas), `malformed`. |
| `StreamPipeline.deltas(from:)` / `deltas(bytes:)` | An `AsyncSequence` of byte chunks, or a factory for a byte sequence such as `URLSession.AsyncBytes`, → `AsyncThrowingStream<StreamDelta>`. Parsing runs on a detached task, never on the caller's actor (tested with a probe inside the parse step while consuming from `@MainActor`). Cancelling the consumer stops the source being pulled (tested on both paths, including a byte source that ignores cancellation). |
| `LeadingEdgeCoalescer` (+ `TrailingEdgeCoalescer` baseline) | Coalesces token deltas to the display refresh **without holding the first one**. |
| `IncrementalMarkdownDocument`, `StreamingMarkdown` | Splits the growing answer into closed blocks and one open tail. Blank lines inside fenced code don't close the block, and fences close by CommonMark's rule (same marker, at least as long, no info string). Each closed block is rendered exactly once; only the tail re-renders. Segmentation is linear: each byte is searched once, even across appends to an unterminated line. |
| `PrewarmPolicy`, `TokenBucket`, `PromptDigest` | Speculation under a budget: asks for a warm connection on composer focus, assembles the prompt on a typing pause, discards it on the next edit, and reports hit rate and waste. |
| `RegressionGate`, `GateBaseline`, `Percentile`, `ReplayBaseline` | Nearest-rank p50/p95 gate against a committed baseline, on the total **and per stage**. Too few samples is a failure, not a pass. `ReplayBaseline` is the committed baseline itself, public so the demo gates against the same numbers CI does; its `sampleCount` is the gate's minimum, so a regression that loses runs fails instead of being judged on the survivors. |
| `FixtureReplayer`, `StreamFixture`, `FixtureByteStream` | Replays byte-exact streams through the real parser, decoder and coalescer in virtual time, deterministically, so the gate can run in CI. Every configuration replayed with the same seed sees the same network draws (tested), so a comparison measures the client, not the dice. `FixtureByteStream` plays the same fixtures in real time for the demo; `StreamFixture.burst` sends deltas faster than a frame so coalescing is visible. |

## Design decisions (and what was rejected)

**1. The draft never leaves the device before the tap.** The policy asks for a warm connection and assembles the prompt, but it never asks for the model request early. *Rejected:* speculative API calls. They bill tokens for drafts the user never sends and ship text the user may not have meant to share. Warming is not free of signal: `URLSession` has no public pre-connect, so in practice it is a lightweight request with no draft in it (a `HEAD` to the API host, whose HTTP/2 or HTTP/3 connection the real request reuses), and the host learns that the composer opened. Prompt assembly is local work when retrieval is on-device; a *remote* retrieval call on a draft is itself speculation that ships draft text and needs the same consent rule as sending. Both kinds of speculation run under token buckets, and `Stats.hitRatePermille` exists so the feature has to justify itself with data.

**2. Leading-edge coalescing, not "flush on the next display tick."** Committing every delta re-lays out the answer at token rate, so coalescing to the display refresh is right. But the common implementation (buffer everything, flush on the tick) delays the very first token by up to a frame, and the first token is the one this whole package exists for. `LeadingEdgeCoalescer` commits a delta immediately when nothing has been committed for a full frame, holds deltas that arrive inside the window, and flushes early once the buffer reaches a byte cap. Only a commit that puts a glyph on screen spends the frame, so a whitespace-only lead (`"\n"`) can't make the first visible delta wait. *Tested:* the first visible delta is never held, including right after a whitespace lead; commits are at least one frame apart (outside buffer-cap flushes); concatenated commits equal concatenated input, in order, over 300 random streams of distinct deltas per strategy; on the `burst` fixture, under half as many commits as text deltas.

**3. A byte-level parser, because chunk boundaries are adversarial.** A delta split across two reads is only usable when its second half arrives. `testTheNaivePerChunkParserLosesTheSplitFirstDelta` runs the obvious split-on-blank-line parser against the same fixture and shows that it silently loses the first token. The real parser's output is identical whether the stream arrives in one read or one byte at a time (tested on every fixture).

**4. Stage gates, not just a total gate.** The gate allows p50 to slip 5% and p95 10%, plus 2 ms. On a ~500 ms total, that tolerance (about 27 ms at p50) swallows a one-frame render regression: switching to trailing-edge commits moves the total to p50 517 / p95 608 ms, inside the allowed 527 / 652 ms, and only the render-stage gate fails (`TTFTGateTests`). Bigger regressions fail both, and the stage gate still says whose they are: losing prompt speculation fails the total *and* names `requestBuild`; losing the connection pre-warm fails the total and names `connection`. *Rejected:* tightening the total until it catches a frame. That makes the gate flaky on the stages nobody on the client team controls.

**5. Deterministic replay in CI, not wall-clock benchmarks.** CI runners are noisy, shared and slow. A wall-clock TTFT gate there is a random-number generator with a red badge. The replayer runs the real parsing and coalescing code under virtual time with seeded jitter drawn in a fixed order, so the committed `ReplayBaseline` is exact (asserted for the total and every gated stage). *The trade-off:* it cannot see CPU cost (see limits).

**6. Saturating arithmetic everywhere.** Timestamps come from three sources (a monotonic clock, fixtures, tests), and a latency library that traps on `a - b` when a mark arrives early is worse than none. All nanosecond arithmetic goes through `Saturating` (`add` / `sub` / `mul`, and a full-width `scale` that cannot overflow in the middle of a calculation). There are no force-unwraps in the library.

## Verification

- `swift build -Xswiftc -warnings-as-errors` from a clean `.build`: 0 warnings, 0 errors (Swift 6.4.2, Xcode 27.2, on the author's Mac).
- `swift test`: **103 tests, 0 failures** (one of them, `testPrintBaselineWhenRequested`, is an opt-in baseline printer that does nothing unless `FIRSTTOKEN_PRINT_BASELINE=1`). They include the regression gate against the committed baseline, and deliberately broken configurations that must fail it.
- **Mutation check** (`Scripts/mutation_check.py`, also a CI job): 17 mutants, each removing one guard (leading-edge commit, whitespace commits not spending the frame, CRLF join, oversize-event drop, separator accounting, stage clamping, fence tracking, CommonMark fence closing, resumed newline search, render-once cache, stale-speculation discard, nearest-rank ceiling, digest matching, insufficient-samples-is-not-a-pass, unconditional network draws, cancellation on the byte path, whitespace pacing charged to the API). Each mutant must compile, and its test class must then fail. All are killed.
- CI ([Actions](https://github.com/rajatslakhina/first-token-budget-kit/actions/workflows/ci.yml)) has three `macos-15` jobs: build and test with warnings as errors; an iOS Simulator SDK build (`generic/platform=iOS Simulator`); and the mutation check.
- The companion demo app was built against this package, resolved from GitHub at the released tag, and run on an iOS 27.2 Simulator. The demo README has the screenshots and the exact run record.

## Honest limits

- **The replay models the pre-stream stages.** Request build, connection and server queue costs come from `NetworkProfile.cellular`, whose numbers are illustrative, not measured. What the replay runs for real is SSE framing, chunk boundaries, JSON decoding, which deltas carry visible text, and coalescer timing against display frames.
- **CPU cost is zero in virtual time**, so the CI gate cannot catch a parser that got slower. That is what the signposts are for: profile on a device in Instruments.
- **"First glyph" is a model in the replay** (the first display refresh after the commit). In a live app it is stamped when the committed text reaches the view model. Pixels land on the next refresh, so a live render stage reads up to one frame short.
- **No networking client is shipped.** The seam is `StreamPipeline.deltas(bytes:)` with a factory that calls `URLSession.bytes(for:)` (or `deltas(from:)` for chunked sources); the app marks `requestBuilt` / `connectionReady` from its own networking layer. Mapping `URLSessionTaskTransactionMetrics` onto milestones is left to the integrator. The byte-sequence path is tested with an `AsyncStream<UInt8>`, not against a live `URLSession`.
- **`firstTextDelta` is stamped where the consumer receives the delta.** Parsing runs off-main, but if the consuming actor is busy (layout, a keyboard animation), the parsed delta waits in the stream's buffer, and that client-side wait is counted in `firstToken` (the API's stage). The replay cannot show it (CPU time is zero there); profile it with the signposts on a device.
- **Stream completeness is the consumer's check.** `StreamPipelineError.truncated` detects bytes cut mid-event only. A stream that ends cleanly between events without `message_stop`, or carries an `error` event (`.serverError`), finishes normally; the snippet below shows the check (and throws `.endedWithoutMessageStop`, a case the pipeline itself never throws).
- **Metric clocks differ.** `URLSessionTaskTransactionMetrics` timestamps are `Date`s (wall clock), not the uptime clock the instrument uses. Convert them through a paired `Date()` / `clock.now()` reading before passing them to `mark(_:at:)`, and discard runs that span a clock change.
- **Replay and fixtures ship in the product on purpose.** `FixtureReplayer`, `StreamFixture`, `FixtureByteStream` and `sampleAnswer` are in `FirstToken` so a consuming app can run the same gate in its own CI and the demo needs one dependency. They are small and inert unless called; a later major version could split them into a separate `FirstTokenReplay` product.
- **Connection warming needs a request.** `PrewarmAction.warmConnection` is advice; how to honour it (typically a `HEAD` to the API host) is the app's code, and it is visible to that host.
- **No MetricKit integration**, and no XCTest `measure` baselines. Field percentiles need your own telemetry pipeline.
- `StreamPipeline`'s output stream buffers without bound, by design (a dropped text delta is data loss). Don't attach a consumer that can stall for seconds.
- The Markdown splitter knows paragraphs and fenced code. Inside a block, rendering is Foundation's inline parser. A very long fenced code block, or a very long paragraph, is one open block, so it re-renders on every commit until it closes.
- The open tail block is re-rendered on every commit. That cost is bounded by block size, not answer size, but it is not zero.

## Use it

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/first-token-budget-kit.git", from: "1.3.1"),
]
```

```swift
import FirstToken

// Owned by a @MainActor view model, so the display refresh can reach the coalescer too.
let instrument = TTFTInstrument()            // SystemClock + os_signpost
let clock = instrument.timeSource
var coalescer = LeadingEdgeCoalescer()
var markdown = StreamingMarkdown()
var glyphShown = false

func commit(_ text: String) async {
    markdown.append(text)                    // publish markdown.blocks to the view
    if !glyphShown, text.contains(where: { !$0.isWhitespace }) {
        glyphShown = true
        let shown = clock.now()              // read before the await, not after it
        await instrument.mark(.firstGlyphRendered, at: shown)
    }
}

// On send:
await instrument.mark(.sendCommitted, at: clock.now())
// ... mark .requestBuilt and .connectionReady from your networking layer
var sawText = false
var sawStop = false
for try await delta in StreamPipeline.deltas(bytes: {
    let (bytes, _) = try await URLSession.shared.bytes(for: request)
    await instrument.mark(.headersReceived, at: clock.now())
    return bytes
}) {
    if case let .serverError(type, message) = delta { throw ChatError.server(type, message) }  // your error type
    if delta == .messageStop { sawStop = true }
    guard let text = delta.text else { continue }
    let now = clock.now()                    // one reading for this delta
    let firstVisible = !sawText && text.contains(where: { !$0.isWhitespace })
    if firstVisible { sawText = true }
    // Commit before awaiting the instrument, so the actor round trip lands after the glyph,
    // not inside the render stage.
    if let ready = coalescer.ingest(text, at: now) { await commit(ready) }
    if firstVisible { await instrument.mark(.firstTextDelta, at: now) }
}
guard sawStop else { throw StreamPipelineError.endedWithoutMessageStop }
if let rest = coalescer.drain() { await commit(rest) }
markdown.finish()

// On every display refresh while streaming (CADisplayLink, or a frame timer):
if let ready = coalescer.frame(at: clock.now()) { await commit(ready) }

if let breakdown = await instrument.breakdown() {
    let report = TTFTBudget.interactiveChat.evaluate(breakdown)   // overruns, dominant stage
}
```

The demo's `LiveSession` is a complete, runnable version of this loop.

## License

MIT
