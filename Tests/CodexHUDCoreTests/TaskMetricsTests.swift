import XCTest
@testable import CodexHUDCore

final class TaskMetricsTests: XCTestCase {
    func testAverageUsesSettledOutputOverElapsedSettlementTime() throws {
        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 1_000,
            output: 274,
            settledAt: started + 10_000
        )))

        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(metrics.averageOutputTokensPerSecond ?? -1, 27.4, accuracy: 0.000_000_1)
        XCTAssertEqual(TaskMetricLineFormatter.average(metrics.averageOutputTokensPerSecond), "AVG   27.4 tok/s")
        XCTAssertEqual(tracker.snapshot.outputSettledAtMilliseconds, started + 10_000)
    }

    func testAverageUnavailableBeforeAuthoritativeOutput() {
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: 1_700_000_000_000))
        let before = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertNil(before.averageOutputTokensPerSecond)
        XCTAssertEqual(TaskMetricLineFormatter.average(before.averageOutputTokensPerSecond), "AVG   — tok/s")

        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r0",
            input: 10,
            output: 0,
            settledAt: 1_700_000_004_000
        )))
        let zero = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(zero.averageOutputTokensPerSecond ?? -1, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(AverageThroughputFormatter.string(zero.averageOutputTokensPerSecond), "0.0 tok/s")
    }

    func testAverageDoesNotChangeWhenWallTimeAdvancesWithoutNewOutput() {
        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 100,
            output: 274,
            settledAt: started + 10_000
        )))
        let first = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )

        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r2",
            input: 400,
            output: 0,
            turnInput: 500,
            turnOutput: 274,
            settledAt: started + 30_000
        )))
        let second = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(first.averageOutputTokensPerSecond ?? -1, 27.4, accuracy: 0.000_000_1)
        XCTAssertEqual(second.averageOutputTokensPerSecond, first.averageOutputTokensPerSecond)
        XCTAssertEqual(tracker.snapshot.settledOutputTokens, 274)
        XCTAssertEqual(tracker.snapshot.outputSettledAtMilliseconds, started + 10_000)
        XCTAssertEqual(tracker.snapshot.totalTokens, 774)
    }

    func testAverageIncludesReasoningOnlyThroughOutputTokens() {
        let started = 1_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 20,
            output: 274,
            reasoning: 200,
            settledAt: started + 10_000
        )))
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(metrics.averageOutputTokensPerSecond ?? -1, 27.4, accuracy: 0.000_000_1)
        XCTAssertNotEqual(metrics.averageOutputTokensPerSecond ?? 0, 47.4, accuracy: 0.000_000_1)
    }

    func testAverageUnavailableForNonPositiveDuration() {
        XCTAssertNil(SettledOutputThroughput.tokensPerSecond(
            outputTokens: 10,
            startedAtMilliseconds: 5_000,
            settledAtMilliseconds: 5_000
        ))
        XCTAssertNil(SettledOutputThroughput.tokensPerSecond(
            outputTokens: 10,
            startedAtMilliseconds: 5_000,
            settledAtMilliseconds: 4_000
        ))
        XCTAssertNil(SettledOutputThroughput.tokensPerSecond(
            outputTokens: 10,
            startedAtMilliseconds: nil,
            settledAtMilliseconds: 6_000
        ))
        XCTAssertNil(SettledOutputThroughput.tokensPerSecond(
            outputTokens: 10,
            startedAtMilliseconds: 5_000,
            settledAtMilliseconds: nil
        ))
        XCTAssertNil(SettledOutputThroughput.tokensPerSecond(
            outputTokens: -1,
            startedAtMilliseconds: 5_000,
            settledAtMilliseconds: 6_000
        ))
    }

    func testTurnSwitchResetsAverage() {
        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 10,
            output: 274,
            settledAt: started + 10_000
        )))
        let first = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(first.averageOutputTokensPerSecond ?? -1, 27.4, accuracy: 0.000_000_1)

        tracker.consume(.taskStarted(turnID: "turn-b", startedAtMilliseconds: started + 20_000))
        let reset = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertNil(reset.averageOutputTokensPerSecond)
        XCTAssertEqual(tracker.snapshot.totalTokens, 0)
        XCTAssertNil(tracker.snapshot.settledOutputTokens)
    }

    func testParentPlusChildDoesNotDoubleCount() {
        let started = 1_700_000_000_000
        var parent = TurnUsageTracker()
        var ledger = SubagentUsageLedger()
        parent.consume(.taskStarted(turnID: "parent-turn", startedAtMilliseconds: started))
        parent.consume(.turnContext(turnID: "parent-turn", model: "gpt-6.1-sol", effort: "high"))
        let parentRecord = record(
            thread: "parent-thread",
            turn: "parent-turn",
            root: "parent-turn",
            response: "p1",
            input: 80,
            output: 20,
            settledAt: started + 5_000
        )
        parent.consume(.usage(parentRecord))
        ledger.consume(parentRecord)
        ledger.assignModel(threadID: "parent-thread", turnID: "parent-turn", model: "gpt-6.1-sol")

        ledger.consume(record(
            thread: "child-thread",
            turn: "child-turn",
            root: "parent-turn",
            response: "c1",
            input: 10,
            output: 5,
            settledAt: started + 6_000
        ))
        ledger.consume(record(
            thread: "child-thread",
            turn: "child-turn",
            root: "parent-turn",
            response: "c2",
            input: 8,
            output: 4,
            turnInput: 18,
            turnOutput: 9,
            settledAt: started + 8_000
        ))
        ledger.assignModel(threadID: "child-thread", turnID: "child-turn", model: "gpt-6.1-sol")

        let child = ledger.summary(rootTurnID: "parent-turn", excludingThreadID: "parent-thread")
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: parent.snapshot.startedAtMilliseconds,
            parent: parent.snapshot,
            child: child
        )
        XCTAssertEqual(parent.snapshot.totalTokens, 100)
        XCTAssertEqual(child.totalTokens, 27)
        XCTAssertEqual(metrics.totalTokens, 127)
        XCTAssertEqual(metrics.apiEquivalentUSD, Decimal(string: "0.000486"))
        XCTAssertNotEqual(metrics.apiEquivalentUSD, Decimal(string: "0.000612"))
    }

    func testChildHighWaterReplacesRatherThanAdds() {
        var ledger = SubagentUsageLedger()
        ledger.consume(record(
            thread: "child-a",
            turn: "child-turn",
            root: "parent-turn",
            response: "r1",
            input: 8,
            output: 4,
            settledAt: 1_000
        ))
        ledger.consume(record(
            thread: "child-a",
            turn: "child-turn",
            root: "parent-turn",
            response: "r1",
            input: 10,
            output: 5,
            settledAt: 2_000
        ))
        let summary = ledger.summary(rootTurnID: "parent-turn", excludingThreadID: "parent")
        XCTAssertEqual(summary.totalTokens, 15)
        XCTAssertEqual(summary.settledOutputTokens, 5)
        XCTAssertEqual(summary.requests.count, 1)
        guard case let .priceable(usage) = summary.requests[0].state else {
            return XCTFail("expected the replacement response")
        }
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.totalTokens, 15)
    }

    func testOrdinaryCachedAndCacheWriteSplit() throws {
        let usage = try components(input: 1_700, cached: 500, cacheWrite: 200, output: 300, reasoning: 100)
        XCTAssertEqual(usage.ordinaryInputTokens, 1_000)
        XCTAssertTrue(usage.isPriceable)
        let decoded = try XCTUnwrap(RolloutLineDecoder.decode(
            #"{"timestamp":"2026-10-05T00:00:10.500Z","type":"token_usage_record","payload":{"thread_id":"thread-a","turn_id":"turn-a","response_id":"response-a","usage":{"input_tokens":1700,"cached_input_tokens":500,"cache_write_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":100,"total_tokens":2000},"turn_token_usage":{"input_tokens":1700,"cached_input_tokens":500,"cache_write_input_tokens":200,"output_tokens":300,"reasoning_output_tokens":100,"total_tokens":2000}}}"#
        ))
        guard case let .usage(record) = decoded else { return XCTFail("expected usage") }
        XCTAssertEqual(record.responseUsage?.ordinaryInputTokens, 1_000)
        XCTAssertEqual(record.turnUsage?.cachedInputTokens, 500)
        XCTAssertEqual(record.turnUsage?.cacheWriteInputTokens, 200)
        XCTAssertEqual(record.settledAtMilliseconds, 1_791_158_410_500)
        XCTAssertEqual(record.totalTokens, 2_000)
    }

    func testGPT61SolShortContextPrice() throws {
        let usage = try components(input: 1_700, cached: 500, cacheWrite: 200, output: 300, reasoning: 100)
        let cost = APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: usage)
        XCTAssertEqual(cost, Decimal(string: "0.00555"))
        XCTAssertEqual(APIListPriceCatalog.snapshotDate, "2026-10-05")
        let rates = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6.1-sol", inputTokens: 1_700))
        XCTAssertEqual(rates.ordinaryInputPerMillion, Decimal(string: "2"))
        XCTAssertEqual(rates.cachedInputPerMillion, Decimal(string: "0.10"))
        XCTAssertEqual(rates.cacheWritePerMillion, Decimal(string: "2.50"))
        XCTAssertEqual(rates.outputPerMillion, Decimal(string: "10"))
        let sol = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6-sol", inputTokens: 1))
        XCTAssertEqual(sol.cachedInputPerMillion, Decimal(string: "0.20"))
        let luna = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6-luna", inputTokens: 1))
        XCTAssertEqual(luna.ordinaryInputPerMillion, Decimal(string: "0.10"))
        XCTAssertEqual(luna.outputPerMillion, Decimal(string: "0.50"))
        let astra = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6-astra", inputTokens: 1))
        XCTAssertEqual(astra.ordinaryInputPerMillion, Decimal(string: "10"))
        XCTAssertEqual(astra.outputPerMillion, Decimal(string: "50"))
    }

    func testLongContextThresholdUsesPerRequestInputNotTurnSum() throws {
        let atThreshold = try components(input: 272_000, cached: 0, cacheWrite: 0, output: 10, reasoning: 0)
        let aboveThreshold = try components(input: 272_001, cached: 0, cacheWrite: 0, output: 10, reasoning: 0)
        let shortRates = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6.1-sol", inputTokens: 272_000))
        let longRates = try XCTUnwrap(APIListPriceCatalog.rates(modelID: "gpt-6.1-sol", inputTokens: 272_001))
        XCTAssertEqual(shortRates.ordinaryInputPerMillion, Decimal(string: "2"))
        XCTAssertEqual(longRates.ordinaryInputPerMillion, Decimal(string: "4"))
        XCTAssertEqual(longRates.cachedInputPerMillion, Decimal(string: "0.20"))
        XCTAssertEqual(longRates.cacheWritePerMillion, Decimal(string: "5"))
        XCTAssertEqual(longRates.outputPerMillion, Decimal(string: "15"))
        XCTAssertEqual(APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: atThreshold), Decimal(string: "0.5441"))
        XCTAssertEqual(
            APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: aboveThreshold),
            Decimal(string: "1.088154")
        )

        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 200_000,
            output: 10,
            settledAt: started + 1_000
        )))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r2",
            input: 200_000,
            output: 10,
            turnInput: 400_000,
            turnOutput: 20,
            settledAt: started + 2_000
        )))
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(tracker.snapshot.totalTokens, 400_020)
        XCTAssertEqual(metrics.apiEquivalentUSD, Decimal(string: "0.8002"))
        XCTAssertNotEqual(metrics.apiEquivalentUSD, Decimal(string: "1.6003"))
    }

    func testReasoningChargedOnceAtOutputRate() throws {
        let usage = try components(input: 1_700, cached: 500, cacheWrite: 200, output: 300, reasoning: 100)
        let cost = APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: usage)
        XCTAssertEqual(cost, Decimal(string: "0.00555"))
        XCTAssertNotEqual(cost, Decimal(string: "0.00655"))
    }

    func testMixedModelChildPricedAtItsOwnModel() {
        let started = 1_700_000_000_000
        var parent = TurnUsageTracker()
        var ledger = SubagentUsageLedger()
        parent.consume(.taskStarted(turnID: "parent-turn", startedAtMilliseconds: started))
        parent.consume(.turnContext(turnID: "parent-turn", model: "gpt-6.1-sol", effort: "high"))
        parent.consume(.usage(record(
            thread: "parent-thread",
            turn: "parent-turn",
            root: "parent-turn",
            response: "p1",
            input: 1_000,
            output: 100,
            settledAt: started + 1_000
        )))
        ledger.consume(record(
            thread: "child-thread",
            turn: "child-turn",
            root: "parent-turn",
            response: "c1",
            input: 2_000,
            output: 500,
            settledAt: started + 2_000
        ))
        ledger.assignModel(threadID: "child-thread", turnID: "child-turn", model: "gpt-6-luna")
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: parent.snapshot,
            child: ledger.summary(rootTurnID: "parent-turn", excludingThreadID: "parent-thread")
        )
        XCTAssertEqual(metrics.apiEquivalentUSD, Decimal(string: "0.00345"))
        XCTAssertNotEqual(metrics.apiEquivalentUSD, Decimal(string: "0.012"))
    }

    func testUnknownModelCostUnavailable() throws {
        let usage = try components(input: 100, cached: 0, cacheWrite: 0, output: 50, reasoning: 10)
        XCTAssertNil(APIListPriceCatalog.cost(modelID: "gpt-6.1-sol-preview", usage: usage))
        XCTAssertNil(APIListPriceCatalog.cost(modelID: "codex-auto-review", usage: usage))
        XCTAssertNil(APIListPriceCatalog.rates(modelID: "gpt-5.6-sol", inputTokens: 100))

        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6-sol", effort: nil))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "known",
            input: 100,
            output: 50,
            settledAt: started + 1_000
        )))
        var ledger = SubagentUsageLedger()
        ledger.consume(record(
            thread: "child",
            turn: "child-turn",
            root: "turn-a",
            response: "unknown",
            input: 10,
            output: 5,
            settledAt: started + 2_000
        ))
        ledger.assignModel(threadID: "child", turnID: "child-turn", model: "deepseek-v4-pro")
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: ledger.summary(rootTurnID: "turn-a", excludingThreadID: "parent")
        )
        XCTAssertNil(metrics.apiEquivalentUSD)
        XCTAssertEqual(metrics.totalTokens, 165)
        XCTAssertNotNil(metrics.averageOutputTokensPerSecond)
    }

    func testMalformedUsageFailsClosed() throws {
        let oversubscribedCache = TokenUsageComponents(
            inputTokens: 120,
            cachedInputTokens: 100,
            cacheWriteInputTokens: 50,
            outputTokens: 10,
            reasoningOutputTokens: 0,
            totalTokens: 130
        )
        XCTAssertFalse(oversubscribedCache.isPriceable)
        XCTAssertNil(APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: oversubscribedCache))

        let reasoningExceedsOutput = try components(input: 10, cached: 0, cacheWrite: 0, output: 4, reasoning: 9)
        XCTAssertFalse(reasoningExceedsOutput.isAccountingConsistent)
        XCTAssertNil(APIListPriceCatalog.cost(modelID: "gpt-6.1-sol", usage: reasoningExceedsOutput))

        let missingCached = TokenUsageComponents(
            inputTokens: 10,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 4,
            reasoningOutputTokens: 0,
            totalTokens: 14,
            specifiesCachedInput: false,
            specifiesCacheWrite: false
        )
        XCTAssertFalse(missingCached.isPriceable)

        let absentCacheWrite = TokenUsageComponents(
            inputTokens: 10,
            cachedInputTokens: 2,
            cacheWriteInputTokens: 0,
            outputTokens: 4,
            reasoningOutputTokens: 1,
            totalTokens: 14,
            specifiesCachedInput: true,
            specifiesCacheWrite: false
        )
        XCTAssertEqual(APIListPriceCatalog.cost(modelID: "gpt-6-astra", usage: absentCacheWrite), Decimal(string: "0.000282"))

        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        tracker.consume(.usage(TokenUsageRecord(
            threadID: "parent",
            turnID: "turn-a",
            responseID: "partial",
            totalTokens: 40,
            turnUsage: nil,
            responseUsage: nil,
            settledAtMilliseconds: started + 1_000
        )))
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(metrics.totalTokens, 40)
        XCTAssertNil(metrics.averageOutputTokensPerSecond)
        XCTAssertNil(metrics.apiEquivalentUSD)
        XCTAssertEqual(TaskMetricLineFormatter.task(totalTokens: metrics.totalTokens, apiEquivalentUSD: nil), "TASK  40 · API≈—")
    }

    func testAPICostFormattingBands() {
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "0.00424")), "API≈$0.0042")
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "0.00999")), "API≈$0.0100")
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "0.01")), "API≈$0.010")
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "0.4284")), "API≈$0.428")
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "1")), "API≈$1.00")
        XCTAssertEqual(APIEquivalentFormatter.string(Decimal(string: "12.346")), "API≈$12.35")
        XCTAssertEqual(APIEquivalentFormatter.string(nil), "API≈—")
        XCTAssertEqual(
            TaskMetricLineFormatter.task(totalTokens: 84_150, apiEquivalentUSD: Decimal(string: "0.428")),
            "TASK  84.15K · API≈$0.428"
        )
        XCTAssertEqual(TaskMetricLineFormatter.average(27.4), "AVG   27.4 tok/s")
    }

    func testNewTaskResetsTaskAverageAndAPIWithoutBleed() {
        let started = 1_700_000_000_000
        var parent = TurnUsageTracker()
        var ledger = SubagentUsageLedger()
        parent.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        parent.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        parent.consume(.usage(record(
            thread: "parent-thread",
            turn: "turn-a",
            root: "turn-a",
            response: "p1",
            input: 1_000,
            output: 274,
            settledAt: started + 10_000
        )))
        ledger.consume(record(
            thread: "child-thread",
            turn: "child-turn",
            root: "turn-a",
            response: "c1",
            input: 100,
            output: 20,
            settledAt: started + 11_000
        ))
        ledger.assignModel(threadID: "child-thread", turnID: "child-turn", model: "gpt-6-luna")
        let first = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: parent.snapshot.startedAtMilliseconds,
            parent: parent.snapshot,
            child: ledger.summary(rootTurnID: "turn-a", excludingThreadID: "parent-thread")
        )
        XCTAssertEqual(first.totalTokens, 1_394)
        XCTAssertNotNil(first.averageOutputTokensPerSecond)
        XCTAssertNotNil(first.apiEquivalentUSD)

        parent.consume(.taskStarted(turnID: "turn-b", startedAtMilliseconds: started + 20_000))
        let reset = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: parent.snapshot.startedAtMilliseconds,
            parent: parent.snapshot,
            child: ledger.summary(rootTurnID: "turn-b", excludingThreadID: "parent-thread")
        )
        XCTAssertEqual(reset.totalTokens, 0)
        XCTAssertNil(reset.averageOutputTokensPerSecond)
        XCTAssertNil(reset.apiEquivalentUSD)
        XCTAssertEqual(TaskMetricLineFormatter.average(reset.averageOutputTokensPerSecond), "AVG   — tok/s")
        XCTAssertEqual(TaskMetricLineFormatter.task(totalTokens: reset.totalTokens, apiEquivalentUSD: nil), "TASK  0 · API≈—")
    }

    func testLaterUnpriceableResponseInvalidatesPreviousPrice() {
        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        tracker.consume(.usage(record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 100,
            output: 20,
            settledAt: started + 1_000
        )))
        let priced = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertNotNil(priced.apiEquivalentUSD)

        tracker.consume(.usage(TokenUsageRecord(
            threadID: "parent",
            turnID: "turn-a",
            responseID: "r1",
            totalTokens: 180,
            turnUsage: TokenUsageComponents(
                inputTokens: 140,
                cachedInputTokens: 0,
                cacheWriteInputTokens: 0,
                outputTokens: 40,
                reasoningOutputTokens: 0,
                totalTokens: 180
            ),
            responseUsage: TokenUsageComponents(
                inputTokens: 40,
                cachedInputTokens: 30,
                cacheWriteInputTokens: 20,
                outputTokens: 20,
                reasoningOutputTokens: 0,
                totalTokens: 60
            ),
            settledAtMilliseconds: started + 2_000
        )))
        let invalidated = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(invalidated.totalTokens, 180)
        XCTAssertNil(invalidated.apiEquivalentUSD)
        XCTAssertNotEqual(invalidated.apiEquivalentUSD, priced.apiEquivalentUSD)
    }

    func testParentModelChangeFailsClosedInsteadOfRepricing() throws {
        let started = 1_700_000_000_000
        var tracker = TurnUsageTracker()
        tracker.consume(.taskStarted(turnID: "turn-a", startedAtMilliseconds: started))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        let usage = record(
            thread: "parent",
            turn: "turn-a",
            response: "r1",
            input: 1_000,
            output: 100,
            settledAt: started + 1_000
        )
        tracker.consume(.usage(usage))
        let sol = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6-luna", effort: "low"))
        tracker.consume(.turnContext(turnID: "turn-a", model: "gpt-6.1-sol", effort: "high"))
        let conflicted = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: started,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        let luna = try XCTUnwrap(APIListPriceCatalog.cost(modelID: "gpt-6-luna", usage: usage.responseUsage!))
        XCTAssertNotNil(sol.apiEquivalentUSD)
        XCTAssertTrue(tracker.snapshot.modelConflict)
        XCTAssertNil(tracker.snapshot.model)
        XCTAssertNil(conflicted.apiEquivalentUSD)
        XCTAssertNotEqual(conflicted.apiEquivalentUSD, luna)
        XCTAssertEqual(conflicted.totalTokens, sol.totalTokens)
    }

    func testDecodedTaskStartAndUsageTimestampBoundaries() throws {
        let started = try XCTUnwrap(RolloutLineDecoder.decode(
            #"{"timestamp":"2026-10-05T00:00:00.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":1791158400}}"#
        ))
        let usage = try XCTUnwrap(RolloutLineDecoder.decode(
            #"{"timestamp":"2026-10-05T00:00:10.500Z","type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"r1","usage":{"input_tokens":8,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":274,"reasoning_output_tokens":200,"total_tokens":282},"turn_token_usage":{"input_tokens":8,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":274,"reasoning_output_tokens":200,"total_tokens":282}}}"#
        ))
        var tracker = TurnUsageTracker()
        tracker.consume(started)
        tracker.consume(usage)
        XCTAssertEqual(tracker.snapshot.startedAtMilliseconds, 1_791_158_400_000)
        XCTAssertEqual(tracker.snapshot.outputSettledAtMilliseconds, 1_791_158_410_500)
        let metrics = CurrentTaskAccountant.metrics(
            startedAtMilliseconds: tracker.snapshot.startedAtMilliseconds,
            parent: tracker.snapshot,
            child: emptyChildren()
        )
        XCTAssertEqual(metrics.averageOutputTokensPerSecond ?? 0, 274.0 / 10.5, accuracy: 0.000_000_1)
    }

    private func emptyChildren() -> ChildUsageSummary {
        ChildUsageSummary(totalTokens: 0, settledOutputTokens: 0, outputSettledAtMilliseconds: nil, requests: [])
    }

    private func components(
        input: Int,
        cached: Int,
        cacheWrite: Int,
        output: Int,
        reasoning: Int
    ) throws -> TokenUsageComponents {
        let usage = TokenUsageComponents(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: input + output
        )
        return usage
    }

    private func record(
        thread: String,
        turn: String,
        root: String? = nil,
        response: String,
        input: Int,
        cached: Int = 0,
        cacheWrite: Int = 0,
        output: Int,
        reasoning: Int = 0,
        turnInput: Int? = nil,
        turnCached: Int? = nil,
        turnCacheWrite: Int? = nil,
        turnOutput: Int? = nil,
        turnReasoning: Int? = nil,
        settledAt: Int?
    ) -> TokenUsageRecord {
        let responseUsage = TokenUsageComponents(
            inputTokens: input,
            cachedInputTokens: cached,
            cacheWriteInputTokens: cacheWrite,
            outputTokens: output,
            reasoningOutputTokens: reasoning,
            totalTokens: input + output
        )
        let cumulativeInput = turnInput ?? input
        let cumulativeCached = turnCached ?? cached
        let cumulativeCacheWrite = turnCacheWrite ?? cacheWrite
        let cumulativeOutput = turnOutput ?? output
        let cumulativeReasoning = turnReasoning ?? reasoning
        let turnUsage = TokenUsageComponents(
            inputTokens: cumulativeInput,
            cachedInputTokens: cumulativeCached,
            cacheWriteInputTokens: cumulativeCacheWrite,
            outputTokens: cumulativeOutput,
            reasoningOutputTokens: cumulativeReasoning,
            totalTokens: cumulativeInput + cumulativeOutput
        )
        return TokenUsageRecord(
            threadID: thread,
            turnID: turn,
            rootTurnID: root,
            responseID: response,
            totalTokens: turnUsage.totalTokens,
            turnUsage: turnUsage,
            responseUsage: responseUsage,
            settledAtMilliseconds: settledAt
        )
    }
}
