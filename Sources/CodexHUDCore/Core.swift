import CoreFoundation
import Foundation

public struct TokenUsageRecord: Equatable, Sendable {
    public let threadID: String?
    public let turnID: String
    public let rootTurnID: String?
    public let responseID: String
    public let totalTokens: Int

    public init(threadID: String? = nil, turnID: String, rootTurnID: String? = nil, responseID: String, totalTokens: Int) {
        self.threadID = threadID
        self.turnID = turnID
        self.rootTurnID = rootTurnID
        self.responseID = responseID
        self.totalTokens = totalTokens
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
                let usage = payload["turn_token_usage"] as? [String: Any],
                let total = nonnegativeInteger(usage["total_tokens"])
            else {
                return nil
            }
            return .usage(.init(
                threadID: nonemptyString(payload["thread_id"]),
                turnID: turnID,
                rootTurnID: nonemptyString(payload["root_turn_id"]),
                responseID: responseID,
                totalTokens: total
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

public struct SubagentUsageLedger: Sendable {
    private struct Key: Hashable {
        let threadID: String
        let turnID: String
    }

    private struct Value {
        let rootTurnID: String
        var totalTokens: Int
    }

    private var values: [Key: Value] = [:]
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
            value.totalTokens = max(value.totalTokens, record.totalTokens)
            values[key] = value
        } else if values[key] == nil {
            values[key] = Value(rootTurnID: rootTurnID, totalTokens: record.totalTokens)
            insertionOrder.append(key)
            trimIfNeeded()
        } else {
            return
        }
    }

    public mutating func retain(rootTurnID: String) {
        values = values.filter { $0.value.rootTurnID == rootTurnID }
        insertionOrder.removeAll { values[$0] == nil }
    }

    public mutating func remove(threadID: String) {
        values = values.filter { $0.key.threadID != threadID }
        insertionOrder.removeAll { $0.threadID == threadID }
    }

    public func totalTokens(rootTurnID: String, excludingThreadID parentThreadID: String) -> Int {
        values.reduce(into: 0) { total, entry in
            guard entry.key.threadID != parentThreadID, entry.value.rootTurnID == rootTurnID else { return }
            let (sum, overflow) = total.addingReportingOverflow(entry.value.totalTokens)
            total = overflow ? Int.max : sum
        }
    }

    private mutating func trimIfNeeded() {
        while insertionOrder.count > maximumEntries {
            let expired = insertionOrder.removeFirst()
            values.removeValue(forKey: expired)
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
    public fileprivate(set) var status: TurnStatus = .idle
    public fileprivate(set) var model: String?
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
                status: .active,
                model: nil,
                effort: nil
            )

        case let .turnContext(turnID, model, effort):
            guard snapshot.turnID == turnID else { return }
            snapshot.model = model ?? snapshot.model
            snapshot.effort = effort ?? snapshot.effort

        case let .taskCompleted(turnID):
            guard snapshot.turnID == turnID else { return }
            snapshot.status = .complete

        case let .usage(record):
            guard snapshot.turnID == record.turnID else { return }
            snapshot.totalTokens = max(snapshot.totalTokens, record.totalTokens)
        }
    }
}
