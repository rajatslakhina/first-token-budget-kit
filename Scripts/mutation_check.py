#!/usr/bin/env python3
"""Apply each mutant to the library, run the test class that guards it, and require that
the test FAILS. A guard whose mutant survives is a guard no test is actually checking.

Run from the package root: python3 Scripts/mutation_check.py
"""
import pathlib
import subprocess
import sys

MUTANTS = [
    ("leading-edge commits the first delta immediately",
     "Sources/FirstToken/Coalescing.swift",
     "if buffer.isEmpty, windowIsOpen(at: now) {", "if false {", "CoalescingTests"),
    ("a CRLF split across reads is one terminator",
     "Sources/FirstToken/SSEParser.swift",
     "if byte == 0x0A { continue } // second half of a CRLF", "", "SSEParserTests"),
    ("oversize events are dropped whole, never truncated",
     "Sources/FirstToken/SSEParser.swift",
     "if eventPoisoned {\n            oversizeEventsDropped", "if false {\n            oversizeEventsDropped", "SSEParserTests"),
    ("stages telescope over clamped milestones",
     "Sources/FirstToken/Timeline.swift",
     "let effectiveEnd = max(rawEnd, effectivePrevious)", "let effectiveEnd = rawEnd", "TimelineTests"),
    ("blank lines inside a fence do not close the block",
     "Sources/FirstToken/StreamingMarkdown.swift",
     "if fenceByte == nil, blockHasContent {", "if blockHasContent {", "MarkdownTests"),
    ("closed blocks are rendered once",
     "Sources/FirstToken/StreamingMarkdown.swift",
     "for index in renderedClosed.count..<closed.count {", "renderedClosed.removeAll()\n            for index in 0..<closed.count {", "MarkdownTests"),
    ("an edit discards a stale speculative prompt",
     "Sources/FirstToken/Prewarm.swift",
     "return discardIfStale(keeping: digest)\n        case let .typingPaused", "return []\n        case let .typingPaused", "PrewarmTests"),
    ("nearest rank rounds up",
     "Sources/FirstToken/RegressionGate.swift",
     "let rank = remainder == 0 ? quotient : quotient + 1", "let rank = quotient", "GateTests"),
    ("a send uses the speculative prompt only when digests match",
     "Sources/FirstToken/Prewarm.swift",
     "case .some(digest):", "case .some:", "PrewarmTests"),
    ("insufficient samples is not a pass",
     "Sources/FirstToken/RegressionGate.swift",
     "public var passed: Bool { status == .pass }", "public var passed: Bool { status != .fail }", "GateTests"),
]


def main() -> int:
    survivors = []
    for name, path, old, new, test in MUTANTS:
        file = pathlib.Path(path)
        original = file.read_text()
        if original.count(old) != 1:
            print(f"BROKEN MUTANT (pattern not found exactly once): {name}")
            return 2
        file.write_text(original.replace(old, new, 1))
        try:
            # A mutant that does not compile proves nothing about the tests: require a clean
            # build first, then a test failure.
            build = subprocess.run(["swift", "build", "--build-tests"], capture_output=True, text=True)
            if build.returncode != 0:
                print(f"BROKEN MUTANT (does not compile): {name}\n{build.stdout[-2000:]}{build.stderr[-2000:]}")
                return 2
            result = subprocess.run(["swift", "test", "--skip-build", "--filter", test], capture_output=True, text=True)
        finally:
            file.write_text(original)
        killed = result.returncode != 0
        print(f"{'KILLED ' if killed else 'SURVIVED'}  {name}  ({test})")
        if not killed:
            survivors.append(name)
    print(f"\n{len(MUTANTS) - len(survivors)}/{len(MUTANTS)} mutants killed")
    return 1 if survivors else 0


if __name__ == "__main__":
    sys.exit(main())
