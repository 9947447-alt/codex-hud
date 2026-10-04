import XCTest
@testable import CodexHUDCore

final class TokenizerAndSpeedTests: XCTestCase {
    func testCanonicalO200kReferenceCounts() throws {
        let tokenizer = try O200kTokenizer()
        let cases: [(String, Int)] = [
            ("", 0),
            ("hello", 1),
            ("hello world", 2),
            ("Hello, world!", 4),
            ("你好世界", 2),
            ("😀", 1),
            ("😀你好", 2),
            ("let x = 42\n", 6),
            ("1234567890", 4),
            ("a\nb\r\nc", 5),
            ("   ", 1),
            ("é é", 3),
            ("你好，世界！", 4),
            ("RUNNING COMMAND", 3),
            ("TASK 238.6K tok", 7),
            ("I'm testing tokenizer boundaries.", 5),
            ("<|im_start|>", 6),
            ("<|im_start|>普通文本", 8),
        ]

        for (text, expected) in cases {
            XCTAssertEqual(tokenizer.countTokens(in: text), expected, "Unexpected o200k count for synthetic text: \(text)")
        }
    }

    func testSpeedUsesOnlyLiveAgentTextAndActualElapsedTime() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 10, uptime: 100)
        XCTAssertNil(meter.speed(at: 100))

        meter.accept(
            revision: 11,
            item: item,
            kind: .agentMessage,
            edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"),
            updatedText: "base x",
            uptime: 101
        )
        XCTAssertEqual(meter.speed(at: 101) ?? -1, 1, accuracy: 0.001)

        meter.accept(
            revision: 12,
            item: item,
            kind: .agentMessage,
            edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"),
            updatedText: "base x y",
            uptime: 102
        )
        XCTAssertEqual(meter.speed(at: 102) ?? -1, 1, accuracy: 0.001)
        XCTAssertNil(meter.speed(at: 105.1), "A quiet stream must expire instead of showing a completed-turn average")
    }

    func testSnapshotReplayCorrectionsAndNewItemNeverCountAsLiveOutput() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 1)
        XCTAssertEqual(meter.speed(at: 1) ?? -1, 1, accuracy: 0.001)

        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 1)
        XCTAssertEqual(meter.speed(at: 1) ?? -1, 1, accuracy: 0.001, "A replayed revision must not count twice")

        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 0, deleteCountUTF16: 1, insert: "B"), updatedText: "Base x", uptime: 2)
        XCTAssertNil(meter.speed(at: 2), "An edit/correction resets the baseline")

        let nextItem = identity("item-b")
        meter.accept(revision: 4, item: nextItem, kind: .agentMessage, edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"), updatedText: "Base x y", uptime: 3)
        XCTAssertNil(meter.speed(at: 3), "A new item starts with a baseline")
    }

    func testOneRevisionCanContainMultipleOrderedAppendEdits() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(
            revision: 2,
            item: item,
            kind: .agentMessage,
            edits: [
                .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"),
                .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"),
            ],
            updatedText: "base x y",
            uptime: 1
        )

        XCTAssertEqual(meter.speed(at: 1) ?? -1, 2, accuracy: 0.001)
    }

    func testContinuousBatchMayAdvanceSeveralRevisionsWithoutDroppingRate() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 10, uptime: 100)
        meter.accept(
            revision: 13,
            item: item,
            kind: .agentMessage,
            edits: [.init(atUTF16: 4, deleteCountUTF16: 0, insert: " x")],
            updatedText: "base x",
            uptime: 101,
            isContinuous: true
        )
        XCTAssertEqual(meter.speed(at: 101) ?? -1, 1, accuracy: 0.001)
        meter.advance(revision: 17, isContinuous: true)
        XCTAssertEqual(meter.speed(at: 102) ?? -1, 0.5, accuracy: 0.001)
    }

    func testLongIdleThenResumeStartsNewSpeedBaseline() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 1)
        XCTAssertNil(meter.speed(at: 4.1))

        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"), updatedText: "base x y", uptime: 5)
        XCTAssertNil(meter.speed(at: 5), "The first patch after a long pause is only a new baseline")
        meter.accept(revision: 4, item: item, kind: .agentMessage, edit: .init(atUTF16: 8, deleteCountUTF16: 0, insert: " z"), updatedText: "base x y z", uptime: 6)
        XCTAssertEqual(meter.speed(at: 6) ?? -1, 1, accuracy: 0.001)
    }

    func testSlidingWindowDropsOutsideSamplesWithoutTreatingActiveStreamAsIdle() {
        var meter = OutputSpeedMeter(tokenCounter: FixtureTokenCounter(), windowSeconds: 3, idleTimeoutSeconds: 10)
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 1)
        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"), updatedText: "base x y", uptime: 2)
        meter.accept(revision: 4, item: item, kind: .agentMessage, edit: .init(atUTF16: 8, deleteCountUTF16: 0, insert: " z"), updatedText: "base x y z", uptime: 3.5)
        meter.accept(revision: 5, item: item, kind: .agentMessage, edit: .init(atUTF16: 10, deleteCountUTF16: 0, insert: " q"), updatedText: "base x y z q", uptime: 4.1)

        XCTAssertEqual(meter.speed(at: 4.1) ?? -1, 1, accuracy: 0.001, "The t=1 sample is outside the 3-second window; the later stream remained below the separate idle timeout")
    }

    func testDenseAcceptedSamplesAreBucketedWithoutLosingWindowTokens() {
        var meter = OutputSpeedMeter(tokenCounter: ByteTokenCounter(), windowSeconds: 3, idleTimeoutSeconds: 10)
        let item = identity("item-a")
        var text = ""
        meter.establishBaseline(item: item, fullText: text, revision: 0, uptime: 0)

        for index in 1...200 {
            let nextText = text + "x"
            meter.accept(
                revision: UInt64(index),
                item: item,
                kind: .agentMessage,
                edit: .init(atUTF16: index - 1, deleteCountUTF16: 0, insert: "x"),
                updatedText: nextText,
                uptime: Double(index) / 200,
                isContinuous: true
            )
            text = nextText
        }

        XCTAssertLessThanOrEqual(meter.sampleCountForTesting, 128)
        XCTAssertLessThan(meter.sampleCountForTesting, 128, "100 ms buckets keep dense 3-second samples below the bound")
        let rate = meter.speed(at: 1.01)
        XCTAssertNotNil(rate)
        XCTAssertTrue(rate?.isFinite == true)
        XCTAssertGreaterThan(rate ?? -1, 0)
        XCTAssertEqual(rate ?? -1, 200 / 1.01, accuracy: 0.1, "All 200 in-window accepted tokens must survive sample compaction")
    }

    func testO200kCountContinuesAcrossPatchBoundaryMerges() throws {
        let tokenizer = try O200kTokenizer()
        XCTAssertEqual(tokenizer.countTokens(in: "hel"), 1)
        XCTAssertEqual(tokenizer.countTokens(in: "hello"), 1)

        var meter = OutputSpeedMeter(tokenCounter: tokenizer)
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "hel", revision: 1, uptime: 0)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 3, deleteCountUTF16: 0, insert: "lo"), updatedText: "hello", uptime: 1)
        XCTAssertNil(meter.speed(at: 1), "The snapshot prefix is not output and a BPE merge must not double-count")
        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 5, deleteCountUTF16: 0, insert: " world"), updatedText: "hello world", uptime: 2)
        XCTAssertEqual(meter.speed(at: 2) ?? -1, 0.5, accuracy: 0.001)
    }

    func testOversizedAppendIsSkippedAndRebaselined() {
        let counter = FixtureTokenCounter()
        var meter = OutputSpeedMeter(tokenCounter: counter, maxAppendBytes: 256)
        let item = identity("item-a")
        let oversized = String(repeating: "x", count: 257)
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(
            revision: 2,
            item: item,
            kind: .agentMessage,
            edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: oversized),
            updatedText: "base" + oversized,
            uptime: 1
        )

        XCTAssertNil(meter.speed(at: 1))
    }

    func testRevisionGapAndToolPauseRequireANewBaseline() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 0)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 1)
        XCTAssertEqual(meter.speed(at: 1) ?? -1, 1, accuracy: 0.001)

        meter.advance(revision: 4)
        XCTAssertNil(meter.speed(at: 1.1), "A revision gap invalidates the live-rate baseline")
        meter.accept(revision: 5, item: item, kind: .agentMessage, edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"), updatedText: "base x y", uptime: 2)
        XCTAssertNil(meter.speed(at: 2), "The first post-gap text patch is a new baseline")

        meter.accept(revision: 6, item: item, kind: .agentMessage, edit: .init(atUTF16: 8, deleteCountUTF16: 0, insert: " z"), updatedText: "base x y z", uptime: 3)
        XCTAssertEqual(meter.speed(at: 3) ?? -1, 1, accuracy: 0.001)
        meter.setToolRunning(true)
        XCTAssertNil(meter.speed(at: 3.1))
        meter.setToolRunning(false)
        meter.accept(revision: 7, item: item, kind: .agentMessage, edit: .init(atUTF16: 10, deleteCountUTF16: 0, insert: " q"), updatedText: "base x y z q", uptime: 4)
        XCTAssertNil(meter.speed(at: 4), "Tool completion restarts with a baseline")
    }

    func testReasoningAndInvalidClockValuesCannotProduceSpeed() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 1)
        meter.accept(revision: 2, item: item, kind: .reasoning, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " secret"), updatedText: "base secret", uptime: 2)
        XCTAssertNil(meter.speed(at: 2))

        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 11, deleteCountUTF16: 0, insert: " x"), updatedText: "base secret x", uptime: .nan)
        XCTAssertNil(meter.speed(at: .infinity))
        XCTAssertNil(meter.speed(at: -1))
    }

    func testBackwardAndZeroDeltaClocksCannotProduceInvalidRates() {
        var meter = makeMeter()
        let item = identity("item-a")
        meter.establishBaseline(item: item, fullText: "base", revision: 1, uptime: 10)
        meter.accept(revision: 2, item: item, kind: .agentMessage, edit: .init(atUTF16: 4, deleteCountUTF16: 0, insert: " x"), updatedText: "base x", uptime: 11)
        XCTAssertEqual(meter.speed(at: 11) ?? -1, 1, accuracy: 0.001)

        meter.accept(revision: 3, item: item, kind: .agentMessage, edit: .init(atUTF16: 6, deleteCountUTF16: 0, insert: " y"), updatedText: "base x y", uptime: 10.5)
        XCTAssertNil(meter.speed(at: 10.5), "A backward clock resets the baseline")
        meter.accept(revision: 4, item: item, kind: .agentMessage, edit: .init(atUTF16: 8, deleteCountUTF16: 0, insert: " z"), updatedText: "base x y z", uptime: 10.5)
        XCTAssertNil(meter.speed(at: 10.5), "A zero elapsed interval must not produce a rate")
    }

    private func makeMeter() -> OutputSpeedMeter {
        let counter = FixtureTokenCounter()
        return OutputSpeedMeter(tokenCounter: counter)
    }

    private func identity(_ itemID: String) -> LiveItemIdentity {
        LiveItemIdentity(hostID: "local", threadID: "thread-a", entityKey: "turn-a", itemID: itemID)
    }
}

private struct FixtureTokenCounter: TokenCounter {
    private let counts: [String: Int] = [
        "": 0,
        "base": 4,
        "base x": 5,
        "base x y": 6,
        "base x y z": 7,
        "base x y z q": 8,
        "Base x": 5,
        "Base x y": 6,
    ]

    func countTokens(in text: String) -> Int { counts[text] ?? 0 }
}

private struct ByteTokenCounter: TokenCounter {
    func countTokens(in text: String) -> Int { text.utf8.count }
}
