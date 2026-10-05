import AppKit

enum HUDPresentationState: Sendable, Equatable {
    case idle
    case active
    case generating
    case runningCommand
    case runningTool
    case completed
    case disconnected
}

@MainActor
final class HUDPanelController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 220, height: 88)
    private static let horizontalInset: CGFloat = 14
    private static let verticalInset: CGFloat = 12
    private static let savedXKey = "CodexHUD.panel.origin.x"
    private static let savedYKey = "CodexHUD.panel.origin.y"

    private let panel: HUDPanel
    private let effectView = HUDBackdropView()
    private let statusDot = HUDStatusDot()
    private let modelLabel = NSTextField(labelWithString: "")
    private let averageLabel = NSTextField(labelWithString: "")
    private let taskLineLabel = NSTextField(labelWithString: "")

    override init() {
        let initialFrame = Self.initialFrame()
        panel = HUDPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        configurePanel()
        configureContent()
        update(modelText: "", status: .idle, averageLine: "AVG   — tok/s", taskLine: "TASK  — · API≈—")
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func update(modelText: String, status: HUDPresentationState, averageLine: String, taskLine: String) {
        let model = modelText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelLabel.stringValue = model.isEmpty ? Self.fallbackTitle(for: status) : model
        self.averageLabel.stringValue = averageLine.isEmpty ? "AVG   — tok/s" : averageLine
        self.taskLineLabel.stringValue = taskLine.isEmpty ? "TASK  — · API≈—" : taskLine
        self.statusDot.state = status
    }

    func windowDidMove(_ notification: Notification) {
        let origin = panel.frame.origin
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: Self.savedXKey)
        defaults.set(Double(origin.y), forKey: Self.savedYKey)
    }

    private func configurePanel() {
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
    }

    private func configureContent() {
        effectView.frame = NSRect(origin: .zero, size: Self.panelSize)
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.borderWidth = 1
        effectView.layer?.masksToBounds = true
        effectView.refreshBorderColor()
        panel.contentView = effectView

        let modelRow = NSStackView(views: [statusDot, modelLabel])
        modelRow.orientation = .horizontal
        modelRow.alignment = .centerY
        modelRow.distribution = .fill
        modelRow.spacing = 8
        modelRow.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [modelRow, averageLabel, taskLineLabel])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.distribution = .fill
        rows.spacing = 7
        rows.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(rows)

        modelLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        modelLabel.textColor = .labelColor
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.maximumNumberOfLines = 1
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        averageLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        averageLabel.textColor = .secondaryLabelColor
        averageLabel.lineBreakMode = .byTruncatingTail
        averageLabel.maximumNumberOfLines = 1
        averageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        taskLineLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        taskLineLabel.textColor = .labelColor
        taskLineLabel.lineBreakMode = .byTruncatingTail
        taskLineLabel.maximumNumberOfLines = 1
        taskLineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: Self.horizontalInset),
            rows.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -Self.horizontalInset),
            rows.topAnchor.constraint(equalTo: effectView.topAnchor, constant: Self.verticalInset),
            rows.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -Self.verticalInset),
            modelRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            modelRow.heightAnchor.constraint(equalToConstant: 17),
            averageLabel.widthAnchor.constraint(equalTo: rows.widthAnchor),
            averageLabel.heightAnchor.constraint(equalToConstant: 16),
            taskLineLabel.widthAnchor.constraint(equalTo: rows.widthAnchor),
            taskLineLabel.heightAnchor.constraint(equalToConstant: 17),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])

        configureContextMenu(for: [effectView, modelRow, statusDot, modelLabel, averageLabel, taskLineLabel])
    }

    private func configureContextMenu(for views: [NSView]) {
        let menu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        views.forEach { $0.menu = menu }
    }

    private static func initialFrame() -> NSRect {
        let size = panelSize
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallback = NSScreen.main?.visibleFrame ?? visibleFrames.first ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let defaults = UserDefaults.standard

        let origin: NSPoint
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedYKey) != nil {
            origin = NSPoint(
                x: defaults.double(forKey: savedXKey),
                y: defaults.double(forKey: savedYKey)
            )
        } else {
            origin = NSPoint(
                x: fallback.maxX - size.width - 18,
                y: fallback.maxY - size.height - 18
            )
        }

        let proposedFrame = NSRect(origin: origin, size: size)
        let screen = visibleFrames.first(where: { $0.intersects(proposedFrame) }) ?? fallback
        let minX = screen.minX + 8
        let minY = screen.minY + 8
        let maxX = max(minX, screen.maxX - size.width - 8)
        let maxY = max(minY, screen.maxY - size.height - 8)
        let clampedOrigin = NSPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
        return NSRect(origin: clampedOrigin, size: size)
    }

    private static func fallbackTitle(for status: HUDPresentationState) -> String {
        switch status {
        case .idle: "IDLE"
        case .active: "ACTIVE"
        case .generating: "GENERATING"
        case .runningCommand: "ACTIVE"
        case .runningTool: "ACTIVE"
        case .completed: "COMPLETE"
        case .disconnected: "DISCONNECTED"
        }
    }

}

@MainActor
private final class HUDBackdropView: NSVisualEffectView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBorderColor()
    }

    func refreshBorderColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}

@MainActor
private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class HUDStatusDot: NSView {
    var state: HUDPresentationState = .idle {
        didSet { refreshColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3.5
        refreshColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    private func refreshColor() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = color(for: state).cgColor
        }
    }

    private func color(for state: HUDPresentationState) -> NSColor {
        switch state {
        case .idle: .tertiaryLabelColor
        case .active: .systemBlue
        case .generating: .systemGreen
        case .runningCommand: .systemOrange
        case .runningTool: .systemPurple
        case .completed: .systemGreen
        case .disconnected: .systemRed
        }
    }
}
