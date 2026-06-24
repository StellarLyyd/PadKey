import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = PadKeyStore.shared
    private let dictationController = DictationController()
    private let hotKeyManager = HotKeyManager()
    private let injector = TextInjector()
    private let polishService = PolishService()
    private let commandCoordinator = MacCommandCoordinator.shared
    private let commandServer = LocalCommandServer()
    private lazy var floatingBar = FloatingBarController()
    private lazy var hubController = HubWindowController(store: store)

    private var targetApplication: NSRunningApplication?
    private var targetInsertionField: TextInsertionTarget?
    private var targetMouseLocation: CGPoint?
    private var lastExternalApplication: NSRunningApplication?
    private var lastTranscript = ""
    private var isRecording = false
    private var insertIntoActiveApp = true
    private var cleanupEnabled = true
    private var prefersLocalWhisper = true
    private var recordingStartedAt: Date?
    private var shouldPressEnterAfterInsert = false
    private var recordingTimeoutTimer: Timer?

    private struct DeliveryContext {
        let targetField: TextInsertionTarget?
        let targetApplication: NSRunningApplication?
        let targetMouseLocation: CGPoint?
        let recordingStartedAt: Date?
        let shouldPressEnterAfterInsert: Bool
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        configureMainMenu()
        configureStatusItem()
        configureFloatingBar()
        observeApplicationActivation()
        do {
            try commandServer.start()
        } catch {
            floatingBar.flash("Mac control unavailable", detail: error.localizedDescription)
        }
        hotKeyManager.register(
            onToggle: { [weak self] in DispatchQueue.main.async { self?.toggleRecording() } },
            onScratchpad: { [weak self] in DispatchQueue.main.async { self?.openScratchpad() } },
            onFnStart: { [weak self] in DispatchQueue.main.async { self?.startRecording() } },
            onFnStop: { [weak self] in DispatchQueue.main.async { self?.stopRecording() } },
            onDiagnostic: { [weak self] message in
                self?.floatingBar.flash("Shortcut needs attention", detail: message)
            }
        )
        let launchArgumentOpenedWindow = handleLaunchArguments()
        if !launchArgumentOpenedWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openHub()
            }
        }
    }

    private func handleLaunchArguments() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        var openedWindow = false
        if arguments.contains("--show-hub") {
            openedWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openHub()
            }
        }
        if arguments.contains("--show-settings") {
            openedWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openHub(page: "Settings")
            }
        }
        if arguments.contains("--show-scratchpad") {
            openedWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openScratchpad()
            }
        }
        if arguments.contains("--insertion-self-test") {
            openedWindow = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.runInsertionSelfTest()
            }
        }
        return openedWindow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        hotKeyManager.unregister()
        dictationController.cancel()
        commandServer.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openHub()
        return false
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "PadKey")

        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = appMenu

        let hubItem = NSMenuItem(title: "Open PadKey Hub", action: #selector(openHubFromMenu), keyEquivalent: "")
        hubItem.target = self
        appMenu.addItem(hubItem)

        let scratchpadItem = NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpadFromMenu), keyEquivalent: "")
        scratchpadItem.target = self
        appMenu.addItem(scratchpadItem)

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit PadKey", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = statusItemIcon(recording: false)
            button.imagePosition = .imageLeft
            button.title = " pad"
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    private func configureFloatingBar() {
        floatingBar.onToggleDictation = { [weak self] in self?.toggleRecording() }
        floatingBar.onOpenHub = { [weak self] in self?.openHub() }
        floatingBar.onPolish = { [weak self] in self?.polishSelectedOrLastText() }
        floatingBar.onOpenScratchpad = { [weak self] in self?.openScratchpad() }
        floatingBar.show()
        floatingBar.setStatus("Ready", detail: "fn or Option-Space")
    }

    private func observeApplicationActivation() {
        if let frontmost = NSWorkspace.shared.frontmostApplication, isExternalApplication(frontmost) {
            lastExternalApplication = frontmost
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func frontmostApplicationDidChange(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            isExternalApplication(app)
        else {
            return
        }

        lastExternalApplication = app
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let recordingTitle = isRecording ? "Stop Dictation" : "Start Dictation"
        let recordingItem = NSMenuItem(title: "\(recordingTitle)    Option-Space", action: #selector(toggleRecordingFromMenu), keyEquivalent: "")
        recordingItem.target = self
        menu.addItem(recordingItem)

        let hubItem = NSMenuItem(title: "Open PadKey Hub", action: #selector(openHubFromMenu), keyEquivalent: "")
        hubItem.target = self
        menu.addItem(hubItem)

        let pipelineItem = NSMenuItem(title: "Open Pipeline", action: #selector(openPipelineFromMenu), keyEquivalent: "")
        pipelineItem.target = self
        menu.addItem(pipelineItem)

        let scratchpadItem = NSMenuItem(title: "Open Scratchpad    Option-S", action: #selector(openScratchpadFromMenu), keyEquivalent: "")
        scratchpadItem.target = self
        menu.addItem(scratchpadItem)

        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastTranscript), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = !lastTranscript.isEmpty
        menu.addItem(copyItem)

        menu.addItem(.separator())

        let engineItem = NSMenuItem(title: "Use Local Recognition", action: #selector(toggleLocalWhisper), keyEquivalent: "")
        engineItem.target = self
        engineItem.state = store.pipelineSettings.effectiveRecognitionEngine == .appleSpeech ? .off : .on
        menu.addItem(engineItem)

        let liveStatusItem = NSMenuItem(title: dictationController.liveTranscriptionStatus, action: nil, keyEquivalent: "")
        liveStatusItem.isEnabled = false
        menu.addItem(liveStatusItem)

        let finalStatusItem = NSMenuItem(title: dictationController.localWhisperStatus, action: nil, keyEquivalent: "")
        finalStatusItem.isEnabled = false
        menu.addItem(finalStatusItem)

        let robustStatusItem = NSMenuItem(title: dictationController.megaASRStatus, action: nil, keyEquivalent: "")
        robustStatusItem.isEnabled = false
        menu.addItem(robustStatusItem)

        menu.addItem(.separator())

        let insertItem = NSMenuItem(title: "Insert Into Active App", action: #selector(toggleInsertMode), keyEquivalent: "")
        insertItem.target = self
        insertItem.state = insertIntoActiveApp ? .on : .off
        menu.addItem(insertItem)

        let cleanupItem = NSMenuItem(title: "Clean Filler Words", action: #selector(toggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = cleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)

        menu.addItem(.separator())

        let permissionsItem = NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let privacyItem = NSMenuItem(title: "Open Privacy Settings", action: #selector(openPrivacySettings), keyEquivalent: "")
        privacyItem.target = self
        menu.addItem(privacyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit PadKey", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleRecordingFromMenu() {
        toggleRecording()
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        guard !isRecording else { return }
        targetMouseLocation = CGEvent(source: nil)?.location
        targetInsertionField = injector.captureFocusedEditableTarget()
        targetApplication = preferredInsertionApplication()
        if let targetApplication, isExternalApplication(targetApplication) {
            lastExternalApplication = targetApplication
        }
        recordingStartedAt = Date()
        isRecording = true
        shouldPressEnterAfterInsert = false
        updateStatusItem()
        floatingBar.updateVoiceMeter(.idle)
        floatingBar.setRecording(true)
        let engine = store.pipelineSettings.effectiveRecognitionEngine
        prefersLocalWhisper = engine != .appleSpeech
        dictationController.recognitionEngine = engine
        dictationController.prefersLocalWhisper = prefersLocalWhisper
        dictationController.robustRetryEnabled = store.pipelineSettings.effectiveRobustRetryEnabled

        let status = listeningStatus(for: engine)
        let help = listeningHelp(for: engine)
        let targetName = targetInsertionField?.appName ?? targetApplication?.localizedName
        floatingBar.setStatus(status, detail: targetName.map { "\(help) Target: \($0)." } ?? help)
        scheduleRecordingTimeout()

        dictationController.start(
            onPartial: { [weak self] transcript in
                guard let self else { return }
                let displayText = self.process(transcript)
                let statusText = displayText.localizedCaseInsensitiveContains("Transcribing")
                    ? "Transcribing offline..."
                    : self.listeningStatus(for: self.store.pipelineSettings.effectiveRecognitionEngine)
                self.floatingBar.setStatus(statusText, detail: displayText.isEmpty ? "Speak naturally." : displayText)
            },
            onMeter: { [weak self] frame in
                DispatchQueue.main.async {
                    self?.floatingBar.updateVoiceMeter(frame)
                }
            },
            onComplete: { [weak self] result in
                self?.completeRecording(result)
            },
            onError: { [weak self] error in
                self?.failRecording(error)
            }
        )
    }

    private func stopRecording() {
        guard isRecording else { return }
        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil
        floatingBar.setStatus("Finishing...", detail: "Turning speech into text.")
        dictationController.stop()
    }

    private func completeRecording(_ result: DictationResult) {
        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil
        isRecording = false
        updateStatusItem()
        floatingBar.setRecording(false)
        floatingBar.updateVoiceMeter(.idle)

        let rawTranscript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var processedTranscript = process(rawTranscript)
        processedTranscript = store.applyPersonalRules(to: processedTranscript)
        processedTranscript = stripPressEnterCommand(from: processedTranscript)
        let deliveryContext = captureDeliveryContext()

        guard !processedTranscript.isEmpty else {
            floatingBar.flash("No speech detected", detail: "Try again with a little more audio.")
            NSSound.beep()
            return
        }

        if store.pipelineSettings.commandModeEnabled,
           MacCommandParser.looksLikeVoiceCommand(processedTranscript)
        {
            floatingBar.setStatus("Working...", detail: processedTranscript)
            let request = MacCommandRequest(
                transcript: processedTranscript,
                source: "padkey_microphone",
                batteryPercent: nil,
                mode: "mac_control"
            )
            commandCoordinator.execute(request: request, preferredApplication: deliveryContext.targetApplication) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.lastTranscript = processedTranscript
                    self.floatingBar.flash(
                        response.confirmationRequired ? "Confirmation needed" : response.ok ? "PadKey action complete" : "PadKey needs attention",
                        detail: response.spoken
                    )
                    if response.permissionRequired != nil || response.clarification != nil || response.confirmationRequired {
                        self.openHub(page: "Agent Control")
                    }
                }
            }
            return
        }

        if store.pipelineSettings.autoPolishAfterDictation {
            floatingBar.setStatus("Polishing...", detail: processedTranscript)
            let polishStartedAt = Date()
            let context = PolishContext(
                targetAppName: deliveryContext.targetField?.appName ?? deliveryContext.targetApplication?.localizedName,
                targetBundleID: deliveryContext.targetField?.bundleIdentifier ?? deliveryContext.targetApplication?.bundleIdentifier
            )
            polishService.polishDetailed(processedTranscript, transform: store.snapshot.transforms.first, context: context) { [weak self] polishResult in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let finalPolish = (try? polishResult.get()) ?? PolishResult(
                        text: processedTranscript,
                        usedAI: false,
                        provider: "Local cleanup",
                        duration: Date().timeIntervalSince(polishStartedAt),
                        fallbackReason: "Polish failed before insertion."
                    )
                    self.deliverTranscript(finalPolish.text, rawTranscript: rawTranscript, dictationResult: result, polishResult: finalPolish, deliveryContext: deliveryContext)
                }
            }
            return
        }

        deliverTranscript(processedTranscript, rawTranscript: rawTranscript, dictationResult: result, polishResult: nil, deliveryContext: deliveryContext)
    }

    private func deliverTranscript(
        _ processedTranscript: String,
        rawTranscript: String,
        dictationResult: DictationResult,
        polishResult: PolishResult?,
        deliveryContext: DeliveryContext
    ) {
        deliveryContext.targetApplication?.activate(options: [.activateIgnoringOtherApps])
        lastTranscript = processedTranscript
        let duration = Date().timeIntervalSince(deliveryContext.recordingStartedAt ?? Date())
        let targetField = deliveryContext.targetField
        let pasteboardFallbackApp = targetField == nil && insertIntoActiveApp && store.pipelineSettings.copyFallbackEnabled && injector.supportsPasteboardFallbackTarget(deliveryContext.targetApplication)
            ? deliveryContext.targetApplication
            : nil
        var latency = PipelineLatency(
            recordingDuration: duration,
            asrDuration: dictationResult.asrDuration,
            polishDuration: polishResult?.duration,
            insertionDuration: nil,
            totalDuration: duration
        )
        let record = store.addHistory(
            text: processedTranscript,
            rawText: rawTranscript,
            appName: targetField?.appName ?? pasteboardFallbackApp?.localizedName ?? "PadKey",
            duration: duration,
            targetBundleID: targetField?.bundleIdentifier ?? pasteboardFallbackApp?.bundleIdentifier,
            inserted: nil,
            insertionStrategy: nil,
            insertionError: nil,
            recognitionEngine: dictationResult.engine.displayName,
            usedRobustRetry: dictationResult.usedRobustRetry,
            polishUsed: polishResult != nil,
            polishProvider: polishResult?.provider,
            latency: latency
        )

        if insertIntoActiveApp, let targetField {
            floatingBar.flash("Inserting...", detail: processedTranscript)
            if !PermissionHelper.isAccessibilityTrusted {
                PermissionHelper.promptAccessibilityIfNeeded()
            }
            injector.insert(
                processedTranscript,
                into: targetField,
                allowPasteboardFallback: store.pipelineSettings.copyFallbackEnabled
            ) { [weak self] result in
                guard let self else { return }
                latency.insertionDuration = result.elapsedSeconds
                latency.totalDuration = Date().timeIntervalSince(deliveryContext.recordingStartedAt ?? Date())
                self.store.updateHistoryInsertion(id: record.id, result: result, latency: latency)
                if !result.inserted {
                    self.floatingBar.flash("Saved to PadKey", detail: result.errorDescription ?? "Could not reach the active editor.")
                    return
                }
                if deliveryContext.shouldPressEnterAfterInsert {
                    self.injector.pressEnter()
                }
            }
        } else if insertIntoActiveApp, let targetApplication = pasteboardFallbackApp {
            floatingBar.flash("Pasting into \(targetApplication.localizedName ?? "active app")", detail: processedTranscript)
            injector.insert(
                processedTranscript,
                into: targetApplication,
                mouseLocation: deliveryContext.targetMouseLocation,
                allowPasteboardFallback: true
            ) { [weak self] result in
                guard let self else { return }
                latency.insertionDuration = result.elapsedSeconds
                latency.totalDuration = Date().timeIntervalSince(deliveryContext.recordingStartedAt ?? Date())
                self.store.updateHistoryInsertion(id: record.id, result: result, latency: latency)
                if !result.inserted {
                    self.floatingBar.flash("Saved to PadKey", detail: result.errorDescription ?? "Could not reach the active editor.")
                    return
                }
                if deliveryContext.shouldPressEnterAfterInsert {
                    self.injector.pressEnter()
                }
            }
        } else if targetField == nil {
            store.updateHistoryInsertion(id: record.id, result: .savedOnly(appName: "PadKey", bundleID: Bundle.main.bundleIdentifier, reason: "No input field was selected."), latency: latency)
            floatingBar.flash("Saved to PadKey", detail: "No input field was selected.")
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(processedTranscript, forType: .string)
            store.updateHistoryInsertion(id: record.id, result: .savedOnly(appName: "PadKey", bundleID: Bundle.main.bundleIdentifier, reason: "Insertion into active apps is turned off; copied to clipboard."), latency: latency)
            floatingBar.flash("Copied", detail: processedTranscript)
        }
    }

    private func captureDeliveryContext() -> DeliveryContext {
        let context = DeliveryContext(
            targetField: targetInsertionField,
            targetApplication: targetApplication,
            targetMouseLocation: targetMouseLocation,
            recordingStartedAt: recordingStartedAt,
            shouldPressEnterAfterInsert: shouldPressEnterAfterInsert
        )
        resetDeliveryState()
        return context
    }

    private func resetDeliveryState() {
        targetInsertionField = nil
        targetApplication = nil
        targetMouseLocation = nil
        recordingStartedAt = nil
        shouldPressEnterAfterInsert = false
    }

    private func preferredInsertionApplication() -> NSRunningApplication? {
        if let targetInsertionField {
            return targetInsertionField.application
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if injector.supportsPasteboardFallbackTarget(frontmost) {
            return frontmost
        }

        if injector.supportsPasteboardFallbackTarget(lastExternalApplication) {
            return lastExternalApplication
        }

        return frontmost
    }

    func preferredMacCommandApplication() -> NSRunningApplication? {
        preferredInsertionApplication()
    }

    private func isExternalApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && application.bundleIdentifier != Bundle.main.bundleIdentifier
            && application.localizedName?.localizedCaseInsensitiveContains("PadKey") != true
    }

    private func failRecording(_ error: Error) {
        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil
        isRecording = false
        updateStatusItem()
        floatingBar.setRecording(false)
        floatingBar.updateVoiceMeter(.idle)
        resetDeliveryState()
        floatingBar.flash("PadKey needs attention", detail: error.localizedDescription)
        NSSound.beep()
    }

    private func process(_ transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanupEnabled else { return trimmed }
        return TextCleanup.clean(trimmed)
    }

    private func scheduleRecordingTimeout() {
        recordingTimeoutTimer?.invalidate()
        recordingTimeoutTimer = nil

        let timeout = store.pipelineSettings.sessionTimeoutSeconds
        guard timeout > 0 else { return }

        let timer = Timer(timeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isRecording else { return }
                self.floatingBar.setStatus("Session timed out", detail: "Finishing this dictation to keep microphone access bounded.")
                self.stopRecording()
            }
        }
        recordingTimeoutTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateStatusItem() {
        if let button = statusItem.button {
            button.title = isRecording ? " rec" : " pad"
            button.image = statusItemIcon(recording: isRecording)
            button.contentTintColor = isRecording ? .systemRed : nil
        }
    }

    private func statusItemIcon(recording: Bool) -> NSImage? {
        if recording {
            return NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "PadKey recording")
        }

        let image: NSImage?
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            image = NSImage(contentsOf: bundled)
        } else {
            let developmentIcon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Assets/AppIcon.icns")
            image = NSImage(contentsOf: developmentIcon)
        }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    @objc private func copyLastTranscript() {
        guard !lastTranscript.isEmpty else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
        floatingBar.flash("Copied", detail: lastTranscript)
    }

    @objc private func toggleInsertMode() {
        insertIntoActiveApp.toggle()
    }

    @objc private func toggleCleanup() {
        cleanupEnabled.toggle()
    }

    @objc private func toggleLocalWhisper() {
        let current = store.pipelineSettings.effectiveRecognitionEngine
        let next: RecognitionEngine = current == .appleSpeech ? .autoRobust : .appleSpeech
        store.updatePipelineSettings { $0.recognitionEngine = next }
        prefersLocalWhisper = next != .appleSpeech
        dictationController.recognitionEngine = next
        dictationController.prefersLocalWhisper = prefersLocalWhisper
        floatingBar.flash(
            next == .appleSpeech ? "Apple Speech selected" : "Auto Robust selected",
            detail: next.displayName
        )
    }

    private func listeningStatus(for engine: RecognitionEngine) -> String {
        switch engine {
        case .autoRobust:
            if dictationController.isSherpaReady {
                return "Listening live locally..."
            }
            if dictationController.isLocalWhisperReady {
                return "Listening offline..."
            }
            return "Listening..."
        case .sherpaWhisper:
            if dictationController.isSherpaReady {
                return "Listening live locally..."
            }
            if dictationController.isLocalWhisperReady {
                return "Listening offline..."
            }
            return "Listening..."
        case .whisper:
            return dictationController.isLocalWhisperReady ? "Listening offline..." : "Listening..."
        case .megaASR:
            return dictationController.isMegaASRReady ? "Listening for robust final pass..." : "Listening..."
        case .appleSpeech:
            return "Listening..."
        }
    }

    private func listeningHelp(for engine: RecognitionEngine) -> String {
        switch engine {
        case .autoRobust:
            if dictationController.isSherpaReady && dictationController.isLocalWhisperReady {
                return "Sherpa shows live words; Whisper finalizes, with Mega-ASR retry only when needed."
            }
            if dictationController.isLocalWhisperReady {
                return "Whisper will transcribe after release; Mega-ASR can retry low-confidence output."
            }
            return "Local engines are not set up yet, so Apple Speech will be used."
        case .sherpaWhisper:
            if dictationController.isSherpaReady && dictationController.isLocalWhisperReady {
                return "Sherpa shows live words; Whisper finalizes when you release fn."
            }
            if dictationController.isLocalWhisperReady {
                return "Sherpa is not set up yet, so Whisper will transcribe after you finish."
            }
            return "Local engines are not set up yet, so Apple Speech will be used."
        case .whisper:
            return dictationController.isLocalWhisperReady
                ? "Speak naturally. Release fn or press Option-Space again to finish."
                : "Local Whisper is not set up yet, so Apple Speech will be used."
        case .megaASR:
            return dictationController.isMegaASRReady
                ? "Mega-ASR runs the robust final pass when you release fn."
                : "Mega-ASR is not set up yet, so Apple Speech will be used."
        case .appleSpeech:
            return "Apple Speech is handling live dictation for this recording."
        }
    }

    @objc private func requestPermissions() {
        PermissionHelper.promptAccessibilityIfNeeded()
        let inputMonitoringAllowed = PermissionHelper.requestInputMonitoring()
        PermissionHelper.requestSpeechAndMicrophone { [weak self] allowed in
            DispatchQueue.main.async {
                let allAllowed = allowed && inputMonitoringAllowed && PermissionHelper.isAccessibilityTrusted
                self?.floatingBar.flash(
                    allAllowed ? "Permissions ready" : "Permissions still needed",
                    detail: allAllowed ? "PadKey can listen, detect shortcuts, and insert text." : "Enable Microphone, Speech Recognition, Accessibility, and Input Monitoring."
                )
            }
        }
    }

    private func stripPressEnterCommand(from text: String) -> String {
        let pattern = "(?i)\\s*press enter[.!?]?\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            shouldPressEnterAfterInsert = true
        }
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func polishSelectedOrLastText() {
        guard store.pipelineSettings.commandModeEnabled else {
            floatingBar.flash("Command mode is off", detail: "Enable voice editing in Pipeline.")
            openHub(page: "Pipeline")
            return
        }

        let sourceText = injector.selectedText() ?? lastTranscript
        polishService.polish(sourceText, transform: store.snapshot.transforms.first) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let polished):
                    self.lastTranscript = polished
                    self.floatingBar.flash("Polished", detail: polished)
                    self.injector.insert(
                        polished,
                        into: NSWorkspace.shared.frontmostApplication,
                        allowPasteboardFallback: self.store.pipelineSettings.copyFallbackEnabled
                    )
                case .failure(let error):
                    self.floatingBar.flash("Polish failed", detail: error.localizedDescription)
                    self.openScratchpad(with: sourceText)
                }
            }
        }
    }

    private func openHub(page: String? = nil) {
        hubController.show(page: page)
    }

    private func openScratchpad(with text: String? = nil) {
        hubController.showScratchpad(with: text)
    }

    @objc private func openHubFromMenu() {
        openHub()
    }

    @objc private func openPipelineFromMenu() {
        openHub(page: "Pipeline")
    }

    @objc private func openScratchpadFromMenu() {
        openScratchpad()
    }

    @objc private func openPrivacySettings() {
        PermissionHelper.openPrivacySettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func runInsertionSelfTest() {
        PermissionHelper.promptAccessibilityIfNeeded()
        _ = PermissionHelper.requestInputMonitoring()

        let marker = "PADKEY_INSERTION_TEST_\(Int(Date().timeIntervalSince1970))"
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PadKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let resultURL = supportDirectory.appendingPathComponent("insertion-self-test.json")
        let testFileURL = supportDirectory.appendingPathComponent("insertion-self-test.txt")
        try? "".write(to: testFileURL, atomically: true, encoding: .utf8)

        let textEditCandidates = [
            URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
            URL(fileURLWithPath: "/Applications/TextEdit.app")
        ]
        guard let textEditURL = textEditCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            writeInsertionSelfTest(
                to: resultURL,
                marker: marker,
                result: nil,
                observedText: nil,
                error: "TextEdit.app was not found."
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([testFileURL], withApplicationAt: textEditURL, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                guard let self else { return }
                if let error {
                    self.writeInsertionSelfTest(
                        to: resultURL,
                        marker: marker,
                        result: nil,
                        observedText: nil,
                        error: error.localizedDescription
                    )
                    return
                }

                let textEdit = app ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
                self.injector.insert(marker, into: textEdit, allowPasteboardFallback: true) { [weak self] result in
                    guard let self else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let observedText = self.injector.focusedTextValue(in: textEdit)
                        self.writeInsertionSelfTest(
                            to: resultURL,
                            marker: marker,
                            result: result,
                            observedText: observedText,
                            error: observedText?.contains(marker) == true ? nil : "Marker was not observed in TextEdit's focused AX value."
                        )
                    }
                }
            }
        }
    }

    private func writeInsertionSelfTest(
        to url: URL,
        marker: String,
        result: InsertionResult?,
        observedText: String?,
        error: String?
    ) {
        let payload: [String: Any] = [
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "marker": marker,
            "accessibilityTrusted": PermissionHelper.isAccessibilityTrusted,
            "inputMonitoringTrusted": PermissionHelper.isInputMonitoringTrusted,
            "inserted": result.map { $0.inserted as Any } ?? NSNull(),
            "strategy": result.map { $0.strategy.displayName as Any } ?? NSNull(),
            "attempts": (result?.attempts.map { [
                "strategy": $0.strategy.displayName,
                "succeeded": $0.succeeded,
                "detail": $0.detail
            ] } ?? []),
            "observedContainsMarker": observedText?.contains(marker) ?? false,
            "observedTextPreview": observedText.map { String($0.prefix(200)) as Any } ?? NSNull(),
            "error": error.map { $0 as Any } ?? NSNull()
        ]

        if JSONSerialization.isValidJSONObject(payload),
           let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        {
            try? data.write(to: url, options: [.atomic])
        }

        floatingBar.flash(
            error == nil ? "Insertion self-test passed" : "Insertion self-test failed",
            detail: error ?? (result?.strategy.displayName ?? "Inserted")
        )
    }
}
