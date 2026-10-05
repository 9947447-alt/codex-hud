import CoreFoundation
import Foundation

public struct TokenUsageComponents: Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    public let specifiesCachedInput: Bool
    public let specifiesCacheWrite: Bool
    public let isWellFormed: Bool

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int,
        outputTokens: Int,
        reasoningOutputTokens: Int,
        totalTokens: Int,
        specifiesCachedInput: Bool = true,
        specifiesCacheWrite: Bool = true,
        isWellFormed: Bool = true
    ) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
        self.specifiesCachedInput = specifiesCachedInput
        self.specifiesCacheWrite = specifiesCacheWrite
        self.isWellFormed = isWellFormed
    }

    public var ordinaryInputTokens: Int {
        inputTokens - cachedInputTokens - cacheWriteInputTokens
    }

    public var isAccountingConsistent: Bool {
        isWellFormed
            && inputTokens >= 0
            && cachedInputTokens >= 0
            && cacheWriteInputTokens >= 0
            && outputTokens >= 0
            && reasoningOutputTokens >= 0
            && totalTokens >= 0
            && reasoningOutputTokens <= outputTokens
            && cachedInputTokens <= inputTokens
            && cacheWriteInputTokens <= inputTokens
            && ordinaryInputTokens >= 0
            && inputTokens + outputTokens == totalTokens
    }

    /// Cached input must be present. Absent cache-write means zero. Reasoning is not priced separately.
    public var isPriceable: Bool {
        specifiesCachedInput && isAccountingConsistent
    }
}

public enum ResponseUsageState: Equatable, Sendable {
    case priceable(TokenUsageComponents)
    case unpriceable
}

public struct TokenUsageRecord: Equatable, Sendable {
    public let threadID: String?
    public let turnID: String
    public let rootTurnID: String?
    public let responseID: String
    public let totalTokens: Int
    public let turnUsage: TokenUsageComponents?
    public let responseUsage: TokenUsageComponents?
    public let settledAtMilliseconds: Int?

    public init(
        threadID: String? = nil,
        turnID: String,
        rootTurnID: String? = nil,
        responseID: String,
        totalTokens: Int,
        turnUsage: TokenUsageComponents? = nil,
        responseUsage: TokenUsageComponents? = nil,
        settledAtMilliseconds: Int? = nil
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.rootTurnID = rootTurnID
        self.responseID = responseID
        self.totalTokens = totalTokens
        self.turnUsage = turnUsage
        self.responseUsage = responseUsage
        self.settledAtMilliseconds = settledAtMilliseconds
    }
}

public struct RolloutSessionMetadata: Equatable, Sendable {
    public let threadID: String
    public let isCodexDesktop: Bool
    public let isVSCodeSource: Bool
    public let isSubagent: Bool

    public init(threadID: String, isCodexDesktop: Bool, isVSCodeSource: Bool, isSubagent: Bool) {
        self.threadID = threadID
        self.isCodexDesktop = isCodexDesktop
        self.isVSCodeSource = isVSCodeSource
        self.isSubagent = isSubagent
    }
}

public enum RolloutEvent: Equatable, Sendable {
    case sessionMetadata(RolloutSessionMetadata)
    case taskStarted(turnID: String, startedAtMilliseconds: Int?)
    case turnContext(turnID: String, model: String?, effort: String?)
    case taskCompleted(turnID: String)
    case usage(TokenUsageRecord)
}

public enum RolloutLineDecoder {
    public static func decode(_ line: String) -> RolloutEvent? {
        decode(Data(line.utf8))
    }

    public static func decode(_ line: Data) -> RolloutEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = root["type"] as? String,
            let payload = root["payload"] as? [String: Any]
        else {
            return nil
        }

        switch type {
        case "session_meta":
            guard
                let threadID = nonemptyString(payload["id"]),
                let originator = payload["originator"] as? String
            else {
                return nil
            }
            let source = payload["source"]
            let sourceObject = source as? [String: Any]
            return .sessionMetadata(.init(
                threadID: threadID,
                isCodexDesktop: originator == "Codex Desktop",
                isVSCodeSource: source as? String == "vscode",
                isSubagent: sourceObject?["subagent"] != nil
            ))

        case "token_usage_record":
            guard
                let turnID = nonemptyString(payload["turn_id"]),
                let responseID = nonemptyString(payload["response_id"]),
                let turnTokenUsage = payload["turn_token_usage"] as? [String: Any],
                let total = nonnegativeInteger(turnTokenUsage["total_tokens"])
            else {
                return nil
            }
            let responseObject = payload["usage"] as? [String: Any]
            return .usage(.init(
                threadID: nonemptyString(payload["thread_id"]),
                turnID: turnID,
                rootTurnID: nonemptyString(payload["root_turn_id"]),
                responseID: responseID,
                totalTokens: total,
                turnUsage: usageComponents(turnTokenUsage),
                responseUsage: responseObject.flatMap(usageComponents),
                settledAtMilliseconds: isoMilliseconds(root["timestamp"])
            ))

        case "turn_context":
            guard let turnID = nonemptyString(payload["turn_id"]) else { return nil }
            return .turnContext(
                turnID: turnID,
                model: nonemptyString(payload["model"]),
                effort: nonemptyString(payload["effort"])
            )

        case "event_msg":
            guard
                let eventType = payload["type"] as? String,
                let turnID = nonemptyString(payload["turn_id"])
            else {
                return nil
            }
            switch eventType {
            case "task_started":
                return .taskStarted(
                    turnID: turnID,
                    startedAtMilliseconds: unixMilliseconds(payload["started_at"])
                )
            case "task_complete":
                return .taskCompleted(turnID: turnID)
            default:
                return nil
            }

        default:
            return nil
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue >= 0,
            number.doubleValue.rounded(.towardZero) == number.doubleValue,
            number.doubleValue < Double(Int.max)
        else {
            return nil
        }
        return number.intValue
    }

    private static func unixMilliseconds(_ value: Any?) -> Int? {
        guard let seconds = nonnegativeInteger(value), seconds <= Int.max / 1_000 else { return nil }
        return seconds * 1_000
    }

    private static func usageComponents(_ usage: [String: Any]) -> TokenUsageComponents? {
        guard
            let input = nonnegativeInteger(usage["input_tokens"]),
            let output = nonnegativeInteger(usage["output_tokens"]),
            let total = nonnegativeInteger(usage["total_tokens"])
        else {
            return nil
        }
        let cachedField = optionalCount(usage, "cached_input_tokens")
        let cacheWriteField = optionalCount(usage, "cache_write_input_tokens")
        let reasoningField = optionalCount(usage, "reasoning_output_tokens")
        let wellFormed = cachedField.wellFormed && cacheWriteField.wellFormed && reasoningField.wellFormed
        return TokenUsageComponents(
            inputTokens: input,
            cachedInputTokens: cachedField.value,
            cacheWriteInputTokens: cacheWriteField.value,
            outputTokens: output,
            reasoningOutputTokens: reasoningField.value,
            totalTokens: total,
            specifiesCachedInput: cachedField.specified,
            specifiesCacheWrite: cacheWriteField.specified,
            isWellFormed: wellFormed
        )
    }

    private static func optionalCount(_ usage: [String: Any], _ key: String) -> (specified: Bool, value: Int, wellFormed: Bool) {
        guard usage[key] != nil else { return (false, 0, true) }
        guard let value = nonnegativeInteger(usage[key]) else { return (true, 0, false) }
        return (true, value, true)
    }

    private static func isoMilliseconds(_ value: Any?) -> Int? {
        guard let text = nonemptyString(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: text)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: text)
        }
        guard let date else { return nil }
        let millis = date.timeIntervalSince1970 * 1_000
        guard millis.isFinite, millis >= 0, millis < Double(Int.max) else { return nil }
        return Int(millis.rounded())
    }
}

enum UsageHighWater {
    static func absorb(
        totalTokens: inout Int,
        settledOutputTokens: inout Int?,
        outputSettledAtMilliseconds: inout Int?,
        responses: inout [String: ResponseUsageState],
        record: TokenUsageRecord
    ) {
        upsertResponse(&responses, record: record)
        let previousTotal = totalTokens
        let previousOutput = settledOutputTokens
        let accept = record.totalTokens > previousTotal
            || (settledOutputTokens == nil && record.turnUsage != nil && record.totalTokens >= previousTotal)
        guard accept else { return }
        totalTokens = record.totalTokens
        if let turn = record.turnUsage {
            settledOutputTokens = turn.outputTokens
            if previousOutput != turn.outputTokens {
                outputSettledAtMilliseconds = record.settledAtMilliseconds
            }
        } else if record.totalTokens > previousTotal {
            settledOutputTokens = nil
            outputSettledAtMilliseconds = nil
        }
    }

    private static func upsertResponse(_ responses: inout [String: ResponseUsageState], record: TokenUsageRecord) {
        let incoming: ResponseUsageState?
        if let response = record.responseUsage {
            incoming = response.isPriceable ? .priceable(response) : .unpriceable
        } else {
            incoming = nil
        }
        switch responses[record.responseID] {
        case nil:
            if let incoming {
                responses[record.responseID] = incoming
            } else if record.totalTokens > 0 {
                responses[record.responseID] = .unpriceable
            }
        case .unpriceable:
            if case .priceable = incoming {
                responses[record.responseID] = incoming
            }
        case let .priceable(existing):
            switch incoming {
            case let .priceable(response) where response.totalTokens >= existing.totalTokens:
                responses[record.responseID] = incoming
            case .unpriceable:
                responses[record.responseID] = .unpriceable
            case nil where record.totalTokens > existing.totalTokens:
                responses[record.responseID] = .unpriceable
            default:
                break
            }
        }
    }
}

public struct ActiveTurnCandidate: Equatable, Sendable {
    public let threadID: String
    public let turnID: String
    public let startedAtMilliseconds: Int?
    public let totalTokens: Int
    public let model: String?
    public let effort: String?
    public let isCodexDesktop: Bool
    public let isVSCodeSource: Bool
    public let isSubagent: Bool
    public let isActive: Bool

    public init(
        threadID: String,
        turnID: String,
        startedAtMilliseconds: Int?,
        totalTokens: Int,
        model: String?,
        effort: String?,
        isCodexDesktop: Bool,
        isVSCodeSource: Bool,
        isSubagent: Bool,
        isActive: Bool
    ) {
        self.threadID = threadID
        self.turnID = turnID
        self.startedAtMilliseconds = startedAtMilliseconds
        self.totalTokens = max(totalTokens, 0)
        self.model = model
        self.effort = effort
        self.isCodexDesktop = isCodexDesktop
        self.isVSCodeSource = isVSCodeSource
        self.isSubagent = isSubagent
        self.isActive = isActive
    }
}

public enum AuthoritativeTurnSelector {
    public static func select(_ candidates: [ActiveTurnCandidate]) -> ActiveTurnCandidate? {
        let eligible = candidates.filter {
            $0.isActive && $0.isCodexDesktop && $0.isVSCodeSource && !$0.isSubagent
        }
        guard !eligible.isEmpty else { return nil }
        if eligible.count == 1 { return eligible[0] }
        guard eligible.allSatisfy({ $0.startedAtMilliseconds != nil }) else { return nil }

        return eligible.sorted { left, right in
            if left.startedAtMilliseconds != right.startedAtMilliseconds {
                return left.startedAtMilliseconds! > right.startedAtMilliseconds!
            }
            if left.threadID != right.threadID { return left.threadID < right.threadID }
            return left.turnID < right.turnID
        }.first
    }
}

public enum ActiveTurnEligibility {
    public static func shouldFollow(rolloutStatus: TurnStatus, desktopTurnStatus: DesktopTurnStatus?) -> Bool {
        rolloutStatus == .active && desktopTurnStatus != .completed
    }
}

public struct ChildUsageRequest: Equatable, Sendable {
    public var modelID: String?
    public var state: ResponseUsageState

    public init(modelID: String?, state: ResponseUsageState) {
        self.modelID = modelID
        self.state = state
    }
}

public struct ChildUsageSummary: Equatable, Sendable {
    public var totalTokens: Int
    public var settledOutputTokens: Int?
    public var outputSettledAtMilliseconds: Int?
    public var requests: [ChildUsageRequest]

    public init(
        totalTokens: Int,
        settledOutputTokens: Int?,
        outputSettledAtMilliseconds: Int?,
        requests: [ChildUsageRequest]
    ) {
        self.totalTokens = totalTokens
        self.settledOutputTokens = settledOutputTokens
        self.outputSettledAtMilliseconds = outputSettledAtMilliseconds
        self.requests = requests
    }
}

public struct SubagentUsageLedger: Sendable {
    private struct Key: Hashable {
        let threadID: String
        let turnID: String
    }

    private struct ModelAssociation {
        var model: String?
        var conflict = false

        mutating func note(_ model: String) {
            guard !conflict else { return }
            if let existing = self.model, existing != model {
                self.model = nil
                conflict = true
            } else {
                self.model = model
            }
        }

        mutating func merge(_ other: ModelAssociation) {
            if other.conflict {
                model = nil
                conflict = true
                return
            }
            if let model = other.model {
                note(model)
            }
        }
    }

    private struct Value {
        let rootTurnID: String
        var totalTokens: Int
        var settledOutputTokens: Int?
        var outputSettledAtMilliseconds: Int?
        var responses: [String: ResponseUsageState]
        var modelAssociation: ModelAssociation
    }

    private var values: [Key: Value] = [:]
    private var pendingModels: [Key: ModelAssociation] = [:]
    private var insertionOrder: [Key] = []

    public init(maximumEntries: Int = 4_096) {
        self.maximumEntries = max(maximumEntries, 1)
    }

    private let maximumEntries: Int

    public mutating func consume(_ record: TokenUsageRecord) {
        guard
            let threadID = record.threadID,
            let rootTurnID = record.rootTurnID,
            !threadID.isEmpty,
            !rootTurnID.isEmpty,
            record.totalTokens >= 0
        else { return }

        let key = Key(threadID: threadID, turnID: record.turnID)
        if var value = values[key], value.rootTurnID == rootTurnID {
            absorb(record, into: &value)
            if let pending = pendingModels.removeValue(forKey: key) {
                value.modelAssociation.merge(pending)
            }
            values[key] = value
        } else if values[key] == nil {
            var value = Value(
                rootTurnID: rootTurnID,
                totalTokens: 0,
                settledOutputTokens: nil,
                outputSettledAtMilliseconds: nil,
                responses: [:],
                modelAssociation: pendingModels.removeValue(forKey: key) ?? ModelAssociation()
            )
            absorb(record, into: &value)
            values[key] = value
            insertionOrder.append(key)
            trimIfNeeded()
        }
    }

    public mutating func assignModel(threadID: String, turnID: String, model: String) {
        guard !threadID.isEmpty, !turnID.isEmpty, !model.isEmpty else { return }
        let key = Key(threadID: threadID, turnID: turnID)
        if var value = values[key] {
            value.modelAssociation.note(model)
            if let pending = pendingModels.removeValue(forKey: key) {
                value.modelAssociation.merge(pending)
            }
            values[key] = value
        } else {
            var pending = pendingModels[key] ?? ModelAssociation()
            pending.note(model)
            pendingModels[key] = pending
            trimIfNeeded()
        }
    }

    public mutating func retain(rootTurnID: String) {
        values = values.filter { $0.value.rootTurnID == rootTurnID }
        insertionOrder.removeAll { values[$0] == nil }
    }

    public mutating func remove(threadID: String) {
        values = values.filter { $0.key.threadID != threadID }
        insertionOrder.removeAll { $0.threadID == threadID }
        pendingModels = pendingModels.filter { $0.key.threadID != threadID }
    }

    public func totalTokens(rootTurnID: String, excludingThreadID parentThreadID: String) -> Int {
        summary(rootTurnID: rootTurnID, excludingThreadID: parentThreadID).totalTokens
    }

    public func summary(rootTurnID: String, excludingThreadID parentThreadID: String) -> ChildUsageSummary {
        var total = 0
        var output = 0
        var outputKnown = true
        var missingPositiveTimestamp = false
        var positiveSettlement: Int?
        var zeroSettlement: Int?
        var requests: [ChildUsageRequest] = []

        for entry in values where entry.key.threadID != parentThreadID && entry.value.rootTurnID == rootTurnID {
            let (sum, overflow) = total.addingReportingOverflow(entry.value.totalTokens)
            total = overflow ? Int.max : sum
            let modelID = entry.value.modelAssociation.conflict ? nil : entry.value.modelAssociation.model
            if entry.value.responses.isEmpty {
                if entry.value.totalTokens > 0 {
                    requests.append(ChildUsageRequest(modelID: modelID, state: .unpriceable))
                }
            } else {
                for state in entry.value.responses.values {
                    requests.append(ChildUsageRequest(modelID: modelID, state: state))
                }
            }
            if let settled = entry.value.settledOutputTokens {
                let (outputSum, outputOverflow) = output.addingReportingOverflow(settled)
                output = outputOverflow ? Int.max : outputSum
                if settled > 0 {
                    if let timestamp = entry.value.outputSettledAtMilliseconds {
                        positiveSettlement = max(positiveSettlement ?? timestamp, timestamp)
                    } else {
                        missingPositiveTimestamp = true
                    }
                } else if let timestamp = entry.value.outputSettledAtMilliseconds {
                    zeroSettlement = max(zeroSettlement ?? timestamp, timestamp)
                }
            } else if entry.value.totalTokens > 0 {
                outputKnown = false
            }
        }

        let settledOutput = outputKnown && !missingPositiveTimestamp ? output : nil
        let settlement = positiveSettlement ?? (output == 0 ? zeroSettlement : nil)
        return ChildUsageSummary(
            totalTokens: total,
            settledOutputTokens: settledOutput,
            outputSettledAtMilliseconds: settledOutput == nil ? nil : settlement,
            requests: requests
        )
    }

    private mutating func absorb(_ record: TokenUsageRecord, into value: inout Value) {
        UsageHighWater.absorb(
            totalTokens: &value.totalTokens,
            settledOutputTokens: &value.settledOutputTokens,
            outputSettledAtMilliseconds: &value.outputSettledAtMilliseconds,
            responses: &value.responses,
            record: record
        )
    }

    private mutating func trimIfNeeded() {
        while insertionOrder.count > maximumEntries {
            let expired = insertionOrder.removeFirst()
            values.removeValue(forKey: expired)
            pendingModels.removeValue(forKey: expired)
        }
        while pendingModels.count > maximumEntries {
            pendingModels.remove(at: pendingModels.startIndex)
        }
    }
}

public enum TurnStatus: Equatable, Sendable {
    case idle
    case active
    case complete
}

public struct TurnUsageSnapshot: Equatable, Sendable {
    public fileprivate(set) var turnID: String?
    public fileprivate(set) var startedAtMilliseconds: Int?
    public fileprivate(set) var totalTokens = 0
    public fileprivate(set) var settledOutputTokens: Int? = nil
    public fileprivate(set) var outputSettledAtMilliseconds: Int? = nil
    public fileprivate(set) var responses: [String: ResponseUsageState] = [:]
    public fileprivate(set) var status: TurnStatus = .idle
    public fileprivate(set) var model: String?
    public fileprivate(set) var modelConflict = false
    public fileprivate(set) var effort: String?
}

public struct TurnUsageTracker: Sendable {
    public private(set) var snapshot = TurnUsageSnapshot()

    public init() {}

    public mutating func consume(_ event: RolloutEvent) {
        switch event {
        case .sessionMetadata:
            break

        case let .taskStarted(turnID, startedAtMilliseconds):
            guard snapshot.turnID != turnID else { return }
            snapshot = TurnUsageSnapshot(
                turnID: turnID,
                startedAtMilliseconds: startedAtMilliseconds,
                totalTokens: 0,
                settledOutputTokens: nil,
                outputSettledAtMilliseconds: nil,
                responses: [:],
                status: .active,
                model: nil,
                modelConflict: false,
                effort: nil
            )

        case let .turnContext(turnID, model, effort):
            guard snapshot.turnID == turnID else { return }
            if let model, !snapshot.modelConflict {
                if let existing = snapshot.model, existing != model {
                    snapshot.model = nil
                    snapshot.modelConflict = true
                } else {
                    snapshot.model = model
                }
            }
            snapshot.effort = effort ?? snapshot.effort

        case let .taskCompleted(turnID):
            guard snapshot.turnID == turnID else { return }
            snapshot.status = .complete

        case let .usage(record):
            guard snapshot.turnID == record.turnID else { return }
            UsageHighWater.absorb(
                totalTokens: &snapshot.totalTokens,
                settledOutputTokens: &snapshot.settledOutputTokens,
                outputSettledAtMilliseconds: &snapshot.outputSettledAtMilliseconds,
                responses: &snapshot.responses,
                record: record
            )
        }
    }
}
