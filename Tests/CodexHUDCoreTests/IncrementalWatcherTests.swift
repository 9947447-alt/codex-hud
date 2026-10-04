import Foundation
import XCTest
@testable import CodexHUDCore

final class IncrementalWatcherTests: XCTestCase {
    func testFirstSessionMetadataRemainsCanonicalAcrossInheritedForkHistory() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let childID = "thread-child"
        let parentID = "thread-parent"
        let rootTurnID = "turn-parent-root"
        let childTurnID = "turn-child"
        let childMetadata = #"{"type":"session_meta","payload":{"id":"thread-child","originator":"Codex Desktop","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread-parent","depth":1}}}}}"#
        let parentMetadata = #"{"type":"session_meta","payload":{"id":"thread-parent","originator":"Codex Desktop","source":"vscode"}}"#
        let parentUsage = #"{"type":"token_usage_record","payload":{"thread_id":"thread-parent","turn_id":"turn-parent-root","root_turn_id":"turn-parent-root","response_id":"response-parent-history","turn_token_usage":{"total_tokens":120}}}"#
        let childUsage = #"{"type":"token_usage_record","payload":{"thread_id":"thread-child","turn_id":"turn-child","root_turn_id":"turn-parent-root","response_id":"response-child","turn_token_usage":{"total_tokens":34}}}"#
        try writeLines([
            childMetadata,
            parentMetadata,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-parent-root","started_at":100}}"#,
            parentUsage,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-child","started_at":200}}"#,
            childUsage,
        ], to: sessionsURL.appendingPathComponent("fork-history.jsonl"))

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }
        let events = recorder.waitFor(timeout: 5) { events in
            events.contains { event in
                guard case let .event(threadID, .usage(record)) = event else { return false }
                return threadID == childID && record.responseID == "response-child"
            }
        }
        queue.sync {}

        XCTAssertFalse(events.contains { if case .removed(childID) = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .removed(parentID) = $0 { return true }; return false })
        let typed = events.compactMap { event -> (String, RolloutEvent)? in
            guard case let .event(threadID, rolloutEvent) = event else { return nil }
            return (threadID, rolloutEvent)
        }
        XCTAssertFalse(typed.isEmpty)
        XCTAssertTrue(typed.allSatisfy { $0.0 == childID }, "the file's first valid session metadata stays canonical")
        let metadataEvents = typed.compactMap { threadID, event -> RolloutSessionMetadata? in
            guard case let .sessionMetadata(metadata) = event else { return nil }
            XCTAssertEqual(threadID, childID)
            return metadata
        }
        XCTAssertEqual(metadataEvents, [.init(threadID: childID, isCodexDesktop: true, isVSCodeSource: false, isSubagent: true)])
        let taskStarts = typed.compactMap { threadID, event -> String? in
            guard threadID == childID, case let .taskStarted(turnID, _) = event else { return nil }
            return turnID
        }
        XCTAssertEqual(taskStarts, [rootTurnID, childTurnID])
        let usageRecords = typed.compactMap { threadID, event -> TokenUsageRecord? in
            guard threadID == childID, case let .usage(record) = event else { return nil }
            return record
        }
        XCTAssertEqual(usageRecords.map(\.threadID), [parentID, childID])
        XCTAssertEqual(usageRecords.map(\.responseID), ["response-parent-history", "response-child"])
    }

    func testStartupReplaysLifecycleAndUsageButSkipsMalformedUnknownAndUnattributedFiles() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)

        let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-a","response_id":"response-a","turn_token_usage":{"total_tokens":18}}}"#
        try writeLines([
            metadata("thread-known"),
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a","started_at":123}}"#,
            "{malformed",
            #"{"type":"unknown_event","payload":{"text":"not telemetry"}}"#,
            usageLine,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#,
        ], to: sessionsURL.appendingPathComponent("known.jsonl"))
        try writeLines([
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"orphan-turn"}}"#,
        ], to: sessionsURL.appendingPathComponent("unknown.jsonl"))

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        let events = recorder.waitFor(timeout: 5) { events in
            events.contains { event in
                if case let .event(threadID, .taskCompleted(turnID)) = event {
                    return threadID == "thread-known" && turnID == "turn-a"
                }
                return false
            }
        }
        queue.sync {}

        let typed = events.compactMap { event -> (String, RolloutEvent)? in
            guard case let .event(threadID, rolloutEvent) = event else { return nil }
            return (threadID, rolloutEvent)
        }
        XCTAssertEqual(typed.map(\.0), Array(repeating: "thread-known", count: 4))
        XCTAssertEqual(typed.map(\.1), [
            .sessionMetadata(.init(threadID: "thread-known", isCodexDesktop: true, isVSCodeSource: true, isSubagent: false)),
            .taskStarted(turnID: "turn-a", startedAtMilliseconds: 123_000),
            .usage(.init(turnID: "turn-a", responseID: "response-a", totalTokens: 18)),
            .taskCompleted(turnID: "turn-a"),
        ])
        XCTAssertFalse(typed.contains { $0.0 == "unknown" })
        XCTAssertFalse(typed.contains { $0.1 == .taskStarted(turnID: "orphan-turn", startedAtMilliseconds: nil) })
    }

    func testPartialLineContinuesAndRepeatedFileNotificationsDoNotDuplicateEvents() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let fileURL = sessionsURL.appendingPathComponent("partial.jsonl")
        let startLine = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-partial","started_at":9}}"#
        let split = startLine.index(startLine.startIndex, offsetBy: 37)
        try Data((metadata("thread-partial") + "\n" + String(startLine[..<split])).utf8).write(to: fileURL)

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-partial", .sessionMetadata) = $0 { return true }; return false }
        }
        queue.sync {}
        XCTAssertFalse(recorder.events.contains { if case .event("thread-partial", .taskStarted) = $0 { return true }; return false })

        try append(String(startLine[split...]) + "\n", to: fileURL)
        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-partial", .taskStarted) = $0 { return true }; return false }
        }

        let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-partial","response_id":"response-1","turn_token_usage":{"total_tokens":4}}}"#
        try append("{malformed\n" + #"{"type":"unknown_event","payload":{}}"# + "\n" + usageLine + "\n", to: fileURL)
        let events = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-partial", .usage) = $0 { return true }; return false }
        }
        queue.sync {}

        XCTAssertEqual(events.filter { if case .event("thread-partial", .taskStarted) = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(events.filter { if case .event("thread-partial", .usage) = $0 { return true }; return false }.count, 1)
    }

    func testTruncationAndAtomicReplacementResetFileOffsetAndIdentity() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let fileURL = sessionsURL.appendingPathComponent("rotating.jsonl")
        let oldContent = [metadata("thread-old"), #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-old"}}"#]
        try writeLines(oldContent, to: fileURL)

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-old", .taskStarted) = $0 { return true }; return false }
        }
        queue.sync {}

        let truncatingHandle = try FileHandle(forWritingTo: fileURL)
        try truncatingHandle.truncate(atOffset: 0)
        try truncatingHandle.close()
        _ = recorder.waitFor(timeout: 5) { events in events.contains { if case .removed("thread-old") = $0 { return true }; return false } }

        try append(metadata("thread-truncated") + "\n", to: fileURL)
        _ = recorder.waitFor(timeout: 5) { events in events.contains { if case .event("thread-truncated", .sessionMetadata) = $0 { return true }; return false } }

        let replacement = [metadata("thread-replaced"), #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-replaced"}}"#]
        try writeLines(replacement, to: fileURL, atomically: true)
        let events = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .removed("thread-truncated") = $0 { return true }; return false }
                && events.contains { if case .event("thread-replaced", .taskCompleted) = $0 { return true }; return false }
        }
        XCTAssertTrue(events.contains { if case .event("thread-replaced", .sessionMetadata) = $0 { return true }; return false })
    }

    func testDiscoversNestedFileAndInvalidatesWhenSessionDirectoryIsArchived() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        let nestedURL = sessionsURL.appendingPathComponent("2026/10", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        let fileURL = nestedURL.appendingPathComponent("new-session.jsonl")
        let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-new","response_id":"response-new","turn_token_usage":{"total_tokens":27}}}"#
        try writeLines([metadata("thread-new"), usageLine], to: fileURL)

        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-new", .usage) = $0 { return true }; return false }
        }
        queue.sync {}

        try FileManager.default.moveItem(at: nestedURL, to: archiveURL.appendingPathComponent("2026-10", isDirectory: true))
        let events = recorder.waitFor(timeout: 5) { events in events.contains { if case .removed("thread-new") = $0 { return true }; return false } }
        XCTAssertTrue(events.contains { if case .removed("thread-new") = $0 { return true }; return false })
    }

    func testAppendsAreObservedWhileRolloutWriterRemainsOpen() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let fileURL = sessionsURL.appendingPathComponent("long-lived-writer.jsonl")
        try Data().write(to: fileURL)

        let writer = try FileHandle(forWritingTo: fileURL)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((metadata("thread-open-writer") + "\n" + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-open-writer"}}"# + "\n").utf8))

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        let startedEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-open-writer", .taskStarted) = $0 { return true }; return false }
        }
        XCTAssertTrue(startedEvents.contains { if case .event("thread-open-writer", .sessionMetadata) = $0 { return true }; return false })
        XCTAssertTrue(startedEvents.contains { if case .event("thread-open-writer", .taskStarted) = $0 { return true }; return false })

        for (responseID, totalTokens) in [("response-open-1", 12), ("response-open-2", 34)] {
            let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-open-writer","response_id":"\#(responseID)","turn_token_usage":{"total_tokens":\#(totalTokens)}}}"#
            try writer.seekToEnd()
            try writer.write(contentsOf: Data((usageLine + "\n").utf8))

            let events = recorder.waitFor(timeout: 5) { events in
                events.contains { event in
                    guard case let .event("thread-open-writer", .usage(record)) = event else { return false }
                    return record.responseID == responseID
                }
            }
            XCTAssertTrue(events.contains { event in
                guard case let .event("thread-open-writer", .usage(record)) = event else { return false }
                return record.responseID == responseID && record.totalTokens == totalTokens
            }, "missing usage event for \(responseID) while writer FD remains open")
        }

        let usageEvents = recorder.events.compactMap { event -> TokenUsageRecord? in
            guard case let .event("thread-open-writer", .usage(record)) = event else { return nil }
            return record
        }
        XCTAssertEqual(usageEvents.map(\.responseID), ["response-open-1", "response-open-2"])
        XCTAssertEqual(usageEvents.map(\.totalTokens), [12, 34])

        try writer.seekToEnd()
        try writer.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-open-writer"}}"# + "\n").utf8))
        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-open-writer", .taskCompleted("turn-open-writer")) = $0 { return true }; return false }
        }

        let nextStart = Int(Date().timeIntervalSince1970) + 1
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-open-writer-next","started_at":\#(nextStart)}}"# + "\n").utf8))
        _ = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-open-writer", .taskStarted("turn-open-writer-next", nextStart * 1_000)) = $0 { return true }; return false }
        }

        let nextUsage = #"{"type":"token_usage_record","payload":{"turn_id":"turn-open-writer-next","response_id":"response-open-next","turn_token_usage":{"total_tokens":55}}}"#
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((nextUsage + "\n").utf8))
        let nextTurnEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-open-writer", .usage(let record)) = $0 { return record.responseID == "response-open-next" }; return false }
        }
        XCTAssertTrue(nextTurnEvents.contains { if case .event("thread-open-writer", .usage(let record)) = $0 { return record.responseID == "response-open-next" && record.totalTokens == 55 }; return false })
    }

    func testOpenMetadataOnlyWriterIsWatchedBeforeItsFirstTaskStarts() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let fileURL = sessionsURL.appendingPathComponent("metadata-only.jsonl")
        try Data().write(to: fileURL)

        let writer = try FileHandle(forWritingTo: fileURL)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data((metadata("thread-metadata-only") + "\n").utf8))

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }
        let metadataEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-metadata-only", .sessionMetadata) = $0 { return true }; return false }
        }
        XCTAssertTrue(metadataEvents.contains { if case .event("thread-metadata-only", .sessionMetadata) = $0 { return true }; return false })
        queue.sync {}

        let startedAt = Int(Date().timeIntervalSince1970)
        let startLine = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-metadata-only","started_at":\#(startedAt)}}"#
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((startLine + "\n").utf8))
        let startedEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-metadata-only", .taskStarted) = $0 { return true }; return false }
        }
        XCTAssertTrue(startedEvents.contains { if case .event("thread-metadata-only", .taskStarted("turn-metadata-only", startedAt * 1_000)) = $0 { return true }; return false })

        let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-metadata-only","response_id":"response-metadata-only","turn_token_usage":{"total_tokens":89}}}"#
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((usageLine + "\n").utf8))
        let usageEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-metadata-only", .usage(let record)) = $0 { return record.responseID == "response-metadata-only" }; return false }
        }
        XCTAssertTrue(usageEvents.contains { if case .event("thread-metadata-only", .usage(let record)) = $0 { return record.responseID == "response-metadata-only" && record.totalTokens == 89 }; return false })
    }

    func testWatcherCapacityKeepsLatestStartedSessionAheadOfOlderActiveRollouts() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let targetURL = sessionsURL.appendingPathComponent("latest.jsonl")
        try Data().write(to: targetURL)

        let latestStart = Int(Date().timeIntervalSince1970)
        let writer = try FileHandle(forWritingTo: targetURL)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data((metadata("thread-latest") + "\n" + #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-latest","started_at":\#(latestStart)}}"# + "\n").utf8))

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }
        let initialEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-latest", .taskStarted) = $0 { return true }; return false }
        }
        XCTAssertTrue(initialEvents.contains { if case .event("thread-latest", .taskStarted) = $0 { return true }; return false })

        let oldSessionsURL = sessionsURL.appendingPathComponent("old-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSessionsURL, withIntermediateDirectories: true)
        let oldSessionCount = 70
        let largeUnknownLine = #"{"type":"unknown_event","payload":{"body":"\#(String(repeating: "x", count: 256 * 1024))"}}"#
        var expectedTailStarts = Set<String>()
        for index in 0..<oldSessionCount {
            let threadID = "thread-old-\(index)"
            let tailTurnID = "turn-old-tail-\(index)"
            expectedTailStarts.insert(threadID + ":" + tailTurnID)
            let startedAt = latestStart - oldSessionCount - index
            try writeLines([
                metadata(threadID),
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-old-initial-\#(index)","started_at":\#(startedAt)}}"#,
                largeUnknownLine,
                #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(tailTurnID)","started_at":\#(startedAt)}}"#,
            ], to: oldSessionsURL.appendingPathComponent("old-\(index).jsonl"))
        }

        let staleEvents = recorder.waitFor(timeout: 30) { events in
            let tailStarts = Set(events.compactMap { event -> String? in
                guard case let .event(threadID, .taskStarted(turnID, _)) = event else { return nil }
                return threadID + ":" + turnID
            })
            return expectedTailStarts.isSubset(of: tailStarts)
        }
        let receivedTailStarts = Set(staleEvents.compactMap { event -> String? in
            guard case let .event(threadID, .taskStarted(turnID, _)) = event else { return nil }
            return threadID + ":" + turnID
        })
        XCTAssertTrue(expectedTailStarts.isSubset(of: receivedTailStarts), "all 70 stale rollout tails should finish draining")
        queue.sync {}

        let pendingURL = sessionsURL.appendingPathComponent("metadata-only-after-cap.jsonl")
        try Data().write(to: pendingURL)
        let pendingWriter = try FileHandle(forWritingTo: pendingURL)
        defer { try? pendingWriter.close() }
        try pendingWriter.write(contentsOf: Data((metadata("thread-pending") + "\n").utf8))
        let pendingEvents = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-pending", .sessionMetadata) = $0 { return true }; return false }
        }
        XCTAssertTrue(pendingEvents.contains { if case .event("thread-pending", .sessionMetadata) = $0 { return true }; return false })
        queue.sync {}

        let usageWhilePendingExists = #"{"type":"token_usage_record","payload":{"turn_id":"turn-latest","response_id":"response-while-pending","turn_token_usage":{"total_tokens":45}}}"#
        try writer.seekToEnd()
        try writer.write(contentsOf: Data((usageWhilePendingExists + "\n").utf8))
        let latestEventsWhilePendingExists = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-latest", .usage(let record)) = $0 { return record.responseID == "response-while-pending" }; return false }
        }
        XCTAssertTrue(latestEventsWhilePendingExists.contains {
            if case .event("thread-latest", .usage(let record)) = $0 {
                return record.responseID == "response-while-pending" && record.totalTokens == 45
            }
            return false
        }, "a pre-start pending watch must not evict a known recent task watcher")

        for (responseID, totalTokens) in [("response-latest-1", 50), ("response-latest-2", 80)] {
            let usageLine = #"{"type":"token_usage_record","payload":{"turn_id":"turn-latest","response_id":"\#(responseID)","turn_token_usage":{"total_tokens":\#(totalTokens)}}}"#
            try writer.seekToEnd()
            try writer.write(contentsOf: Data((usageLine + "\n").utf8))
            let events = recorder.waitFor(timeout: 5) { events in
                events.contains { event in
                    guard case let .event("thread-latest", .usage(record)) = event else { return false }
                    return record.responseID == responseID
                }
            }
            XCTAssertTrue(events.contains { event in
                guard case let .event("thread-latest", .usage(record)) = event else { return false }
                return record.responseID == responseID && record.totalTokens == totalTokens
            }, "the latest task's long-lived writer must stay watched after old active files drain")
        }
    }

    func testOversizedLineIsDroppedAndFollowingTelemetryStillDecodes() throws {
        let temporaryRoot = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let sessionsURL = temporaryRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        let fileURL = sessionsURL.appendingPathComponent("oversized.jsonl")
        var data = Data((metadata("thread-oversized") + "\n").utf8)
        data.append(Data(repeating: 0x78, count: 1024 * 1024 + 32))
        data.append(0x0A)
        data.append(Data((#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-after-oversized"}}"# + "\n").utf8))
        try data.write(to: fileURL)

        let (watcher, queue, recorder) = makeWatcher(rootURL: sessionsURL)
        watcher.start()
        defer { stop(watcher, on: queue) }

        let events = recorder.waitFor(timeout: 5) { events in
            events.contains { if case .event("thread-oversized", .taskCompleted) = $0 { return true }; return false }
        }
        XCTAssertFalse(events.contains { if case .event(_, .taskStarted) = $0 { return true }; return false })
    }

    private func makeWatcher(rootURL: URL) -> (IncrementalRolloutWatcher, DispatchQueue, WatchEventRecorder) {
        let queue = DispatchQueue(label: "codexhud.incremental-watcher-test.\(UUID().uuidString)")
        let recorder = WatchEventRecorder()
        let watcher = IncrementalRolloutWatcher(rootURL: rootURL, queue: queue) { event in
            recorder.append(event)
        }
        return (watcher, queue, recorder)
    }

    private func stop(_ watcher: IncrementalRolloutWatcher, on queue: DispatchQueue) {
        watcher.stop()
        queue.sync {}
    }

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codexhud-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func metadata(_ threadID: String) -> String {
        #"{"type":"session_meta","payload":{"id":"\#(threadID)","originator":"Codex Desktop","source":"vscode"}}"#
    }

    private func writeLines(_ lines: [String], to url: URL, atomically: Bool = false) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        try data.write(to: url, options: atomically ? .atomic : [])
    }

    private func append(_ string: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(string.utf8))
        try handle.close()
    }
}

private final class WatchEventRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var recordedEvents: [RolloutWatchEvent] = []

    var events: [RolloutWatchEvent] {
        condition.lock()
        defer { condition.unlock() }
        return recordedEvents
    }

    func append(_ event: RolloutWatchEvent) {
        condition.lock()
        recordedEvents.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func waitFor(timeout: TimeInterval, matching predicate: ([RolloutWatchEvent]) -> Bool) -> [RolloutWatchEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(recordedEvents), condition.wait(until: deadline) {}
        return recordedEvents
    }
}
