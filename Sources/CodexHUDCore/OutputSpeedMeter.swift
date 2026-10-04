import Foundation

public struct LiveItemIdentity: Equatable, Hashable, Sendable {
    public let hostID: String
    public let threadID: String
    public let entityKey: String
    public let itemID: String

    public init(hostID: String, threadID: String, entityKey: String, itemID: String) {
        self.hostID = hostID
        self.threadID = threadID
        self.entityKey = entityKey
        self.itemID = itemID
    }
}

public enum LiveItemKind: Sendable {
    case agentMessage
    case reasoning
    case tool
}

public struct LiveTextEdit: Equatable, Sendable {
    public let atUTF16: Int
    public let deleteCountUTF16: Int
    public let insert: String

    public init(atUTF16: Int, deleteCountUTF16: Int, insert: String) {
        self.atUTF16 = atUTF16
        self.deleteCountUTF16 = deleteCountUTF16
        self.insert = insert
    }
}

public struct OutputSpeedMeter {
    private struct Sample {
        let bucket: Double
        var uptime: Double
        var tokenCount: Int
    }

    private static let sampleBucketSeconds = 0.1

    private let tokenCounter: any TokenCounter
    private let windowSeconds: Double
    private let idleTimeoutSeconds: Double
    private let tailLimitBytes: Int
    private let maxAppendBytes: Int
    private let sampleLimit: Int
    private var item: LiveItemIdentity?
    private var tail = ""
    private var textLengthUTF16 = 0
    private var baselineUptime: Double?
    private var lastTextUptime: Double?
    private var lastOutputUptime: Double?
    private var lastRevision: UInt64?
    private var pendingTokens = 0
    private var samples: [Sample] = []
    private var needsBaseline = true
    private var toolRunning = false

    var sampleCountForTesting: Int { samples.count }

    public init(
        tokenCounter: any TokenCounter,
        windowSeconds: Double = 3,
        idleTimeoutSeconds: Double = 3,
        tailLimitBytes: Int = 1_024,
        maxAppendBytes: Int = 4_096,
        sampleLimit: Int = 128
    ) {
        self.tokenCounter = tokenCounter
        self.windowSeconds = windowSeconds.isFinite && windowSeconds > 0 ? windowSeconds : 3
        self.idleTimeoutSeconds = idleTimeoutSeconds.isFinite && idleTimeoutSeconds > 0 ? idleTimeoutSeconds : 3
        self.tailLimitBytes = min(max(tailLimitBytes, 64), 1_024)
        self.maxAppendBytes = min(max(maxAppendBytes, 256), 4_096)
        self.sampleLimit = max(sampleLimit, 1)
    }

    public mutating func establishBaseline(item: LiveItemIdentity, fullText: String, revision: UInt64, uptime: Double) {
        guard uptime.isFinite, uptime >= 0 else {
            resetForBaseline(item: item, fullText: fullText, revision: revision, uptime: nil)
            return
        }
        resetForBaseline(item: item, fullText: fullText, revision: revision, uptime: uptime)
    }

    public mutating func advance(revision: UInt64, isContinuous: Bool = false) {
        guard let previous = lastRevision else {
            lastRevision = revision
            invalidateRate(requireBaseline: true)
            return
        }
        guard revision > previous else { return }
        if !isContinuous && (previous == UInt64.max || revision != previous + 1) {
            invalidateRate(requireBaseline: true)
        }
        lastRevision = revision
    }

    public mutating func accept(
        revision: UInt64,
        item incomingItem: LiveItemIdentity,
        kind: LiveItemKind,
        edit: LiveTextEdit,
        updatedText: String,
        uptime: Double,
        isContinuous: Bool = false
    ) {
        accept(
            revision: revision,
            item: incomingItem,
            kind: kind,
            edits: [edit],
            updatedText: updatedText,
            uptime: uptime,
            isContinuous: isContinuous
        )
    }

    public mutating func accept(
        revision: UInt64,
        item incomingItem: LiveItemIdentity,
        kind: LiveItemKind,
        edits: [LiveTextEdit],
        updatedText: String,
        uptime: Double,
        isContinuous: Bool = false
    ) {
        guard let previous = lastRevision else {
            establishBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: uptime)
            return
        }
        guard revision > previous else { return }
        lastRevision = revision
        if !isContinuous && (previous == UInt64.max || revision != previous + 1) {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: validUptime(uptime))
            return
        }
        guard case .agentMessage = kind else { return }
        guard !toolRunning else {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: validUptime(uptime))
            return
        }
        guard let now = validUptime(uptime) else {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: nil)
            return
        }
        if let lastOutputUptime, now - lastOutputUptime >= idleTimeoutSeconds {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: now)
            return
        }
        guard
            !needsBaseline,
            self.item == incomingItem,
            let currentUptime = lastTextUptime,
            now >= currentUptime,
            !edits.isEmpty
        else {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: validUptime(uptime))
            return
        }

        var nextLengthUTF16 = textLengthUTF16
        var insertedText = ""
        for edit in edits {
            guard
                edit.atUTF16 == nextLengthUTF16,
                edit.deleteCountUTF16 == 0,
                edit.atUTF16 >= 0,
                edit.insert.utf16.count <= Int.max - nextLengthUTF16
            else {
                resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: now)
                return
            }
            nextLengthUTF16 += edit.insert.utf16.count
            insertedText.append(edit.insert)
            if insertedText.utf8.count > maxAppendBytes {
                resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: now)
                return
            }
        }
        guard updatedText.utf16.count == nextLengthUTF16 else {
            resetForBaseline(item: incomingItem, fullText: updatedText, revision: revision, uptime: now)
            return
        }

        let previousCount = tokenCounter.countTokens(in: tail)
        let appendedTail = tail + insertedText
        let currentCount = tokenCounter.countTokens(in: appendedTail)
        let delta = currentCount >= previousCount ? currentCount - previousCount : 0
        pendingTokens = pendingTokens.addingReportingOverflow(delta).overflow ? Int.max : pendingTokens + delta
        tail = boundedSuffix(appendedTail)
        textLengthUTF16 = nextLengthUTF16
        lastTextUptime = now
        lastOutputUptime = now

        if now > currentUptime, pendingTokens > 0 {
            let bucket = sampleBucket(at: now)
            if let lastIndex = samples.indices.last, samples[lastIndex].bucket == bucket {
                let (sum, overflow) = samples[lastIndex].tokenCount.addingReportingOverflow(pendingTokens)
                samples[lastIndex].tokenCount = overflow ? Int.max : sum
                samples[lastIndex].uptime = now
            } else {
                samples.append(Sample(bucket: bucket, uptime: now, tokenCount: pendingTokens))
            }
            pendingTokens = 0
            let cutoff = now - windowSeconds
            samples.removeAll { $0.uptime < cutoff }
            if samples.count > sampleLimit { samples.removeFirst(samples.count - sampleLimit) }
        }
    }

    public mutating func setToolRunning(_ running: Bool) {
        guard toolRunning != running else { return }
        toolRunning = running
        invalidateRate(requireBaseline: true)
    }

    public mutating func reset() {
        item = nil
        tail = ""
        textLengthUTF16 = 0
        lastRevision = nil
        toolRunning = false
        invalidateRate(requireBaseline: true)
    }

    public func speed(at uptime: Double) -> Double? {
        guard
            !toolRunning,
            !needsBaseline,
            uptime.isFinite,
            uptime >= 0,
            let baselineUptime,
            let lastOutputUptime,
            uptime >= baselineUptime,
            uptime >= lastOutputUptime,
            uptime - lastOutputUptime < idleTimeoutSeconds
        else {
            return nil
        }

        let elapsed = min(windowSeconds, uptime - baselineUptime)
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        let cutoff = uptime - windowSeconds
        let tokenTotal = samples.reduce(into: 0.0) { total, sample in
            if sample.uptime >= cutoff { total += Double(sample.tokenCount) }
        }
        let rate = tokenTotal / elapsed
        return rate.isFinite && rate > 0 ? rate : nil
    }

    private mutating func resetForBaseline(item: LiveItemIdentity, fullText: String, revision: UInt64, uptime: Double?) {
        self.item = item
        tail = boundedSuffix(fullText)
        textLengthUTF16 = fullText.utf16.count
        baselineUptime = uptime
        lastTextUptime = uptime
        lastOutputUptime = nil
        lastRevision = revision
        pendingTokens = 0
        samples.removeAll(keepingCapacity: true)
        needsBaseline = uptime == nil || toolRunning
    }

    private mutating func invalidateRate(requireBaseline: Bool) {
        samples.removeAll(keepingCapacity: true)
        pendingTokens = 0
        lastOutputUptime = nil
        if requireBaseline {
            baselineUptime = nil
            lastTextUptime = nil
            needsBaseline = true
        }
    }

    private func validUptime(_ uptime: Double) -> Double? {
        uptime.isFinite && uptime >= 0 ? uptime : nil
    }

    private func sampleBucket(at uptime: Double) -> Double {
        let scaled = uptime / Self.sampleBucketSeconds
        return scaled.isFinite ? floor(scaled) : uptime
    }

    private func boundedSuffix(_ text: String) -> String {
        var reversedScalars: [UnicodeScalar] = []
        reversedScalars.reserveCapacity(min(text.unicodeScalars.count, tailLimitBytes))
        var byteCount = 0
        for scalar in text.unicodeScalars.reversed() {
            let width: Int
            switch scalar.value {
            case 0...0x7F: width = 1
            case 0x80...0x7FF: width = 2
            case 0x800...0xFFFF: width = 3
            default: width = 4
            }
            guard byteCount + width <= tailLimitBytes else { break }
            reversedScalars.append(scalar)
            byteCount += width
        }
        return String(String.UnicodeScalarView(reversedScalars.reversed()))
    }
}
