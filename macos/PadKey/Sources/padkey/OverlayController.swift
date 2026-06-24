import AppKit

final class OverlayController {
    private let panel: NSPanel
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "")

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 104),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureContent()
    }

    func show(status: String, transcript: String) {
        statusLabel.stringValue = status
        transcriptLabel.stringValue = transcript
        positionPanel()
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
    }

    private func configureContent() {
        let blurView = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .hudWindow
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 18
        blurView.layer?.masksToBounds = true

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        transcriptLabel.font = .systemFont(ofSize: 16, weight: .medium)
        transcriptLabel.textColor = .labelColor
        transcriptLabel.maximumNumberOfLines = 2
        transcriptLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [statusLabel, transcriptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        blurView.addSubview(stack)
        panel.contentView = blurView

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -22),
            stack.centerYAnchor.constraint(equalTo: blurView.centerYAnchor)
        ])
    }

    private func positionPanel() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        let panelSize = panel.frame.size
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
