import Darwin
import Foundation
import XCTest
@testable import CodexHUD

final class DesktopFollowerConnectionTests: XCTestCase {
    func testEOFReconnectsAndSubscribesAgainUsingOnlyObserverMessages() throws {
        let server = try LocalUnixServer()
        let queue = DispatchQueue(label: "CodexHUDTests.follower.eof")
        let events = ConnectionEventProbe()
        let connection = DesktopFollowerConnection(socketURL: server.url, queue: queue) { events.record($0) }
        connection.follow(threadID: "thread-fixture")
        connection.start()
        defer { connection.stop() }

        let first = try server.accept(timeout: 4)
        let firstInitialize = try server.readJSONObject(first, timeout: 3)
        try assertInitialize(firstInitialize)
        try server.writeJSON([
            "type": "reply",
            "requestId": try requestID(firstInitialize),
            "method": "initialize",
            "result": ["clientId": "observer-one"],
        ], to: first)
        let firstFollowing = try server.readJSONObject(first, timeout: 3)
        try assertFollowing(firstFollowing, clientID: "observer-one", following: true)
        XCTAssertTrue(events.wait(connected: 1, disconnected: 0, timeout: 3))

        server.closePeer(first)
        XCTAssertTrue(events.wait(connected: 1, disconnected: 1, timeout: 3))

        let second = try server.accept(timeout: 5)
        defer { server.closePeer(second) }
        let secondInitialize = try server.readJSONObject(second, timeout: 3)
        try assertInitialize(secondInitialize)
        try server.writeJSON([
            "type": "reply",
            "requestId": try requestID(secondInitialize),
            "method": "initialize",
            "result": ["clientId": "observer-two"],
        ], to: second)
        let secondFollowing = try server.readJSONObject(second, timeout: 3)
        try assertFollowing(secondFollowing, clientID: "observer-two", following: true)
        XCTAssertTrue(events.wait(connected: 2, disconnected: 1, timeout: 3))

        try server.writeJSON(["type": "broadcast", "method": "unknown-notification"], to: second)
        try server.write(Data("{malformed".utf8), to: second)
        connection.stop()
        let unfollow = try server.readJSONObject(second, timeout: 3)
        try assertFollowing(unfollow, clientID: "observer-two", following: false)
    }

    func testMalformedHandshakeDisconnectsAndUnknownFramesDoNotBreakReconnectedClient() throws {
        let server = try LocalUnixServer()
        let queue = DispatchQueue(label: "CodexHUDTests.follower.handshake")
        let events = ConnectionEventProbe()
        let connection = DesktopFollowerConnection(socketURL: server.url, queue: queue) { events.record($0) }
        connection.follow(threadID: "thread-fixture")
        connection.start()
        defer { connection.stop() }

        let first = try server.accept(timeout: 4)
        let firstInitialize = try server.readJSONObject(first, timeout: 3)
        try assertInitialize(firstInitialize)
        try server.writeJSON([
            "type": "reply",
            "requestId": try requestID(firstInitialize),
            "method": "initialize",
            "result": [:] as [String: String],
        ], to: first)
        server.closePeer(first)
        XCTAssertTrue(events.wait(connected: 0, disconnected: 1, timeout: 3))

        let second = try server.accept(timeout: 5)
        defer { server.closePeer(second) }
        let secondInitialize = try server.readJSONObject(second, timeout: 3)
        try assertInitialize(secondInitialize)
        try server.writeJSON([
            "type": "reply",
            "requestId": try requestID(secondInitialize),
            "method": "initialize",
            "result": ["clientId": "observer-recovered"],
        ], to: second)
        let following = try server.readJSONObject(second, timeout: 3)
        try assertFollowing(following, clientID: "observer-recovered", following: true)
        XCTAssertTrue(events.wait(connected: 1, disconnected: 1, timeout: 3))

        try server.write(Data("{malformed".utf8), to: second)
        try server.writeJSON(["type": "broadcast", "method": "unknown-notification"], to: second)
        connection.stop()
        let unfollow = try server.readJSONObject(second, timeout: 3)
        try assertFollowing(unfollow, clientID: "observer-recovered", following: false)
    }

    private func assertInitialize(_ message: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(message["type"] as? String, "request", file: file, line: line)
        XCTAssertEqual(message["method"] as? String, "initialize", file: file, line: line)
        XCTAssertEqual((message["params"] as? [String: Any])?["clientType"] as? String, "client", file: file, line: line)
        XCTAssertEqual(Set(message.keys), ["type", "requestId", "method", "params"], file: file, line: line)
    }

    private func assertFollowing(
        _ message: [String: Any],
        clientID: String,
        following: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(message["type"] as? String, "broadcast", file: file, line: line)
        XCTAssertEqual(message["method"] as? String, "thread-stream-following-changed", file: file, line: line)
        XCTAssertEqual(message["sourceClientId"] as? String, clientID, file: file, line: line)
        XCTAssertEqual(message["version"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(Set(message.keys), ["type", "method", "sourceClientId", "version", "params"], file: file, line: line)
        let params = try XCTUnwrap(message["params"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(params["conversationId"] as? String, "thread-fixture", file: file, line: line)
        XCTAssertEqual(params["hostId"] as? String, "local", file: file, line: line)
        XCTAssertEqual(params["following"] as? Bool, following, file: file, line: line)
        XCTAssertEqual(Set(params.keys), ["conversationId", "hostId", "following"], file: file, line: line)
    }

    private func requestID(_ message: [String: Any]) throws -> String {
        try XCTUnwrap(message["requestId"] as? String)
    }
}

private final class ConnectionEventProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var connectedCount = 0
    private var disconnectedCount = 0

    func record(_ event: DesktopConnectionEvent) {
        condition.lock()
        switch event {
        case .connected:
            connectedCount += 1
        case .disconnected:
            disconnectedCount += 1
        case .stream:
            break
        }
        condition.broadcast()
        condition.unlock()
    }

    func wait(connected: Int, disconnected: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while connectedCount < connected || disconnectedCount < disconnected {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

private final class LocalUnixServer {
    let url: URL
    private let descriptor: Int32

    init() throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let path = "/tmp/codhud-\(suffix).sock"
        url = URL(fileURLWithPath: path)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.socketError("socket") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let copied = withUnsafeMutableBytes(of: &address.sun_path) { destination -> Bool in
            let pathBytes = Array(path.utf8) + [0]
            guard pathBytes.count <= destination.count, let base = destination.baseAddress else { return false }
            base.copyMemory(from: pathBytes, byteCount: pathBytes.count)
            return true
        }
        guard copied else { throw Self.socketError("socket path") }

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Self.socketError("bind") }
        guard Darwin.listen(descriptor, 4) == 0 else { throw Self.socketError("listen") }
    }

    deinit {
        Darwin.close(descriptor)
        unlink(url.path)
    }

    func accept(timeout: TimeInterval) throws -> Int32 {
        try waitForReadable(descriptor, timeout: timeout)
        let peer = Darwin.accept(descriptor, nil, nil)
        guard peer >= 0 else { throw Self.socketError("accept") }
        return peer
    }

    func closePeer(_ peer: Int32) {
        _ = Darwin.shutdown(peer, SHUT_RDWR)
        Darwin.close(peer)
    }

    func readJSONObject(_ peer: Int32, timeout: TimeInterval) throws -> [String: Any] {
        let header = try readExactly(4, from: peer, timeout: timeout)
        let bytes = [UInt8](header)
        let length = Int(UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24))
        guard length > 0, length <= 16 * 1_024 * 1_024 else { throw Self.socketError("invalid frame length") }
        let payload = try readExactly(length, from: peer, timeout: timeout)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw Self.socketError("invalid JSON object")
        }
        return object
    }

    func writeJSON(_ object: [String: Any], to peer: Int32) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        try write(payload, to: peer)
    }

    func write(_ payload: Data, to peer: Int32) throws {
        var length = UInt32(payload.count).littleEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        try writeAll(frame, to: peer)
    }

    private func readExactly(_ length: Int, from peer: Int32, timeout: TimeInterval) throws -> Data {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var data = Data()
        data.reserveCapacity(length)
        while data.count < length {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw Self.socketError("read timeout") }
            try waitForReadable(peer, timeout: remaining)
            var chunk = [UInt8](repeating: 0, count: length - data.count)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: chunk.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw Self.socketError("peer closed while reading")
            }
        }
        return data
    }

    private func writeAll(_ data: Data, to peer: Int32) throws {
        let result = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var written = 0
            while written < raw.count {
                let count = Darwin.send(peer, base.advanced(by: written), raw.count - written, 0)
                if count > 0 {
                    written += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard result else { throw Self.socketError("write") }
    }

    private func waitForReadable(_ fd: Int32, timeout: TimeInterval) throws {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(1, min(timeout * 1_000, Double(Int32.max))))
        let result = Darwin.poll(&descriptor, 1, milliseconds)
        guard result > 0 else { throw Self.socketError("poll timeout") }
    }

    private static func socketError(_ operation: String) -> NSError {
        NSError(domain: "CodexHUDTests.LocalUnixServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
    }
}
