import XCTest
@testable import CodexHUDCore

final class RolloutTelemetryTests: XCTestCase {
    func testUsageEventUsesCurrentTurnTotalAndIgnoresThreadLifetimeTotal() throws {
        let line = #"{"type":"token_usage_record","payload":{"thread_id":"thread-a","turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":12},"turn_token_usage":{"input_tokens":8,"cached_input_tokens":3,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":12},"thread_token_usage":{"total_tokens":91}}}"#

        let event = try XCTUnwrap(RolloutLineDecoder.decode(line))
        guard case let .usage(record) = event else {
            return XCTFail("Expected a usage event")
        }
        XCTAssertEqual(record.turnID, "turn-a")
        XCTAssertEqual(record.threadID, "thread-a")
        XCTAssertNil(record.rootTurnID)
        XCTAssertEqual(record.responseID, "response-a")
        XCTAssertEqual(record.totalTokens, 12)
    }

    func testSubagentUsageIsHighWaterAggregatedOnlyForLinkedParentTurn() throws {
        var ledger = SubagentUsageLedger()
        let childTurnA = TokenUsageRecord(threadID: "child-a", turnID: "child-turn-a", rootTurnID: "parent-turn", responseID: "r1", totalTokens: 12)
        let childTurnB = TokenUsageRecord(threadID: "child-a", turnID: "child-turn-a", rootTurnID: "parent-turn", responseID: "r1", totalTokens: 15)
        let anotherChildTurn = TokenUsageRecord(threadID: "child-b", turnID: "child-turn-b", rootTurnID: "parent-turn", responseID: "r2", totalTokens: 8)
        let unrelated = TokenUsageRecord(threadID: "child-c", turnID: "child-turn-c", rootTurnID: "other-parent", responseID: "r3", totalTokens: 99)
        let parentRecord = TokenUsageRecord(threadID: "parent-thread", turnID: "parent-turn", rootTurnID: "parent-turn", responseID: "r4", totalTokens: 20)

        [childTurnA, childTurnB, childTurnB, anotherChildTurn, unrelated, parentRecord].forEach { ledger.consume($0) }

        XCTAssertEqual(ledger.totalTokens(rootTurnID: "parent-turn", excludingThreadID: "parent-thread"), 23)
        XCTAssertEqual(ledger.totalTokens(rootTurnID: "other-parent", excludingThreadID: "parent-thread"), 99)
    }

    func testSubagentLedgerRejectsOwnershipConflictAndKeepsArchivedChildUsage() {
        var ledger = SubagentUsageLedger()
        ledger.consume(.init(threadID: "child-a", turnID: "child-turn-a", rootTurnID: "parent-turn", responseID: "r1", totalTokens: 15))
        ledger.consume(.init(threadID: "child-a", turnID: "child-turn-a", rootTurnID: "other-parent", responseID: "r2", totalTokens: 100))

        XCTAssertEqual(ledger.totalTokens(rootTurnID: "parent-turn", excludingThreadID: "parent-thread"), 15)
        ledger.retain(rootTurnID: "parent-turn")
        XCTAssertEqual(ledger.totalTokens(rootTurnID: "parent-turn", excludingThreadID: "parent-thread"), 15)
    }

    func testTaskTokenFormattingIsCompactAndStable() {
        XCTAssertEqual(TaskTokenFormatter.string(943), "943 tok")
        XCTAssertEqual(TaskTokenFormatter.string(12_400), "12.4K tok")
        XCTAssertEqual(TaskTokenFormatter.string(1_260_000), "1.26M tok")
        XCTAssertEqual(TaskTokenFormatter.string(-1), "— tok")
    }

    func testDesktopParentTaskUsesTurnTotalPlusLinkedChildHighWaterAndResets() {
        let desktop = RolloutSessionMetadata(threadID: "parent-thread", isCodexDesktop: true, isVSCodeSource: true, isSubagent: false)
        var parent = TurnUsageTracker()
        var childLedger = SubagentUsageLedger()
        parent.consume(.sessionMetadata(desktop))
        parent.consume(.taskStarted(turnID: "parent-turn", startedAtMilliseconds: 1_700_000_000_000))
        parent.consume(.turnContext(turnID: "parent-turn", model: "gpt-6.1-sol", effort: "xhigh"))
        parent.consume(.usage(.init(threadID: "parent-thread", turnID: "parent-turn", rootTurnID: "parent-turn", responseID: "p1", totalTokens: 100)))
        childLedger.consume(.init(threadID: "child-thread", turnID: "child-turn", rootTurnID: "parent-turn", responseID: "c1", totalTokens: 15))

        let selected = AuthoritativeTurnSelector.select([
            ActiveTurnCandidate(
                threadID: desktop.threadID,
                turnID: "parent-turn",
                startedAtMilliseconds: parent.snapshot.startedAtMilliseconds,
                totalTokens: parent.snapshot.totalTokens,
                model: parent.snapshot.model,
                effort: parent.snapshot.effort,
                isCodexDesktop: desktop.isCodexDesktop,
                isVSCodeSource: desktop.isVSCodeSource,
                isSubagent: desktop.isSubagent,
                isActive: parent.snapshot.status == .active
            ),
            candidate("child-thread", turn: "child-turn", started: 1_700_000_001_000, subagent: true),
        ])
        XCTAssertEqual(selected?.turnID, "parent-turn")
        XCTAssertEqual(
            parent.snapshot.totalTokens + childLedger.totalTokens(rootTurnID: "parent-turn", excludingThreadID: desktop.threadID),
            115
        )

        parent.consume(.taskStarted(turnID: "next-turn", startedAtMilliseconds: 1_700_000_002_000))
        XCTAssertEqual(parent.snapshot.totalTokens, 0)
        XCTAssertEqual(childLedger.totalTokens(rootTurnID: "next-turn", excludingThreadID: desktop.threadID), 0)
        parent.consume(.taskCompleted(turnID: "next-turn"))
        XCTAssertEqual(parent.snapshot.status, .complete)
    }

    func testMalformedOrPartialLinesAreIgnored() {
        XCTAssertNil(RolloutLineDecoder.decode("{\"type\":\"token_usage_record\""))
        XCTAssertNil(RolloutLineDecoder.decode(#"{"type":"token_usage_record","payload":{"turn_id":"turn-a","turn_token_usage":{"total_tokens":-1}}}"#))
        XCTAssertNil(RolloutLineDecoder.decode(#"{"type":"unknown_event","payload":{"text":"not telemetry"}}"#))
    }

    func testTaskLifecycleAndTurnContextAreTyped() throws {
        let started = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":1234}}"#))
        let context = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"turn_context","payload":{"turn_id":"turn-a","model":"gpt-6.1-sol","effort":"xhigh"}}"#))
        let completed = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#))

        XCTAssertEqual(started, .taskStarted(turnID: "turn-a", startedAtMilliseconds: 1_234_000))
        XCTAssertEqual(context, .turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "xhigh"))
        XCTAssertEqual(completed, .taskCompleted(turnID: "turn-a"))
    }

    func testTaskStartUnixSecondsConvertToMillisecondsWithoutOverflow() throws {
        let representative = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":1700000000}}"#))
        let tooLarge = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":9223372036854776}}"#))

        XCTAssertEqual(representative, .taskStarted(turnID: "turn-a", startedAtMilliseconds: 1_700_000_000_000))
        XCTAssertEqual(tooLarge, .taskStarted(turnID: "turn-a", startedAtMilliseconds: nil))
    }

    func testSessionMetadataDistinguishesDesktopRootFromSubagent() throws {
        let desktop = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"session_meta","payload":{"id":"thread-root","originator":"Codex Desktop","source":"vscode"}}"#))
        let subagent = try XCTUnwrap(RolloutLineDecoder.decode(#"{"type":"session_meta","payload":{"id":"thread-child","originator":"Codex Desktop","source":{"subagent":{}}}}"#))

        XCTAssertEqual(desktop, .sessionMetadata(.init(threadID: "thread-root", isCodexDesktop: true, isVSCodeSource: true, isSubagent: false)))
        XCTAssertEqual(subagent, .sessionMetadata(.init(threadID: "thread-child", isCodexDesktop: true, isVSCodeSource: false, isSubagent: true)))
    }

    func testSelectorChoosesMostRecentlyStartedActiveDesktopMainTurn() {
        let older = candidate("thread-a", turn: "turn-a", started: 1_700_000_000_000)
        let newest = candidate("thread-b", turn: "turn-b", started: 1_700_000_002_000)
        let subagent = candidate("thread-c", turn: "turn-c", started: 1_700_000_003_000, subagent: true)
        let completed = candidate("thread-d", turn: "turn-d", started: 1_700_000_004_000, active: false)

        XCTAssertEqual(AuthoritativeTurnSelector.select([completed, subagent, older, newest]), newest)
    }

    func testSelectorUsesStableTieBreakAndRejectsUnrankableMultipleActiveTurns() {
        let laterID = candidate("thread-z", turn: "turn-z", started: 1_700_000_000_000)
        let earlierID = candidate("thread-a", turn: "turn-a", started: 1_700_000_000_000)
        XCTAssertEqual(AuthoritativeTurnSelector.select([laterID, earlierID]), earlierID)

        let unranked = candidate("thread-b", turn: "turn-b", started: nil)
        XCTAssertNil(AuthoritativeTurnSelector.select([earlierID, unranked]))
    }

    func testIPCCompletedTurnCannotBeReselectedFromStaleActiveRollout() {
        let metadata = RolloutSessionMetadata(threadID: "thread-a", isCodexDesktop: true, isVSCodeSource: true, isSubagent: false)
        var usage = TurnUsageTracker()
        usage.consume(.sessionMetadata(metadata))
        usage.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: 1_700_000_000_000))

        usage.consume(.taskCompleted(turnID: "turn-a"))
        let completedCandidate = candidate(
            metadata,
            turn: usage.snapshot.turnID!,
            started: usage.snapshot.startedAtMilliseconds,
            active: ActiveTurnEligibility.shouldFollow(
                rolloutStatus: usage.snapshot.status,
                desktopTurnStatus: .completed
            )
        )
        XCTAssertEqual(usage.snapshot.status, .complete)
        XCTAssertNil(AuthoritativeTurnSelector.select([completedCandidate]))

        usage.consume(.taskStarted(turnID: "turn-b", startedAtMilliseconds: 1_700_000_001_000))
        let nextCandidate = candidate(
            metadata,
            turn: "turn-b",
            started: usage.snapshot.startedAtMilliseconds,
            active: ActiveTurnEligibility.shouldFollow(
                rolloutStatus: usage.snapshot.status,
                desktopTurnStatus: .inProgress
            )
        )
        XCTAssertEqual(AuthoritativeTurnSelector.select([nextCandidate]), nextCandidate)
    }

    func testSameTurnRuntimePauseDoesNotRevokeFollowerEligibility() {
        XCTAssertTrue(ActiveTurnEligibility.shouldFollow(rolloutStatus: .active, desktopTurnStatus: .inProgress))
        XCTAssertTrue(ActiveTurnEligibility.shouldFollow(rolloutStatus: .active, desktopTurnStatus: nil))
        XCTAssertFalse(ActiveTurnEligibility.shouldFollow(rolloutStatus: .active, desktopTurnStatus: .completed))
        XCTAssertFalse(ActiveTurnEligibility.shouldFollow(rolloutStatus: .complete, desktopTurnStatus: .inProgress))
    }

    private func candidate(
        _ threadID: String,
        turn: String,
        started: Int?,
        active: Bool = true,
        subagent: Bool = false
    ) -> ActiveTurnCandidate {
        ActiveTurnCandidate(
            threadID: threadID,
            turnID: turn,
            startedAtMilliseconds: started,
            totalTokens: 0,
            model: "gpt-6.1-sol",
            effort: "xhigh",
            isCodexDesktop: true,
            isVSCodeSource: !subagent,
            isSubagent: subagent,
            isActive: active
        )
    }

    private func candidate(
        _ metadata: RolloutSessionMetadata,
        turn: String,
        started: Int?,
        active: Bool
    ) -> ActiveTurnCandidate {
        ActiveTurnCandidate(
            threadID: metadata.threadID,
            turnID: turn,
            startedAtMilliseconds: started,
            totalTokens: 0,
            model: nil,
            effort: nil,
            isCodexDesktop: metadata.isCodexDesktop,
            isVSCodeSource: metadata.isVSCodeSource,
            isSubagent: metadata.isSubagent,
            isActive: active
        )
    }

    func testUsageIsMonotonicDeduplicatedAndResetForANewTask() throws {
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: 1))
        tracker.consume(.usage(.init(turnID: "turn-a", responseID: "r1", totalTokens: 12)))
        tracker.consume(.usage(.init(turnID: "turn-a", responseID: "r1", totalTokens: 12)))
        tracker.consume(.usage(.init(turnID: "turn-a", responseID: "r1", totalTokens: 15)))
        tracker.consume(.usage(.init(turnID: "turn-a", responseID: "r0", totalTokens: 8)))
        XCTAssertEqual(tracker.snapshot.totalTokens, 15)

        tracker.consume(.taskStarted(turnID: "turn-b", startedAtMilliseconds: 2))
        XCTAssertEqual(tracker.snapshot.turnID, "turn-b")
        XCTAssertEqual(tracker.snapshot.totalTokens, 0)
        XCTAssertEqual(tracker.snapshot.status, .active)
    }
}
