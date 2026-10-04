import XCTest
@testable import CodexHUDCore

final class DesktopStreamDecoderTests: XCTestCase {
    func testLengthPrefixedDecoderAcceptsSplitAndCoalescedFrames() throws {
        let first = Data(#"{"type":"reply","requestId":"one"}"#.utf8)
        let second = Data(#"{"type":"broadcast","method":"noop"}"#.utf8)
        var decoder = DesktopIPCFrameDecoder()

        XCTAssertTrue(try decoder.append(frame(first).prefix(3)).isEmpty)
        let frames = try decoder.append(frame(first).dropFirst(3) + frame(second))

        XCTAssertEqual(frames, [first, second])
    }

    func testSnapshotReadsLiveEntityMapAndTypedStatusWithoutRetainingTranscript() throws {
        let message = #"{"type":"broadcast","method":"thread-stream-state-changed","version":11,"params":{"conversationId":"thread-a","hostId":"local","change":{"type":"snapshot","revision":4,"conversationState":{"latestModel":"gpt-6.1-sol","latestThreadSettings":{"model":"gpt-6.1-sol","effort":"xhigh"},"latestTokenUsageInfo":{"totalTokens":999},"threadRuntimeStatus":{"type":"active"},"turns":[],"turnHistory":{"history":{"entitiesByKey":{"entity-a":{"turnId":"turn-a","status":"inProgress","turnStartedAtMs":1700000000000,"items":[{"id":"item-a","type":"agentMessage","text":"synthetic prior text"},{"id":"command-a","type":"commandExecution","status":"inProgress"}]}}}}}}}}"#

        guard case let .snapshot(snapshot) = try XCTUnwrap(DesktopStreamDecoder.decode(Data(message.utf8))) else {
            return XCTFail("Expected a snapshot event")
        }
        XCTAssertEqual(snapshot.threadID, "thread-a")
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(snapshot.model, "gpt-6.1-sol")
        XCTAssertEqual(snapshot.effort, "xhigh")
        XCTAssertTrue(snapshot.runtimeActive)
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].turnID, "turn-a")
        XCTAssertEqual(snapshot.turns[0].status, .inProgress)
        XCTAssertEqual(snapshot.turns[0].items.map(\.kind), [.agentMessage, .commandExecution])
        XCTAssertEqual(snapshot.turns[0].items[0].textUTF16Length, "synthetic prior text".utf16.count)
        XCTAssertEqual(snapshot.turns[0].items[1].commandStatus, .inProgress)
    }

    func testPatchCarriesTypedTextEditsAndIgnoresOpaqueEditType() throws {
        let message = #"{"type":"broadcast","method":"thread-stream-state-changed","version":11,"params":{"conversationId":"thread-a","hostId":"local","change":{"type":"patches","baseRevision":4,"revision":5,"patches":[{"op":"replace","path":["turnHistory","history","entitiesByKey","entity-a","items",0,"text"],"value":"synthetic full updated text"}],"acceptedTextChanges":[{"type":"xYz1","key":{"hostId":"local","threadId":"thread-a","entityKey":"entity-a","itemId":"item-a"},"target":{"field":"text"},"edits":[{"at":20,"deleteCount":0,"insert":" added"}]}]}}}"#

        guard case let .patches(patch) = try XCTUnwrap(DesktopStreamDecoder.decode(Data(message.utf8))) else {
            return XCTFail("Expected a patches event")
        }
        XCTAssertEqual(patch.baseRevision, 4)
        XCTAssertEqual(patch.revision, 5)
        XCTAssertEqual(patch.operations.count, 1)
        XCTAssertEqual(patch.operations[0].path, ["turnHistory", "history", "entitiesByKey", "entity-a", "items", "0", "text"])
        XCTAssertEqual(patch.operations[0].textValueUTF16Length, "synthetic full updated text".utf16.count)
        XCTAssertEqual(patch.acceptedTextChanges.count, 1)
        XCTAssertEqual(patch.acceptedTextChanges[0].item.itemID, "item-a")
        XCTAssertEqual(patch.acceptedTextChanges[0].edits, [.init(atUTF16: 20, deleteCountUTF16: 0, insert: " added")])
    }

    func testPatchCanAddTurnEntityAndUpdateRuntimeState() throws {
        let message = #"{"type":"broadcast","method":"thread-stream-state-changed","version":11,"params":{"conversationId":"thread-a","hostId":"local","change":{"type":"patches","baseRevision":4,"revision":7,"patches":[{"op":"add","path":["turnHistory","history","entitiesByKey","entity-b"],"value":{"turnId":"turn-b","status":"inProgress","turnStartedAtMs":1700000000000,"items":[]}},{"op":"replace","path":["threadRuntimeStatus","type"],"value":"active"}]}}}"#

        guard case let .patches(patch) = try XCTUnwrap(DesktopStreamDecoder.decode(Data(message.utf8))) else {
            return XCTFail("Expected a patches event")
        }
        XCTAssertEqual(patch.revision, 7)
        XCTAssertEqual(patch.operations[0].turnValue?.entityKey, "entity-b")
        XCTAssertEqual(patch.operations[0].turnValue?.turnID, "turn-b")
        XCTAssertEqual(patch.operations[0].turnValue?.status, .inProgress)
        XCTAssertEqual(patch.operations[1].runtimeTypeValue, "active")
    }

    func testMalformedAndUnrelatedNotificationsAreIgnored() {
        XCTAssertNil(DesktopStreamDecoder.decode(Data("{broken".utf8)))
        XCTAssertNil(DesktopStreamDecoder.decode(Data(#"{"type":"broadcast","method":"other"}"#.utf8)))
        var decoder = DesktopIPCFrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0xff, 0xff, 0xff, 0xff])))
    }

    func testOutboundAllowlistContainsOnlyInitializeAndTemporaryFollowingRegistration() throws {
        let initialize = try XCTUnwrap(DesktopIPCOutboundMessage.initialize(requestID: "request-a").encodedFrame())
        let follow = try XCTUnwrap(DesktopIPCOutboundMessage.following(clientID: "client-a", threadID: "thread-a", isFollowing: true).encodedFrame())
        let unfollow = try XCTUnwrap(DesktopIPCOutboundMessage.following(clientID: "client-a", threadID: "thread-a", isFollowing: false).encodedFrame())

        let objects = [initialize, follow, unfollow].compactMap { frame -> [String: Any]? in
            let payload = frame.dropFirst(4)
            return try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        }
        XCTAssertEqual(objects.count, 3)
        XCTAssertEqual(objects[0]["method"] as? String, "initialize")
        XCTAssertEqual((objects[0]["params"] as? [String: String])?["clientType"], "client")
        XCTAssertEqual(objects[1]["method"] as? String, "thread-stream-following-changed")
        XCTAssertEqual(((objects[1]["params"] as? [String: Any])?["following"] as? Bool), true)
        XCTAssertEqual(((objects[2]["params"] as? [String: Any])?["following"] as? Bool), false)
    }

    private func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }
}
