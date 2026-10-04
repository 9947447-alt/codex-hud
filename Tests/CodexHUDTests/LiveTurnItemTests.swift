import Foundation
import XCTest
import CodexHUDCore
@testable import CodexHUD

final class LiveTurnItemTests: XCTestCase {
    func testNegativeTextIndexPreservesTrackedItemsAndPatchFlags() throws {
        var turn = fixtureTurn()
        let originalItems = turn.items
        var newIDs: Set<String> = ["already-created"]
        var unsupported = false
        let operation = try decodeOperation(op: "replace", index: -1, field: "text", value: "synthetic replacement")

        XCTAssertFalse(turn.applyItemOperation(
            operation, itemIndex: -1, entityIndex: 2,
            newlyCreatedAgentItemIDs: &newIDs, unsupportedStatePatch: &unsupported
        ))

        XCTAssertEqual(turn.items, originalItems)
        XCTAssertEqual(newIDs, ["already-created"])
        XCTAssertFalse(unsupported)
    }

    func testNegativeItemOperationsCannotCrashOrMutateTrackingState() throws {
        let item: [String: Any] = ["id": "invalid-fixture", "type": "agentMessage", "text": "synthetic text"]
        for index in [-1, Int.min] {
            for (op, field, value) in [
                ("add", nil, item as Any),
                ("replace", nil, item as Any),
                ("remove", nil, NSNull() as Any),
                ("replace", "status", "completed" as Any),
                ("replace", "phase", "synthetic phase" as Any),
            ] as [(String, String?, Any)] {
                var turn = fixtureTurn()
                let originalItems = turn.items
                var newIDs: Set<String> = ["already-created"]
                var unsupported = false
                let operation = try decodeOperation(op: op, index: index, field: field, value: value)

                XCTAssertFalse(turn.applyItemOperation(
                    operation, itemIndex: index, entityIndex: 2,
                    newlyCreatedAgentItemIDs: &newIDs, unsupportedStatePatch: &unsupported
                ))
                XCTAssertEqual(turn.items, originalItems)
                XCTAssertEqual(newIDs, ["already-created"])
                XCTAssertFalse(unsupported)
            }
        }
    }

    func testValidItemOperationsKeepExistingInsertionAndUpdateSemantics() throws {
        var turn = fixtureTurn()
        var newIDs: Set<String> = []
        var unsupported = false

        func apply(_ op: String, _ index: Int, field: String? = nil, value: Any) throws {
            let operation = try decodeOperation(op: op, index: index, field: field, value: value)
            XCTAssertTrue(turn.applyItemOperation(
                operation, itemIndex: index, entityIndex: 2,
                newlyCreatedAgentItemIDs: &newIDs, unsupportedStatePatch: &unsupported
            ))
        }

        try apply("add", 0, value: ["id": "agent-new", "type": "agentMessage", "text": "synthetic"])
        XCTAssertEqual(turn.items.map(\.id), ["agent-new", "item-fixture"])
        XCTAssertEqual(newIDs, ["agent-new"])

        try apply("add", 2, value: ["id": "command-end", "type": "commandExecution", "status": "inProgress"])
        try apply("add", Int.max, value: ["id": "tool-end", "type": "mcpToolCall", "status": "inProgress"])
        XCTAssertEqual(turn.items.map(\.id), ["agent-new", "item-fixture", "command-end", "tool-end"])

        try apply("replace", 0, field: "text", value: "synthetic 😀")
        XCTAssertEqual(turn.items[0].textUTF16Length, "synthetic 😀".utf16.count)
        try apply("replace", 2, field: "status", value: "completed")
        XCTAssertEqual(turn.items[2].commandStatus, .completed)
        try apply("replace", 1, value: ["id": "agent-replaced", "type": "agentMessage", "text": "x"])
        XCTAssertEqual(turn.items[1].id, "agent-replaced")
        XCTAssertEqual(newIDs, ["agent-new", "agent-replaced"])

        try apply("remove", 1, value: NSNull())
        XCTAssertEqual(turn.items.map(\.id), ["agent-new", "command-end", "tool-end"])
        XCTAssertFalse(unsupported)
    }

    func testRejectedNegativeItemCannotSupplySameIDBaselineForValidItem() throws {
        let itemID = "agent-fixture"
        let valid = try decodeOperation(op: "add", index: 0, value: [
            "id": itemID, "type": "agentMessage", "text": "OK",
        ])
        for (op, index) in [("add", -1), ("replace", -1), ("add", Int.min), ("replace", Int.min)] {
            let invalid = try decodeOperation(op: op, index: index, value: [
                "id": itemID, "type": "agentMessage", "text": "INVALID BASELINE",
            ])
            let operations = [invalid, valid]
            var turn = fixtureTurn()
            var newIDs: Set<String> = []
            var unsupported = false
            for operation in operations {
                let index = try XCTUnwrap(Int(operation.path[5]))
                _ = turn.applyItemOperation(
                    operation, itemIndex: index, entityIndex: 2,
                    newlyCreatedAgentItemIDs: &newIDs, unsupportedStatePatch: &unsupported
                )
            }
            XCTAssertEqual(turn.items.first?.id, itemID)
            XCTAssertEqual(turn.items.first?.textUTF16Length, 2)
            XCTAssertEqual(newIDs, [itemID])
            XCTAssertFalse(unsupported)

            XCTAssertNil(turn.matchingItemSnapshotText(operations: [invalid], itemID: itemID))
            XCTAssertEqual(turn.matchingItemSnapshotText(operations: [valid], itemID: itemID), "OK")
            let baseline = try XCTUnwrap(turn.matchingItemSnapshotText(operations: operations, itemID: itemID))
            XCTAssertEqual(baseline, "OK")
            let identity = LiveItemIdentity(hostID: "local", threadID: "thread-fixture", entityKey: "entity-fixture", itemID: itemID)
            var meter = OutputSpeedMeter(tokenCounter: FixtureCharacterCounter())
            meter.establishBaseline(item: identity, fullText: baseline, revision: 2, uptime: 1)
            meter.accept(
                revision: 3, item: identity, kind: .agentMessage,
                edit: LiveTextEdit(atUTF16: 2, deleteCountUTF16: 0, insert: "!"),
                updatedText: "OK!", uptime: 2, isContinuous: true
            )
            XCTAssertEqual(meter.speed(at: 2), 1)
        }
    }

    private func fixtureTurn() -> LiveTurn {
        LiveTurn(
            entityKey: "entity-fixture", turnID: "turn-fixture", status: .inProgress,
            startedAtMilliseconds: 1,
            items: [LiveItem(id: "item-fixture", kind: .agentMessage, textUTF16Length: 4, commandStatus: .other)]
        )
    }

    private func decodeOperation(op: String, index: Int, field: String? = nil, value: Any) throws -> DesktopStateOperation {
        var path: [Any] = ["turnHistory", "history", "entitiesByKey", "entity-fixture", "items", index == Int.max ? String(index) as Any : index]
        if let field { path.append(field) }
        let message: [String: Any] = [
            "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "params": [
                "conversationId": "thread-fixture", "hostId": "local",
                "change": [
                    "type": "patches", "baseRevision": 1, "revision": 2,
                    "patches": [["op": op, "path": path, "value": value]],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard case let .patches(batch) = try XCTUnwrap(DesktopStreamDecoder.decode(data)) else {
            throw NSError(domain: "LiveTurnItemTests", code: 1)
        }
        return try XCTUnwrap(batch.operations.first)
    }
}

private struct FixtureCharacterCounter: TokenCounter {
    func countTokens(in text: String) -> Int { text.utf16.count }
}
