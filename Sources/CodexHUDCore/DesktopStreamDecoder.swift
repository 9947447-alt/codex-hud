import CoreFoundation
import Foundation

public struct DesktopIPCFrameDecoder {
    private let maximumFrameBytes: Int
    private var buffer = Data()

    public init(maximumFrameBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumFrameBytes = min(max(maximumFrameBytes, 1), 16 * 1_024 * 1_024)
    }

    public mutating func append<S: DataProtocol>(_ bytes: S) throws -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = UInt32(buffer[0])
                | (UInt32(buffer[1]) << 8)
                | (UInt32(buffer[2]) << 16)
                | (UInt32(buffer[3]) << 24)
            guard length > 0, length <= maximumFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw DesktopStreamDecodeError.invalidFrameLength
            }
            let frameLength = 4 + Int(length)
            guard buffer.count >= frameLength else { break }
            frames.append(buffer.subdata(in: 4..<frameLength))
            buffer.removeSubrange(0..<frameLength)
        }
        if buffer.count > maximumFrameBytes + 4 {
            buffer.removeAll(keepingCapacity: false)
            throw DesktopStreamDecodeError.invalidFrameLength
        }
        return frames
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

public enum DesktopStreamDecodeError: Error {
    case invalidFrameLength
}

public enum DesktopIPCOutboundMessage: Sendable {
    case initialize(requestID: String)
    case following(clientID: String, threadID: String, isFollowing: Bool)

    public func encodedFrame() -> Data? {
        let message: [String: Any]
        switch self {
        case let .initialize(requestID):
            message = [
                "type": "request",
                "requestId": requestID,
                "method": "initialize",
                "params": ["clientType": "client"],
            ]
        case let .following(clientID, threadID, isFollowing):
            message = [
                "type": "broadcast",
                "method": "thread-stream-following-changed",
                "sourceClientId": clientID,
                "version": 1,
                "params": [
                    "conversationId": threadID,
                    "hostId": "local",
                    "following": isFollowing,
                ],
            ]
        }
        guard
            let payload = try? JSONSerialization.data(withJSONObject: message),
            !payload.isEmpty,
            payload.count <= Int(UInt32.max)
        else { return nil }
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }
}

public enum DesktopStreamEvent: Sendable {
    case snapshot(DesktopConversationSnapshot)
    case patches(DesktopPatchBatch)
}

public struct DesktopConversationSnapshot: Sendable {
    public let threadID: String
    public let hostID: String
    public let revision: UInt64
    public let model: String?
    public let effort: String?
    public let runtimeActive: Bool
    public let turns: [DesktopTurnSnapshot]
}

public enum DesktopTurnItemKind: Equatable, Sendable {
    case agentMessage
    case reasoning
    case commandExecution
    case tool
    case other
}

public enum DesktopTurnStatus: Equatable, Sendable {
    case inProgress
    case completed
    case other
}

public struct DesktopTurnItemSnapshot: Sendable {
    public let id: String
    public let kind: DesktopTurnItemKind
    public let text: String?
    public let commandStatus: DesktopTurnStatus

    public var textUTF16Length: Int { text?.utf16.count ?? 0 }
}

public struct DesktopTurnSnapshot: Sendable {
    public let entityKey: String
    public let turnID: String
    public let status: DesktopTurnStatus
    public let startedAtMilliseconds: Int?
    public let items: [DesktopTurnItemSnapshot]
}

public struct DesktopPatchBatch: Sendable {
    public let threadID: String
    public let hostID: String
    public let baseRevision: UInt64
    public let revision: UInt64
    public let operations: [DesktopStateOperation]
    public let acceptedTextChanges: [DesktopAcceptedTextChange]
}

public struct DesktopStateOperation: Sendable {
    public let operation: String
    public let path: [String]
    public let turnValue: DesktopTurnSnapshot?
    public let itemValue: DesktopTurnItemSnapshot?
    public let textValue: String?
    public let statusValue: String?
    public let runtimeTypeValue: String?

    public var textValueUTF16Length: Int? { textValue?.utf16.count }
}

public struct DesktopAcceptedTextChange: Sendable {
    public let item: LiveItemIdentity
    public let edits: [LiveTextEdit]
}

public enum DesktopStreamDecoder {
    public static func decode(_ data: Data) -> DesktopStreamEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["type"] as? String == "broadcast",
            root["method"] as? String == "thread-stream-state-changed",
            integer(root["version"]) == 11,
            let params = root["params"] as? [String: Any],
            let threadID = nonemptyString(params["conversationId"]),
            let hostID = nonemptyString(params["hostId"]),
            let change = params["change"] as? [String: Any],
            let type = change["type"] as? String,
            let revision = unsignedInteger(change["revision"])
        else { return nil }

        switch type {
        case "snapshot":
            guard let state = change["conversationState"] as? [String: Any] else { return nil }
            return .snapshot(snapshot(threadID: threadID, hostID: hostID, revision: revision, state: state))
        case "patches":
            guard
                let baseRevision = unsignedInteger(change["baseRevision"]),
                let patchValues = change["patches"] as? [Any],
                patchValues.count <= 2_048
            else { return nil }
            return .patches(DesktopPatchBatch(
                threadID: threadID,
                hostID: hostID,
                baseRevision: baseRevision,
                revision: revision,
                operations: patchValues.compactMap(operation),
                acceptedTextChanges: acceptedTextChanges(change["acceptedTextChanges"], hostID: hostID, threadID: threadID)
            ))
        default:
            return nil
        }
    }

    private static func snapshot(
        threadID: String,
        hostID: String,
        revision: UInt64,
        state: [String: Any]
    ) -> DesktopConversationSnapshot {
        let settings = state["latestThreadSettings"] as? [String: Any]
        let runtime = state["threadRuntimeStatus"] as? [String: Any]
        let entities = state["turnHistory"] as? [String: Any]
        let history = entities?["history"] as? [String: Any]
        let turnsByKey = history?["entitiesByKey"] as? [String: Any] ?? [:]
        let turns = turnsByKey.keys.sorted().compactMap { key -> DesktopTurnSnapshot? in
            guard let value = turnsByKey[key] as? [String: Any],
                  let turnID = nonemptyString(value["turnId"]) else { return nil }
            let items = (value["items"] as? [Any] ?? []).compactMap { item($0) }
            return DesktopTurnSnapshot(
                entityKey: key,
                turnID: turnID,
                status: turnStatus(value["status"]),
                startedAtMilliseconds: integer(value["turnStartedAtMs"]),
                items: items
            )
        }

        return DesktopConversationSnapshot(
            threadID: threadID,
            hostID: hostID,
            revision: revision,
            model: nonemptyString(settings?["model"]) ?? nonemptyString(state["latestModel"]),
            effort: nonemptyString(settings?["effort"]),
            runtimeActive: runtime?["type"] as? String == "active",
            turns: turns
        )
    }

    private static func operation(_ value: Any) -> DesktopStateOperation? {
        guard
            let raw = value as? [String: Any],
            let operation = nonemptyString(raw["op"]),
            let pathValues = raw["path"] as? [Any],
            pathValues.count <= 32
        else { return nil }
        let path = pathValues.compactMap(pathComponent)
        guard path.count == pathValues.count else { return nil }
        let rawValue = raw["value"]
        let fullTurn = turn(rawValue, entityKey: path.last ?? "")
        let fullItem = item(rawValue)
        let text = rawValue as? String
        let status = (rawValue as? [String: Any]).flatMap { nonemptyString($0["status"]) }
            ?? (path.last == "status" ? nonemptyString(rawValue) : nil)
        let runtimeType = path.starts(with: ["threadRuntimeStatus"]) && path.last == "type"
            ? nonemptyString(rawValue)
            : nil
        return DesktopStateOperation(
            operation: operation,
            path: path,
            turnValue: fullTurn,
            itemValue: fullItem,
            textValue: text,
            statusValue: status,
            runtimeTypeValue: runtimeType
        )
    }

    private static func acceptedTextChanges(
        _ value: Any?,
        hostID: String,
        threadID: String
    ) -> [DesktopAcceptedTextChange] {
        guard let changes = value as? [Any], changes.count <= 2_048 else { return [] }
        return changes.compactMap { value in
            guard
                let raw = value as? [String: Any],
                let key = raw["key"] as? [String: Any],
                nonemptyString(key["hostId"]) == hostID,
                nonemptyString(key["threadId"]) == threadID,
                let entityKey = nonemptyString(key["entityKey"]),
                let itemID = nonemptyString(key["itemId"]),
                let target = raw["target"] as? [String: Any],
                target["field"] as? String == "text",
                let rawEdits = raw["edits"] as? [Any],
                !rawEdits.isEmpty,
                rawEdits.count <= 256
            else { return nil }

            let edits = rawEdits.compactMap { edit -> LiveTextEdit? in
                guard
                    let value = edit as? [String: Any],
                    let at = integer(value["at"]),
                    let deleted = integer(value["deleteCount"]),
                    let inserted = value["insert"] as? String,
                    at >= 0,
                    deleted >= 0,
                    inserted.utf8.count <= 4_096
                else { return nil }
                return LiveTextEdit(atUTF16: at, deleteCountUTF16: deleted, insert: inserted)
            }
            guard edits.count == rawEdits.count else { return nil }
            return DesktopAcceptedTextChange(
                item: LiveItemIdentity(hostID: hostID, threadID: threadID, entityKey: entityKey, itemID: itemID),
                edits: edits
            )
        }
    }

    private static func item(_ value: Any?) -> DesktopTurnItemSnapshot? {
        guard
            let raw = value as? [String: Any],
            let id = nonemptyString(raw["id"]),
            let type = nonemptyString(raw["type"])
        else { return nil }
        let kind: DesktopTurnItemKind
        switch type {
        case "agentMessage": kind = .agentMessage
        case "reasoning": kind = .reasoning
        case "commandExecution": kind = .commandExecution
        case "mcpToolCall", "webSearchCall", "imageGenerationCall": kind = .tool
        default: kind = .other
        }
        return DesktopTurnItemSnapshot(
            id: id,
            kind: kind,
            text: kind == .agentMessage ? raw["text"] as? String : nil,
            commandStatus: turnStatus(raw["status"])
        )
    }

    private static func turn(_ value: Any?, entityKey: String) -> DesktopTurnSnapshot? {
        guard
            let raw = value as? [String: Any],
            let turnID = nonemptyString(raw["turnId"])
        else { return nil }
        return DesktopTurnSnapshot(
            entityKey: entityKey,
            turnID: turnID,
            status: turnStatus(raw["status"]),
            startedAtMilliseconds: integer(raw["turnStartedAtMs"]),
            items: (raw["items"] as? [Any] ?? []).compactMap { item($0) }
        )
    }

    private static func turnStatus(_ value: Any?) -> DesktopTurnStatus {
        switch value as? String {
        case "inProgress": .inProgress
        case "completed": .completed
        default: .other
        }
    }

    private static func pathComponent(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let number = integer(value) { return String(number) }
        return nil
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func integer(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue.rounded(.towardZero) == number.doubleValue,
            number.doubleValue >= Double(Int.min),
            number.doubleValue < Double(Int.max)
        else { return nil }
        return number.intValue
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let int = integer(value), int >= 0 else { return nil }
        return UInt64(int)
    }
}
