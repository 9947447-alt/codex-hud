import AppKit
import CodexHUDCore
import Foundation

@MainActor
@main
enum CodexHUDMain {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = HUDApplicationDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
private final class HUDApplicationDelegate: NSObject, NSApplicationDelegate {
    private let panel = HUDPanelController()
    private var coordinator: HUDRuntimeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel.show()
        coordinator = HUDRuntimeCoordinator(diagnosticsEnabled: ProcessInfo.processInfo.arguments.contains("--diagnostics")) { [weak self] display in
            self?.panel.update(
                modelText: display.model,
                status: display.status,
                speedText: display.speed,
                taskText: display.task
            )
        }
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

private struct HUDDisplay: Equatable, Sendable {
    let model: String
    let status: HUDPresentationState
    let speed: String
    let task: String
}

private struct ThreadTelemetryState {
    var metadata: RolloutSessionMetadata?
    var usage = TurnUsageTracker()
    var live: LiveConversation?
}

private struct LiveConversation {
    var revision: UInt64
    var model: String?
    var effort: String?
    var runtimeActive: Bool
    var turns: [String: LiveTurn]
}

struct LiveTurn {
    var entityKey: String
    var turnID: String
    var status: DesktopTurnStatus
    var startedAtMilliseconds: Int?
    var items: [LiveItem]

    func matchingItemSnapshotText(operations: [DesktopStateOperation], itemID: String) -> String? {
        operations.first(where: { operation in
            guard operation.itemValue?.id == itemID else { return false }
            let path = operation.path
            if let entityIndex = path.firstIndex(of: "entitiesByKey"),
               path.count >= entityIndex + 4,
               path[entityIndex + 2] == "items" {
                guard let itemIndex = Int(path[entityIndex + 3]), itemIndex >= 0 else { return false }
            }
            return true
        })?.itemValue?.text
    }

    mutating func applyItemOperation(
        _ operation: DesktopStateOperation,
        itemIndex: Int,
        entityIndex: Int,
        newlyCreatedAgentItemIDs: inout Set<String>,
        unsupportedStatePatch: inout Bool
    ) -> Bool {
        guard itemIndex >= 0 else { return false }
        let path = operation.path
        if path.count == entityIndex + 4 {
            if operation.operation == "remove" {
                if items.indices.contains(itemIndex) { items.remove(at: itemIndex) }
            } else if let item = operation.itemValue {
                let liveItem = LiveItem(id: item.id, kind: item.kind, textUTF16Length: item.textUTF16Length, commandStatus: item.commandStatus)
                if operation.operation == "add" {
                    items.insert(liveItem, at: min(itemIndex, items.count))
                } else if items.indices.contains(itemIndex) {
                    items[itemIndex] = liveItem
                }
                if item.kind == .agentMessage { newlyCreatedAgentItemIDs.insert(item.id) }
            } else {
                unsupportedStatePatch = true
            }
        } else if path.count == entityIndex + 5, path.last == "text",
                  items.indices.contains(itemIndex) {
            items[itemIndex].textUTF16Length = operation.textValue?.utf16.count ?? 0
        } else if path.count == entityIndex + 5, path.last == "status",
                  items.indices.contains(itemIndex) {
            items[itemIndex].commandStatus = operation.statusValue == "inProgress" ? .inProgress
                : operation.statusValue == "completed" ? .completed : .other
            if items[itemIndex].commandStatus == .other { unsupportedStatePatch = true }
        } else if path.count == entityIndex + 4 {
            unsupportedStatePatch = true
        } else if !items.indices.contains(itemIndex) {
            unsupportedStatePatch = true
        } else {
            // Ignore unrelated item metadata such as phase and delivery.
        }
        return true
    }
}

struct LiveItem: Equatable {
    var id: String
    var kind: DesktopTurnItemKind
    var textUTF16Length: Int
    var commandStatus: DesktopTurnStatus
}

private struct TurnReference: Equatable {
    let threadID: String
    let turnID: String
}

private final class HUDRuntimeCoordinator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodexHUD.runtime.serial")
    private let onDisplay: @MainActor @Sendable (HUDDisplay) -> Void
    private let diagnosticsEnabled: Bool
    private lazy var sessionWatcher = IncrementalRolloutWatcher(queue: queue) { [weak self] event in
        self?.handleSessionEvent(event)
    }
    private lazy var archiveWatcher: IncrementalRolloutWatcher = {
        let archivedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        return IncrementalRolloutWatcher(rootURL: archivedRoot, queue: queue) { [weak self] event in
            self?.handleArchivedEvent(event)
        }
    }()
    private lazy var follower = DesktopFollowerConnection(queue: queue) { [weak self] event in
        self?.handleConnectionEvent(event)
    }
    private let timer: DispatchSourceTimer
    private var tokenizer: O200kTokenizer?
    private var speedMeter: OutputSpeedMeter?
    private var threads: [String: ThreadTelemetryState] = [:]
    private var childUsage = SubagentUsageLedger()
    private var selectedTurn: TurnReference?
    private var connected = false
    private var lastAgentTextUptime: Double?
    private var outputPatchCount = 0
    private var streamEventCount = 0
    private var lastRevisionSummary = "none"
    private var revisionGapCount = 0
    private var lastDiagnostic = ""
    private var lastPublishedDisplay: HUDDisplay?
    private var started = false

    init(
        diagnosticsEnabled: Bool,
        onDisplay: @escaping @MainActor @Sendable (HUDDisplay) -> Void
    ) {
        self.diagnosticsEnabled = diagnosticsEnabled
        self.onDisplay = onDisplay
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            do {
                self.tokenizer = try O200kTokenizer()
                if let tokenizer = self.tokenizer {
                    self.speedMeter = OutputSpeedMeter(tokenCounter: tokenizer)
                }
            } catch {
                self.log("tokenizer=unavailable")
            }
            self.sessionWatcher.start()
            self.archiveWatcher.start()
            self.follower.start()
            self.timer.schedule(deadline: .now() + .milliseconds(350), repeating: .milliseconds(350))
            self.timer.setEventHandler { [weak coordinator = self] in coordinator?.refreshDisplay() }
            self.timer.resume()
            self.refreshDisplay()
        }
    }

    func stop() {
        queue.async {
            self.timer.setEventHandler {}
            self.timer.cancel()
            self.sessionWatcher.stop()
            self.archiveWatcher.stop()
            self.follower.stop()
        }
    }

    private func handleSessionEvent(_ event: RolloutWatchEvent) {
        switch event {
        case let .event(threadID, rolloutEvent):
            var state = threads[threadID] ?? ThreadTelemetryState()
            if case let .taskStarted(turnID, _) = rolloutEvent {
                if state.usage.snapshot.turnID != turnID {
                    state.live = nil
                    if selectedTurn?.threadID == threadID {
                        speedMeter?.reset()
                        lastAgentTextUptime = nil
                    }
                }
            }
            if case let .sessionMetadata(metadata) = rolloutEvent {
                state.metadata = metadata
            }
            if case let .usage(record) = rolloutEvent {
                let ownedRecord = TokenUsageRecord(
                    threadID: record.threadID ?? threadID,
                    turnID: record.turnID,
                    rootTurnID: record.rootTurnID,
                    responseID: record.responseID,
                    totalTokens: record.totalTokens
                )
                childUsage.consume(ownedRecord)
            }
            state.usage.consume(rolloutEvent)
            threads[threadID] = state
            reconcileSelection()
        case let .removed(threadID):
            threads.removeValue(forKey: threadID)
            if selectedTurn?.threadID == threadID {
                selectedTurn = nil
                lastAgentTextUptime = nil
                speedMeter?.reset()
            }
            reconcileSelection()
        }
    }

    private func handleArchivedEvent(_ event: RolloutWatchEvent) {
        guard case let .event(threadID, .usage(record)) = event else { return }
        childUsage.consume(TokenUsageRecord(
            threadID: record.threadID ?? threadID,
            turnID: record.turnID,
            rootTurnID: record.rootTurnID,
            responseID: record.responseID,
            totalTokens: record.totalTokens
        ))
    }

    private func handleConnectionEvent(_ event: DesktopConnectionEvent) {
        switch event {
        case .connected:
            connected = true
            if let selectedTurn { follower.follow(threadID: selectedTurn.threadID) }
        case .disconnected:
            connected = false
            for threadID in Array(threads.keys) {
                threads[threadID]?.live = nil
            }
            lastAgentTextUptime = nil
            speedMeter?.reset()
        case let .stream(.snapshot(snapshot)):
            streamEventCount += 1
            receive(snapshot)
        case let .stream(.patches(patch)):
            streamEventCount += 1
            receive(patch)
        }
        reconcileSelection()
    }

    private func receive(_ snapshot: DesktopConversationSnapshot) {
        guard snapshot.hostID == "local", snapshot.threadID == selectedTurn?.threadID else { return }
        if let appliedRevision = threads[snapshot.threadID]?.live?.revision,
           snapshot.revision < appliedRevision {
            return
        }
        if var state = threads[snapshot.threadID], let turnID = state.usage.snapshot.turnID {
            let currentTurn = snapshot.turns.first(where: { $0.turnID == turnID })
            if currentTurn?.status == .completed {
                state.usage.consume(.taskCompleted(turnID: turnID))
            }
            threads[snapshot.threadID] = state
        }
        let turns = snapshot.turns.reduce(into: [String: LiveTurn]()) { result, turn in
            result[turn.entityKey] = LiveTurn(
                entityKey: turn.entityKey,
                turnID: turn.turnID,
                status: turn.status,
                startedAtMilliseconds: turn.startedAtMilliseconds,
                items: turn.items.map(scrub)
            )
        }
        threads[snapshot.threadID]?.live = LiveConversation(
            revision: snapshot.revision,
            model: snapshot.model,
            effort: snapshot.effort,
            runtimeActive: snapshot.runtimeActive,
            turns: turns
        )

        lastAgentTextUptime = nil
        let selectedLiveTurn = selectedTurn.flatMap { reference in
            turns.values.first(where: { $0.turnID == reference.turnID })
        }
        let toolState = selectedLiveTurn.map(liveToolState)
        speedMeter?.setToolRunning(toolState?.isRunning ?? false)
        if let agentItem = selectedLiveTurn?.items.last(where: { $0.kind == .agentMessage }) {
            let source = snapshot.turns.first(where: { $0.entityKey == selectedLiveTurn?.entityKey })?
                .items.last(where: { $0.id == agentItem.id })?.text ?? ""
            speedMeter?.establishBaseline(
                item: identity(snapshot.threadID, selectedLiveTurn!.entityKey, agentItem.id),
                fullText: source,
                revision: snapshot.revision,
                uptime: monotonicUptime()
            )
        } else {
            speedMeter?.reset()
        }
    }

    private func receive(_ patch: DesktopPatchBatch) {
        guard
            patch.hostID == "local",
            patch.threadID == selectedTurn?.threadID,
            var conversation = threads[patch.threadID]?.live
        else { return }
        lastRevisionSummary = "\(patch.baseRevision)->\(patch.revision)"
        if patch.revision <= conversation.revision { return }
        guard patch.baseRevision == conversation.revision else {
            revisionGapCount += 1
            threads[patch.threadID]?.live = nil
            lastAgentTextUptime = nil
            speedMeter?.reset()
            follower.refreshSnapshot()
            return
        }

        let previousSelected = selectedTurn.flatMap { reference in
            conversation.turns.values.first(where: { $0.turnID == reference.turnID })
        }
        var newlyCreatedAgentItemIDs: Set<String> = []
        var unsupportedStatePatch = false

        for operation in patch.operations {
            let path = operation.path
            if path.first == "threadRuntimeStatus", path.last == "type" {
                conversation.runtimeActive = operation.runtimeTypeValue == "active"
            } else if path == ["latestModel"] {
                conversation.model = operation.textValue
            } else if path.starts(with: ["latestThreadSettings", "model"]) {
                conversation.model = operation.textValue
            } else if path.starts(with: ["latestThreadSettings", "effort"]) {
                conversation.effort = operation.textValue
            } else if let entityIndex = path.firstIndex(of: "entitiesByKey"), path.count > entityIndex + 1 {
                let entityKey = path[entityIndex + 1]
                if path.count == entityIndex + 2 {
                    if operation.operation == "remove" {
                        conversation.turns = conversation.turns.filter { $0.value.entityKey != entityKey }
                    } else if let turn = operation.turnValue {
                        conversation.turns[turn.entityKey] = liveTurn(turn)
                    } else {
                        unsupportedStatePatch = true
                    }
                } else if path.count == entityIndex + 3, path.last == "status",
                          var turn = conversation.turns.values.first(where: { $0.entityKey == entityKey }) {
                    turn.status = operation.statusValue == "inProgress" ? .inProgress
                        : operation.statusValue == "completed" ? .completed : .other
                    conversation.turns[turn.entityKey] = turn
                    if turn.status == .other { unsupportedStatePatch = true }
                } else if path.count == entityIndex + 3, path.last == "items" {
                    unsupportedStatePatch = true
                } else if path.count >= entityIndex + 4, path[entityIndex + 2] == "items",
                          let itemIndex = Int(path[entityIndex + 3]),
                          var turn = conversation.turns.values.first(where: { $0.entityKey == entityKey }) {
                    guard turn.applyItemOperation(
                        operation,
                        itemIndex: itemIndex,
                        entityIndex: entityIndex,
                        newlyCreatedAgentItemIDs: &newlyCreatedAgentItemIDs,
                        unsupportedStatePatch: &unsupportedStatePatch
                    ) else { continue }
                    conversation.turns[turn.entityKey] = turn
                } else {
                    if path.count == entityIndex + 2 {
                        unsupportedStatePatch = true
                    } else if path.count == entityIndex + 3, path.last == "turnId" {
                        unsupportedStatePatch = true
                    }
                }
            } else if path.first == "turnHistory", !path.contains("entitiesByKey") {
                unsupportedStatePatch = true
            }
        }
        conversation.revision = patch.revision
        if var state = threads[patch.threadID], let turnID = state.usage.snapshot.turnID {
            let currentTurn = conversation.turns.values.first(where: { $0.turnID == turnID })
            if currentTurn?.status == .completed {
                state.usage.consume(.taskCompleted(turnID: turnID))
            }
            threads[patch.threadID] = state
        }
        threads[patch.threadID]?.live = conversation

        guard let selectedTurn,
              let selectedLiveTurn = conversation.turns.values.first(where: { $0.turnID == selectedTurn.turnID }) else {
            speedMeter?.advance(revision: patch.revision, isContinuous: true)
            if unsupportedStatePatch { follower.refreshSnapshot() }
            updateToolState(conversation: conversation, turn: nil)
            return
        }

        let toolState = liveToolState(selectedLiveTurn)
        let wasRunningTool = previousSelected.map(liveToolState)?.isRunning ?? false
        updateToolState(conversation: conversation, turn: selectedLiveTurn)
        if wasRunningTool != toolState.isRunning {
            lastAgentTextUptime = nil
        }

        if let newItem = selectedLiveTurn.items.last(where: {
            $0.kind == .agentMessage && newlyCreatedAgentItemIDs.contains($0.id)
        }) {
            let fullText = matchingTextOperation(
                operations: patch.operations,
                entityKey: selectedLiveTurn.entityKey,
                itemIndex: selectedLiveTurn.items.firstIndex(where: { $0.id == newItem.id })
            ) ?? selectedLiveTurn.matchingItemSnapshotText(operations: patch.operations, itemID: newItem.id) ?? ""
            speedMeter?.establishBaseline(
                item: identity(patch.threadID, selectedLiveTurn.entityKey, newItem.id),
                fullText: fullText,
                revision: patch.revision,
                uptime: monotonicUptime()
            )
        } else if let visibleAgent = selectedLiveTurn.items.last(where: { $0.kind == .agentMessage }),
                  let change = patch.acceptedTextChanges.first(where: {
                      $0.item.entityKey == selectedLiveTurn.entityKey && $0.item.itemID == visibleAgent.id
                  }),
                  let fullText = matchingTextOperation(
                      operations: patch.operations,
                      entityKey: selectedLiveTurn.entityKey,
                      itemIndex: selectedLiveTurn.items.firstIndex(where: { $0.id == visibleAgent.id })
                  ) {
            let edits = patch.acceptedTextChanges
                .filter { $0.item == change.item }
                .flatMap(\.edits)
            speedMeter?.accept(
                revision: patch.revision,
                item: change.item,
                kind: .agentMessage,
                edits: edits,
                updatedText: fullText,
                uptime: monotonicUptime(),
                isContinuous: true
            )
            if !toolState.isRunning, edits.contains(where: { !$0.insert.isEmpty && $0.deleteCountUTF16 == 0 }) {
                outputPatchCount += 1
                lastAgentTextUptime = monotonicUptime()
            }
        } else {
            speedMeter?.advance(revision: patch.revision, isContinuous: true)
        }
        if unsupportedStatePatch { follower.refreshSnapshot() }
    }

    private func reconcileSelection() {
        let candidates = threads.compactMap { threadID, state -> ActiveTurnCandidate? in
            guard
                let metadata = state.metadata,
                let turnID = state.usage.snapshot.turnID
            else { return nil }
            let live = state.live
            let liveTurn = live?.turns.values.first(where: { $0.turnID == turnID })
            let isActive = ActiveTurnEligibility.shouldFollow(
                rolloutStatus: state.usage.snapshot.status,
                desktopTurnStatus: liveTurn?.status
            )
            return ActiveTurnCandidate(
                threadID: threadID,
                turnID: turnID,
                startedAtMilliseconds: state.usage.snapshot.startedAtMilliseconds,
                totalTokens: state.usage.snapshot.totalTokens,
                model: state.usage.snapshot.model,
                effort: state.usage.snapshot.effort,
                isCodexDesktop: metadata.isCodexDesktop,
                isVSCodeSource: metadata.isVSCodeSource,
                isSubagent: metadata.isSubagent,
                isActive: isActive
            )
        }
        let active = AuthoritativeTurnSelector.select(candidates)
        let next = active.map { TurnReference(threadID: $0.threadID, turnID: $0.turnID) }
        if next != selectedTurn {
            selectedTurn = next
            speedMeter?.reset()
            lastAgentTextUptime = nil
            follower.follow(threadID: next?.threadID)
            if let next {
                log("event=selected_turn uptime=\(monotonicUptime()) thread=\(next.threadID) turn=\(next.turnID)")
            }
        }
    }

    private func refreshDisplay() {
        let candidate = selectedTurn.flatMap { reference in
            makeCandidate(threadID: reference.threadID, state: threads[reference.threadID], requireActive: true)
        } ?? newestDisplayCandidate()
        guard let candidate, let state = threads[candidate.threadID] else {
            publish(HUDDisplay(model: "", status: connected ? .idle : .disconnected, speed: "— tok/s", task: "— tok"))
            return
        }

        let usage = state.usage.snapshot
        let childTotal = childUsage.totalTokens(rootTurnID: candidate.turnID, excludingThreadID: candidate.threadID)
        let (taskTokens, overflow) = usage.totalTokens.addingReportingOverflow(childTotal)
        let total = overflow ? Int.max : taskTokens
        let model = usage.model
            ?? state.live?.model
            ?? ""
        let effort = usage.effort ?? state.live?.effort
        let modelText = [model, effort].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let selectedLiveTurn = state.live?.turns.values.first(where: { $0.turnID == candidate.turnID })
        let tool = selectedLiveTurn.map(liveToolState)
        let uptime = monotonicUptime()
        let speed = speedMeter?.speed(at: uptime)

        let status: HUDPresentationState
        if !connected {
            status = .disconnected
        } else if usage.status == .complete {
            status = .completed
        } else if tool?.isCommand == true {
            status = .runningCommand
        } else if tool?.isRunning == true {
            status = .runningTool
        } else if state.live?.runtimeActive == false {
            status = .idle
        } else if let lastAgentTextUptime, uptime >= lastAgentTextUptime, uptime - lastAgentTextUptime < 3 {
            status = .generating
        } else if candidate.isActive {
            status = .active
        } else {
            status = .idle
        }

        let speedText = status == .generating
            ? speed.map { String(format: "≈%.1f tok/s", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "— tok/s"
            : "— tok/s"
        let display = HUDDisplay(
            model: modelText,
            status: status,
            speed: speedText,
            task: TaskTokenFormatter.string(total)
        )
        diagnose(
            display: display,
            candidate: candidate,
            parentTokens: usage.totalTokens,
            childTokens: childTotal,
            outputRate: status == .generating ? speed : nil
        )
        publish(display)
    }

    private func makeCandidate(threadID: String, state: ThreadTelemetryState?, requireActive: Bool) -> ActiveTurnCandidate? {
        guard
            let state,
            let metadata = state.metadata,
            let turnID = state.usage.snapshot.turnID
        else { return nil }
        let live = state.live
        let liveTurn = live?.turns.values.first(where: { $0.turnID == turnID })
        let active = ActiveTurnEligibility.shouldFollow(
            rolloutStatus: state.usage.snapshot.status,
            desktopTurnStatus: liveTurn?.status
        )
        guard !requireActive || active else { return nil }
        return ActiveTurnCandidate(
            threadID: threadID,
            turnID: turnID,
            startedAtMilliseconds: state.usage.snapshot.startedAtMilliseconds,
            totalTokens: state.usage.snapshot.totalTokens,
            model: state.usage.snapshot.model,
            effort: state.usage.snapshot.effort,
            isCodexDesktop: metadata.isCodexDesktop,
            isVSCodeSource: metadata.isVSCodeSource,
            isSubagent: metadata.isSubagent,
            isActive: active
        )
    }

    private func newestDisplayCandidate() -> ActiveTurnCandidate? {
        threads.keys.compactMap { makeCandidate(threadID: $0, state: threads[$0], requireActive: false) }
            .filter { $0.isCodexDesktop && $0.isVSCodeSource && !$0.isSubagent }
            .sorted {
                if $0.startedAtMilliseconds != $1.startedAtMilliseconds {
                    return ($0.startedAtMilliseconds ?? Int.min) > ($1.startedAtMilliseconds ?? Int.min)
                }
                return $0.threadID < $1.threadID
            }
            .first
    }

    private func updateToolState(conversation: LiveConversation, turn: LiveTurn?) {
        let state = turn.map(liveToolState)
        speedMeter?.setToolRunning(state?.isRunning ?? false)
        if state?.isRunning == true {
            lastAgentTextUptime = nil
        }
    }

    private func liveToolState(_ turn: LiveTurn) -> (isRunning: Bool, isCommand: Bool) {
        let commandRunning = turn.items.contains { $0.kind == .commandExecution && $0.commandStatus == .inProgress }
        let otherToolRunning = turn.items.contains { $0.kind == .tool && $0.commandStatus == .inProgress }
        return (commandRunning || otherToolRunning, commandRunning)
    }

    private func matchingTextOperation(operations: [DesktopStateOperation], entityKey: String, itemIndex: Int?) -> String? {
        guard let itemIndex else { return nil }
        return operations.first(where: {
            $0.path.contains(entityKey)
                && $0.path.contains("items")
                && $0.path.last == "text"
                && $0.path.dropLast().last == String(itemIndex)
        })?.textValue
    }

    private func liveTurn(_ turn: DesktopTurnSnapshot) -> LiveTurn {
        LiveTurn(
            entityKey: turn.entityKey,
            turnID: turn.turnID,
            status: turn.status,
            startedAtMilliseconds: turn.startedAtMilliseconds,
            items: turn.items.map(scrub)
        )
    }

    private func scrub(_ item: DesktopTurnItemSnapshot) -> LiveItem {
        LiveItem(id: item.id, kind: item.kind, textUTF16Length: item.textUTF16Length, commandStatus: item.commandStatus)
    }

    private func identity(_ threadID: String, _ entityKey: String, _ itemID: String) -> LiveItemIdentity {
        LiveItemIdentity(hostID: "local", threadID: threadID, entityKey: entityKey, itemID: itemID)
    }

    private func monotonicUptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private func publish(_ display: HUDDisplay) {
        guard display != lastPublishedDisplay else { return }
        lastPublishedDisplay = display
        Task { @MainActor [onDisplay] in onDisplay(display) }
    }

    private func diagnose(
        display: HUDDisplay,
        candidate: ActiveTurnCandidate,
        parentTokens: Int,
        childTokens: Int,
        outputRate: Double?
    ) {
        guard diagnosticsEnabled else { return }
        let rate = outputRate.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "none"
        let signature = "\(display.status)|\(candidate.threadID)|\(candidate.turnID)|\(parentTokens)|\(childTokens)|\(rate)|\(outputPatchCount)|\(streamEventCount)|\(lastRevisionSummary)|\(revisionGapCount)"
        guard signature != lastDiagnostic else { return }
        lastDiagnostic = signature
        log("uptime=\(monotonicUptime()) state=\(display.status) thread=\(candidate.threadID) turn=\(candidate.turnID) parent_tokens=\(parentTokens) child_tokens=\(childTokens) task=\(display.task) rate=\(rate) patches=\(outputPatchCount) events=\(streamEventCount) revision=\(lastRevisionSummary) revision_gaps=\(revisionGapCount)")
    }

    private func log(_ line: String) {
        guard diagnosticsEnabled else { return }
        fputs("[CodexHUD] \(line)\n", stderr)
    }
}
