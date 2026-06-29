import AppKit

final class HubWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private enum Layout {
        static let windowMinimumSize = NSSize(width: 1120, height: 680)
        static let contentMinimumWidth: CGFloat = 900
        static let initialContentHeight: CGFloat = 1800
    }

    private enum Page: String, CaseIterable {
        case studio = "Studio"
        case home = "Overview"
        case pipeline = "Dictation"
        case liveCaptions = "Live Captions"
        case agent = "Agent Control"
        case signalMonitor = "Signal Monitor"
        case advanced = "Advanced"
        case help = "Help"
        case insights = "Insights"
        case sync = "Voice Setup"
        case dictionary = "Dictionary"
        case snippets = "Snippets"
        case style = "Style"
        case transforms = "Transforms"
        case scratchpad = "Scratchpad"
        case settings = "Settings"

        var symbol: String {
            switch self {
            case .studio: return "waveform.and.mic"
            case .home: return "square.grid.2x2"
            case .insights: return "chart.bar"
            case .sync: return "waveform.badge.mic"
            case .pipeline: return "point.3.connected.trianglepath.dotted"
            case .liveCaptions: return "captions.bubble"
            case .agent: return "command"
            case .signalMonitor: return "waveform.path.ecg"
            case .advanced: return "slider.horizontal.3"
            case .help: return "questionmark.circle"
            case .dictionary: return "doc.text.magnifyingglass"
            case .snippets: return "scissors"
            case .style: return "textformat"
            case .transforms: return "wand.and.stars"
            case .scratchpad: return "note.text"
            case .settings: return "gearshape"
            }
        }
    }

    private let store: PadKeyStore
    private let commandCoordinator = MacCommandCoordinator.shared
    private let syncDictationController = DictationController()
    private let liveCaptionController = DictationController()
    private let captionPlayback = CaptionPlaybackService.shared
    private var page: Page = .studio
    private let root = NSStackView()
    private let sidebar = NSStackView()
    private let contentHost = NSView()
    private let content = RoundedView(
        fillColor: PadKeyTheme.raisedPanelBackground,
        radius: 24,
        strokeColor: NSColor.white.withAlphaComponent(0.62),
        strokeWidth: 1
    )
    private let contentScrollView = NSScrollView()
    private let contentDocument = FlippedView()
    private let contentStack = FlippedStackView()
    private let studioController = StudioWebViewController()
    private var pageButtons: [Page: HoverButton] = [:]
    private var activeScratchNoteID: UUID?
    private var scratchTitleField: NSTextField?
    private var scratchTextView: NSTextView?
    private var scratchSaveLabel: NSTextField?
    private var scratchSaveWorkItem: DispatchWorkItem?
    private var isLoadingScratchNote = false
    private var syncPromptIndex = 0
    private var syncIsRecording = false
    private var syncStartedAt: Date?
    private var syncLiveTranscript = ""
    private weak var syncStatusLabel: NSTextField?
    private weak var syncTranscriptLabel: NSTextField?
    private weak var syncRecordButton: HoverButton?
    private weak var syncMeterView: SyncMeterView?
    private var liveCaptionIsRecording = false
    private var liveCaptionStartedAt: Date?
    private var liveCaptionRawTranscript = ""
    private var liveCaptionCleanTranscript = ""
    private var liveCaptionBatches: [String] = []
    private var liveCaptionStatus = "Ready for captions"
    private var liveCaptionPlaybackStatus = "Playback ready"
    private var liveCaptionRenderScheduled = false
    private weak var liveCaptionStatusLabel: NSTextField?
    private weak var liveCaptionAudienceLabel: NSTextField?
    private weak var liveCaptionMeterView: SyncMeterView?
    private weak var agentCommandField: NSTextField?
    private var hardwareStatus = PadKeyHardwareAudioService.shared.status
    private var lastSignalMonitorRenderAt = Date.distantPast
    private var signalMonitorRenderScheduled = false
    private let speechSynthesizer = NSSpeechSynthesizer()
    private var capturePlaybackSound: NSSound?
    private var didCenterOnFirstShow = false

    init(store: PadKeyStore = .shared) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PadKey"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = Layout.windowMinimumSize

        super.init(window: window)
        window.delegate = self
        configure()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentControlDidUpdate),
            name: .padKeyAgentControlDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hardwareStreamDidUpdate(_:)),
            name: .padKeyHardwareStreamDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputSourceDidChange),
            name: .padKeyInputSourceDidChange,
            object: nil
        )
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private static let syncPrompts = [
        "PadKey should understand me when I speak softly and naturally.",
        "My names, product terms, PadKey, Gemini, and Codex should stay spelled correctly.",
        "Polish this rough thought into something clear, warm, and easy to act on.",
        "I may pause, whisper, speed up, or change direction while I am thinking out loud.",
        "My personal dictionary keeps names, products, domains, and shortcuts spelled correctly."
    ]

    func show(page: String? = nil) {
        if let page, let target = Page(rawValue: page) {
            self.page = target
        }
        render()
        NSApp.setActivationPolicy(.regular)
        if !didCenterOnFirstShow {
            window?.center()
            didCenterOnFirstShow = true
        }
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusScratchpadIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        cancelSyncRecording()
        cancelLiveCaptionRecording()
    }

    func showScratchpad(with text: String? = nil) {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = text.split(separator: "\n").first.map(String.init) ?? "Dictation"
            let note = store.createNote(title: String(title.prefix(72)), body: text)
            activeScratchNoteID = note.id
        } else {
            ensureScratchSelection(createIfNeeded: true)
        }

        show(page: Page.scratchpad.rawValue)
    }

    private func configure() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = PadKeyTheme.appBackground.cgColor

        root.orientation = .horizontal
        root.spacing = 0
        contentView.addSubview(root)
        root.fillSuperview()

        let sidebarContainer = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 0)
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.widthAnchor.constraint(equalToConstant: 220).isActive = true

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 28, left: 14, bottom: 18, right: 14)
        sidebarContainer.addSubview(sidebar)
        sidebar.fillSuperview()

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 22
        contentStack.edgeInsets = NSEdgeInsets(top: 44, left: 40, bottom: 40, right: 40)

        contentScrollView.drawsBackground = false
        contentScrollView.borderType = .noBorder
        contentScrollView.hasVerticalScroller = true
        contentScrollView.hasHorizontalScroller = false
        contentScrollView.autohidesScrollers = true
        content.addSubview(contentScrollView)
        contentScrollView.fillSuperview()
        studioController.view.translatesAutoresizingMaskIntoConstraints = false
        studioController.view.isHidden = true
        content.addSubview(studioController.view)
        studioController.view.fillSuperview()
        contentDocument.frame = NSRect(origin: .zero, size: NSSize(width: Layout.contentMinimumWidth, height: Layout.initialContentHeight))
        contentScrollView.documentView = contentDocument
        contentDocument.addSubview(contentStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = true
        contentStack.autoresizingMask = [.width]
        contentStack.frame = contentDocument.bounds

        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = PadKeyTheme.appBackground.cgColor
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.widthAnchor.constraint(greaterThanOrEqualToConstant: Layout.contentMinimumWidth).isActive = true
        contentHost.addSubview(content)
        content.fillSuperview(insets: NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22))
        configureRaisedContentSurface()

        root.addArrangedSubview(sidebarContainer)
        root.addArrangedSubview(contentHost)

        buildSidebar()
    }

    private func configureRaisedContentSurface() {
        content.wantsLayer = true
        content.layer?.masksToBounds = false
        content.layer?.shadowColor = NSColor.black.withAlphaComponent(0.18).cgColor
        content.layer?.shadowOpacity = 1
        content.layer?.shadowRadius = 10
        content.layer?.shadowOffset = CGSize(width: 0, height: -5)
    }

    private func buildSidebar() {
        sidebar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        pageButtons.removeAll()

        let sidebarIcon = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar") ?? NSImage(), target: self, action: #selector(selectHomeFromSidebarIcon))
        sidebarIcon.isBordered = false
        sidebarIcon.contentTintColor = PadKeyTheme.secondaryInk
        sidebarIcon.toolTip = "Home"
        sidebarIcon.translatesAutoresizingMaskIntoConstraints = false
        sidebarIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        sidebarIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
        sidebar.addArrangedSubview(sidebarIcon)

        let brand = NSStackView()
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 8
        brand.translatesAutoresizingMaskIntoConstraints = false
        brand.widthAnchor.constraint(equalToConstant: 192).isActive = true

        let logoView = NSImageView()
        logoView.image = padKeyLogoImage() ?? appIconImage() ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "PadKey")
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.widthAnchor.constraint(equalToConstant: 136).isActive = true
        logoView.heightAnchor.constraint(equalToConstant: 38).isActive = true

        brand.addArrangedSubview(logoView)
        sidebar.addArrangedSubview(brand)

        let plan = NSTextField(labelWithString: "Personal")
        plan.font = .systemFont(ofSize: 12, weight: .semibold)
        plan.textColor = PadKeyTheme.secondaryInk
        sidebar.addArrangedSubview(plan)

        sidebar.addArrangedSubview(spacer(height: 24))

        for item in Page.allCases {
            if item == .settings {
                sidebar.addArrangedSubview(spacer(height: 18))
            }

            let button = navButton(item)
            pageButtons[item] = button
            sidebar.addArrangedSubview(button)
        }

        sidebar.addArrangedSubview(NSView())

        let usage = NSView()
        usage.translatesAutoresizingMaskIntoConstraints = false
        usage.widthAnchor.constraint(equalToConstant: 192).isActive = true
        usage.heightAnchor.constraint(equalToConstant: 58).isActive = true

        let usageLabel = NSTextField(labelWithString: "\(store.totalWords) words dictated")
        usageLabel.font = .systemFont(ofSize: 14, weight: .bold)
        usageLabel.textColor = PadKeyTheme.ink
        usage.addSubview(usageLabel)
        usageLabel.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(labelWithString: "Local-first. No weekly limit.")
        sub.font = .systemFont(ofSize: 11, weight: .medium)
        sub.textColor = PadKeyTheme.secondaryInk
        sub.lineBreakMode = .byWordWrapping
        sub.maximumNumberOfLines = 2
        usage.addSubview(sub)
        sub.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            usageLabel.leadingAnchor.constraint(equalTo: usage.leadingAnchor, constant: 6),
            usageLabel.topAnchor.constraint(equalTo: usage.topAnchor, constant: 5),
            sub.leadingAnchor.constraint(equalTo: usage.leadingAnchor, constant: 6),
            sub.trailingAnchor.constraint(equalTo: usage.trailingAnchor, constant: -6),
            sub.topAnchor.constraint(equalTo: usageLabel.bottomAnchor, constant: 6)
        ])

        sidebar.addArrangedSubview(usage)
    }

    private func navButton(_ page: Page) -> HoverButton {
        let button = HoverButton()
        button.title = "  \(page.rawValue)"
        button.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.rawValue)
        button.imagePosition = .imageLeft
        button.alignment = .left
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.normalColor = self.page == page ? PadKeyTheme.softSurface : .clear
        button.hoverColor = PadKeyTheme.softSurface.withAlphaComponent(0.72)
        button.contentTintColor = PadKeyTheme.ink
        button.target = self
        button.action = #selector(selectPage(_:))
        button.identifier = NSUserInterfaceItemIdentifier(page.rawValue)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 192).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func selectPage(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let next = Page(rawValue: raw) else { return }
        if page == .scratchpad {
            persistScratchpadNote()
        }
        if page == .sync, next != .sync {
            cancelSyncRecording()
        }
        if page == .liveCaptions, next != .liveCaptions {
            cancelLiveCaptionRecording()
        }
        page = next
        buildSidebar()
        render()
        focusScratchpadIfNeeded()
    }

    @objc private func selectHomeFromSidebarIcon() {
        if page == .scratchpad {
            persistScratchpadNote()
        }
        if page == .sync {
            cancelSyncRecording()
        }
        if page == .liveCaptions {
            cancelLiveCaptionRecording()
        }
        page = .home
        buildSidebar()
        render()
    }

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let showsStudio = page == .studio || page == .advanced
        contentScrollView.isHidden = showsStudio
        studioController.view.isHidden = !showsStudio
        if showsStudio {
            if page == .advanced {
                studioController.openAdvanced("signals")
            } else {
                studioController.openStudio()
            }
            return
        }

        switch page {
        case .studio:
            break
        case .home:
            renderHome()
        case .insights:
            renderInsights()
        case .sync:
            renderSync()
        case .pipeline:
            renderPipeline()
        case .liveCaptions:
            renderLiveCaptions()
        case .agent:
            renderAgentControl()
        case .signalMonitor:
            renderSignalMonitor()
        case .advanced:
            break
        case .help:
            renderHelp()
        case .dictionary:
            renderDictionary()
        case .snippets:
            renderSnippets()
        case .style:
            renderStyle()
        case .transforms:
            renderTransforms()
        case .scratchpad:
            renderScratchpad()
        case .settings:
            renderSettings()
        }

        refreshContentLayout()
    }

    private func refreshContentLayout() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let documentWidth = max(Layout.contentMinimumWidth, self.contentScrollView.contentView.bounds.width)
            let fittingHeight = max(1, self.contentStack.fittingSize.height)
            let visibleHeight = max(1, self.contentScrollView.contentView.bounds.height)
            let neededHeight = max(visibleHeight, fittingHeight)
            self.contentDocument.setFrameSize(NSSize(width: documentWidth, height: neededHeight))
            self.contentStack.frame = NSRect(x: 0, y: 0, width: documentWidth, height: fittingHeight)
            self.contentScrollView.contentView.scroll(to: .zero)
            self.contentScrollView.reflectScrolledClipView(self.contentScrollView.contentView)
        }
    }

    private func renderHome() {
        contentStack.addArrangedSubview(title("Welcome back"))
        contentStack.addArrangedSubview(hero(
            title: "Make PadKey sound like you",
            subtitle: "Local dictation, personal vocabulary, snippets, and optional AI polish.",
            action: "Open scratchpad",
            color: PadKeyTheme.teal,
            actionSelector: #selector(openScratchpad)
        ))

        contentStack.addArrangedSubview(sectionLabel("TODAY"))
        let history = store.snapshot.history.prefix(8)
        if history.isEmpty {
            contentStack.addArrangedSubview(emptyState("No dictations yet", detail: "Press fn or Option-Space anywhere you can type."))
        } else {
            contentStack.addArrangedSubview(historyTable(Array(history)))
        }
    }

    private func renderInsights() {
        contentStack.addArrangedSubview(title("Insights"))
        contentStack.addArrangedSubview(tabLine(["Your Usage", "Your Voice"]))

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.spacing = 18
        metrics.addArrangedSubview(metricCard(value: "\(store.averageWPM)", label: "words per minute"))
        metrics.addArrangedSubview(metricCard(value: "\(Int((store.insertionSuccessRate * 100).rounded()))%", label: "insertion success"))
        metrics.addArrangedSubview(metricCard(value: "\(store.totalWords)", label: "total words dictated"))
        contentStack.addArrangedSubview(metrics)

        contentStack.addArrangedSubview(insightsCharts())
    }

    private func renderSync() {
        syncStatusLabel = nil
        syncTranscriptLabel = nil
        syncRecordButton = nil
        syncMeterView = nil

        contentStack.addArrangedSubview(pageHeader("Sync", buttonTitle: syncIsRecording ? "Stop" : "Record sample", action: #selector(toggleSyncRecording)))
        contentStack.addArrangedSubview(syncRecorderCard())

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.spacing = 18
        metrics.addArrangedSubview(metricCard(value: "\(syncStrength)%", label: "context strength"))
        metrics.addArrangedSubview(metricCard(value: "\(store.voiceSyncSamples.count)", label: "samples saved"))
        metrics.addArrangedSubview(metricCard(value: "\(store.snapshot.dictionary.count)", label: "preferred spellings"))
        contentStack.addArrangedSubview(metrics)

        contentStack.addArrangedSubview(sectionLabel("VOICE SAMPLES"))
        contentStack.addArrangedSubview(syncSamplesList())
    }

    private func renderPipeline() {
        contentStack.addArrangedSubview(title("Pipeline"))
        contentStack.addArrangedSubview(subtitle("Voice capture, transcription, cleanup, context, and insertion are visible here so the system feels observable instead of magical."))
        contentStack.addArrangedSubview(pipelineStatusStrip())
        contentStack.addArrangedSubview(inputSourcePanel())
        contentStack.addArrangedSubview(pipelineMap())
        contentStack.addArrangedSubview(recognitionStrategyPanel())
        contentStack.addArrangedSubview(sectionLabel("CONTROL SURFACE"))
        contentStack.addArrangedSubview(pipelineControls())
        contentStack.addArrangedSubview(sectionLabel("RECENT SESSIONS"))
        contentStack.addArrangedSubview(pipelineDiagnosticsTable())
    }

    private func renderLiveCaptions() {
        liveCaptionStatusLabel = nil
        liveCaptionAudienceLabel = nil
        liveCaptionMeterView = nil

        contentStack.addArrangedSubview(pageHeader("Live Captions", buttonTitle: liveCaptionIsRecording ? "Stop captioning" : "Start captioning", action: #selector(toggleLiveCaptions)))
        contentStack.addArrangedSubview(subtitle("A big audience-facing caption surface for whispered or quiet speech. PadKey filters fillers, applies punctuation, preserves your dictionary, and keeps playback local."))
        contentStack.addArrangedSubview(liveCaptionAudiencePanel())
        contentStack.addArrangedSubview(liveCaptionControlPanel())
        contentStack.addArrangedSubview(sectionLabel("CAPTION BATCHES"))
        contentStack.addArrangedSubview(liveCaptionBatchList())
        contentStack.addArrangedSubview(sectionLabel("PLAYBACK VOICE"))
        contentStack.addArrangedSubview(liveCaptionVoicePanel())
    }

    private func renderDictionary() {
        contentStack.addArrangedSubview(pageHeader("Dictionary", buttonTitle: "Add word", action: #selector(addDictionaryWord)))
        contentStack.addArrangedSubview(hero(
            title: "PadKey spells the way you do.",
            subtitle: "Names, tools, domains, and phrases stay consistent after dictation.",
            action: "Add new word",
            color: PadKeyTheme.amber,
            actionSelector: #selector(addDictionaryWord)
        ))
        contentStack.addArrangedSubview(simpleList(store.snapshot.dictionary.map { entry in
            entry.replacement.map { "\(entry.phrase) -> \($0)" } ?? entry.phrase
        }))
    }

    private func renderSnippets() {
        contentStack.addArrangedSubview(pageHeader("Snippets", buttonTitle: "Add snippet", action: #selector(addSnippet)))
        contentStack.addArrangedSubview(hero(
            title: "The stuff you say often should not be re-typed.",
            subtitle: "Say a cue and PadKey expands it into the full text.",
            action: "Add new snippet",
            color: NSColor(calibratedRed: 0.18, green: 0.28, blue: 0.35, alpha: 1),
            actionSelector: #selector(addSnippet)
        ))
        contentStack.addArrangedSubview(simpleList(store.snapshot.snippets.map { "\($0.trigger) -> \($0.expansion)" }))
    }

    private func renderStyle() {
        contentStack.addArrangedSubview(title("Style"))
        contentStack.addArrangedSubview(tabLine(["Personal messages", "Work messages", "Email", "Other", "Auto Cleanup"]))
        contentStack.addArrangedSubview(hero(
            title: "Make PadKey sound like you",
            subtitle: "Style profiles are local prompts today. Add Gemini to make them smarter.",
            action: "Start now",
            color: PadKeyTheme.teal,
            actionSelector: #selector(openSettings)
        ))
    }

    private func renderTransforms() {
        contentStack.addArrangedSubview(transformsTopBar())
        contentStack.addArrangedSubview(transformsHero())

        contentStack.addArrangedSubview(transformsSectionHeader())
        let grid = NSStackView()
        grid.orientation = .horizontal
        grid.spacing = 16
        for transform in store.snapshot.transforms.prefix(2) {
            grid.addArrangedSubview(transformCard(transform))
        }
        grid.addArrangedSubview(createTransformCard())
        contentStack.addArrangedSubview(grid)
    }

    private func renderScratchpad() {
        ensureScratchSelection(createIfNeeded: false)
        contentStack.addArrangedSubview(pageHeader("Scratchpad", buttonTitle: "New note", action: #selector(addScratchpadNote)))
        contentStack.addArrangedSubview(subtitle("Draft, capture, and polish thoughts without opening a separate window. Notes autosave as you type."))

        if store.snapshot.notes.isEmpty {
            contentStack.addArrangedSubview(scratchpadEmptyState())
        } else {
            contentStack.addArrangedSubview(scratchpadWorkspace())
        }
    }

    private func renderSettings() {
        contentStack.addArrangedSubview(title("Settings"))
        contentStack.addArrangedSubview(subtitle("Your local dictation surface, model choices, AI polish, and insertion behavior in one place."))
        contentStack.addArrangedSubview(settingsSummaryStrip())
        contentStack.addArrangedSubview(inputSourcePanel())
        contentStack.addArrangedSubview(permissionStatusTable())
        contentStack.addArrangedSubview(settingsBlock())
    }

    private func renderAgentControl() {
        contentStack.addArrangedSubview(agentRuntimeHeader())
        contentStack.addArrangedSubview(agentCapabilityStrip())
        contentStack.addArrangedSubview(agentRealtimeStackPanel())
        contentStack.addArrangedSubview(agentCommandComposer())
        contentStack.addArrangedSubview(sectionLabel("LIVE RUNTIME"))
        contentStack.addArrangedSubview(agentActionStatus())
        contentStack.addArrangedSubview(sectionLabel("CONTROL SURFACE"))
        contentStack.addArrangedSubview(agentSupportedActionsTable())
        contentStack.addArrangedSubview(sectionLabel("SMOKE TESTS"))
        contentStack.addArrangedSubview(agentTestActions())
    }

    private func renderSignalMonitor() {
        let status = hardwareStatus
        let source = store.selectedInputSource
        contentStack.addArrangedSubview(title("Signal Monitor"))
        contentStack.addArrangedSubview(subtitle("This page makes the source obvious: PadKey hardware streams are separate from the MacBook microphone. fn uses the selected source below."))
        contentStack.addArrangedSubview(inputSourcePanel())

        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.spacing = 18
        metrics.addArrangedSubview(metricCard(value: source.transportName, label: "active transport"))
        metrics.addArrangedSubview(metricCard(value: source.channel?.displayName ?? "System", label: "selected channel"))
        metrics.addArrangedSubview(metricCard(value: source.isPadKeyHardware ? "PadKey hardware" : "MacBook mic", label: "actual source"))
        contentStack.addArrangedSubview(metrics)

        let signalMetrics = NSStackView()
        signalMetrics.orientation = .horizontal
        signalMetrics.spacing = 18
        signalMetrics.addArrangedSubview(metricCard(value: status.bleConnected ? "Connected" : "Disconnected", label: "BLE status"))
        signalMetrics.addArrangedSubview(metricCard(value: status.sampleRate > 0 ? "\(status.sampleRate) Hz" : "-", label: "sample rate"))
        signalMetrics.addArrangedSubview(metricCard(value: status.batteryPercent.map { "\($0)%" } ?? "-", label: "battery"))
        contentStack.addArrangedSubview(signalMetrics)

        contentStack.addArrangedSubview(signalStatusPanel())
        contentStack.addArrangedSubview(sectionLabel("RECENT CAPTURES"))
        contentStack.addArrangedSubview(captureHistoryTable())
    }

    private func renderHelp() {
        contentStack.addArrangedSubview(title("How PadKey Works"))
        contentStack.addArrangedSubview(subtitle("The simple version: PadKey listens where your laptop cannot, then the Mac app turns that capture into text or safe actions."))
        contentStack.addArrangedSubview(simpleList([
            "PadKey captures low-volume, whispered, and subvocal-style speech using the breadboard or wearable microphone.",
            "The ESP32-S3 sends the selected sensor stream over Bluetooth, USB, or Wi‑Fi.",
            "The macOS app receives that PadKey stream natively, not just inside the Studio browser view.",
            "The selected input source controls dictation and agent commands. MacBook microphone capture is only used when explicitly selected.",
            "Press and hold fn to capture from the selected source. Release fn to transcribe and act.",
            "If the transcript looks like a command, Agent Control maps it to Mac actions such as open app, live UI inspection, click, type, copy, paste, scroll, and close window.",
            "Signal Monitor shows the actual incoming PadKey signal so you can verify whether audio came from hardware or the MacBook mic."
        ]))
        contentStack.addArrangedSubview(sectionLabel("PERMISSIONS"))
        contentStack.addArrangedSubview(permissionStatusTable())
    }

    private func liveCaptionAudiencePanel() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.ink, radius: 14)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(equalToConstant: 360).isActive = true

        let badge = NSTextField(labelWithString: liveCaptionIsRecording ? "LIVE" : "READY")
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = PadKeyTheme.ink
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = (liveCaptionIsRecording ? PadKeyTheme.mint : NSColor.white.withAlphaComponent(0.86)).cgColor
        badge.layer?.cornerRadius = 7
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 72).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let caption = NSTextField(wrappingLabelWithString: liveCaptionDisplayText)
        caption.font = liveCaptionFont(for: liveCaptionDisplayText)
        caption.textColor = .white
        caption.alignment = .center
        caption.maximumNumberOfLines = 6
        caption.lineBreakMode = .byWordWrapping

        let meter = SyncMeterView()
        meter.update(level: liveCaptionIsRecording ? 0.22 : 0)
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalToConstant: 150).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 46).isActive = true

        let status = NSTextField(labelWithString: liveCaptionStatus)
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = NSColor.white.withAlphaComponent(0.76)

        [badge, caption, meter, status].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            badge.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            meter.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            meter.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            caption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 38),
            caption.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -38),
            caption.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: 6),
            status.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            status.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -22)
        ])

        liveCaptionAudienceLabel = caption
        liveCaptionStatusLabel = status
        liveCaptionMeterView = meter
        return panel
    }

    private func liveCaptionControlPanel() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(primaryButton(liveCaptionIsRecording ? "Stop captioning" : "Start captioning", action: #selector(toggleLiveCaptions)))
        buttons.addArrangedSubview(primaryButton("Play captions", action: #selector(playLiveCaptions), inverted: true))
        buttons.addArrangedSubview(primaryButton("Stop audio", action: #selector(stopLiveCaptionPlayback), inverted: true))
        buttons.addArrangedSubview(primaryButton("Clear", action: #selector(clearLiveCaptions), inverted: true))

        rows.addArrangedSubview(buttons)
        rows.addArrangedSubview(settingsDetailRow("Input", store.selectedInputSource.displayName))
        rows.addArrangedSubview(settingsDetailRow("Engine", store.pipelineSettings.effectiveRecognitionEngine.displayName))
        rows.addArrangedSubview(settingsDetailRow("Cleanup", "Spoken punctuation, filler removal, sentence casing, snippets, and dictionary words."))
        rows.addArrangedSubview(settingsDetailRow("Playback", liveCaptionPlaybackStatus))

        panel.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            rows.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            rows.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            rows.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        return panel
    }

    private func liveCaptionBatchList() -> NSView {
        guard !liveCaptionBatches.isEmpty else {
            return emptyState("No caption batches yet", detail: "Start captioning and speak naturally. PadKey will show clean batches here as it hears you.")
        }

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: 760).isActive = true

        for (index, batch) in liveCaptionBatches.enumerated() {
            list.addArrangedSubview(liveCaptionBatchRow(number: index + 1, text: batch))
        }

        return list
    }

    private func liveCaptionBatchRow(number: Int, text: String) -> NSView {
        let row = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.32), strokeWidth: 1)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true

        let index = NSTextField(labelWithString: "\(number)")
        index.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        index.textColor = PadKeyTheme.ink
        index.alignment = .center
        index.wantsLayer = true
        index.layer?.backgroundColor = PadKeyTheme.softSurface.cgColor
        index.layer?.cornerRadius = 8
        index.translatesAutoresizingMaskIntoConstraints = false
        index.widthAnchor.constraint(equalToConstant: 34).isActive = true
        index.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = PadKeyTheme.ink
        label.maximumNumberOfLines = 3

        [index, label].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            index.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            index.topAnchor.constraint(equalTo: row.topAnchor, constant: 18),
            label.leadingAnchor.constraint(equalTo: index.trailingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            label.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func liveCaptionVoicePanel() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let title = NSTextField(labelWithString: "Local playback and voice profile")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = PadKeyTheme.ink

        let body = NSTextField(wrappingLabelWithString: "PadKey only learns a personal voice profile after explicit samples. Today those samples improve phrasing and spelling context; an open-source cloned voice can be attached locally through Piper/OpenVoice-style tooling once a model is configured.")
        body.font = .systemFont(ofSize: 12, weight: .medium)
        body.textColor = PadKeyTheme.secondaryInk
        body.maximumNumberOfLines = 3

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(primaryButton("Play captions", action: #selector(playLiveCaptions)))
        buttons.addArrangedSubview(primaryButton("Save as voice sample", action: #selector(saveLiveCaptionsAsVoiceSample), inverted: true))
        buttons.addArrangedSubview(primaryButton("Open Voice Setup", action: #selector(openVoiceSetupFromLiveCaptions), inverted: true))

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(body)
        stack.addArrangedSubview(settingsDetailRow("Open source", captionPlayback.statusMessage))
        stack.addArrangedSubview(settingsDetailRow("Profile", "\(store.voiceSyncSamples.count) saved samples; local-only and user-triggered."))
        stack.addArrangedSubview(settingsDetailRow("Consent", "No background cloning. Save samples only when the speaker chooses it."))
        stack.addArrangedSubview(buttons)

        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        return panel
    }

    private var liveCaptionDisplayText: String {
        let text = LiveCaptionFormatter.audienceText(from: liveCaptionCleanTranscript)
        return text.isEmpty
            ? "Start captioning, then whisper or speak naturally."
            : text
    }

    private func liveCaptionFont(for text: String) -> NSFont {
        switch text.count {
        case 0...72:
            return .systemFont(ofSize: 50, weight: .bold)
        case 73...150:
            return .systemFont(ofSize: 40, weight: .bold)
        case 151...240:
            return .systemFont(ofSize: 32, weight: .bold)
        default:
            return .systemFont(ofSize: 26, weight: .semibold)
        }
    }

    private func inputSourcePanel() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let titleLabel = NSTextField(labelWithString: "Dictation and command input")
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let detail = NSTextField(wrappingLabelWithString: "\(store.selectedInputSource.displayName). \(store.selectedInputSource.statusDetail)")
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = PadKeyTheme.secondaryInk
        detail.maximumNumberOfLines = 2

        let options = NSStackView()
        options.orientation = .horizontal
        options.spacing = 8
        let sources: [(String, PadKeyInputSource)] = [
            ("BLE · INMP441", .padKeyBLE(channel: .inmp441)),
            ("BLE · MAX4466", .padKeyBLE(channel: .max4466)),
            ("BLE · Piezo", .padKeyBLE(channel: .piezo)),
            ("USB · INMP441", .padKeyUSB(channel: .inmp441)),
            ("MacBook mic", .systemAudio(deviceID: nil))
        ]
        for (label, source) in sources {
            let button = pipelineOptionButton(
                title: label,
                identifier: "input-\(source.commandSource)",
                selected: store.selectedInputSource == source,
                action: #selector(selectInputSource(_:))
            )
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            options.addArrangedSubview(button)
        }

        [titleLabel, detail, options].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            detail.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            detail.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            options.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            options.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -18),
            options.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            options.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -18)
        ])

        return panel
    }

    private func signalStatusPanel() -> NSView {
        let status = hardwareStatus
        let lastPacket = status.lastPacketAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "No packet yet"
        let rows = [
            ("Active input", store.selectedInputSource.displayName),
            ("Hardware stream", status.bleConnected || status.usbConnected || status.wifiConnected ? "Connected" : "Not connected"),
            ("Last packet", lastPacket),
            ("Packet count", "\(status.packetCount)"),
            ("Latest channel", status.lastChannel?.displayName ?? "-"),
            ("Live meter", "Peak \(status.latestPeak) · RMS \(Int(status.latestRMS.rounded()))"),
            ("Source truth", store.selectedInputSource.isPadKeyHardware ? "PadKey hardware, not MacBook microphone" : "MacBook/system microphone")
        ]
        return settingsCard(title: "Stream status", rows: rows, height: 272)
    }

    private func agentSupportedActionsTable() -> NSView {
        let actions: [(String, String, String, String)] = [
            ("App launch and focus", "Open Safari / Open FaceTime / Open Notes", "LaunchServices and deterministic app tools", "Live"),
            ("Frontmost-app UI", "Choose the second option in this app", "Accessibility tree plus local action planner", PermissionHelper.isAccessibilityTrusted ? "Live" : "Needs Accessibility"),
            ("Fields and controls", "Fill the search field / click Continue / select PDF", "Direct AX match first, local planner fallback", PermissionHelper.isAccessibilityTrusted ? "Live" : "Needs Accessibility"),
            ("Writing surfaces", "Make a note / append to current note / paste that", "AppleScript, text insertion, clipboard actions", "Live"),
            ("Navigation", "Scroll down / go back / close window", "Keyboard and scroll adapters", "Live"),
            ("Page understanding", "Summarize this page", "Readable Accessibility text plus local model", PermissionHelper.isAccessibilityTrusted ? "Live" : "Needs Accessibility"),
            ("Communications", "Prepare FaceTime call / send message", "Preview/confirm before calls or sends", "Guarded"),
            ("Atlas adapters", "Volume, media, system, browser, scriptable apps", "Python atlas/runtime has deterministic adapter plans", "Engine ready")
        ]
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        panel.addSubview(stack)
        stack.fillSuperview()
        stack.addArrangedSubview(actionRow(["Surface", "Voice examples", "Runtime", "Status"], isHeader: true))
        for action in actions {
            stack.addArrangedSubview(historySeparator())
            stack.addArrangedSubview(actionRow([action.0, action.1, action.2, action.3], isHeader: false))
        }
        return panel
    }

    private func actionRow(_ values: [String], isHeader: Bool) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true
        let widths: [CGFloat] = values.count == 4 ? [146, 246, 220, 86] : [96, 148, 164, 86, 96, 70]
        for (index, value) in values.enumerated() {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = .systemFont(ofSize: isHeader ? 11 : 10, weight: isHeader ? .bold : .medium)
            if !isHeader, index == values.count - 1 {
                label.textColor = statusColor(value)
            } else {
                label.textColor = isHeader ? PadKeyTheme.ink : PadKeyTheme.secondaryInk
            }
            label.maximumNumberOfLines = 3
            label.translatesAutoresizingMaskIntoConstraints = false
            label.widthAnchor.constraint(equalToConstant: widths[min(index, widths.count - 1)]).isActive = true
            row.addArrangedSubview(label)
        }
        return row
    }

    private func statusColor(_ value: String) -> NSColor {
        let lower = value.lowercased()
        if lower.contains("live") { return PadKeyTheme.teal }
        if lower.contains("guarded") || lower.contains("engine") { return PadKeyTheme.amber }
        if lower.contains("needs") { return NSColor.systemRed.withAlphaComponent(0.86) }
        return PadKeyTheme.secondaryInk
    }

    private func permissionStatusTable() -> NSView {
        let rows = [
            ("Microphone", "Needed only when MacBook microphone is selected", "Request in macOS Privacy settings"),
            ("Bluetooth", "Needed for PadKey BLE hardware input", "Grant when macOS prompts"),
            ("Accessibility", "Needed for Mac control and text insertion", PermissionHelper.isAccessibilityTrusted ? "Enabled" : "Needs permission"),
            ("Input Monitoring", "Needed for global fn detection", PermissionHelper.isInputMonitoringTrusted ? "Enabled" : "Needs permission"),
            ("Speech Recognition", "Only needed for Apple Speech fallback", "Optional"),
            ("Local Network", "Only needed for Wi‑Fi transport", "Optional until Wi‑Fi is used")
        ]
        let panel = settingsCard(title: "Permission checklist", rows: rows.map { ($0.0, "\($0.1) · \($0.2)") }, height: 330)
        return panel
    }

    private func captureHistoryTable() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        panel.addSubview(list)
        list.fillSuperview()
        let records = store.snapshot.history.prefix(8)
        if records.isEmpty {
            list.addArrangedSubview(emptyState("No captures yet", detail: "Press fn to create a dictation or command capture."))
            return panel
        }
        for (index, record) in records.enumerated() {
            list.addArrangedSubview(captureHistoryRow(record))
            if index < records.count - 1 { list.addArrangedSubview(historySeparator()) }
        }
        return panel
    }

    private func captureHistoryRow(_ record: TranscriptRecord) -> NSView {
        let row = RoundedView(fillColor: .clear, radius: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let source = record.inputSource?.displayName ?? "Unknown input"
        let text = NSTextField(wrappingLabelWithString: record.text)
        text.font = .systemFont(ofSize: 13, weight: .semibold)
        text.textColor = PadKeyTheme.ink
        text.maximumNumberOfLines = 2

        let detail = NSTextField(wrappingLabelWithString: "\(source) · \(record.recognitionEngine ?? "Unknown ASR") · \(record.audioPath == nil ? "No saved audio" : "Audio saved")")
        detail.font = .systemFont(ofSize: 11, weight: .medium)
        detail.textColor = PadKeyTheme.secondaryInk
        detail.maximumNumberOfLines = 2

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.addArrangedSubview(compactActionButton("Copy", identifier: record.id.uuidString, action: #selector(copyHistoryRecord(_:))))
        actions.addArrangedSubview(compactActionButton("Read", identifier: record.id.uuidString, action: #selector(readHistoryRecord(_:))))
        actions.addArrangedSubview(compactActionButton("Play", identifier: record.id.uuidString, action: #selector(playHistoryAudio(_:))))
        actions.addArrangedSubview(compactActionButton("Run", identifier: record.id.uuidString, action: #selector(runHistoryAsCommand(_:))))

        [text, detail, actions].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            detail.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 7),
            actions.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            actions.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 10),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -14)
        ])
        return row
    }

    private func agentCommandComposer() -> NSView {
        let panel = RoundedView(
            fillColor: PadKeyTheme.panelBackground,
            radius: 12,
            strokeColor: NSColor.separatorColor.withAlphaComponent(0.42),
            strokeWidth: 1
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(equalToConstant: 126).isActive = true

        let label = NSTextField(labelWithString: "COMMAND")
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = PadKeyTheme.secondaryInk

        let field = NSTextField(string: "Tell me about how PadKey should handle accents")
        field.placeholderString = "Try: make a diagram of PadKey voice control"
        field.font = .systemFont(ofSize: 14)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default

        let run = primaryButton("Run command", action: #selector(runAgentCommand))

        let detail = NSTextField(wrappingLabelWithString: "Runs the same native path as hold-to-talk: local cleanup, command routing, Ollama chat/planning, and Accessibility actions.")
        detail.font = .systemFont(ofSize: 11, weight: .medium)
        detail.textColor = PadKeyTheme.secondaryInk
        detail.maximumNumberOfLines = 2

        [label, field, run, detail].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            label.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: run.leadingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            field.heightAnchor.constraint(equalToConstant: 38),
            run.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            run.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            run.widthAnchor.constraint(equalToConstant: 122),
            detail.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            detail.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10)
        ])
        agentCommandField = field
        return panel
    }

    private func agentRuntimeHeader() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.ink, radius: 14)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 188).isActive = true

        let badge = NSTextField(labelWithString: "Native runtime wired")
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = PadKeyTheme.ink
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.86).cgColor
        badge.layer?.cornerRadius = 6
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 138).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let headline = NSTextField(wrappingLabelWithString: "Voice control for the whole Mac")
        headline.font = .systemFont(ofSize: 26, weight: .bold)
        headline.textColor = .white
        headline.maximumNumberOfLines = 2

        let body = NSTextField(wrappingLabelWithString: "No wake phrase required. PadKey cleans spoken text, understands personal vocabulary, chats through the local model, and routes command-shaped speech into a live frontmost-app runtime with native Accessibility.")
        body.font = .systemFont(ofSize: 13, weight: .semibold)
        body.textColor = NSColor.white.withAlphaComponent(0.86)
        body.maximumNumberOfLines = 3

        let source = NSTextField(labelWithString: "Input: \(store.selectedInputSource.displayName)")
        source.font = .systemFont(ofSize: 12, weight: .bold)
        source.textColor = PadKeyTheme.mint

        [badge, headline, body, source].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            badge.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22),
            headline.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
            headline.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -22),
            headline.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 10),
            source.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            source.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 14),
            source.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -20)
        ])

        return panel
    }

    private func agentCapabilityStrip() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        row.addArrangedSubview(agentCapabilityTile(
            value: "No wake",
            label: "Activation",
            detail: "Command mode listens for intent, not a magic phrase",
            accent: PadKeyTheme.teal
        ))
        row.addArrangedSubview(agentCapabilityTile(
            value: "Clean",
            label: "Speech text",
            detail: "Filler words, punctuation, and personal terms",
            accent: PadKeyTheme.mint
        ))
        row.addArrangedSubview(agentCapabilityTile(
            value: "Local",
            label: "AI brain",
            detail: "Ollama plans actions and answers chat",
            accent: PadKeyTheme.purple
        ))
        row.addArrangedSubview(agentCapabilityTile(
            value: PermissionHelper.isAccessibilityTrusted ? "Ready" : "Needed",
            label: "Accessibility",
            detail: PermissionHelper.isAccessibilityTrusted ? "Native actions can run" : "Grant permission to control apps",
            accent: PermissionHelper.isAccessibilityTrusted ? PadKeyTheme.teal : PadKeyTheme.amber
        ))
        row.addArrangedSubview(agentCapabilityTile(
            value: "Guarded",
            label: "Risk gate",
            detail: "Sends, calls, deletes pause for confirm",
            accent: PadKeyTheme.amber
        ))
        return row
    }

    private func agentCapabilityTile(value: String, label: String, detail: String, accent: NSColor) -> NSView {
        let tile = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.36), strokeWidth: 1)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.widthAnchor.constraint(equalToConstant: 144).isActive = true
        tile.heightAnchor.constraint(greaterThanOrEqualToConstant: 114).isActive = true

        let bar = RoundedView(fillColor: accent, radius: 3)
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .bold)
        valueLabel.textColor = PadKeyTheme.ink

        let labelView = NSTextField(labelWithString: label.uppercased())
        labelView.font = .systemFont(ofSize: 10, weight: .bold)
        labelView.textColor = PadKeyTheme.secondaryInk

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 2

        [bar, valueLabel, labelView, detailLabel].forEach {
            tile.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            bar.topAnchor.constraint(equalTo: tile.topAnchor, constant: 14),
            bar.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -14),
            bar.widthAnchor.constraint(equalToConstant: 5),
            valueLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            valueLabel.topAnchor.constraint(equalTo: tile.topAnchor, constant: 14),
            labelView.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
            labelView.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 10),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -12)
        ])

        return tile
    }

    private func agentRealtimeStackPanel() -> NSView {
        let panel = RoundedView(
            fillColor: PadKeyTheme.panelBackground,
            radius: 12,
            strokeColor: NSColor.separatorColor.withAlphaComponent(0.42),
            strokeWidth: 1
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let title = NSTextField(labelWithString: "Local realtime stack")
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = PadKeyTheme.ink

        let detail = NSTextField(wrappingLabelWithString: "This build borrows the realtime voice-agent shape, but keeps the working path native: live captions, final local ASR, cleanup, local model reasoning, Accessibility actions, and macOS speech output.")
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = PadKeyTheme.secondaryInk
        detail.maximumNumberOfLines = 3

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 8
        rows.addArrangedSubview(settingsDetailRow("Transcription", "\(store.pipelineSettings.effectiveRecognitionEngine.displayName); \(syncDictationController.liveTranscriptionStatus)"))
        rows.addArrangedSubview(settingsDetailRow("Cleanup", "Spoken punctuation, filler-word handling, sentence casing, personal dictionary, snippets."))
        rows.addArrangedSubview(settingsDetailRow("Conversation", "Local Ollama chat for explain, tell me about, chat about, and PadKey-prefixed questions."))
        rows.addArrangedSubview(settingsDetailRow("Diagrams", "Voice requests create Mermaid diagram notes through the local model and Apple Notes."))
        rows.addArrangedSubview(settingsDetailRow("Voice feedback", "macOS NSSpeechSynthesizer speaks command results and local answers. Cloud voice APIs are not required."))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(rows)

        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        return panel
    }

    private func agentActionStatus() -> NSView {
        let state = commandCoordinator.snapshot
        let panel = RoundedView(
            fillColor: PadKeyTheme.panelBackground,
            radius: 12,
            strokeColor: NSColor.separatorColor.withAlphaComponent(0.42),
            strokeWidth: 1
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let statusLine = NSStackView()
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 10
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.widthAnchor.constraint(equalToConstant: 724).isActive = true
        statusLine.addArrangedSubview(agentStatusBadge(state.status))
        statusLine.addArrangedSubview(agentStatusBadge(state.accessibilityStatus))
        statusLine.addArrangedSubview(NSView())
        let frontmost = NSTextField(labelWithString: state.frontmostApp)
        frontmost.font = .systemFont(ofSize: 12, weight: .semibold)
        frontmost.textColor = PadKeyTheme.secondaryInk
        statusLine.addArrangedSubview(frontmost)
        stack.addArrangedSubview(statusLine)

        stack.addArrangedSubview(settingsDetailRow("Last command", state.lastCommand))
        stack.addArrangedSubview(settingsDetailRow("Intent", state.detectedIntent))
        stack.addArrangedSubview(settingsDetailRow("Target", state.selectedTarget))
        stack.addArrangedSubview(settingsDetailRow("Result", state.actionResult))
        stack.addArrangedSubview(settingsDetailRow("Response", state.spokenResponse))
        if !state.clarification.isEmpty {
            stack.addArrangedSubview(settingsDetailRow("Clarification", state.clarification))
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        if state.confirmationId != nil {
            actions.addArrangedSubview(primaryButton("Confirm action", action: #selector(confirmAgentAction)))
        }
        if !PermissionHelper.isAccessibilityTrusted {
            let permission = primaryButton("Enable Accessibility", action: #selector(requestAgentAccessibility))
            actions.addArrangedSubview(permission)
        }
        if !actions.arrangedSubviews.isEmpty {
            stack.addArrangedSubview(actions)
        }

        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        return panel
    }

    private func agentStatusBadge(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = PadKeyTheme.ink
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = (text.localizedCaseInsensitiveContains("permission") ? PadKeyTheme.amber : PadKeyTheme.mint).withAlphaComponent(0.42).cgColor
        label.layer?.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        label.heightAnchor.constraint(equalToConstant: 24).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        return label
    }

    private func agentTestActions() -> NSView {
        let panel = RoundedView(
            fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.56),
            radius: 12,
            strokeColor: NSColor.separatorColor.withAlphaComponent(0.34),
            strokeWidth: 1
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let detail = NSTextField(wrappingLabelWithString: "These run the real deterministic and Accessibility tools. They are not simulated status buttons.")
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = PadKeyTheme.secondaryInk
        detail.maximumNumberOfLines = 2

        let rowOne = NSStackView()
        rowOne.orientation = .horizontal
        rowOne.spacing = 10
        rowOne.addArrangedSubview(agentTestButton("Test Make Note", id: "make-note"))
        rowOne.addArrangedSubview(agentTestButton("Test Open FaceTime", id: "open-facetime"))
        rowOne.addArrangedSubview(agentTestButton("Test Fill Search Field", id: "fill-search"))

        let rowTwo = NSStackView()
        rowTwo.orientation = .horizontal
        rowTwo.spacing = 10
        rowTwo.addArrangedSubview(agentTestButton("Test Click Current Field", id: "click-current"))
        rowTwo.addArrangedSubview(agentTestButton("Test Current App Choice", id: "computer-runtime"))
        rowTwo.addArrangedSubview(agentTestButton("Test Accessibility Tree", id: "accessibility-tree"))

        let rowThree = NSStackView()
        rowThree.orientation = .horizontal
        rowThree.spacing = 10
        rowThree.addArrangedSubview(agentTestButton("Test Local Chat", id: "local-chat"))
        rowThree.addArrangedSubview(agentTestButton("Test Diagram Note", id: "diagram-note"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(rowOne)
        stack.addArrangedSubview(rowTwo)
        stack.addArrangedSubview(rowThree)
        panel.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -18)
        ])
        return panel
    }

    private func agentTestButton(_ title: String, id: String) -> HoverButton {
        let button = HoverButton()
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.target = self
        button.action = #selector(runAgentTest(_:))
        button.normalColor = PadKeyTheme.panelBackground
        button.hoverColor = PadKeyTheme.softSurface
        button.contentTintColor = PadKeyTheme.ink
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 172).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func transformsTopBar() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let heading = title("Transforms")
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let badge = NSTextField(labelWithString: "Beta")
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = PadKeyTheme.ink.cgColor
        badge.layer?.cornerRadius = 6
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 42).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let left = NSStackView()
        left.orientation = .horizontal
        left.alignment = .centerY
        left.spacing = 8
        left.addArrangedSubview(heading)
        left.addArrangedSubview(badge)

        let shortcut = NSTextField(labelWithString: "Option-1 polish  •  Option-2 prompt")
        shortcut.font = .systemFont(ofSize: 12, weight: .semibold)
        shortcut.textColor = PadKeyTheme.secondaryInk
        shortcut.lineBreakMode = .byTruncatingTail
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addArrangedSubview(left)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(shortcut)
        return row
    }

    private func transformsHero() -> NSView {
        let panel = RoundedView(fillColor: NSColor(calibratedRed: 0.23, green: 0.30, blue: 0.34, alpha: 1), radius: 14)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 214).isActive = true

        let wave = WavePatternView(color: NSColor.white.withAlphaComponent(0.32))
        panel.addSubview(wave)
        wave.fillSuperview()

        let headline = NSTextField(wrappingLabelWithString: "Transform work anywhere you write")
        headline.font = .systemFont(ofSize: 26, weight: .bold)
        headline.textColor = .white
        headline.maximumNumberOfLines = 2

        let body = NSTextField(wrappingLabelWithString: "Rewrite, clean up, or restructure dictated text without leaving the app you are already in.")
        body.font = .systemFont(ofSize: 14, weight: .semibold)
        body.textColor = NSColor.white.withAlphaComponent(0.88)
        body.maximumNumberOfLines = 2

        let tryButton = primaryButton("Try polish", action: #selector(openSettings), inverted: true)
        let howButton = HoverButton()
        howButton.title = "How it works"
        howButton.target = self
        howButton.action = #selector(openSettings)
        howButton.normalColor = NSColor.white.withAlphaComponent(0.14)
        howButton.hoverColor = NSColor.white.withAlphaComponent(0.25)
        howButton.contentTintColor = .white
        howButton.translatesAutoresizingMaskIntoConstraints = false
        howButton.widthAnchor.constraint(equalToConstant: 118).isActive = true
        howButton.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.addArrangedSubview(tryButton)
        buttons.addArrangedSubview(howButton)

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 12
        copyStack.addArrangedSubview(headline)
        copyStack.addArrangedSubview(body)
        copyStack.addArrangedSubview(buttons)
        panel.addSubview(copyStack)
        copyStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            copyStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 28),
            copyStack.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -28),
            copyStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
            copyStack.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -24),
            headline.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            body.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
        ])

        return panel
    }

    private func transformsSectionHeader() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let label = NSTextField(labelWithString: "My Transforms")
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = PadKeyTheme.ink

        row.addArrangedSubview(label)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(primaryButton("Create new", action: #selector(addTransform)))
        return row
    }

    private func insightsCharts() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(equalToConstant: 430).isActive = true

        let dailyChart = DailyWordsChartView(points: dailyWordSeries(days: 14))
        dailyChart.translatesAutoresizingMaskIntoConstraints = false
        dailyChart.widthAnchor.constraint(equalToConstant: 448).isActive = true
        dailyChart.heightAnchor.constraint(equalToConstant: 172).isActive = true

        let appChart = AppUsageChartView(items: store.appBreakdown)
        appChart.translatesAutoresizingMaskIntoConstraints = false
        appChart.widthAnchor.constraint(equalToConstant: 448).isActive = true
        appChart.heightAnchor.constraint(equalToConstant: 172).isActive = true

        let streak = StreakGridView(activeDays: activeHistoryDays())
        streak.translatesAutoresizingMaskIntoConstraints = false
        streak.widthAnchor.constraint(equalToConstant: 214).isActive = true
        streak.heightAnchor.constraint(equalToConstant: 286).isActive = true

        let dailyCard = chartCard(title: "Words over time", subtitle: "Last 14 days", graph: dailyChart)
        let appCard = chartCard(title: "Desktop usage", subtitle: "\(max(1, store.appBreakdown.count)) tracked apps", graph: appChart)
        let streakCard = chartCard(title: "\(store.currentStreak) day streak", subtitle: "Last 8 weeks", graph: streak)

        [dailyCard, appCard, streakCard].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            dailyCard.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            dailyCard.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            appCard.leadingAnchor.constraint(equalTo: dailyCard.leadingAnchor),
            appCard.topAnchor.constraint(equalTo: dailyCard.bottomAnchor, constant: 18),
            streakCard.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            streakCard.topAnchor.constraint(equalTo: dailyCard.topAnchor),
            streakCard.bottomAnchor.constraint(equalTo: appCard.bottomAnchor)
        ])

        return panel
    }

    private func chartCard(title: String, subtitle: String, graph: NSView) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.62), radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.26), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: graph is StreakGridView ? 250 : 474).isActive = true
        card.heightAnchor.constraint(equalToConstant: graph is StreakGridView ? 394 : 188).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let subtitleLabel = NSTextField(labelWithString: subtitle.uppercased())
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        subtitleLabel.textColor = PadKeyTheme.secondaryInk

        [titleLabel, subtitleLabel, graph].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            graph.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            graph.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            graph.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            graph.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -14)
        ])

        return card
    }

    private func dailyWordSeries(days: Int) -> [(Date, Int)] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let grouped = Dictionary(grouping: store.snapshot.history) { record in
            calendar.startOfDay(for: record.createdAt)
        }

        return stride(from: days - 1, through: 0, by: -1).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
            let words = grouped[day]?.reduce(0) { $0 + $1.wordCount } ?? 0
            return (day, words)
        }
    }

    private func activeHistoryDays() -> Set<Date> {
        let calendar = Calendar.current
        return Set(store.snapshot.history.map { calendar.startOfDay(for: $0.createdAt) })
    }

    private var currentSyncPrompt: String {
        Self.syncPrompts[syncPromptIndex % Self.syncPrompts.count]
    }

    private var syncStrength: Int {
        let samples = min(5, store.voiceSyncSamples.count) * 16
        let dictionary = min(10, store.snapshot.dictionary.count * 2)
        let usage = min(10, store.snapshot.sessions)
        return min(100, samples + dictionary + usage)
    }

    private func appIconImage() -> NSImage? {
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: bundled)
        }

        let developmentIcon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/AppIcon.icns")
        return NSImage(contentsOf: developmentIcon)
    }

    private func padKeyLogoImage() -> NSImage? {
        if let bundled = Bundle.main.url(forResource: "PadKeyLogo", withExtension: "svg") {
            return NSImage(contentsOf: bundled)
        }
        let developmentLogo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/PadKeyLogo.svg")
        return NSImage(contentsOf: developmentLogo)
    }

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textColor = PadKeyTheme.ink
        return label
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = PadKeyTheme.secondaryInk
        return label
    }

    private func subtitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = PadKeyTheme.secondaryInk
        label.maximumNumberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 760).isActive = true
        return label
    }

    private func pageHeader(_ titleText: String, buttonTitle: String, action: Selector) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.addArrangedSubview(title(titleText))
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(primaryButton(buttonTitle, action: action))
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true
        return row
    }

    private func hero(title: String, subtitle: String, action: String, color: NSColor, actionSelector: Selector) -> NSView {
        let view = RoundedView(fillColor: color, radius: 14)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 760).isActive = true
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.maximumNumberOfLines = 2

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        subtitleLabel.maximumNumberOfLines = 2

        let button = primaryButton(action, action: actionSelector, inverted: true)

        let copyStack = NSStackView()
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = 10
        copyStack.addArrangedSubview(titleLabel)
        copyStack.addArrangedSubview(subtitleLabel)
        copyStack.addArrangedSubview(spacer(height: 4))
        copyStack.addArrangedSubview(button)
        view.addSubview(copyStack)
        copyStack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            copyStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            copyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            copyStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            copyStack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])

        return view
    }

    private func metricCard(value: String, label: String) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.5), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 232).isActive = true
        card.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold)
        valueLabel.textColor = PadKeyTheme.ink

        let labelView = NSTextField(labelWithString: label.uppercased())
        labelView.font = .systemFont(ofSize: 11, weight: .bold)
        labelView.textColor = PadKeyTheme.secondaryInk

        card.addSubview(valueLabel)
        card.addSubview(labelView)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        labelView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            valueLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            valueLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            labelView.leadingAnchor.constraint(equalTo: valueLabel.leadingAnchor),
            labelView.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 10)
        ])

        return card
    }

    private func historyTable(_ records: [TranscriptRecord]) -> NSView {
        let panel = RoundedView(
            fillColor: PadKeyTheme.panelBackground,
            radius: 12,
            strokeColor: NSColor.separatorColor.withAlphaComponent(0.42),
            strokeWidth: 1
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        panel.addSubview(list)
        list.fillSuperview()

        for (index, record) in records.enumerated() {
            list.addArrangedSubview(historyRow(record))
            if index < records.count - 1 {
                list.addArrangedSubview(historySeparator())
            }
        }
        return panel
    }

    private func historyRow(_ record: TranscriptRecord) -> NSView {
        let actionRailWidth: CGFloat = 184
        let container = RoundedView(fillColor: .clear, radius: 0)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 760).isActive = true
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true

        let timeLabel = NSTextField(labelWithString: Self.timeFormatter.string(from: record.createdAt))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = PadKeyTheme.secondaryInk

        let transcriptLabel = NSTextField(wrappingLabelWithString: record.text)
        transcriptLabel.font = .systemFont(ofSize: 14)
        transcriptLabel.textColor = PadKeyTheme.ink
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.maximumNumberOfLines = 0
        transcriptLabel.preferredMaxLayoutWidth = 430
        transcriptLabel.cell?.wraps = true
        transcriptLabel.cell?.usesSingleLineMode = false
        transcriptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let copy = compactActionButton("Copy", identifier: record.id.uuidString, action: #selector(copyHistoryRecord(_:)))
        let edit = compactActionButton("Edit", identifier: record.id.uuidString, action: #selector(editHistoryRecord(_:)))
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        actions.addArrangedSubview(copy)
        actions.addArrangedSubview(edit)
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.widthAnchor.constraint(equalToConstant: actionRailWidth).isActive = true

        [timeLabel, transcriptLabel, actions].forEach {
            container.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            timeLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            timeLabel.widthAnchor.constraint(equalToConstant: 92),
            transcriptLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            transcriptLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -14),
            transcriptLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            transcriptLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            actions.leadingAnchor.constraint(equalTo: container.trailingAnchor, constant: -(18 + actionRailWidth)),
            actions.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func breakdownList(_ items: [(name: String, words: Int)]) -> NSView {
        simpleList(items.prefix(8).map { "\($0.name)  \($0.words) words" })
    }

    private func simpleList(_ items: [String]) -> NSView {
        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: 760).isActive = true

        if items.isEmpty {
            list.addArrangedSubview(emptyState("Nothing here yet", detail: "Add your first item to make this yours."))
            return list
        }

        for item in items {
            list.addArrangedSubview(row(left: "", right: item))
        }
        return list
    }

    private func row(left: String, right: String) -> NSView {
        let container = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 0, strokeColor: NSColor.separatorColor.withAlphaComponent(0.35), strokeWidth: 1)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: 760).isActive = true
        container.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true

        let leftLabel = NSTextField(labelWithString: left)
        leftLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        leftLabel.textColor = PadKeyTheme.secondaryInk
        container.addSubview(leftLabel)
        leftLabel.translatesAutoresizingMaskIntoConstraints = false

        let rightLabel = NSTextField(wrappingLabelWithString: right)
        rightLabel.font = .systemFont(ofSize: 14)
        rightLabel.textColor = PadKeyTheme.ink
        rightLabel.lineBreakMode = .byWordWrapping
        rightLabel.maximumNumberOfLines = 0
        rightLabel.preferredMaxLayoutWidth = 724
        rightLabel.cell?.wraps = true
        rightLabel.cell?.usesSingleLineMode = false
        container.addSubview(rightLabel)
        rightLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            leftLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            leftLabel.widthAnchor.constraint(equalToConstant: left.isEmpty ? 0 : 92),
            rightLabel.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: left.isEmpty ? 0 : 12),
            rightLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            rightLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            rightLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        return container
    }

    private func hairlineSeparator(width: CGFloat) -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.34).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: width).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func historySeparator() -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.widthAnchor.constraint(equalToConstant: 760).isActive = true
        wrapper.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor(calibratedWhite: 0.78, alpha: 0.55).cgColor
        wrapper.addSubview(line)
        line.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 18),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -18),
            line.topAnchor.constraint(equalTo: wrapper.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])

        return wrapper
    }

    private func transformCard(_ transform: TransformEntry) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.5), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 236).isActive = true
        card.heightAnchor.constraint(equalToConstant: 132).isActive = true

        let shortcut = NSTextField(labelWithString: transform.shortcut)
        shortcut.font = .systemFont(ofSize: 11, weight: .semibold)
        shortcut.textColor = PadKeyTheme.secondaryInk
        let name = NSTextField(labelWithString: transform.name)
        name.font = .systemFont(ofSize: 15, weight: .bold)
        name.textColor = PadKeyTheme.ink
        let desc = NSTextField(wrappingLabelWithString: transform.prompt)
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = PadKeyTheme.secondaryInk
        desc.maximumNumberOfLines = 2

        [shortcut, name, desc].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            shortcut.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            shortcut.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            name.leadingAnchor.constraint(equalTo: shortcut.leadingAnchor),
            name.topAnchor.constraint(equalTo: shortcut.bottomAnchor, constant: 18),
            desc.leadingAnchor.constraint(equalTo: shortcut.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10)
        ])

        return card
    }

    private func createTransformCard() -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.5), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 236).isActive = true
        card.heightAnchor.constraint(equalToConstant: 132).isActive = true

        let plus = NSTextField(labelWithString: "+")
        plus.font = .systemFont(ofSize: 20, weight: .semibold)
        plus.textColor = PadKeyTheme.teal
        plus.alignment = .center
        plus.wantsLayer = true
        plus.layer?.backgroundColor = PadKeyTheme.softSurface.cgColor
        plus.layer?.cornerRadius = 14
        plus.translatesAutoresizingMaskIntoConstraints = false
        plus.widthAnchor.constraint(equalToConstant: 28).isActive = true
        plus.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let name = NSTextField(labelWithString: "Create your own")
        name.font = .systemFont(ofSize: 15, weight: .bold)
        name.textColor = PadKeyTheme.ink

        let desc = NSTextField(wrappingLabelWithString: "Add a reusable rewrite prompt for your own workflow.")
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = PadKeyTheme.secondaryInk
        desc.maximumNumberOfLines = 2

        let hitArea = HoverButton()
        hitArea.title = ""
        hitArea.target = self
        hitArea.action = #selector(addTransform)
        hitArea.normalColor = .clear
        hitArea.hoverColor = PadKeyTheme.teal.withAlphaComponent(0.08)
        hitArea.pressedColor = PadKeyTheme.teal.withAlphaComponent(0.12)
        hitArea.cornerRadius = 10

        [plus, name, desc].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        card.addSubview(hitArea)
        hitArea.fillSuperview()

        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            plus.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            name.leadingAnchor.constraint(equalTo: plus.leadingAnchor),
            name.topAnchor.constraint(equalTo: plus.bottomAnchor, constant: 16),
            desc.leadingAnchor.constraint(equalTo: plus.leadingAnchor),
            desc.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            desc.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10)
        ])

        return card
    }

    private func tabLine(_ labels: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 24
        for (index, label) in labels.enumerated() {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 14, weight: index == 0 ? .bold : .semibold)
            text.textColor = index == 0 ? PadKeyTheme.ink : PadKeyTheme.secondaryInk
            stack.addArrangedSubview(text)
        }
        return stack
    }

    private func pipelineStatusStrip() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        row.addArrangedSubview(statusTile(
            title: "Current engine",
            value: store.pipelineSettings.effectiveRecognitionEngine.displayName,
            detail: asrLayerDetail(),
            accent: PadKeyTheme.teal
        ))
        row.addArrangedSubview(statusTile(
            title: "Voice context",
            value: "\(store.voiceSyncSamples.count) samples",
            detail: "\(store.snapshot.dictionary.count) preferred spellings available.",
            accent: PadKeyTheme.purple
        ))
        row.addArrangedSubview(statusTile(
            title: "Insertion path",
            value: "\(Int((store.insertionSuccessRate * 100).rounded()))% success",
            detail: store.pipelineSettings.copyFallbackEnabled ? "AX first, full clipboard restore fallback." : "AX only; no clipboard fallback.",
            accent: PadKeyTheme.amber
        ))

        return row
    }

    private func pipelineMap() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.86), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.35), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 256).isActive = true

        let headline = NSTextField(labelWithString: "Voice -> local brain -> active app")
        headline.font = .systemFont(ofSize: 22, weight: .bold)
        headline.textColor = PadKeyTheme.ink

        let subhead = NSTextField(wrappingLabelWithString: "PadKey keeps capture, voice context, cleanup, history, and insertion local by default. Gemini can join as an optional polish layer when you choose.")
        subhead.font = .systemFont(ofSize: 13, weight: .medium)
        subhead.textColor = PadKeyTheme.secondaryInk
        subhead.maximumNumberOfLines = 2

        let flow = NSStackView()
        flow.orientation = .horizontal
        flow.spacing = 10
        flow.alignment = .top

        let layers: [(String, String, String)] = [
            ("Capture", "fn / Option-Space", "Bounded session with live waveform."),
            ("ASR", asrLayerTitle(), asrLayerDetail()),
            ("Cleanup", "Rules", "Filler words, commands, snippets."),
            ("Context", "Sync", "\(store.voiceSyncSamples.count) voice samples, \(store.snapshot.dictionary.count) spellings."),
            ("Inject", "Active app", store.pipelineSettings.copyFallbackEnabled ? "Layered AX + clipboard restore." : "AX only; no clipboard fallback.")
        ]

        for (index, layer) in layers.enumerated() {
            flow.addArrangedSubview(pipelineLayerCard(step: index + 1, title: layer.0, value: layer.1, detail: layer.2))
        }

        [headline, subhead, flow].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            headline.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            headline.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            subhead.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            subhead.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            subhead.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 8),
            flow.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            flow.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -22),
            flow.topAnchor.constraint(equalTo: subhead.bottomAnchor, constant: 22),
            flow.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -22)
        ])

        return panel
    }

    private func recognitionStrategyPanel() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        row.addArrangedSubview(strategyCard(
            title: "Fast path",
            value: "Sherpa + Whisper",
            detail: "Live local feedback while Whisper finalizes after release.",
            accent: PadKeyTheme.teal
        ))
        row.addArrangedSubview(strategyCard(
            title: "Robust retry",
            value: "Mega-ASR",
            detail: "Optional GGUF pass for empty or suspicious transcripts.",
            accent: PadKeyTheme.purple
        ))
        row.addArrangedSubview(strategyCard(
            title: "System fallback",
            value: "Apple Speech",
            detail: "Used when local engines are missing or permissions are still settling.",
            accent: PadKeyTheme.amber
        ))

        return row
    }

    private func asrLayerTitle() -> String {
        switch store.pipelineSettings.effectiveRecognitionEngine {
        case .autoRobust:
            return "Auto robust"
        case .sherpaWhisper:
            return "Hybrid local"
        case .whisper:
            return "Whisper"
        case .megaASR:
            return "Mega-ASR"
        case .appleSpeech:
            return "Apple Speech"
        }
    }

    private func asrLayerDetail() -> String {
        switch store.pipelineSettings.effectiveRecognitionEngine {
        case .autoRobust:
            return "Sherpa live, Whisper final, Mega retry when needed."
        case .sherpaWhisper:
            return "Sherpa live captions, Whisper final."
        case .whisper:
            return "Private final pass after release."
        case .megaASR:
            return "Robust GGUF final pass after release."
        case .appleSpeech:
            return "macOS live fallback."
        }
    }

    private func strategyCard(title: String, value: String, detail: String, accent: NSColor) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.40), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 242).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        let eyebrow = NSTextField(labelWithString: title.uppercased())
        eyebrow.font = .systemFont(ofSize: 10, weight: .bold)
        eyebrow.textColor = accent

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 18, weight: .bold)
        valueLabel.textColor = PadKeyTheme.ink
        valueLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 3

        [eyebrow, valueLabel, detailLabel].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            eyebrow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            eyebrow.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            valueLabel.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 10),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16)
        ])

        return card
    }

    private func statusTile(title: String, value: String, detail: String, accent: NSColor) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.38), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 242).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true

        let accentBar = RoundedView(fillColor: accent, radius: 2)
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.widthAnchor.constraint(equalToConstant: 4).isActive = true

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        titleLabel.textColor = PadKeyTheme.secondaryInk

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 16, weight: .bold)
        valueLabel.textColor = PadKeyTheme.ink
        valueLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 2

        [accentBar, titleLabel, valueLabel, detailLabel].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            accentBar.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            accentBar.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            titleLabel.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 8),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -16)
        ])

        return card
    }

    private func pipelineLayerCard(step: Int, title: String, value: String, detail: String) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.34), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 132).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 118).isActive = true

        let number = NSTextField(labelWithString: "\(step)")
        number.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        number.textColor = PadKeyTheme.teal

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        valueLabel.textColor = PadKeyTheme.secondaryInk
        valueLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 2

        [number, titleLabel, valueLabel, detailLabel].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            number.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: number.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: number.bottomAnchor, constant: 8),
            valueLabel.leadingAnchor.constraint(equalTo: number.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: number.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12)
        ])

        return card
    }

    private func pipelineControls() -> NSView {
        let settings = store.pipelineSettings
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true
        panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 276).isActive = true

        let left = NSStackView()
        left.orientation = .vertical
        left.spacing = 12
        left.alignment = .leading

        left.addArrangedSubview(pipelineToggleRow(
            title: "Auto-polish after dictation",
            detail: store.hasGeminiAPIKey ? "Runs the polish layer before inserting text." : "Uses local polish until a Gemini key is available.",
            isOn: settings.autoPolishAfterDictation,
            action: #selector(toggleAutoPolish)
        ))
        left.addArrangedSubview(pipelineToggleRow(
            title: "Command mode",
            detail: "Route command-shaped speech through deterministic Mac tools and Accessibility instead of typing it.",
            isOn: settings.commandModeEnabled,
            action: #selector(toggleCommandMode)
        ))
        left.addArrangedSubview(pipelineToggleRow(
            title: "Clipboard fallback",
            detail: "If direct insertion fails, paste through the clipboard and restore it.",
            isOn: settings.copyFallbackEnabled,
            action: #selector(toggleCopyFallback)
        ))
        left.addArrangedSubview(pipelineToggleRow(
            title: "Robust ASR retry",
            detail: "Runs Mega-ASR only when the fast transcript looks empty or low-confidence.",
            isOn: settings.effectiveRobustRetryEnabled,
            action: #selector(toggleRobustRetry)
        ))

        let timeoutTitle = NSTextField(labelWithString: "Session timeout")
        timeoutTitle.font = .systemFont(ofSize: 15, weight: .bold)
        timeoutTitle.textColor = PadKeyTheme.ink

        let timeoutDetail = NSTextField(wrappingLabelWithString: "Bound microphone access so a forgotten recording cannot run forever.")
        timeoutDetail.font = .systemFont(ofSize: 12, weight: .medium)
        timeoutDetail.textColor = PadKeyTheme.secondaryInk
        timeoutDetail.maximumNumberOfLines = 2

        let timeoutButtons = NSStackView()
        timeoutButtons.orientation = .horizontal
        timeoutButtons.spacing = 8
        for option in [(30, "30s"), (60, "60s"), (90, "90s"), (0, "Off")] {
            timeoutButtons.addArrangedSubview(pipelineOptionButton(
                title: option.1,
                identifier: "timeout-\(option.0)",
                selected: settings.sessionTimeoutSeconds == option.0,
                action: #selector(setSessionTimeout(_:))
            ))
        }

        let engineTitle = NSTextField(labelWithString: "Recognition engine")
        engineTitle.font = .systemFont(ofSize: 15, weight: .bold)
        engineTitle.textColor = PadKeyTheme.ink

        let engineDetail = NSTextField(wrappingLabelWithString: settings.effectiveRecognitionEngine.displayName)
        engineDetail.font = .systemFont(ofSize: 12, weight: .medium)
        engineDetail.textColor = PadKeyTheme.secondaryInk
        engineDetail.maximumNumberOfLines = 2

        let engineButtons = NSStackView()
        engineButtons.orientation = .vertical
        engineButtons.spacing = 8
        engineButtons.alignment = .leading
        let engineRowOne = NSStackView()
        engineRowOne.orientation = .horizontal
        engineRowOne.spacing = 8
        let engineRowTwo = NSStackView()
        engineRowTwo.orientation = .horizontal
        engineRowTwo.spacing = 8
        let engineOptions: [(RecognitionEngine, String)] = [
            (.autoRobust, "Auto"),
            (.sherpaWhisper, "Hybrid"),
            (.whisper, "Whisper"),
            (.megaASR, "Mega"),
            (.appleSpeech, "Apple")
        ]
        for (index, option) in engineOptions.enumerated() {
            let button = pipelineOptionButton(
                title: option.1,
                identifier: "engine-\(option.0.rawValue)",
                selected: settings.effectiveRecognitionEngine == option.0,
                action: #selector(setRecognitionEngine(_:))
            )
            if index < 3 {
                engineRowOne.addArrangedSubview(button)
            } else {
                engineRowTwo.addArrangedSubview(button)
            }
        }
        engineButtons.addArrangedSubview(engineRowOne)
        engineButtons.addArrangedSubview(engineRowTwo)

        let right = NSStackView()
        right.orientation = .vertical
        right.spacing = 12
        right.alignment = .leading
        right.addArrangedSubview(timeoutTitle)
        right.addArrangedSubview(timeoutDetail)
        right.addArrangedSubview(timeoutButtons)
        right.addArrangedSubview(engineTitle)
        right.addArrangedSubview(engineDetail)
        right.addArrangedSubview(engineButtons)

        [left, right].forEach {
            panel.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            left.topAnchor.constraint(equalTo: panel.topAnchor, constant: 22),
            left.widthAnchor.constraint(equalToConstant: 410),
            left.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -22),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 34),
            right.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
            right.topAnchor.constraint(equalTo: left.topAnchor),
            right.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -22)
        ])

        return panel
    }

    private func pipelineToggleRow(title: String, detail: String, isOn: Bool, action: Selector) -> NSView {
        let row = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.58), radius: 9)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 410).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink
        titleLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 2

        let button = pipelineOptionButton(title: isOn ? "On" : "Off", identifier: title, selected: isOn, action: action)

        [titleLabel, detailLabel, button].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func pipelineDiagnosticsTable() -> NSView {
        let panel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        panel.addSubview(list)
        list.fillSuperview()

        let records = store.recentInsertionDiagnostics
        if records.isEmpty {
            list.addArrangedSubview(emptyState("No pipeline sessions yet", detail: "Your next dictation will show engine, insertion, latency, and fallback details here."))
            return panel
        }

        for (index, record) in records.prefix(8).enumerated() {
            list.addArrangedSubview(pipelineDiagnosticRow(record))
            if index < min(records.count, 8) - 1 {
                list.addArrangedSubview(historySeparator())
            }
        }

        return panel
    }

    private func pipelineDiagnosticRow(_ record: TranscriptRecord) -> NSView {
        let row = RoundedView(fillColor: .clear, radius: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 78).isActive = true

        let status = record.inserted == true ? "Inserted" : "Saved"
        let statusLabel = NSTextField(labelWithString: status)
        statusLabel.font = .systemFont(ofSize: 13, weight: .bold)
        statusLabel.textColor = record.inserted == true ? PadKeyTheme.teal : PadKeyTheme.amber

        let titleLabel = NSTextField(wrappingLabelWithString: record.appName)
        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink
        titleLabel.maximumNumberOfLines = 1

        let strategy = record.insertionStrategy ?? "No insertion attempted"
        let latencyText = record.latency?.insertionDuration.map { String(format: "%.0fms", $0 * 1000) } ?? "-"
        let detail = "\(record.recognitionEngine ?? "Unknown engine")  •  \(strategy)  •  \(latencyText)"
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 2

        let retry = NSTextField(labelWithString: record.usedRobustRetry == true ? "Mega retry" : "Fast path")
        retry.font = .systemFont(ofSize: 11, weight: .bold)
        retry.alignment = .center
        retry.textColor = record.usedRobustRetry == true ? .white : PadKeyTheme.ink
        retry.wantsLayer = true
        retry.layer?.cornerRadius = 8
        retry.layer?.backgroundColor = (record.usedRobustRetry == true ? PadKeyTheme.purple : PadKeyTheme.softSurface).cgColor
        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.widthAnchor.constraint(equalToConstant: 88).isActive = true
        retry.heightAnchor.constraint(equalToConstant: 28).isActive = true

        [statusLabel, titleLabel, detailLabel, retry].forEach {
            row.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            statusLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 18),
            statusLabel.widthAnchor.constraint(equalToConstant: 86),
            titleLabel.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: retry.leadingAnchor, constant: -18),
            titleLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -16),
            retry.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18),
            retry.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func pipelineOptionButton(title: String, identifier: String, selected: Bool, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.title = title
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.font = .systemFont(ofSize: 12, weight: .bold)
        button.normalColor = selected ? PadKeyTheme.ink : PadKeyTheme.softSurface
        button.hoverColor = selected ? PadKeyTheme.teal : PadKeyTheme.softSurface.withAlphaComponent(0.72)
        button.contentTintColor = selected ? .white : PadKeyTheme.ink
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func settingsSummaryStrip() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 760).isActive = true

        row.addArrangedSubview(statusTile(
            title: "Dictation",
            value: "\(store.totalWords) words",
            detail: "\(store.snapshot.sessions) sessions captured locally.",
            accent: PadKeyTheme.teal
        ))
        row.addArrangedSubview(statusTile(
            title: "AI polish",
            value: store.hasGeminiAPIKey ? "Configured" : "Optional",
            detail: store.hasGeminiAPIKey ? "Gemini key is stored in Keychain." : "Local cleanup still works without a key.",
            accent: PadKeyTheme.purple
        ))
        row.addArrangedSubview(statusTile(
            title: "Scratchpad",
            value: "\(store.snapshot.notes.count) notes",
            detail: "Fallback captures and drafts stay close by.",
            accent: PadKeyTheme.amber
        ))

        return row
    }

    private func settingsBlock() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let topRow = NSStackView()
        topRow.orientation = .horizontal
        topRow.spacing = 16
        topRow.addArrangedSubview(settingsCard(
            title: "General",
            rows: [
                ("Shortcut", "Hold fn, or Option-Space when macOS does not expose fn."),
                ("Microphone", "Built-in mic recommended. External mics work when macOS routes them."),
                ("Language", "English, with personal spellings from Dictionary and Sync.")
            ]
        ))
        topRow.addArrangedSubview(settingsCard(
            title: "Recognition",
            rows: [
                ("Engine", store.pipelineSettings.effectiveRecognitionEngine.displayName),
                ("Live layer", "Sherpa-ONNX streaming model."),
                ("Robust layer", store.pipelineSettings.effectiveRobustRetryEnabled ? "Mega-ASR retries low-confidence output." : "Mega-ASR retry is off."),
                ("Fallback", "Apple Speech when local engines are missing.")
            ]
        ))

        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 16

        let geminiCard = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.70), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.32), strokeWidth: 1)
        geminiCard.translatesAutoresizingMaskIntoConstraints = false
        geminiCard.widthAnchor.constraint(equalToConstant: 372).isActive = true
        geminiCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 292).isActive = true

        let geminiTitle = NSTextField(labelWithString: "Gemini usage")
        geminiTitle.font = .systemFont(ofSize: 18, weight: .bold)
        geminiTitle.textColor = PadKeyTheme.ink

        let keyField = NSSecureTextField()
        keyField.placeholderString = store.hasGeminiAPIKey
            ? "Stored in Keychain: \(store.maskedGeminiAPIKey)"
            : "Paste Gemini API key for AI polish"
        keyField.target = self
        keyField.action = #selector(saveGeminiKey(_:))

        let usage = store.snapshot.geminiUsage
        let geminiRows = NSStackView()
        geminiRows.orientation = .vertical
        geminiRows.spacing = 7
        geminiRows.addArrangedSubview(settingsDetailRow("Key", store.hasGeminiAPIKey ? "Stored securely (\(store.maskedGeminiAPIKey))" : "Not configured"))
        geminiRows.addArrangedSubview(settingsDetailRow("Provider", "Gemini 2.0 Flash polish"))
        if let details = store.snapshot.geminiKeyDetails {
            if !details.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                geminiRows.addArrangedSubview(settingsDetailRow("Name", details.name))
            }
            if !details.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                geminiRows.addArrangedSubview(settingsDetailRow("Project", details.projectName))
            }
        }
        geminiRows.addArrangedSubview(settingsDetailRow("Requests", "\(usage.totalRequests)"))
        geminiRows.addArrangedSubview(settingsDetailRow("Est. tokens", "\(usage.estimatedInputTokens + usage.estimatedOutputTokens)"))
        if let lastError = usage.lastError, !lastError.isEmpty {
            geminiRows.addArrangedSubview(settingsDetailRow("Last status", compactStatus(lastError)))
        }

        [geminiTitle, keyField, geminiRows].forEach {
            geminiCard.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            geminiTitle.leadingAnchor.constraint(equalTo: geminiCard.leadingAnchor, constant: 18),
            geminiTitle.topAnchor.constraint(equalTo: geminiCard.topAnchor, constant: 18),
            keyField.leadingAnchor.constraint(equalTo: geminiTitle.leadingAnchor),
            keyField.trailingAnchor.constraint(equalTo: geminiCard.trailingAnchor, constant: -18),
            keyField.topAnchor.constraint(equalTo: geminiTitle.bottomAnchor, constant: 14),
            geminiRows.leadingAnchor.constraint(equalTo: geminiTitle.leadingAnchor),
            geminiRows.trailingAnchor.constraint(equalTo: geminiCard.trailingAnchor, constant: -18),
            geminiRows.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 16),
            geminiRows.bottomAnchor.constraint(lessThanOrEqualTo: geminiCard.bottomAnchor, constant: -18)
        ])

        bottomRow.addArrangedSubview(geminiCard)
        bottomRow.addArrangedSubview(settingsCard(
            title: "Privacy and insertion",
            rows: [
                ("Hub behavior", "fn never opens the Hub by itself."),
                ("Target field", "Selected input receives text; otherwise history saves silently."),
                ("Fallback", store.pipelineSettings.copyFallbackEnabled ? "Clipboard fallback restores previous pasteboard data." : "Clipboard fallback is off.")
            ],
            height: 292
        ))

        grid.addArrangedSubview(topRow)
        grid.addArrangedSubview(bottomRow)
        return grid
    }

    private func settingsCard(title: String, rows: [(String, String)], height: CGFloat = 242) -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.70), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.32), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 372).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        rows.forEach { stack.addArrangedSubview(settingsDetailRow($0.0, $0.1)) }

        [titleLabel, stack].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18)
        ])

        return card
    }

    private func compactStatus(_ message: String) -> String {
        if message.contains("429") {
            return "HTTP 429: quota exceeded"
        }
        let clean = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"AIza[0-9A-Za-z_\-]+"#, with: "[redacted-key]", options: .regularExpression)
        guard clean.count > 82 else { return clean }
        return "\(clean.prefix(82))..."
    }

    private func syncRecorderCard() -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.86), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.35), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 760).isActive = true
        card.heightAnchor.constraint(equalToConstant: 226).isActive = true

        let promptHeader = NSTextField(labelWithString: "CURRENT PHRASE")
        promptHeader.font = .systemFont(ofSize: 11, weight: .bold)
        promptHeader.textColor = PadKeyTheme.secondaryInk

        let prompt = NSTextField(wrappingLabelWithString: currentSyncPrompt)
        prompt.font = .systemFont(ofSize: 20, weight: .bold)
        prompt.textColor = PadKeyTheme.ink
        prompt.maximumNumberOfLines = 2

        let meter = SyncMeterView()
        meter.update(level: syncIsRecording ? 0.18 : 0)
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalToConstant: 148).isActive = true
        meter.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let status = NSTextField(labelWithString: syncIsRecording ? "Listening..." : "Ready for a voice sample")
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = PadKeyTheme.secondaryInk

        let transcript = NSTextField(wrappingLabelWithString: syncLiveTranscript.isEmpty ? "Saved samples become phrasing context for Whisper prompts and AI polish." : syncLiveTranscript)
        transcript.font = .systemFont(ofSize: 13)
        transcript.textColor = syncLiveTranscript.isEmpty ? PadKeyTheme.secondaryInk : PadKeyTheme.ink
        transcript.maximumNumberOfLines = 3

        let record = primaryButton(syncIsRecording ? "Stop" : "Record", action: #selector(toggleSyncRecording))
        let next = HoverButton()
        next.title = "Next phrase"
        next.target = self
        next.action = #selector(nextSyncPhrase)
        next.normalColor = NSColor.white.withAlphaComponent(0.42)
        next.hoverColor = NSColor.white.withAlphaComponent(0.72)
        next.contentTintColor = PadKeyTheme.ink
        next.translatesAutoresizingMaskIntoConstraints = false
        next.widthAnchor.constraint(equalToConstant: 112).isActive = true
        next.heightAnchor.constraint(equalToConstant: 32).isActive = true
        next.isEnabled = !syncIsRecording

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 10
        actionRow.alignment = .centerY
        actionRow.addArrangedSubview(record)
        actionRow.addArrangedSubview(next)

        [promptHeader, prompt, meter, status, transcript, actionRow].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            promptHeader.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            promptHeader.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            prompt.leadingAnchor.constraint(equalTo: promptHeader.leadingAnchor),
            prompt.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -24),
            prompt.topAnchor.constraint(equalTo: promptHeader.bottomAnchor, constant: 10),
            meter.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -26),
            meter.topAnchor.constraint(equalTo: card.topAnchor, constant: 32),
            status.leadingAnchor.constraint(equalTo: promptHeader.leadingAnchor),
            status.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 18),
            transcript.leadingAnchor.constraint(equalTo: promptHeader.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -26),
            transcript.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            actionRow.leadingAnchor.constraint(equalTo: promptHeader.leadingAnchor),
            actionRow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20)
        ])

        syncStatusLabel = status
        syncTranscriptLabel = transcript
        syncRecordButton = record
        syncMeterView = meter
        return card
    }

    private func syncSamplesList() -> NSView {
        let samples = store.voiceSyncSamples
        guard !samples.isEmpty else {
            return emptyState("No voice samples yet", detail: "Record a few natural phrases to build personal phrasing context.")
        }

        let list = NSStackView()
        list.orientation = .vertical
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: 760).isActive = true

        for sample in samples.prefix(5) {
            let duration = sample.duration > 0 ? "\(Int(sample.duration.rounded()))s" : "sample"
            let left = "\(Self.relativeDate(sample.createdAt))  \(duration)"
            list.addArrangedSubview(row(left: left, right: sample.transcript))
        }

        return list
    }

    private func settingsDetailRow(_ label: String, _ value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10

        let labelView = NSTextField(labelWithString: label)
        labelView.font = .systemFont(ofSize: 12, weight: .semibold)
        labelView.textColor = PadKeyTheme.secondaryInk
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 108).isActive = true

        let valueView = NSTextField(wrappingLabelWithString: value)
        valueView.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueView.textColor = PadKeyTheme.ink
        valueView.maximumNumberOfLines = 3
        valueView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(valueView)
        return row
    }

    private func scratchpadWorkspace() -> NSView {
        let workspace = NSStackView()
        workspace.orientation = .horizontal
        workspace.alignment = .top
        workspace.spacing = 16
        workspace.translatesAutoresizingMaskIntoConstraints = false
        workspace.widthAnchor.constraint(equalToConstant: 760).isActive = true
        workspace.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let notesPanel = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.78), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.35), strokeWidth: 1)
        notesPanel.translatesAutoresizingMaskIntoConstraints = false
        notesPanel.widthAnchor.constraint(equalToConstant: 236).isActive = true
        notesPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let noteList = FlippedStackView()
        noteList.orientation = .vertical
        noteList.alignment = .leading
        noteList.spacing = 6
        noteList.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 14, right: 14)
        notesPanel.addSubview(noteList)
        noteList.fillSuperview()
        refreshScratchpadList(noteList)

        let editorPanel = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.42), strokeWidth: 1)
        editorPanel.translatesAutoresizingMaskIntoConstraints = false
        editorPanel.widthAnchor.constraint(equalToConstant: 508).isActive = true
        editorPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 12

        let titleField = NSTextField()
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.textColor = PadKeyTheme.ink
        titleField.delegate = self
        titleField.focusRingType = .none
        titleField.placeholderString = "Untitled note"
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let saveLabel = NSTextField(labelWithString: "Saved")
        saveLabel.font = .systemFont(ofSize: 11, weight: .medium)
        saveLabel.textColor = PadKeyTheme.secondaryInk
        saveLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        toolbar.addArrangedSubview(titleField)
        toolbar.addArrangedSubview(saveLabel)

        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder

        let textView = NSTextView()
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = PadKeyTheme.ink
        textView.backgroundColor = .clear
        textView.insertionPointColor = PadKeyTheme.amber
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 468, height: CGFloat.greatestFiniteMagnitude)
        textScroll.documentView = textView

        editorPanel.addSubview(toolbar)
        editorPanel.addSubview(textScroll)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: editorPanel.leadingAnchor, constant: 20),
            toolbar.trailingAnchor.constraint(equalTo: editorPanel.trailingAnchor, constant: -20),
            toolbar.topAnchor.constraint(equalTo: editorPanel.topAnchor, constant: 18),
            textScroll.leadingAnchor.constraint(equalTo: editorPanel.leadingAnchor, constant: 20),
            textScroll.trailingAnchor.constraint(equalTo: editorPanel.trailingAnchor, constant: -20),
            textScroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            textScroll.bottomAnchor.constraint(equalTo: editorPanel.bottomAnchor, constant: -18)
        ])

        scratchTitleField = titleField
        scratchTextView = textView
        scratchSaveLabel = saveLabel
        loadActiveScratchNote()

        workspace.addArrangedSubview(notesPanel)
        workspace.addArrangedSubview(editorPanel)
        return workspace
    }

    private func refreshScratchpadList(_ noteList: NSStackView) {
        let heading = NSTextField(labelWithString: "RECENTS")
        heading.font = .systemFont(ofSize: 11, weight: .bold)
        heading.textColor = PadKeyTheme.secondaryInk
        noteList.addArrangedSubview(heading)

        for note in store.snapshot.notes {
            let button = HoverButton()
            button.title = note.title
            button.alignment = .left
            button.font = .systemFont(ofSize: 13, weight: activeScratchNoteID == note.id ? .semibold : .regular)
            button.normalColor = activeScratchNoteID == note.id ? NSColor.white.withAlphaComponent(0.60) : .clear
            button.hoverColor = NSColor.white.withAlphaComponent(0.42)
            button.contentTintColor = PadKeyTheme.ink
            button.target = self
            button.action = #selector(selectScratchpadNote(_:))
            button.identifier = NSUserInterfaceItemIdentifier(note.id.uuidString)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 192).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            noteList.addArrangedSubview(button)
        }
    }

    private func ensureScratchSelection(createIfNeeded: Bool) {
        if
            let activeScratchNoteID,
            store.snapshot.notes.contains(where: { $0.id == activeScratchNoteID })
        {
            return
        }

        if let first = store.snapshot.notes.first {
            activeScratchNoteID = first.id
        } else if createIfNeeded {
            activeScratchNoteID = store.createNote().id
        } else {
            activeScratchNoteID = nil
        }
    }

    private func loadActiveScratchNote() {
        guard
            let activeScratchNoteID,
            let note = store.snapshot.notes.first(where: { $0.id == activeScratchNoteID })
        else {
            return
        }

        isLoadingScratchNote = true
        scratchTitleField?.stringValue = note.title
        scratchTextView?.string = note.body
        scratchSaveLabel?.stringValue = "Saved"
        isLoadingScratchNote = false
    }

    private func scheduleScratchpadSave() {
        guard !isLoadingScratchNote else { return }
        scratchSaveLabel?.stringValue = "Saving..."
        scratchSaveWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.persistScratchpadNote()
            }
        }
        scratchSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: item)
    }

    private func persistScratchpadNote() {
        guard let activeScratchNoteID else { return }
        scratchSaveWorkItem?.cancel()

        let title = scratchTitleField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = scratchTextView?.string ?? ""
        store.updateNote(id: activeScratchNoteID, title: title.isEmpty ? "Untitled" : title, body: body)
        scratchSaveLabel?.stringValue = "Saved"
    }

    private func focusScratchpadIfNeeded() {
        guard page == .scratchpad else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let scratchTextView = self.scratchTextView else { return }
            self.window?.makeFirstResponder(scratchTextView)
        }
    }

    private func emptyState(_ title: String, detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 760).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        return stack
    }

    private func scratchpadEmptyState() -> NSView {
        let card = RoundedView(fillColor: PadKeyTheme.softSurface.withAlphaComponent(0.70), radius: 12, strokeColor: NSColor.separatorColor.withAlphaComponent(0.32), strokeWidth: 1)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 760).isActive = true
        card.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let titleLabel = NSTextField(labelWithString: "No notes found")
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let detailLabel = NSTextField(wrappingLabelWithString: "Start a note here, or let PadKey save dictation here when no input field is selected. Scratchpad keeps rough ideas, fallback captures, and polished drafts together.")
        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 3

        let button = primaryButton("New note", action: #selector(addScratchpadNote))

        let lanes = NSStackView()
        lanes.orientation = .horizontal
        lanes.spacing = 12
        lanes.addArrangedSubview(scratchpadLane(title: "Inbox", detail: "Catch text when no target field is ready."))
        lanes.addArrangedSubview(scratchpadLane(title: "Draft", detail: "Shape notes into messages without switching apps."))
        lanes.addArrangedSubview(scratchpadLane(title: "Polish", detail: "Keep rewrites beside the original thought."))

        [titleLabel, detailLabel, lanes, button].forEach {
            card.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            lanes.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            lanes.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            lanes.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 22),
            button.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            button.topAnchor.constraint(equalTo: lanes.bottomAnchor, constant: 24),
            button.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -24)
        ])

        return card
    }

    private func scratchpadLane(title: String, detail: String) -> NSView {
        let lane = RoundedView(fillColor: PadKeyTheme.panelBackground, radius: 10, strokeColor: NSColor.separatorColor.withAlphaComponent(0.28), strokeWidth: 1)
        lane.translatesAutoresizingMaskIntoConstraints = false
        lane.widthAnchor.constraint(equalToConstant: 230).isActive = true
        lane.heightAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = PadKeyTheme.ink

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailLabel.textColor = PadKeyTheme.secondaryInk
        detailLabel.maximumNumberOfLines = 3

        [titleLabel, detailLabel].forEach {
            lane.addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: lane.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: lane.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: lane.topAnchor, constant: 16),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: lane.bottomAnchor, constant: -16)
        ])

        return lane
    }

    private func primaryButton(_ title: String, action: Selector, inverted: Bool = false) -> HoverButton {
        let button = HoverButton()
        button.title = title
        button.target = self
        button.action = action
        button.normalColor = inverted ? PadKeyTheme.panelBackground : PadKeyTheme.ink
        button.hoverColor = inverted ? NSColor.white : PadKeyTheme.teal
        button.contentTintColor = inverted ? PadKeyTheme.ink : .white
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func compactActionButton(_ title: String, identifier: String, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.title = title
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.font = .systemFont(ofSize: 11, weight: .bold)
        button.normalColor = PadKeyTheme.softSurface
        button.hoverColor = PadKeyTheme.mint.withAlphaComponent(0.42)
        button.contentTintColor = PadKeyTheme.ink
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 54).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    @objc private func toggleSyncRecording() {
        syncIsRecording ? stopSyncRecording() : startSyncRecording()
    }

    private func startSyncRecording() {
        guard !syncIsRecording else { return }

        syncIsRecording = true
        syncStartedAt = Date()
        syncLiveTranscript = ""
        syncDictationController.recognitionEngine = store.pipelineSettings.effectiveRecognitionEngine
        syncDictationController.prefersLocalWhisper = store.pipelineSettings.effectiveRecognitionEngine != .appleSpeech
        syncDictationController.robustRetryEnabled = store.pipelineSettings.effectiveRobustRetryEnabled
        render()

        syncDictationController.start(
            onPartial: { [weak self] transcript in
                DispatchQueue.main.async {
                    guard let self, self.syncIsRecording else { return }
                    self.syncLiveTranscript = transcript
                    self.syncStatusLabel?.stringValue = transcript.localizedCaseInsensitiveContains("Transcribing")
                        ? "Transcribing..."
                        : "Listening..."
                    self.syncTranscriptLabel?.textColor = PadKeyTheme.ink
                    self.syncTranscriptLabel?.stringValue = transcript.isEmpty ? "Listening..." : transcript
                }
            },
            onMeter: { [weak self] frame in
                DispatchQueue.main.async {
                    self?.syncMeterView?.update(level: frame.level)
                }
            },
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    self?.finishSyncRecording(transcript: result.transcript)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.failSyncRecording(error)
                }
            }
        )
    }

    private func stopSyncRecording() {
        guard syncIsRecording else { return }
        syncStatusLabel?.stringValue = "Finishing..."
        syncRecordButton?.title = "Stop"
        syncDictationController.stop()
    }

    private func finishSyncRecording(transcript: String) {
        let cleaned = store.applyPersonalRules(to: TextCleanup.clean(transcript))
        let duration = Date().timeIntervalSince(syncStartedAt ?? Date())
        syncIsRecording = false
        syncStartedAt = nil
        syncMeterView?.update(level: 0)

        if !cleaned.isEmpty {
            store.addVoiceSyncSample(prompt: currentSyncPrompt, transcript: cleaned, duration: duration)
            syncPromptIndex = min(syncPromptIndex + 1, Self.syncPrompts.count - 1)
        } else {
            NSSound.beep()
        }

        syncLiveTranscript = ""
        render()
    }

    private func failSyncRecording(_ error: Error) {
        syncIsRecording = false
        syncStartedAt = nil
        syncLiveTranscript = ""
        syncMeterView?.update(level: 0)
        render()
        NSSound.beep()
    }

    private func cancelSyncRecording() {
        guard syncIsRecording else { return }
        syncDictationController.cancel()
        syncIsRecording = false
        syncStartedAt = nil
        syncLiveTranscript = ""
        syncMeterView?.update(level: 0)
    }

    @objc private func toggleLiveCaptions() {
        liveCaptionIsRecording ? stopLiveCaptionRecording() : startLiveCaptionRecording()
    }

    private func startLiveCaptionRecording() {
        guard !liveCaptionIsRecording else { return }

        liveCaptionIsRecording = true
        liveCaptionStartedAt = Date()
        liveCaptionRawTranscript = ""
        liveCaptionCleanTranscript = ""
        liveCaptionBatches = []
        liveCaptionStatus = "Listening..."
        liveCaptionPlaybackStatus = "Playback ready"
        liveCaptionController.recognitionEngine = store.pipelineSettings.effectiveRecognitionEngine
        liveCaptionController.prefersLocalWhisper = store.pipelineSettings.effectiveRecognitionEngine != .appleSpeech
        liveCaptionController.robustRetryEnabled = store.pipelineSettings.effectiveRobustRetryEnabled
        liveCaptionController.inputSource = store.selectedInputSource
        render()

        liveCaptionController.start(
            onPartial: { [weak self] transcript in
                DispatchQueue.main.async {
                    self?.updateLiveCaptionPartial(transcript)
                }
            },
            onMeter: { [weak self] frame in
                DispatchQueue.main.async {
                    self?.liveCaptionMeterView?.update(level: frame.level)
                }
            },
            onComplete: { [weak self] result in
                DispatchQueue.main.async {
                    self?.finishLiveCaptionRecording(result)
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.failLiveCaptionRecording(error)
                }
            }
        )
    }

    private func updateLiveCaptionPartial(_ transcript: String) {
        guard liveCaptionIsRecording else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isDictationStatusMessage(trimmed) {
            liveCaptionStatus = trimmed
            liveCaptionStatusLabel?.stringValue = trimmed
            return
        }

        liveCaptionRawTranscript = trimmed
        let cleaned = LiveCaptionFormatter.clean(trimmed, store: store)
        liveCaptionCleanTranscript = cleaned
        liveCaptionBatches = LiveCaptionFormatter.batches(from: cleaned)
        liveCaptionStatus = cleaned.isEmpty ? "Listening..." : "Captioning..."
        liveCaptionAudienceLabel?.stringValue = liveCaptionDisplayText
        liveCaptionAudienceLabel?.font = liveCaptionFont(for: liveCaptionDisplayText)
        liveCaptionStatusLabel?.stringValue = liveCaptionStatus
        scheduleLiveCaptionRender()
    }

    private func stopLiveCaptionRecording() {
        guard liveCaptionIsRecording else { return }
        liveCaptionStatus = "Finishing..."
        liveCaptionStatusLabel?.stringValue = liveCaptionStatus
        liveCaptionController.stop()
    }

    private func finishLiveCaptionRecording(_ result: DictationResult) {
        let raw = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? liveCaptionRawTranscript
            : result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = LiveCaptionFormatter.clean(raw, store: store)
        let duration = Date().timeIntervalSince(liveCaptionStartedAt ?? Date())

        liveCaptionIsRecording = false
        liveCaptionStartedAt = nil
        liveCaptionRawTranscript = raw
        liveCaptionCleanTranscript = cleaned
        liveCaptionBatches = LiveCaptionFormatter.batches(from: cleaned)
        liveCaptionStatus = cleaned.isEmpty ? "No caption text captured" : "Caption session ready"
        liveCaptionMeterView?.update(level: 0)

        if !cleaned.isEmpty {
            store.addHistory(
                text: cleaned,
                rawText: raw,
                appName: "Live Captions",
                duration: duration,
                recognitionEngine: result.engine.displayName,
                usedRobustRetry: result.usedRobustRetry,
                polishUsed: false,
                polishProvider: nil,
                latency: PipelineLatency(recordingDuration: duration, asrDuration: result.asrDuration, polishDuration: nil, insertionDuration: nil, totalDuration: duration),
                inputSource: result.inputSource ?? store.selectedInputSource,
                processedTranscript: cleaned,
                confidenceStatus: result.fallbackReason,
                audioURL: result.audioURL
            )
        } else {
            NSSound.beep()
        }

        render()
    }

    private func failLiveCaptionRecording(_ error: Error) {
        liveCaptionIsRecording = false
        liveCaptionStartedAt = nil
        liveCaptionStatus = error.localizedDescription
        liveCaptionMeterView?.update(level: 0)
        render()
        NSSound.beep()
    }

    private func cancelLiveCaptionRecording() {
        guard liveCaptionIsRecording else { return }
        liveCaptionController.cancel()
        liveCaptionIsRecording = false
        liveCaptionStartedAt = nil
        liveCaptionStatus = "Captioning stopped"
        liveCaptionMeterView?.update(level: 0)
    }

    private func scheduleLiveCaptionRender() {
        guard page == .liveCaptions, !liveCaptionRenderScheduled else { return }
        liveCaptionRenderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            self.liveCaptionRenderScheduled = false
            guard self.page == .liveCaptions else { return }
            self.render()
        }
    }

    @objc private func playLiveCaptions() {
        liveCaptionPlaybackStatus = captionPlayback.speak(liveCaptionCleanTranscript)
        render()
    }

    @objc private func stopLiveCaptionPlayback() {
        captionPlayback.stop()
        liveCaptionPlaybackStatus = "Playback stopped"
        render()
    }

    @objc private func clearLiveCaptions() {
        captionPlayback.stop()
        if liveCaptionIsRecording {
            liveCaptionController.cancel()
        }
        liveCaptionIsRecording = false
        liveCaptionStartedAt = nil
        liveCaptionRawTranscript = ""
        liveCaptionCleanTranscript = ""
        liveCaptionBatches = []
        liveCaptionStatus = "Ready for captions"
        liveCaptionPlaybackStatus = "Playback ready"
        render()
    }

    @objc private func saveLiveCaptionsAsVoiceSample() {
        let cleaned = liveCaptionCleanTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            NSSound.beep()
            liveCaptionPlaybackStatus = "No caption text to save yet."
            render()
            return
        }

        store.addVoiceSyncSample(prompt: "Live caption playback voice sample", transcript: cleaned, duration: Date().timeIntervalSince(liveCaptionStartedAt ?? Date()))
        liveCaptionPlaybackStatus = "Saved this caption as a local voice profile sample."
        render()
    }

    @objc private func openVoiceSetupFromLiveCaptions() {
        if liveCaptionIsRecording {
            cancelLiveCaptionRecording()
        }
        page = .sync
        buildSidebar()
        render()
    }

    private static func isDictationStatusMessage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("listening")
            || lower.hasPrefix("recording")
            || lower.hasPrefix("transcribing")
            || lower.contains("whisper final transcription is still recording")
            || lower.contains("sherpa live")
    }

    @objc private func nextSyncPhrase() {
        guard !syncIsRecording else { return }
        syncPromptIndex = (syncPromptIndex + 1) % Self.syncPrompts.count
        render()
    }

    @objc private func toggleAutoPolish() {
        store.updatePipelineSettings { $0.autoPolishAfterDictation.toggle() }
        render()
    }

    @objc private func toggleCommandMode() {
        store.updatePipelineSettings { $0.commandModeEnabled.toggle() }
        render()
    }

    @objc private func toggleCopyFallback() {
        store.updatePipelineSettings { $0.copyFallbackEnabled.toggle() }
        render()
    }

    @objc private func toggleRobustRetry() {
        store.updatePipelineSettings { $0.robustRetryEnabled = !$0.effectiveRobustRetryEnabled }
        render()
    }

    @objc private func setSessionTimeout(_ sender: NSButton) {
        guard
            let raw = sender.identifier?.rawValue.replacingOccurrences(of: "timeout-", with: ""),
            let timeout = Int(raw)
        else {
            return
        }

        store.updatePipelineSettings { $0.sessionTimeoutSeconds = timeout }
        render()
    }

    @objc private func setRecognitionEngine(_ sender: NSButton) {
        guard
            let raw = sender.identifier?.rawValue.replacingOccurrences(of: "engine-", with: ""),
            let engine = RecognitionEngine(rawValue: raw)
        else {
            return
        }

        store.updatePipelineSettings { $0.recognitionEngine = engine }
        render()
    }

    @objc private func openScratchpad() {
        showScratchpad()
    }

    @objc private func runAgentCommand() {
        let transcript = agentCommandField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        executeAgentCommand(transcript)
    }

    @objc private func runAgentTest(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "make-note":
            executeAgentCommand("Make a note PadKey test successful")
        case "open-facetime":
            executeAgentCommand("Open FaceTime")
        case "fill-search":
            executeAgentCommand("Fill the search field with assistive speech devices")
        case "click-current":
            executeAgentCommand("Click the current field")
        case "computer-runtime":
            executeAgentCommand("Find the second option in whatever app is open and choose it")
        case "accessibility-tree":
            commandCoordinator.inspectAccessibility(application: AppDelegate.shared?.preferredMacCommandApplication()) { _ in }
        case "local-chat":
            executeAgentCommand("Tell me about why punctuation cleanup matters for voice control")
        case "diagram-note":
            executeAgentCommand("Make a diagram of PadKey voice control")
        default:
            break
        }
    }

    @objc private func confirmAgentAction() {
        guard let id = commandCoordinator.snapshot.confirmationId else { return }
        commandCoordinator.confirm(id: id) { _ in }
    }

    @objc private func requestAgentAccessibility() {
        PermissionHelper.promptAccessibilityIfNeeded()
        PermissionHelper.openPrivacySettings()
        commandCoordinator.refreshPermissionState()
    }

    @objc private func agentControlDidUpdate() {
        guard page == .agent else { return }
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    @objc private func hardwareStreamDidUpdate(_ notification: Notification) {
        guard let status = notification.userInfo?["status"] as? PadKeyHardwareStreamStatus else { return }
        hardwareStatus = status
        guard page == .signalMonitor else { return }
        let elapsed = Date().timeIntervalSince(lastSignalMonitorRenderAt)
        guard elapsed >= 0.25 else {
            guard !signalMonitorRenderScheduled else { return }
            signalMonitorRenderScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.25 - elapsed)) { [weak self] in
                guard let self, self.page == .signalMonitor else { return }
                self.signalMonitorRenderScheduled = false
                self.lastSignalMonitorRenderAt = Date()
                self.render()
            }
            return
        }
        lastSignalMonitorRenderAt = Date()
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    @objc private func inputSourceDidChange() {
        guard page == .signalMonitor || page == .agent || page == .pipeline || page == .liveCaptions else { return }
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    private func executeAgentCommand(_ transcript: String) {
        let request = MacCommandRequest(
            transcript: transcript,
            source: store.selectedInputSource.commandSource,
            batteryPercent: PadKeyHardwareAudioService.shared.status.batteryPercent,
            mode: "mac_control"
        )
        commandCoordinator.execute(
            request: request,
            preferredApplication: AppDelegate.shared?.preferredMacCommandApplication()
        ) { _ in }
    }

    @objc private func selectInputSource(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.replacingOccurrences(of: "input-", with: "") else { return }
        let source: PadKeyInputSource
        switch raw {
        case "padkey_ble_inmp441":
            source = .padKeyBLE(channel: .inmp441)
        case "padkey_ble_max4466":
            source = .padKeyBLE(channel: .max4466)
        case "padkey_ble_piezo":
            source = .padKeyBLE(channel: .piezo)
        case "padkey_usb_inmp441":
            source = .padKeyUSB(channel: .inmp441)
        case "system_microphone":
            source = .systemAudio(deviceID: nil)
        default:
            return
        }
        store.setSelectedInputSource(source)
        render()
    }

    @objc private func addScratchpadNote() {
        persistScratchpadNote()
        activeScratchNoteID = store.createNote(title: "Untitled", body: "").id
        render()
        focusScratchpadIfNeeded()
    }

    @objc private func copyHistoryRecord(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let record = store.snapshot.history.first(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.text, forType: .string)
    }

    @objc private func readHistoryRecord(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let record = store.snapshot.history.first(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }
        speechSynthesizer.startSpeaking(record.text)
    }

    @objc private func playHistoryAudio(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let record = store.snapshot.history.first(where: { $0.id == id }),
            let path = record.audioPath
        else {
            NSSound.beep()
            return
        }
        capturePlaybackSound = NSSound(contentsOfFile: path, byReference: true)
        if capturePlaybackSound?.play() != true { NSSound.beep() }
    }

    @objc private func runHistoryAsCommand(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let record = store.snapshot.history.first(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }
        executeAgentCommand(record.text)
    }

    @objc private func editHistoryRecord(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID),
            let record = store.snapshot.history.first(where: { $0.id == id })
        else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Edit transcript"
        alert.informativeText = "Update this log without changing where it was originally inserted."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true

        let textView = NSTextView(frame: scroll.bounds)
        textView.font = .systemFont(ofSize: 14)
        textView.string = record.text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = textView

        guard let window = self.window else {
            NSSound.beep()
            return
        }

        alert.beginSheetModal(for: window) { [weak self, textView] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.updateHistoryRecord(id: id, text: textView.string)
            self?.render()
        }
    }

    @objc private func selectScratchpadNote(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let id = UUID(uuidString: rawID)
        else {
            return
        }

        persistScratchpadNote()
        activeScratchNoteID = id
        render()
        focusScratchpadIfNeeded()
    }

    @objc private func openSettings() {
        page = .settings
        buildSidebar()
        render()
    }

    @objc private func addDictionaryWord() {
        let alert = NSAlert()
        alert.messageText = "Add dictionary word"
        alert.informativeText = "Add a name, product, domain, or phrase PadKey should keep spelled correctly."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let phraseField = NSTextField()
        phraseField.placeholderString = "Phrase"
        let replacementField = NSTextField()
        replacementField.placeholderString = "Optional replacement"

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 420, height: 72))
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(phraseField)
        stack.addArrangedSubview(replacementField)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = phraseField

        guard let window = self.window else {
            NSSound.beep()
            return
        }

        alert.beginSheetModal(for: window) { [weak self, phraseField, replacementField] response in
            guard response == .alertFirstButtonReturn else { return }
            let phrase = phraseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else {
                NSSound.beep()
                return
            }
            let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.store.addDictionaryEntry(phrase, replacement: replacement.isEmpty ? nil : replacement)
            self?.render()
        }
    }

    @objc private func addSnippet() {
        let alert = NSAlert()
        alert.messageText = "Add snippet"
        alert.informativeText = "Create a spoken cue and the full text PadKey should expand it into."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let triggerField = NSTextField()
        triggerField.placeholderString = "Spoken cue"

        let expansionScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 112))
        expansionScroll.borderType = .bezelBorder
        expansionScroll.hasVerticalScroller = true

        let expansionView = NSTextView(frame: expansionScroll.bounds)
        expansionView.font = .systemFont(ofSize: 14)
        expansionView.isRichText = false
        expansionView.allowsUndo = true
        expansionView.textContainerInset = NSSize(width: 8, height: 8)
        expansionView.string = ""
        expansionScroll.documentView = expansionView

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(triggerField)
        stack.addArrangedSubview(expansionScroll)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = triggerField

        guard let window = self.window else {
            NSSound.beep()
            return
        }

        alert.beginSheetModal(for: window) { [weak self, triggerField, expansionView] response in
            guard response == .alertFirstButtonReturn else { return }
            let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let expansion = expansionView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trigger.isEmpty, !expansion.isEmpty else {
                NSSound.beep()
                return
            }
            self?.store.addSnippet(trigger: trigger, expansion: expansion)
            self?.render()
        }
    }

    @objc private func addTransform() {
        let alert = NSAlert()
        alert.messageText = "Create transform"
        alert.informativeText = "Add a reusable rewrite instruction for polished dictation or selected text."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField()
        nameField.placeholderString = "Name"

        let promptScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 128))
        promptScroll.borderType = .bezelBorder
        promptScroll.hasVerticalScroller = true

        let promptView = NSTextView(frame: promptScroll.bounds)
        promptView.font = .systemFont(ofSize: 14)
        promptView.isRichText = false
        promptView.allowsUndo = true
        promptView.textContainerInset = NSSize(width: 8, height: 8)
        promptView.string = ""
        promptScroll.documentView = promptView

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 460, height: 166))
        stack.orientation = .vertical
        stack.spacing = 8
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(promptScroll)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        guard let window = self.window else {
            NSSound.beep()
            return
        }

        alert.beginSheetModal(for: window) { [weak self, nameField, promptView] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !prompt.isEmpty else {
                NSSound.beep()
                return
            }
            self?.store.addTransform(name: name, prompt: prompt)
            self?.render()
        }
    }

    @objc private func saveGeminiKey(_ sender: NSTextField) {
        guard !sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            render()
            return
        }
        store.setGeminiAPIKey(sender.stringValue)
        render()
    }

    func textDidChange(_ notification: Notification) {
        guard let object = notification.object as? NSTextView, object === scratchTextView else { return }
        scheduleScratchpadSave()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let object = obj.object as? NSTextField, object === scratchTitleField else { return }
        scheduleScratchpadSave()
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

final class WavePatternView: NSView {
    let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        color = .white
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.setStroke()
        for index in 0..<9 {
            let path = NSBezierPath()
            path.lineWidth = 2
            let y = bounds.height * (0.24 + CGFloat(index) * 0.075)
            path.move(to: NSPoint(x: bounds.width * 0.55, y: y))
            path.curve(
                to: NSPoint(x: bounds.width + 40, y: y + CGFloat(index % 3) * 8),
                controlPoint1: NSPoint(x: bounds.width * 0.68, y: y + 36),
                controlPoint2: NSPoint(x: bounds.width * 0.82, y: y - 30)
            )
            path.stroke()
        }
    }
}

final class SyncMeterView: NSView {
    private var level: CGFloat = 0

    func update(level: Double) {
        self.level = CGFloat(min(1, max(0, level)))
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let barCount = 16
        let gap: CGFloat = 3
        let barWidth = max(2, (bounds.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount))
        let centerY = bounds.midY

        for index in 0..<barCount {
            let progress = CGFloat(index) / CGFloat(max(1, barCount - 1))
            let localShape = 0.52 + 0.48 * sin(progress * CGFloat.pi)
            let animated = max(0.08, level * localShape)
            let height = 5 + animated * (bounds.height - 8)
            let rect = NSRect(
                x: CGFloat(index) * (barWidth + gap),
                y: centerY - height / 2,
                width: barWidth,
                height: height
            )
            let color = level > 0.04 ? PadKeyTheme.teal : PadKeyTheme.secondaryInk
            color.withAlphaComponent(0.24 + animated * 0.64).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

final class DailyWordsChartView: NSView {
    private let points: [(Date, Int)]
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    init(points: [(Date, Int)]) {
        self.points = points
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        points = []
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let chartRect = bounds.insetBy(dx: 4, dy: 22)
        let maxWords = max(1, points.map(\.1).max() ?? 1)
        let barGap: CGFloat = 5
        let barWidth = max(6, (chartRect.width - CGFloat(points.count - 1) * barGap) / CGFloat(max(1, points.count)))

        NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
        for step in 0...3 {
            let y = chartRect.minY + chartRect.height * CGFloat(step) / 3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chartRect.minX, y: y))
            path.line(to: NSPoint(x: chartRect.maxX, y: y))
            path.lineWidth = 1
            path.stroke()
        }

        let line = NSBezierPath()
        line.lineWidth = 2.2

        for (index, item) in points.enumerated() {
            let heightRatio = CGFloat(item.1) / CGFloat(maxWords)
            let x = chartRect.minX + CGFloat(index) * (barWidth + barGap)
            let height = max(4, chartRect.height * heightRatio)
            let bar = NSRect(x: x, y: chartRect.minY, width: barWidth, height: height)
            PadKeyTheme.mint.withAlphaComponent(0.34 + min(0.46, heightRatio * 0.46)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()

            let point = NSPoint(x: x + barWidth / 2, y: chartRect.minY + height)
            index == 0 ? line.move(to: point) : line.line(to: point)

            if index == 0 || index == points.count - 1 {
                let label = formatter.string(from: item.0) as NSString
                label.draw(
                    at: NSPoint(x: x - 2, y: bounds.minY + 2),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                        .foregroundColor: PadKeyTheme.secondaryInk
                    ]
                )
            }
        }

        PadKeyTheme.teal.setStroke()
        line.stroke()
    }
}

final class AppUsageChartView: NSView {
    private let items: [(name: String, words: Int)]

    init(items: [(name: String, words: Int)]) {
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        items = []
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let visible = Array(items.prefix(5))
        let fallback = visible.isEmpty ? [("No app yet", 1)] : visible
        let maxWords = max(1, fallback.map(\.words).max() ?? 1)
        let rowHeight = bounds.height / CGFloat(fallback.count)

        for (index, item) in fallback.enumerated() {
            let y = bounds.maxY - CGFloat(index + 1) * rowHeight + 8
            let label = "\(item.name)" as NSString
            label.draw(
                at: NSPoint(x: 0, y: y + 16),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: PadKeyTheme.secondaryInk
                ]
            )

            let ratio = CGFloat(item.words) / CGFloat(maxWords)
            let bar = NSRect(x: 120, y: y + 14, width: max(12, (bounds.width - 146) * ratio), height: 14)
            PadKeyTheme.teal.withAlphaComponent(visible.isEmpty ? 0.18 : 0.78).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()

            let words = visible.isEmpty ? "waiting" : "\(item.words)"
            (words as NSString).draw(
                at: NSPoint(x: bar.maxX + 8, y: y + 13),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: PadKeyTheme.ink
                ]
            )
        }
    }
}

final class StreakGridView: NSView {
    private let activeDays: Set<Date>
    private let calendar = Calendar.current

    init(activeDays: Set<Date>) {
        self.activeDays = activeDays
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        activeDays = []
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let columns = 8
        let rows = 7
        let gap: CGFloat = 5
        let cell = min((bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns), (bounds.height - CGFloat(rows - 1) * gap) / CGFloat(rows))
        let today = calendar.startOfDay(for: Date())

        for column in 0..<columns {
            for row in 0..<rows {
                let dayOffset = -((columns - 1 - column) * rows + (rows - 1 - row))
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }
                let rect = NSRect(
                    x: CGFloat(column) * (cell + gap),
                    y: CGFloat(row) * (cell + gap),
                    width: cell,
                    height: cell
                )
                let active = activeDays.contains(calendar.startOfDay(for: date))
                let fill = active ? PadKeyTheme.teal.withAlphaComponent(0.82) : PadKeyTheme.softSurface.withAlphaComponent(0.86)
                fill.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}
