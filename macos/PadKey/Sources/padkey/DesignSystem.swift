import AppKit

enum PadKeyTheme {
    static let appBackground = NSColor(calibratedRed: 0.965, green: 0.956, blue: 0.935, alpha: 1.0)
    static let panelBackground = NSColor(calibratedRed: 0.990, green: 0.986, blue: 0.976, alpha: 1.0)
    static let raisedPanelBackground = NSColor(calibratedRed: 0.982, green: 0.976, blue: 0.958, alpha: 1.0)
    static let softSurface = NSColor(calibratedRed: 0.935, green: 0.923, blue: 0.895, alpha: 1.0)
    static let ink = NSColor(calibratedRed: 0.090, green: 0.088, blue: 0.083, alpha: 1.0)
    static let secondaryInk = NSColor(calibratedRed: 0.420, green: 0.405, blue: 0.380, alpha: 1.0)
    static let teal = NSColor(calibratedRed: 0.170, green: 0.405, blue: 0.390, alpha: 1.0)
    static let mint = NSColor(calibratedRed: 0.520, green: 0.780, blue: 0.730, alpha: 1.0)
    static let purple = NSColor(calibratedRed: 0.655, green: 0.420, blue: 0.910, alpha: 1.0)
    static let amber = NSColor(calibratedRed: 0.925, green: 0.620, blue: 0.285, alpha: 1.0)
}

extension NSView {
    func fillSuperview(insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)) {
        guard let superview else { return }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: superview.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

final class RoundedView: NSView {
    var fillColor: NSColor {
        didSet { layer?.backgroundColor = fillColor.cgColor }
    }

    var strokeColor: NSColor? {
        didSet { layer?.borderColor = strokeColor?.cgColor }
    }

    init(fillColor: NSColor = .clear, radius: CGFloat = 8, strokeColor: NSColor? = nil, strokeWidth: CGFloat = 0) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.backgroundColor = fillColor.cgColor
        layer?.borderColor = strokeColor?.cgColor
        layer?.borderWidth = strokeWidth
    }

    required init?(coder: NSCoder) {
        fillColor = .clear
        super.init(coder: coder)
    }
}

final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class HoverButton: NSButton {
    var normalColor = NSColor.clear {
        didSet { updateFill() }
    }
    var hoverColor = NSColor.controlAccentColor.withAlphaComponent(0.12) {
        didSet { updateFill() }
    }
    var pressedColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
    var cornerRadius: CGFloat = 8 {
        didSet { layer?.cornerRadius = cornerRadius }
    }
    private var tracking: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        font = .systemFont(ofSize: 13, weight: .semibold)
        contentTintColor = PadKeyTheme.ink
        updateFill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateFill()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateFill()
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = pressedColor.cgColor
        super.mouseDown(with: event)
        updateFill()
    }

    private func updateFill() {
        layer?.backgroundColor = (isHovering ? hoverColor : normalColor).cgColor
    }
}
