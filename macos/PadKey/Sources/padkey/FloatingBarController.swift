import AppKit
import QuartzCore

final class FloatingBarController {
    private enum Layout {
        static let panelSize = NSSize(width: 332, height: 126)
        static let edgeInset: CGFloat = 22
    }

    private let panel: NSPanel
    private let barView = FlowBarView()
    private var positionTimer: Timer?
    private let customOriginKey = "padkey.floatingBar.customOrigin"
    private var usesCustomPosition = false

    var onToggleDictation: (() -> Void)?
    var onOpenHub: (() -> Void)?
    var onPolish: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = barView

        barView.onToggleDictation = { [weak self] in self?.onToggleDictation?() }
        barView.onOpenHub = { [weak self] in self?.onOpenHub?() }
        barView.onPolish = { [weak self] in self?.onPolish?() }
        barView.onOpenScratchpad = { [weak self] in self?.onOpenScratchpad?() }
        barView.onDragStarted = { [weak self] in
            self?.usesCustomPosition = true
        }
        barView.onMoveRequested = { [weak self] origin in
            self?.move(to: origin)
        }
        barView.onDragEnded = { [weak self] in
            self?.saveCustomPosition()
        }
    }

    func show() {
        let savedOrigin = loadCustomPosition(for: Layout.panelSize)
        usesCustomPosition = savedOrigin != nil
        let origin = savedOrigin ?? positionOrigin(for: Layout.panelSize)
        panel.setFrame(NSRect(origin: origin, size: Layout.panelSize), display: true)
        panel.orderFrontRegardless()

        positionTimer?.invalidate()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.maintainPosition()
        }
        positionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func setRecording(_ recording: Bool) {
        barView.isRecording = recording
    }

    func updateVoiceMeter(_ frame: VoiceMeterFrame) {
        barView.updateVoiceMeter(frame)
    }

    func setStatus(_ status: String, detail: String? = nil) {
        barView.status = status
        barView.detail = detail
    }

    func flash(_ status: String, detail: String? = nil) {
        setStatus(status, detail: detail)
        barView.setExpanded(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard self?.barView.isRecording == false else { return }
            self?.barView.setExpanded(false)
        }
    }

    private func maintainPosition() {
        if usesCustomPosition {
            move(to: panel.frame.origin)
            return
        }

        let origin = positionOrigin(for: panel.frame.size)
        guard abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 else {
            return
        }
        panel.setFrameOrigin(origin)
    }

    private func move(to proposedOrigin: NSPoint) {
        let origin = clampedOrigin(proposedOrigin, size: panel.frame.size)
        guard abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 else {
            return
        }
        panel.setFrameOrigin(origin)
    }

    private func saveCustomPosition() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: customOriginKey)
    }

    private func loadCustomPosition(for size: NSSize) -> NSPoint? {
        guard let raw = UserDefaults.standard.string(forKey: customOriginKey) else {
            return nil
        }
        return clampedOrigin(NSPointFromString(raw), size: size)
    }

    private func positionOrigin(for size: NSSize) -> NSPoint {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
        return NSPoint(
            x: screenFrame.maxX - size.width - Layout.edgeInset,
            y: screenFrame.minY + Layout.edgeInset
        )
    }

    private func clampedOrigin(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let frame = NSScreen.screens
            .map(\.visibleFrame)
            .reduce(NSRect.null) { $0.union($1) }

        guard !frame.isNull else { return origin }

        let maxX = frame.maxX - size.width
        let maxY = frame.maxY - size.height
        return NSPoint(
            x: min(max(origin.x, frame.minX), maxX),
            y: min(max(origin.y, frame.minY), maxY)
        )
    }
}

final class FlowBarView: NSView {
    var onToggleDictation: (() -> Void)?
    var onOpenHub: (() -> Void)?
    var onPolish: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onMoveRequested: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    var isRecording = false {
        didSet {
            meter.isActive = isRecording
            dictateButton.title = isRecording ? "Stop" : "Dictate fn"
            if isRecording {
                setExpanded(true)
            }
        }
    }

    var status = "Ready" {
        didSet { statusLabel.stringValue = status }
    }

    var detail: String? {
        didSet { detailLabel.stringValue = detail ?? "" }
    }

    private(set) var expanded = false
    private var tracking: NSTrackingArea?
    private var collapseWorkItem: DispatchWorkItem?

    private let meter = CircularVoiceMeterView()
    private let controls = RoundedView(
        fillColor: NSColor.black.withAlphaComponent(0.86),
        radius: 24,
        strokeColor: NSColor.white.withAlphaComponent(0.10),
        strokeWidth: 1
    )
    private let dictateButton = HoverButton()
    private let polishButton = HoverButton()
    private let scratchpadButton = HoverButton()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    func setExpanded(_ expanded: Bool) {
        collapseWorkItem?.cancel()
        guard self.expanded != expanded else { return }
        self.expanded = expanded
        updateVisibility(animated: true)
    }

    func updateVoiceMeter(_ frame: VoiceMeterFrame) {
        meter.update(frame)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let activeRect = expanded ? bounds : meter.frame.insetBy(dx: -12, dy: -12)
        guard activeRect.contains(point) else { return nil }
        return super.hitTest(point)
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
        collapseWorkItem?.cancel()
        setExpanded(true)
    }

    override func mouseExited(with event: NSEvent) {
        if !isRecording {
            scheduleCollapse()
        }
    }

    private func configure() {
        wantsLayer = true

        addSubview(controls)
        addSubview(meter)

        meter.toolTip = "Click to dictate. Hold and drag to move."
        meter.onClick = { [weak self] in self?.onToggleDictation?() }
        meter.onDragStarted = { [weak self] in
            self?.collapseWorkItem?.cancel()
            self?.setExpanded(false)
            self?.onDragStarted?()
        }
        meter.onMoveRequested = { [weak self] origin in
            self?.onMoveRequested?(origin)
        }
        meter.onDragEnded = { [weak self] in
            self?.onDragEnded?()
        }

        configureDictateButton()
        configureIconButton(polishButton, symbol: "wand.and.stars", toolTip: "Polish last text", color: PadKeyTheme.purple)
        configureIconButton(scratchpadButton, symbol: "note.text", toolTip: "Open scratchpad", color: PadKeyTheme.teal)

        polishButton.target = self
        polishButton.action = #selector(polish)
        scratchpadButton.target = self
        scratchpadButton.action = #selector(openScratchpad)

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.82)
        statusLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        detailLabel.lineBreakMode = .byTruncatingTail

        [dictateButton, polishButton, scratchpadButton].forEach(controls.addSubview)
        [statusLabel, detailLabel].forEach(addSubview)
        updateVisibility(animated: false)
    }

    override func layout() {
        super.layout()

        meter.frame = NSRect(x: bounds.maxX - 96, y: 17, width: 88, height: 88)
        controls.frame = NSRect(x: 12, y: 19, width: 214, height: 54)
        statusLabel.frame = NSRect(x: 22, y: 92, width: 204, height: 16)
        detailLabel.frame = NSRect(x: 22, y: 76, width: 206, height: 13)

        dictateButton.frame = NSRect(x: 10, y: 10, width: 96, height: 34)
        polishButton.frame = NSRect(x: 116, y: 10, width: 38, height: 34)
        scratchpadButton.frame = NSRect(x: 164, y: 10, width: 38, height: 34)
    }

    private func configureDictateButton() {
        dictateButton.title = "Dictate fn"
        dictateButton.font = .systemFont(ofSize: 12, weight: .bold)
        dictateButton.contentTintColor = .white
        dictateButton.normalColor = NSColor.white.withAlphaComponent(0.10)
        dictateButton.hoverColor = NSColor.white.withAlphaComponent(0.18)
        dictateButton.pressedColor = PadKeyTheme.mint.withAlphaComponent(0.34)
        dictateButton.cornerRadius = 17
        dictateButton.toolTip = "Hold fn or click to dictate"
        dictateButton.target = self
        dictateButton.action = #selector(toggleDictation)
    }

    private func configureIconButton(_ button: HoverButton, symbol: String, toolTip: String, color: NSColor) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.contentTintColor = .white
        button.normalColor = NSColor.white.withAlphaComponent(0.08)
        button.hoverColor = color.withAlphaComponent(0.42)
        button.pressedColor = color.withAlphaComponent(0.62)
        button.cornerRadius = 17
        button.toolTip = toolTip
    }

    private func scheduleCollapse() {
        collapseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRecording else { return }
            if let window = self.window {
                let mousePoint = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                if self.bounds.insetBy(dx: -6, dy: -6).contains(mousePoint) {
                    return
                }
            }
            self.setExpanded(false)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
    }

    private func updateVisibility(animated: Bool) {
        let targetAlpha: CGFloat = expanded ? 1 : 0
        if expanded {
            [controls, statusLabel, detailLabel].forEach { $0.isHidden = false }
        }

        let changes = {
            self.controls.alphaValue = targetAlpha
            self.statusLabel.alphaValue = targetAlpha
            self.detailLabel.alphaValue = targetAlpha
        }

        let completion = {
            if !self.expanded {
                [self.controls, self.statusLabel, self.detailLabel].forEach { $0.isHidden = true }
            }
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                changes()
            } completionHandler: {
                completion()
            }
        } else {
            changes()
            completion()
        }
    }

    @objc private func toggleDictation() {
        onToggleDictation?()
    }

    @objc private func polish() {
        onPolish?()
    }

    @objc private func openScratchpad() {
        onOpenScratchpad?()
    }
}

final class CircularVoiceMeterView: NSView {
    var onClick: (() -> Void)?
    var onDragStarted: (() -> Void)?
    var onMoveRequested: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    var isActive = false {
        didSet {
            isActive ? start() : stop()
        }
    }

    private var timer: Timer?
    private var phase: CGFloat = 0
    private var smoothedBands = Array(repeating: CGFloat(0), count: VoiceMeterFrame.bandCount)
    private var smoothedLevel: CGFloat = 0
    private var lastMeterUpdate = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.button)
        setAccessibilityLabel("Dictate with PadKey")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func update(_ frame: VoiceMeterFrame) {
        lastMeterUpdate = Date()
        smoothedLevel = blend(current: smoothedLevel, target: CGFloat(frame.level), attack: 0.62, release: 0.30)

        let targetBands = frame.bands.map { CGFloat(min(1, max(0, $0))) }
        if smoothedBands.count != targetBands.count {
            smoothedBands = Array(repeating: 0, count: targetBands.count)
        }

        for index in targetBands.indices {
            smoothedBands[index] = blend(
                current: smoothedBands[index],
                target: targetBands[index],
                attack: 0.58,
                release: 0.26
            )
        }

        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            onClick?()
            return
        }

        let startingMouse = NSEvent.mouseLocation
        let startingOrigin = window.frame.origin
        var didDrag = false

        while true {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                break
            }

            if nextEvent.type == .leftMouseUp {
                break
            }

            let currentMouse = NSEvent.mouseLocation
            let delta = NSPoint(
                x: currentMouse.x - startingMouse.x,
                y: currentMouse.y - startingMouse.y
            )
            let distance = hypot(delta.x, delta.y)

            if !didDrag, distance > 4 {
                didDrag = true
                onDragStarted?()
            }

            if didDrag {
                onMoveRequested?(NSPoint(
                    x: startingOrigin.x + delta.x,
                    y: startingOrigin.y + delta.y
                ))
            }
        }

        if didDrag {
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard bounds.width > 1, bounds.height > 1 else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let outerRadius = min(bounds.width, bounds.height) / 2 - 5
        let innerRadius = outerRadius - 13

        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowBlurRadius = 16
        shadow.set()
        NSColor.black.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        )).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.10).setStroke()
        let innerStroke = NSBezierPath(ovalIn: NSRect(
            x: center.x - innerRadius,
            y: center.y - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        innerStroke.lineWidth = 1
        innerStroke.stroke()

        drawRing(center: center, radius: outerRadius)
        drawCenterMark(center: center)
    }

    private func drawRing(center: NSPoint, radius: CGFloat) {
        let dotCount = 104
        for index in 0..<dotCount {
            let progress = CGFloat(index) / CGFloat(dotCount)
            let angle = progress * CGFloat.pi * 2 - CGFloat.pi / 2
            let voice = isActive ? liveValue(at: progress) : 0
            let lift = voice * 12
            let dotSize = isActive ? 2.15 + voice * 5.5 : 2.35
            let dotRadius = radius + lift
            let x = center.x + cos(angle) * dotRadius - dotSize / 2
            let y = center.y + sin(angle) * dotRadius - dotSize / 2
            let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dotSize, height: dotSize))

            if isActive {
                PadKeyTheme.mint.withAlphaComponent(0.42 + voice * 0.52).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.46).setFill()
            }
            dot.fill()
        }
    }

    private func drawCenterMark(center: NSPoint) {
        if isActive {
            let barCount = 5
            let barWidth: CGFloat = 4
            let gap: CGFloat = 4
            let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
            let startX = center.x - totalWidth / 2

            for index in 0..<barCount {
                let progress = CGFloat(index) / CGFloat(max(1, barCount - 1))
                let voice = max(liveValue(at: progress), smoothedLevel * 0.32)
                let height = 8 + voice * 28
                PadKeyTheme.mint.withAlphaComponent(0.62 + voice * 0.34).setFill()
                let rect = NSRect(
                    x: startX + CGFloat(index) * (barWidth + gap),
                    y: center.y - height / 2,
                    width: barWidth,
                    height: height
                )
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        } else {
            let text = "fn" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.82)
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2 + 1),
                withAttributes: attributes
            )
        }
    }

    private func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = self.wrapProgress(self.phase + 0.010)
            self.decayMeterIfStale()
            self.needsDisplay = true
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        needsDisplay = true
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        phase = 0
        smoothedLevel = 0
        smoothedBands = Array(repeating: 0, count: VoiceMeterFrame.bandCount)
        lastMeterUpdate = .distantPast
        needsDisplay = true
    }

    private func liveValue(at progress: CGFloat) -> CGFloat {
        guard !smoothedBands.isEmpty else { return 0 }

        let wrapped = wrapProgress(progress + phase)
        let scaled = wrapped * CGFloat(smoothedBands.count)
        let lowerIndex = Int(floor(scaled)) % smoothedBands.count
        let upperIndex = (lowerIndex + 1) % smoothedBands.count
        let fraction = scaled - floor(scaled)
        let interpolated = smoothedBands[lowerIndex] * (1 - fraction) + smoothedBands[upperIndex] * fraction
        return min(1, max(interpolated, smoothedLevel * 0.16))
    }

    private func decayMeterIfStale() {
        guard Date().timeIntervalSince(lastMeterUpdate) > 0.18 else { return }
        smoothedLevel *= 0.86
        for index in smoothedBands.indices {
            smoothedBands[index] *= 0.86
        }
    }

    private func blend(current: CGFloat, target: CGFloat, attack: CGFloat, release: CGFloat) -> CGFloat {
        let factor = target > current ? attack : release
        return current + (target - current) * factor
    }

    private func wrapProgress(_ value: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }
}
