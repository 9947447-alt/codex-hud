import CodexHUDCore
import Darwin
import Foundation

enum DesktopConnectionEvent: Sendable {
    case connected
    case disconnected
    case stream(DesktopStreamEvent)
}

final class DesktopFollowerConnection: @unchecked Sendable {
    private let queue: DispatchQueue
    private let socketURL: URL
    private let onEvent: @Sendable (DesktopConnectionEvent) -> Void
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var frameDecoder = DesktopIPCFrameDecoder()
    private var initializeRequestID: String?
    private var clientID: String?
    private var desiredThreadID: String?
    private var registeredThreadID: String?
    private var reconnectWork: DispatchWorkItem?
    private var handshakeWork: DispatchWorkItem?
    private var shouldReconnect = false

    init(
        socketURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock"),
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (DesktopConnectionEvent) -> Void
    ) {
        self.socketURL = socketURL
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() {
        queue.async {
            guard !self.shouldReconnect else { return }
            self.shouldReconnect = true
            self.connect()
        }
    }

    func follow(threadID: String?) {
        queue.async {
            guard self.desiredThreadID != threadID else { return }
            self.desiredThreadID = threadID
            guard self.clientID != nil else { return }
            self.updateFollowingRegistration()
        }
    }

    func stop() {
        queue.async {
            self.shouldReconnect = false
            self.reconnectWork?.cancel()
            self.reconnectWork = nil
            let previousRegistration = self.registeredThreadID
            self.registeredThreadID = nil
            if self.descriptor >= 0 {
                self.sendFollowing(threadID: previousRegistration, following: false)
            }
            self.handshakeWork?.cancel()
            self.handshakeWork = nil
            self.clientID = nil
            self.closeSocket()
        }
    }

    func refreshSnapshot() {
        queue.async {
            guard let clientID = self.clientID, let threadID = self.registeredThreadID else { return }
            self.sendFollowing(threadID: threadID, following: false)
            guard self.descriptor >= 0, self.clientID == clientID else { return }
            self.sendFollowing(threadID: threadID, following: true)
        }
    }

    private func connect() {
        guard shouldReconnect, descriptor < 0 else { return }
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            scheduleReconnect()
            return
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleReconnect()
            return
        }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let addressReady = withUnsafeMutableBytes(of: &address.sun_path) { pathBytes -> Bool in
            guard path.utf8.count + 1 <= pathBytes.count else { return false }
            pathBytes.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.copyBytes(from: path.utf8)
            return true
        }
        guard addressReady else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }

        let currentFlags = fcntl(fd, F_GETFL)
        guard currentFlags >= 0, fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            scheduleReconnect()
            return
        }
        descriptor = fd
        frameDecoder.reset()
        beginReading(fd: fd)
        sendInitialize()
    }

    private func beginReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
    }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
        while descriptor >= 0 {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress, buffer.count)
            }
            if count > 0 {
                do {
                    let frames = try frameDecoder.append(bytes.prefix(count))
                    for frame in frames { handle(frame) }
                } catch {
                    connectionFailed()
                    return
                }
                continue
            }
            if count == 0 {
                connectionFailed()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            connectionFailed()
            return
        }
    }

    private func handle(_ frame: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: frame) as? [String: Any] else { return }
        if let requestID = initializeRequestID, root["requestId"] as? String == requestID {
            guard
                root["method"] as? String == "initialize",
                let result = root["result"] as? [String: Any],
                let clientID = result["clientId"] as? String,
                !clientID.isEmpty
            else {
                connectionFailed()
                return
            }
            initializeRequestID = nil
            handshakeWork?.cancel()
            handshakeWork = nil
            self.clientID = clientID
            onEvent(.connected)
            updateFollowingRegistration()
            return
        }
        if let event = DesktopStreamDecoder.decode(frame) {
            onEvent(.stream(event))
        }
    }

    private func sendInitialize() {
        let requestID = UUID().uuidString
        initializeRequestID = requestID
        send(.initialize(requestID: requestID))
        guard descriptor >= 0 else { return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.clientID == nil, self.descriptor >= 0 else { return }
            self.connectionFailed()
        }
        handshakeWork = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    private func updateFollowingRegistration() {
        guard clientID != nil else { return }
        if registeredThreadID != desiredThreadID {
            let previousRegistration = registeredThreadID
            registeredThreadID = nil
            sendFollowing(threadID: previousRegistration, following: false)
            guard descriptor >= 0, clientID != nil else { return }
            if let desiredThreadID {
                sendFollowing(threadID: desiredThreadID, following: true)
                if descriptor >= 0 { registeredThreadID = desiredThreadID }
            }
        }
    }

    private func sendFollowing(threadID: String?, following: Bool) {
        guard let clientID, let threadID else { return }
        send(.following(clientID: clientID, threadID: threadID, isFollowing: following))
    }

    private func send(_ message: DesktopIPCOutboundMessage) {
        guard descriptor >= 0, let framed = message.encodedFrame(), framed.count <= 16 * 1_024 * 1_024 else { return }
        let success = framed.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
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
        if !success { connectionFailed() }
    }

    private func connectionFailed() {
        guard descriptor >= 0 else { return }
        registeredThreadID = nil
        clientID = nil
        initializeRequestID = nil
        handshakeWork?.cancel()
        handshakeWork = nil
        closeSocket()
        onEvent(.disconnected)
        scheduleReconnect()
    }

    private func closeSocket() {
        descriptor = -1
        readSource?.cancel()
        readSource = nil
        frameDecoder.reset()
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWork = nil
            self.connect()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
