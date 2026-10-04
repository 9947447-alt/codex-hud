import CoreServices
import Darwin
import Dispatch
import Foundation

public enum RolloutWatchEvent: Sendable {
    case event(threadID: String, event: RolloutEvent)
    case removed(threadID: String)
}

/// Incrementally tails typed rollout telemetry without retaining conversation text.
/// All mutable state and callbacks are confined to the caller-provided serial queue.
/// FSEvents discovers paths; bounded vnode sources follow active file writes.
public final class IncrementalRolloutWatcher: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let volume: UInt64
        let file: UInt64
    }

    private struct FileState {
        var offset: UInt64 = 0
        var partialLine = Data()
        var discardingOversizedLine = false
        var threadID: String?
        var eventsBeforeMetadata: [RolloutEvent] = []
        var identity: FileIdentity?
        var latestStartedAtMilliseconds: Int?
    }

    private struct FileWatch {
        let source: any DispatchSourceFileSystemObject
        let identity: FileIdentity?
        var latestStartedAtMilliseconds: Int?
        var pendingOrder: UInt64?
    }

    private struct FileSnapshot {
        let size: UInt64
        let identity: FileIdentity?
    }

    private static let maxBytesPerRead = 256 * 1024
    private static let maxLineBytes = 1024 * 1024
    private static let maxEventsBeforeMetadata = 64
    private static let maxWatchedFiles = 64 // Keep the newest authoritative task_started timestamps.
    private static let maxPendingWatches = 4 // Small separate pool for files before a timestamp is decoded.

    private let rootURL: URL
    private let rootPath: String
    private let queue: DispatchQueue
    private let onEvent: @Sendable (RolloutWatchEvent) -> Void
    private var stream: FSEventStreamRef?
    private var isRunning = false
    private var files: [String: FileState] = [:]
    private var pendingDrains: Set<String> = []
    private var fileWatches: [String: FileWatch] = [:]
    private var nextPendingWatchOrder: UInt64 = 0

    public init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
        queue: DispatchQueue,
        onEvent: @escaping @Sendable (RolloutWatchEvent) -> Void
    ) {
        let canonicalRootPath = Self.canonicalPath(rootURL.path)
        self.rootURL = URL(fileURLWithPath: canonicalRootPath, isDirectory: true)
        self.rootPath = canonicalRootPath
        self.queue = queue
        self.onEvent = onEvent
    }

    /// Starts asynchronously on the serial queue. Repeated starts are ignored.
    public func start() {
        queue.async {
            guard !self.isRunning else { return }
            self.startOnQueue()
        }
    }

    /// Stops asynchronously on the serial queue. Repeated stops are ignored.
    public func stop() {
        queue.async {
            self.stopOnQueue()
        }
    }

    private func startOnQueue() {
        isRunning = true
        startEventStream()
        rescanAllFiles()
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        isRunning = false
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        for path in Array(fileWatches.keys) { cancelFileWatch(path) }
        files.removeAll()
        pendingDrains.removeAll()
    }

    private func startEventStream() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<IncrementalRolloutWatcher>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<IncrementalRolloutWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let paths = [rootPath] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(newStream, queue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            return
        }
        stream = newStream
    }

    private static let eventCallback: FSEventStreamCallback = { _, info, count, pathsPointer, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<IncrementalRolloutWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue()
        let changedPaths = (0..<count).compactMap { index -> (String, FSEventStreamEventFlags)? in
            let rawPath = CFArrayGetValueAtIndex(paths, index)
            guard let path = rawPath.map({ Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }) else {
                return nil
            }
            return (IncrementalRolloutWatcher.canonicalPath(path), flags[index])
        }
        watcher.receive(changedPaths)
    }

    private func receive(_ changedPaths: [(String, FSEventStreamEventFlags)]) {
        guard isRunning else { return }
        if changedPaths.contains(where: { _, flags in
            Self.hasFlag(flags, kFSEventStreamEventFlagUserDropped)
                || Self.hasFlag(flags, kFSEventStreamEventFlagKernelDropped)
                || Self.hasFlag(flags, kFSEventStreamEventFlagMustScanSubDirs)
        }) {
            rescanAllFiles()
            return
        }

        for (path, flags) in changedPaths {
            guard isInsideRoot(path) else { continue }
            let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let itemIsDirectory = Self.hasFlag(flags, kFSEventStreamEventFlagItemIsDir)
            let exists = FileManager.default.fileExists(atPath: path)
            if values?.isDirectory == true || itemIsDirectory {
                if exists,
                   Self.hasFlag(flags, kFSEventStreamEventFlagItemCreated)
                    || Self.hasFlag(flags, kFSEventStreamEventFlagItemRenamed) {
                    scanDirectory(at: URL(fileURLWithPath: path))
                } else if !exists {
                    removeFiles(under: path)
                }
            } else if URL(fileURLWithPath: path).pathExtension == "jsonl" {
                if values?.isRegularFile == true {
                    ensureFileWatch(path, state: files[path] ?? FileState())
                    scheduleDrain(path)
                } else {
                    removeFile(path)
                }
            } else if !exists {
                removeFiles(under: path)
            }
        }
    }

    private func rescanAllFiles() {
        guard FileManager.default.fileExists(atPath: rootPath) else {
            for path in Array(files.keys) { removeFile(path) }
            return
        }
        var discovered = Set<String>()
        scanDirectory(at: rootURL, discovered: &discovered)
        for path in Array(files.keys) where !discovered.contains(path) {
            removeFile(path)
        }
    }

    private func scanDirectory(at directoryURL: URL) {
        var discovered = Set<String>()
        scanDirectory(at: directoryURL, discovered: &discovered)
    }

    private func scanDirectory(at directoryURL: URL, discovered: inout Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let path = Self.canonicalPath(url.path)
            guard isInsideRoot(path), isRegularFile(at: path) else { continue }
            discovered.insert(path)
            ensureFileWatch(path, state: files[path] ?? FileState())
            scheduleDrain(path)
        }
    }

    private func scheduleDrain(_ path: String) {
        guard isRunning, pendingDrains.insert(path).inserted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingDrains.remove(path)
            self.drain(path)
        }
    }

    private func ensureFileWatch(_ path: String, state: FileState) {
        guard isRunning, let snapshot = fileSnapshot(at: path) else { return }
        let priority = state.latestStartedAtMilliseconds

        if var watch = fileWatches[path], watch.identity == snapshot.identity {
            if watch.latestStartedAtMilliseconds == nil, let priority {
                guard canPromotePendingWatch(path, priority: priority) else {
                    cancelFileWatch(path)
                    return
                }
                watch.pendingOrder = nil
            } else if watch.latestStartedAtMilliseconds != nil, priority == nil {
                guard makePendingWatchRoom(excluding: path) else {
                    cancelFileWatch(path)
                    return
                }
                watch.pendingOrder = nextPendingWatchOrder
                nextPendingWatchOrder &+= 1
            }
            watch.latestStartedAtMilliseconds = priority
            fileWatches[path] = watch
            return
        } else if fileWatches[path] != nil {
            cancelFileWatch(path)
        }

        if let priority {
            guard canPromotePendingWatch(path, priority: priority) else { return }
        } else {
            guard makePendingWatchRoom(excluding: nil) else { return }
        }

        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke],
            queue: queue
        )
        let identity = snapshot.identity
        source.setEventHandler { [weak self] in
            self?.handleFileWatchEvent(at: path, identity: identity)
        }
        source.setCancelHandler {
            // Close only after libdispatch finishes using this descriptor.
            _ = Darwin.close(descriptor)
        }
        fileWatches[path] = FileWatch(
            source: source,
            identity: identity,
            latestStartedAtMilliseconds: priority,
            pendingOrder: priority == nil ? nextPendingWatchOrder : nil
        )
        if priority == nil { nextPendingWatchOrder &+= 1 }
        source.activate()
    }

    private func canPromotePendingWatch(_ path: String, priority: Int) -> Bool {
        let rankedPaths = fileWatches.keys.filter {
            $0 != path && fileWatches[$0]?.latestStartedAtMilliseconds != nil
        }
        guard rankedPaths.count >= Self.maxWatchedFiles else { return true }
        guard let oldestPath = rankedPaths.min(by: {
            (fileWatches[$0]?.latestStartedAtMilliseconds ?? Int.min)
                < (fileWatches[$1]?.latestStartedAtMilliseconds ?? Int.min)
        }) else { return true }
        let oldestPriority = fileWatches[oldestPath]?.latestStartedAtMilliseconds ?? Int.min
        guard priority > oldestPriority else { return false }
        cancelFileWatch(oldestPath)
        return true
    }

    private func makePendingWatchRoom(excluding path: String?) -> Bool {
        let pendingPaths = fileWatches.keys.filter {
            $0 != path && fileWatches[$0]?.latestStartedAtMilliseconds == nil
        }
        guard pendingPaths.count >= Self.maxPendingWatches else { return true }
        guard let oldestPath = pendingPaths.min(by: {
            (fileWatches[$0]?.pendingOrder ?? 0) < (fileWatches[$1]?.pendingOrder ?? 0)
        }) else { return false }
        cancelFileWatch(oldestPath)
        return true
    }

    private func handleFileWatchEvent(at path: String, identity: FileIdentity?) {
        guard isRunning, let watch = fileWatches[path], watch.identity == identity else { return }
        let events = watch.source.data
        if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
            cancelFileWatch(path, matching: identity)
            guard let snapshot = fileSnapshot(at: path) else {
                removeFile(path)
                return
            }
            if snapshot.identity != identity {
                scheduleDrain(path)
                return
            }
        }

        scheduleDrain(path)
    }

    private func refreshFileWatch(for path: String, state: FileState) {
        ensureFileWatch(path, state: state)
    }

    private func cancelFileWatch(_ path: String) {
        guard let watch = fileWatches.removeValue(forKey: path) else { return }
        watch.source.setEventHandler {}
        watch.source.cancel()
    }

    private func cancelFileWatch(_ path: String, matching identity: FileIdentity?) {
        guard fileWatches[path]?.identity == identity else { return }
        cancelFileWatch(path)
    }

    private func drain(_ path: String) {
        guard isRunning, isInsideRoot(path), let snapshot = fileSnapshot(at: path) else {
            removeFile(path)
            return
        }

        var state = files[path] ?? FileState()
        let identityChanged = state.identity != nil && snapshot.identity != nil && state.identity != snapshot.identity
        if identityChanged || snapshot.size < state.offset {
            if let threadID = state.threadID { onEvent(.removed(threadID: threadID)) }
            state = FileState(identity: snapshot.identity)
        } else if state.identity == nil {
            state.identity = snapshot.identity
        }

        guard snapshot.size > state.offset else {
            files[path] = state
            refreshFileWatch(for: path, state: state)
            return
        }

        let bytesToRead = min(snapshot.size - state.offset, UInt64(Self.maxBytesPerRead))
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: state.offset)
            let data = try handle.read(upToCount: Int(bytesToRead)) ?? Data()
            guard !data.isEmpty else {
                files[path] = state
                return
            }
            state.offset += UInt64(data.count)
            consume(data, state: &state)
            files[path] = state
            refreshFileWatch(for: path, state: state)
            if snapshot.size > state.offset { scheduleDrain(path) }
        } catch {
            files[path] = state
        }
    }

    private func consume(_ data: Data, state: inout FileState) {
        state.partialLine.append(data)
        var lineStart = state.partialLine.startIndex

        while let newline = state.partialLine[lineStart...].firstIndex(of: 0x0A) {
            if state.discardingOversizedLine {
                state.discardingOversizedLine = false
            } else if newline - lineStart <= Self.maxLineBytes {
                var line = Data(state.partialLine[lineStart..<newline])
                if line.last == 0x0D { line.removeLast() }
                consumeLine(line, state: &state)
            }
            lineStart = state.partialLine.index(after: newline)
        }

        if lineStart > state.partialLine.startIndex {
            state.partialLine.removeSubrange(state.partialLine.startIndex..<lineStart)
        }
        if state.partialLine.count > Self.maxLineBytes {
            state.partialLine.removeAll(keepingCapacity: false)
            state.discardingOversizedLine = true
        }
    }

    private func consumeLine(_ line: Data, state: inout FileState) {
        guard let event = RolloutLineDecoder.decode(line) else { return }
        switch event {
        case let .taskStarted(_, startedAtMilliseconds):
            if let startedAtMilliseconds {
                state.latestStartedAtMilliseconds = startedAtMilliseconds
            }
        case .taskCompleted:
            break
        case .sessionMetadata, .turnContext, .usage:
            break
        }

        if case let .sessionMetadata(metadata) = event {
            guard state.threadID == nil else { return }
            state.threadID = metadata.threadID
            onEvent(.event(threadID: metadata.threadID, event: event))
            for pendingEvent in state.eventsBeforeMetadata {
                onEvent(.event(threadID: metadata.threadID, event: pendingEvent))
            }
            state.eventsBeforeMetadata.removeAll(keepingCapacity: false)
        } else if let threadID = state.threadID {
            onEvent(.event(threadID: threadID, event: event))
        } else if state.eventsBeforeMetadata.count < Self.maxEventsBeforeMetadata {
            state.eventsBeforeMetadata.append(event)
        }
    }

    private func removeFiles(under path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        for knownPath in Array(files.keys) where knownPath == path || knownPath.hasPrefix(prefix) {
            removeFile(knownPath)
        }
    }

    private func removeFile(_ path: String) {
        cancelFileWatch(path)
        guard let state = files.removeValue(forKey: path) else { return }
        pendingDrains.remove(path)
        if let threadID = state.threadID { onEvent(.removed(threadID: threadID)) }
    }

    private func isInsideRoot(_ path: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    private func isRegularFile(at path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private func fileSnapshot(at path: String) -> FileSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return nil }

        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let identity: FileIdentity?
        if let volume, let file {
            identity = FileIdentity(volume: volume, file: file)
        } else {
            identity = nil
        }
        return FileSnapshot(size: size, identity: identity)
    }

    private static func hasFlag(_ flags: FSEventStreamEventFlags, _ flag: Int) -> Bool {
        flags & FSEventStreamEventFlags(flag) != 0
    }

    private static func canonicalPath(_ path: String) -> String {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        var existingPath = standardizedPath
        var missingComponents: [String] = []

        while true {
            if let resolvedPointer = existingPath.withCString({ realpath($0, nil) }) {
                let resolvedPath = String(cString: resolvedPointer)
                free(resolvedPointer)
                return missingComponents.reduce(resolvedPath) { parent, component in
                    URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(component).path
                }
            }

            let componentURL = URL(fileURLWithPath: existingPath)
            let parentPath = componentURL.deletingLastPathComponent().path
            guard parentPath != existingPath else { return standardizedPath }
            missingComponents.insert(componentURL.lastPathComponent, at: 0)
            existingPath = parentPath
        }
    }
}
