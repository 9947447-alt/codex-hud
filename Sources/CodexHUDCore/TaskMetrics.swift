import Foundation

public struct TaskMetricValues: Equatable, Sendable {
    public let totalTokens: Int
    public let averageOutputTokensPerSecond: Double?
    public let apiEquivalentUSD: Decimal?

    public init(totalTokens: Int, averageOutputTokensPerSecond: Double?, apiEquivalentUSD: Decimal?) {
        self.totalTokens = totalTokens
        self.averageOutputTokensPerSecond = averageOutputTokensPerSecond
        self.apiEquivalentUSD = apiEquivalentUSD
    }
}

public enum SettledOutputThroughput {
    /// Wall-clock average of settled output tokens.
    /// `outputTokens` already includes reasoning tokens. Elapsed time ends at the
    /// usage settlement that established this numerator, not at the current clock.
    public static func tokensPerSecond(
        outputTokens: Int,
        startedAtMilliseconds: Int?,
        settledAtMilliseconds: Int?
    ) -> Double? {
        guard
            outputTokens >= 0,
            let startedAtMilliseconds,
            let settledAtMilliseconds,
            startedAtMilliseconds >= 0,
            settledAtMilliseconds > startedAtMilliseconds
        else {
            return nil
        }
        let elapsedMilliseconds = settledAtMilliseconds - startedAtMilliseconds
        guard elapsedMilliseconds > 0 else { return nil }
        let seconds = Double(elapsedMilliseconds) / 1_000
        guard seconds.isFinite, seconds > 0 else { return nil }
        let rate = Double(outputTokens) / seconds
        guard rate.isFinite, rate >= 0 else { return nil }
        return rate
    }
}

public enum CurrentTaskAccountant {
    public static func metrics(
        startedAtMilliseconds: Int?,
        parent: TurnUsageSnapshot,
        child: ChildUsageSummary
    ) -> TaskMetricValues {
        let (total, totalOverflow) = parent.totalTokens.addingReportingOverflow(child.totalTokens)
        let average = averageThroughput(
            startedAtMilliseconds: startedAtMilliseconds,
            parentOutput: parent.settledOutputTokens,
            parentSettledAtMilliseconds: parent.outputSettledAtMilliseconds,
            childOutput: child.settledOutputTokens,
            childSettledAtMilliseconds: child.outputSettledAtMilliseconds
        )
        return TaskMetricValues(
            totalTokens: totalOverflow ? Int.max : total,
            averageOutputTokensPerSecond: average,
            apiEquivalentUSD: APIEquivalentCost.total(
                parentModelID: parent.model,
                parentResponses: parent.responses,
                childRequests: child.requests
            )
        )
    }

    static func averageThroughput(
        startedAtMilliseconds: Int?,
        parentOutput: Int?,
        parentSettledAtMilliseconds: Int?,
        childOutput: Int?,
        childSettledAtMilliseconds: Int?
    ) -> Double? {
        guard let parentOutput, let childOutput else { return nil }
        let (output, overflow) = parentOutput.addingReportingOverflow(childOutput)
        guard !overflow else { return nil }
        var settlements: [Int] = []
        if parentOutput > 0 {
            guard let parentSettledAtMilliseconds else { return nil }
            settlements.append(parentSettledAtMilliseconds)
        } else if output == 0, let parentSettledAtMilliseconds {
            settlements.append(parentSettledAtMilliseconds)
        }
        if childOutput > 0 {
            guard let childSettledAtMilliseconds else { return nil }
            settlements.append(childSettledAtMilliseconds)
        } else if output == 0, let childSettledAtMilliseconds {
            settlements.append(childSettledAtMilliseconds)
        }
        guard output > 0 || !settlements.isEmpty else { return nil }
        return SettledOutputThroughput.tokensPerSecond(
            outputTokens: output,
            startedAtMilliseconds: startedAtMilliseconds,
            settledAtMilliseconds: settlements.max()
        )
    }
}

public struct ModelTokenRates: Equatable, Sendable {
    public let ordinaryInputPerMillion: Decimal
    public let cachedInputPerMillion: Decimal
    public let cacheWritePerMillion: Decimal
    public let outputPerMillion: Decimal

    public init(
        ordinaryInputPerMillion: Decimal,
        cachedInputPerMillion: Decimal,
        cacheWritePerMillion: Decimal,
        outputPerMillion: Decimal
    ) {
        self.ordinaryInputPerMillion = ordinaryInputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.outputPerMillion = outputPerMillion
    }
}

public enum APIListPriceCatalog {
    public static let snapshotDate = "2026-10-05"
    /// Published Standard threshold: prompts with more than 272K input tokens.
    public static let longContextInputTokenThreshold = 272_000

    /// Standard list prices only. Codex `service_tier` is not a multiplier:
    /// default/priority, Batch, Flex, Fast, and regional premiums are not applied.
    public static func rates(modelID: String, inputTokens: Int) -> ModelTokenRates? {
        guard inputTokens >= 0, let pair = models[modelID] else { return nil }
        if inputTokens > longContextInputTokenThreshold {
            return pair.longContext
        }
        return pair.shortContext
    }

    public static func cost(modelID: String, usage: TokenUsageComponents) -> Decimal? {
        guard usage.isPriceable, let rates = rates(modelID: modelID, inputTokens: usage.inputTokens) else {
            return nil
        }
        let million = Decimal(1_000_000)
        return Decimal(usage.ordinaryInputTokens) * rates.ordinaryInputPerMillion / million
            + Decimal(usage.cachedInputTokens) * rates.cachedInputPerMillion / million
            + Decimal(usage.cacheWriteInputTokens) * rates.cacheWritePerMillion / million
            + Decimal(usage.outputTokens) * rates.outputPerMillion / million
    }

    private struct RatePair {
        let shortContext: ModelTokenRates
        let longContext: ModelTokenRates
    }

    private static let models: [String: RatePair] = [
        "gpt-6.1-sol": pair(short: ["2", "0.10", "2.50", "10"], long: ["4", "0.20", "5", "15"]),
        "gpt-6-sol": pair(short: ["2", "0.20", "2.50", "10"], long: ["4", "0.40", "5", "15"]),
        "gpt-6-luna": pair(short: ["0.10", "0.01", "0.125", "0.50"], long: ["0.20", "0.02", "0.25", "0.75"]),
        "gpt-6-astra": pair(short: ["10", "1", "12.50", "50"], long: ["20", "2", "25", "75"]),
    ]

    private static func pair(short: [String], long: [String]) -> RatePair {
        RatePair(shortContext: rates(short), longContext: rates(long))
    }

    private static func rates(_ values: [String]) -> ModelTokenRates {
        func usd(_ value: String) -> Decimal {
            guard let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
                preconditionFailure("invalid bundled rate \(value)")
            }
            return decimal
        }
        return ModelTokenRates(
            ordinaryInputPerMillion: usd(values[0]),
            cachedInputPerMillion: usd(values[1]),
            cacheWritePerMillion: usd(values[2]),
            outputPerMillion: usd(values[3])
        )
    }
}

public enum APIEquivalentCost {
    public static func total(
        parentModelID: String?,
        parentResponses: [String: ResponseUsageState],
        childRequests: [ChildUsageRequest]
    ) -> Decimal? {
        var parts: [(String?, ResponseUsageState)] = parentResponses.values.map { (parentModelID, $0) }
        parts.append(contentsOf: childRequests.map { ($0.modelID, $0.state) })
        guard !parts.isEmpty else { return nil }
        var sum = Decimal(0)
        for (modelID, state) in parts {
            switch state {
            case .unpriceable:
                return nil
            case let .priceable(usage):
                guard let modelID, let cost = APIListPriceCatalog.cost(modelID: modelID, usage: usage) else {
                    return nil
                }
                sum += cost
            }
        }
        return sum
    }
}

public enum AverageThroughputFormatter {
    public static func string(_ tokensPerSecond: Double?) -> String {
        guard let tokensPerSecond, tokensPerSecond.isFinite, tokensPerSecond >= 0 else { return "— tok/s" }
        return String(format: "%.1f tok/s", locale: Locale(identifier: "en_US_POSIX"), tokensPerSecond)
    }
}

public enum APIEquivalentFormatter {
    public static func string(_ usd: Decimal?) -> String {
        guard let usd, usd >= 0, usd.isFinite else { return "API≈—" }
        let places = fractionDigits(for: usd)
        let handler = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: Int16(places),
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        let rounded = NSDecimalNumber(decimal: usd).rounding(accordingToBehavior: handler)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.roundingMode = .halfEven
        guard let body = formatter.string(from: rounded) else { return "API≈—" }
        return "API≈$\(body)"
    }

    private static func fractionDigits(for usd: Decimal) -> Int {
        if usd < Decimal(string: "0.01", locale: Locale(identifier: "en_US_POSIX"))! { return 4 }
        if usd < 1 { return 3 }
        return 2
    }
}

public enum TaskMetricLineFormatter {
    public static func average(_ tokensPerSecond: Double?) -> String {
        "AVG   \(AverageThroughputFormatter.string(tokensPerSecond))"
    }

    public static func task(totalTokens: Int, apiEquivalentUSD: Decimal?) -> String {
        "TASK  \(TaskTokenFormatter.compact(totalTokens)) · \(APIEquivalentFormatter.string(apiEquivalentUSD))"
    }
}
