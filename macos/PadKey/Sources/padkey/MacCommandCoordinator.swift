import AppKit
import ApplicationServices
import Foundation

enum GenericUIAction: Equatable {
    case fill(target: String, value: String)
    case focus(target: String)
    case click(target: String)
    case select(option: String, target: String?)
}

enum ParsedMacCommand: Equatable {
    case newNote
    case makeNote(String)
    case appendNote(String)
    case openFaceTime
    case faceTimeContact(String)
    case openApplication(String)
    case browserSearch(String)
    case summarizePage
    case genericUI(GenericUIAction)
    case computerControl(String)
    case conversation(String)
    case diagram(String)
    case copy
    case paste
    case scroll(direction: String)
    case goBack
    case closeWindow
    case confirm
    case unknown
}

enum MacCommandParser {
    static func hasWakePhrase(_ transcript: String) -> Bool {
        transcript.range(of: #"^\s*(?:hey\s+)?pad\s*key\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeVoiceCommand(_ transcript: String) -> Bool {
        hasWakePhrase(transcript)
            || normalized(transcript).range(of: #"^(confirm|cancel)$"#, options: .regularExpression) != nil
            || parse(transcript) != .unknown
    }

    static func parse(_ transcript: String) -> ParsedMacCommand {
        let command = stripWakePhrase(transcript)
        if command.range(of: #"^(confirm|yes confirm|do it)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .confirm
        }
        if command.range(of: #"^(?:(?:make|create|start|open)\s+(?:a\s+)?new\s+note|new\s+note|blank\s+note)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .newNote
        }
        if let value = capture(command, #"^(?:make\s+(?:a\s+)?note|create\s+(?:a\s+)?note|note)\s+(.+)$"#) {
            return .makeNote(value)
        }
        if let value = capture(command, #"^(?:add|append)\s+to\s+(?:this|the current)\s+note\s+(.+)$"#) {
            return .appendNote(value)
        }
        if command.range(of: #"^(?:open|start)\s+(?:the\s+)?(?:app\s+)?facetime$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .openFaceTime
        }
        if let value = capture(command, #"^(?:call|facetime)\s+(.+?)(?:\s+on\s+facetime)?$"#) {
            return .faceTimeContact(value)
        }
        if let value = capture(command, #"^(?:open|launch|start|switch\s+to|focus|bring\s+up)\s+(?:the\s+)?(?:app\s+)?(.+)$"#) {
            return .openApplication(value)
        }
        if let value = capture(command, #"^(?:search\s+(?:the\s+)?web\s+for|search\s+for|google|look\s+up)\s+(.+)$"#) {
            return .browserSearch(value)
        }
        if command.range(of: #"^summarize\s+(?:this\s+)?page$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .summarizePage
        }
        if let value = capture(command, #"^(?:create|make|draw|generate)\s+(?:a\s+)?(?:diagram|flowchart|map)(?:\s+(?:of|for|about|showing))?\s+(.+)$"#) {
            return .diagram(value)
        }
        if let value = capture(command, #"^(?:diagram|flowchart)\s+(.+)$"#) {
            return .diagram(value)
        }
        if let value = conversationalPrompt(from: command) {
            return .conversation(value)
        }
        if command.range(of: #"^(?:copy|copy that|copy this)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .copy
        }
        if command.range(of: #"^(?:paste|paste that|paste this)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .paste
        }
        if let value = capture(command, #"^scroll\s+(up|down|left|right)$"#) {
            return .scroll(direction: value.lowercased())
        }
        if command.range(of: #"^(?:go\s+back|back)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .goBack
        }
        if command.range(of: #"^(?:close\s+(?:the\s+)?window|close\s+window)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .closeWindow
        }
        if let captures = captures(command, #"^(?:fill|input)\s+(?:the\s+)?(.+?)\s+with\s+(.+)$"#, count: 2) {
            return .genericUI(.fill(target: captures[0], value: captures[1]))
        }
        if let captures = captures(command, #"^type\s+(.+?)\s+into\s+(?:the\s+)?(.+)$"#, count: 2) {
            return .genericUI(.fill(target: captures[1], value: captures[0]))
        }
        if let captures = captures(command, #"^type\s+(?:this\s+)?into\s+(?:the\s+)?(.+?)(?:\s+with\s+(.+))?$"#, count: 2) {
            let value = captures[1].isEmpty ? "" : captures[1]
            return .genericUI(.fill(target: captures[0], value: value))
        }
        if let value = capture(command, #"^focus\s+(?:the\s+)?(.+)$"#) {
            return .genericUI(.focus(target: value))
        }
        if let value = capture(command, #"^(?:click|press)\s+(?:the\s+)?(.+)$"#) {
            return .genericUI(.click(target: value))
        }
        if let captures = captures(command, #"^select\s+(.+?)(?:\s+from\s+(?:the\s+)?(.+))?$"#, count: 2) {
            return .genericUI(.select(option: captures[0], target: captures[1].isEmpty ? nil : captures[1]))
        }
        if hasWakePhrase(transcript), !command.isEmpty {
            return .conversation(command)
        }
        if looksLikeComputerControlRuntime(command, originalTranscript: transcript) {
            return .computerControl(command)
        }
        return .unknown
    }

    static func stripWakePhrase(_ transcript: String) -> String {
        transcript.replacingOccurrences(
            of: #"^\s*(?:hey\s+)?pad\s*key\s*[,;:\-]?\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        captures(text, pattern, count: 1)?.first
    }

    private static func captures(_ text: String, _ pattern: String, count: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              match.range.location != NSNotFound
        else {
            return nil
        }
        return (1...count).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return "" }
            return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func conversationalPrompt(from command: String) -> String? {
        let patterns = [
            #"^(?:ask\s+padkey|chat\s+with\s+padkey|talk\s+to\s+padkey)\s+(.+)$"#,
            #"^(?:talk\s+to\s+me\s+about|chat\s+(?:with\s+me\s+)?about|answer\s+this|explain|tell\s+me\s+about|help\s+me\s+understand)\s+(.+)$"#,
            #"^(?:can\s+you|could\s+you)\s+(?:explain|tell\s+me|help\s+me|talk\s+to\s+me\s+about)\s+(.+)$"#,
            #"^(?:what\s+do\s+you\s+think(?:\s+about)?|what\s+would\s+you\s+do\s+about)\s+(.+)$"#
        ]
        for pattern in patterns {
            if let value = capture(command, pattern), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func looksLikeComputerControlRuntime(_ command: String, originalTranscript: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if hasWakePhrase(originalTranscript) {
            return true
        }

        let lower = trimmed.lowercased()
        let liveStateMarkers = [
            "current app", "frontmost app", "whatever app is open", "this app",
            "on screen", "the screen", "visible", "window", "tab", "menu",
            "button", "field", "option", "control", "sidebar", "drawer",
            "canvas", "toolbar", "panel", "list", "row", "project", "chat"
        ]
        let actionMarkers = [
            "find", "choose", "pick", "select", "click", "press", "focus",
            "fill", "type", "open", "navigate", "go to", "look at", "use",
            "show", "new", "create", "start", "search", "switch"
        ]
        return liveStateMarkers.contains { lower.contains($0) }
            && actionMarkers.contains { lower.contains($0) }
    }
}

enum MacActionSafetyPolicy {
    private static let confirmationKeywords = [
        "send", "submit", "call", "purchase", "buy", "pay", "delete", "remove",
        "email", "message", "upload", "share", "post", "publish", "terminal", "run command"
    ]

    static func requiresConfirmation(command: String, target: String? = nil) -> Bool {
        let combined = "\(command) \(target ?? "")".lowercased()
        return confirmationKeywords.contains { combined.contains($0) }
    }
}

final class MacCommandCoordinator {
    static let shared = MacCommandCoordinator()

    private struct PendingConfirmation {
        let id: String
        let execute: (@escaping (MacCommandResponse) -> Void) -> Void
    }

    private let accessibility = AccessibilityTreeService.shared
    private let planner = AppActionPlanner()
    private let localModel = LocalModelClient()
    private let speech = NSSpeechSynthesizer()
    private var pendingConfirmations: [String: PendingConfirmation] = [:]
    private(set) var snapshot = AgentControlSnapshot.idle

    private init() {
        refreshPermissionState()
    }

    func permissions() -> MacPermissionsResponse {
        MacPermissionsResponse(
            accessibility: PermissionRequirement(
                granted: PermissionHelper.isAccessibilityTrusted,
                required: true,
                reason: "Required to inspect and interact with fields, buttons, tabs, and active apps."
            ),
            automation: PermissionRequirement(
                granted: nil,
                required: true,
                reason: "Required to control supported apps through Apple Events. macOS asks the first time each app is controlled."
            ),
            inputMonitoring: PermissionRequirement(
                granted: PermissionHelper.isInputMonitoringTrusted,
                required: false,
                reason: "Required for the global fn shortcut, but not for commands submitted from PadKey Studio."
            ),
            screenRecording: PermissionRequirement(
                granted: nil,
                required: false,
                reason: "Reserved for a future screenshot fallback; current actions use Accessibility."
            )
        )
    }

    func refreshPermissionState() {
        snapshot.accessibilityStatus = PermissionHelper.isAccessibilityTrusted ? "Ready" : "Permission needed"
        publishSnapshot()
    }

    func execute(
        request: MacCommandRequest,
        preferredApplication: NSRunningApplication? = nil,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        let transcript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            finish(.failure(spoken: "Tell me what you want PadKey to do."), command: transcript, completion: completion)
            return
        }
        guard transcript.count <= 4_000 else {
            finish(.failure(spoken: "That command is too long. Please try a shorter instruction."), command: String(transcript.prefix(160)), completion: completion)
            return
        }

        snapshot.status = "Working"
        snapshot.lastCommand = transcript
        snapshot.actionResult = "Inspecting the command"
        publishSnapshot()

        let parsed = MacCommandParser.parse(transcript)
        switch parsed {
        case .confirm:
            guard let pending = Array(pendingConfirmations.values).last else {
                finish(.failure(intent: "confirm", spoken: "There is no pending action to confirm."), command: transcript, completion: completion)
                return
            }
            pendingConfirmations.removeValue(forKey: pending.id)
            pending.execute { [weak self] response in
                self?.finish(response, command: transcript, completion: completion)
            }

        case .newNote:
            do {
                try NotesTool.newNote()
                finish(success(
                    intent: "new_note",
                    spoken: "New note created.",
                    actions: [MacCommandActionRecord(type: "new_note", appName: "Notes", nodeId: nil, target: "Blank note", text: nil)],
                    frontmostApp: "Notes",
                    target: "Blank note",
                    result: "Created a blank note in Apple Notes"
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "new_note", error: error, app: "Notes"), command: transcript, completion: completion)
            }

        case .makeNote(let content):
            do {
                try NotesTool.makeNote(content: content)
                finish(success(
                    intent: "make_note",
                    spoken: "Note created.",
                    actions: [MacCommandActionRecord(type: "make_note", appName: "Notes", nodeId: nil, target: "New note", text: content)],
                    frontmostApp: "Notes",
                    target: "New note",
                    result: "Created a note in Apple Notes"
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "make_note", error: error, app: "Notes"), command: transcript, completion: completion)
            }

        case .appendNote(let content):
            do {
                try NotesTool.appendToCurrentNote(content)
                finish(success(
                    intent: "append_note",
                    spoken: "Note updated.",
                    actions: [MacCommandActionRecord(type: "append_note", appName: "Notes", nodeId: nil, target: "Selected note", text: content)],
                    frontmostApp: "Notes",
                    target: "Selected note",
                    result: "Appended text to the selected note"
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "append_note", error: error, app: "Notes"), command: transcript, completion: completion)
            }

        case .openFaceTime:
            do {
                try FaceTimeTool.openFaceTime()
                finish(success(
                    intent: "open_facetime",
                    spoken: "Opening FaceTime.",
                    actions: [MacCommandActionRecord(type: "open_app", appName: "FaceTime", nodeId: nil, target: nil, text: nil)],
                    frontmostApp: "FaceTime",
                    target: nil,
                    result: "FaceTime opened"
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "open_facetime", error: error, app: "FaceTime"), command: transcript, completion: completion)
            }

        case .faceTimeContact(let contact):
            do {
                try FaceTimeTool.openFaceTime()
            } catch {
                finish(toolFailure(intent: "facetime_contact", error: error, app: "FaceTime"), command: transcript, completion: completion)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                var selectedTarget = "FaceTime contact field"
                do {
                    if let node = try FaceTimeTool.prepareContact(contact, accessibility: self.accessibility) {
                        selectedTarget = node.displayName
                    }
                } catch {
                    // FaceTime still opened. The user gets an actionable permission/error result below.
                    if !PermissionHelper.isAccessibilityTrusted {
                        self.finish(self.accessibilityFailure(intent: "facetime_contact", app: "FaceTime"), command: transcript, completion: completion)
                        return
                    }
                }
                let confirmation = self.makeConfirmation { confirmed in
                    do {
                        try FaceTimeTool.startConfirmedCall(contactName: contact)
                        confirmed(self.success(
                            intent: "start_facetime_call",
                            spoken: "Starting the FaceTime call with \(contact).",
                            actions: [MacCommandActionRecord(type: "start_call", appName: "FaceTime", nodeId: nil, target: contact, text: nil)],
                            frontmostApp: "FaceTime",
                            target: contact,
                            result: "FaceTime call requested after confirmation"
                        ))
                    } catch {
                        confirmed(self.toolFailure(intent: "start_facetime_call", error: error, app: "FaceTime"))
                    }
                }
                let response = MacCommandResponse(
                    ok: true,
                    intent: "facetime_contact",
                    spoken: "I found the contact field for \(contact). Confirm before starting the call.",
                    actions: [MacCommandActionRecord(type: "prepare_call", appName: "FaceTime", nodeId: nil, target: selectedTarget, text: contact)],
                    frontmostApp: "FaceTime",
                    selectedTarget: selectedTarget,
                    actionResult: "Contact prepared; call not started",
                    clarification: nil,
                    options: nil,
                    confirmationRequired: true,
                    confirmationId: confirmation.id,
                    permissionRequired: nil,
                    message: nil
                )
                self.finish(response, command: transcript, completion: completion)
            }

        case .openApplication(let appName):
            do {
                let app = try UIAutomation.resolveApplication(named: appName)
                try UIAutomation.openApplication(named: app.displayName)
                finish(success(
                    intent: "open_app",
                    spoken: "Opening \(app.displayName).",
                    actions: [MacCommandActionRecord(type: "open_app", appName: app.displayName, nodeId: nil, target: nil, text: nil)],
                    frontmostApp: app.displayName,
                    target: nil,
                    result: "\(app.displayName) opened"
                ), command: transcript, completion: completion)
            } catch UIAutomationError.ambiguousApp(_, let options) {
                finish(clarification(
                    spoken: "I found more than one matching app. Which one did you mean?",
                    app: nil,
                    options: options
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "open_app", error: error, app: appName), command: transcript, completion: completion)
            }

        case .browserSearch(let query):
            do {
                try BrowserTool.searchWeb(query)
                finish(success(
                    intent: "browser_search",
                    spoken: "Searching the web for \(query).",
                    actions: [MacCommandActionRecord(type: "browser_search", appName: "Browser", nodeId: nil, target: "Search", text: query)],
                    frontmostApp: preferredApplication?.localizedName,
                    target: "Browser search",
                    result: "Opened web search results"
                ), command: transcript, completion: completion)
            } catch {
                finish(toolFailure(intent: "browser_search", error: error, app: preferredApplication?.localizedName), command: transcript, completion: completion)
            }

        case .summarizePage:
            summarizePage(command: transcript, application: preferredApplication, completion: completion)

        case .genericUI(let action):
            executeGeneric(action, command: transcript, application: preferredApplication, completion: completion)

        case .computerControl(let instruction):
            executeComputerControl(instruction, command: transcript, application: preferredApplication, completion: completion)

        case .conversation(let prompt):
            executeLocalConversation(prompt, command: transcript, application: preferredApplication, completion: completion)

        case .diagram(let topic):
            createDiagramNote(topic, command: transcript, application: preferredApplication, completion: completion)

        case .copy:
            executeKeyboardShortcut(intent: "copy", spoken: "Copied.", key: "c", command: transcript, application: preferredApplication, completion: completion)

        case .paste:
            executeKeyboardShortcut(intent: "paste", spoken: "Pasted.", key: "v", command: transcript, application: preferredApplication, completion: completion)

        case .scroll(let direction):
            executeScroll(direction: direction, command: transcript, application: preferredApplication, completion: completion)

        case .goBack:
            executeKeyboardShortcut(intent: "go_back", spoken: "Going back.", key: "[", command: transcript, application: preferredApplication, completion: completion)

        case .closeWindow:
            executeKeyboardShortcut(intent: "close_window", spoken: "Closing the window.", key: "w", command: transcript, application: preferredApplication, completion: completion)

        case .unknown:
            finish(.failure(
                intent: "command_misunderstood",
                spoken: "I heard that as a command, but I need a clearer action or target.",
                frontmostApp: preferredApplication?.localizedName
            ), command: transcript, completion: completion)
        }
    }

    func confirm(id: String, completion: @escaping (MacCommandResponse) -> Void) {
        guard let pending = pendingConfirmations.removeValue(forKey: id) else {
            finish(.failure(intent: "confirm", spoken: "That confirmation has expired."), command: "Confirm", completion: completion)
            return
        }
        pending.execute { [weak self] response in
            self?.finish(response, command: "Confirm", completion: completion)
        }
    }

    func inspectAccessibility(
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        guard PermissionHelper.isAccessibilityTrusted else {
            PermissionHelper.promptAccessibilityIfNeeded()
            finish(accessibilityFailure(intent: "inspect_accessibility", app: application?.localizedName), command: "Inspect accessibility tree", completion: completion)
            return
        }
        do {
            let app = try accessibility.frontmostApp(preferred: application)
            let nodes = try accessibility.getAccessibilityTree(for: application)
            let response = success(
                intent: "inspect_accessibility",
                spoken: "I found \(nodes.count) accessible controls in \(app.name).",
                actions: [MacCommandActionRecord(type: "inspect", appName: app.name, nodeId: nil, target: "Accessibility tree", text: nil)],
                frontmostApp: app.name,
                target: "\(nodes.count) accessible controls",
                result: "Accessibility tree inspected"
            )
            finish(response, command: "Inspect accessibility tree", completion: completion)
        } catch {
            finish(toolFailure(intent: "inspect_accessibility", error: error, app: application?.localizedName), command: "Inspect accessibility tree", completion: completion)
        }
    }

    private func executeGeneric(
        _ action: GenericUIAction,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        guard PermissionHelper.isAccessibilityTrusted else {
            PermissionHelper.promptAccessibilityIfNeeded()
            finish(accessibilityFailure(intent: "ui_action", app: application?.localizedName), command: command, completion: completion)
            return
        }

        do {
            let app = try accessibility.frontmostApp(preferred: application)
            let nodes = try accessibility.getAccessibilityTree(for: application)
            let query: String
            let roles: Set<String>
            switch action {
            case .fill(let target, _):
                query = target
                roles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXSearchFieldSubrole as String, kAXComboBoxRole as String]
            case .focus(let target):
                query = target
                roles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXSearchFieldSubrole as String, kAXComboBoxRole as String, kAXButtonRole as String]
            case .click(let target):
                query = target
                roles = [kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String, "AXLink", kAXMenuItemRole as String, kAXTextFieldRole as String, kAXTextAreaRole as String, kAXSearchFieldSubrole as String]
            case .select(_, let target):
                query = target ?? "popup menu"
                roles = [kAXPopUpButtonRole as String, kAXComboBoxRole as String]
            }
            var matches = AccessibilityMatcher.matches(nodes: nodes, query: query, preferredRoles: roles)
            if query.localizedCaseInsensitiveContains("current"), let focused = nodes.first(where: { $0.focused == true && roles.contains($0.role ?? "") }) {
                matches = [focused]
            }

            guard !matches.isEmpty else {
                planner.plan(transcript: command, frontmostApp: app, nodes: nodes) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        switch result {
                        case .failure(let error):
                            self.finish(.failure(
                                intent: "ui_action",
                                spoken: error.localizedDescription,
                                frontmostApp: app.name,
                                message: "No matching accessible field or button was found."
                            ), command: command, completion: completion)
                        case .success(let plan):
                            self.executePlan(plan, nodes: nodes, app: app, command: command, completion: completion)
                        }
                    }
                }
                return
            }

            if matches.count > 1 {
                let options = Array(matches.prefix(3).map(\.displayName))
                let question = "I see multiple matching controls. Do you mean \(options.joined(separator: " or "))?"
                let response = MacCommandResponse(
                    ok: false,
                    intent: "clarification",
                    spoken: question,
                    actions: [],
                    frontmostApp: app.name,
                    selectedTarget: nil,
                    actionResult: "Waiting for clarification",
                    clarification: question,
                    options: options,
                    confirmationRequired: false,
                    confirmationId: nil,
                    permissionRequired: nil,
                    message: nil
                )
                finish(response, command: command, completion: completion)
                return
            }

            let node = matches[0]
            if MacActionSafetyPolicy.requiresConfirmation(command: command, target: node.displayName) {
                let confirmation = makeConfirmation { [weak self] confirmed in
                    guard let self else { return }
                    confirmed(self.performGeneric(action, node: node, app: app))
                }
                let response = MacCommandResponse(
                    ok: true,
                    intent: "ui_action_confirmation",
                    spoken: "I’m ready to interact with \(node.displayName). Confirm before I continue.",
                    actions: [],
                    frontmostApp: app.name,
                    selectedTarget: node.displayName,
                    actionResult: "Action paused for confirmation",
                    clarification: nil,
                    options: nil,
                    confirmationRequired: true,
                    confirmationId: confirmation.id,
                    permissionRequired: nil,
                    message: nil
                )
                finish(response, command: command, completion: completion)
                return
            }
            finish(performGeneric(action, node: node, app: app), command: command, completion: completion)
        } catch {
            finish(toolFailure(intent: "ui_action", error: error, app: application?.localizedName), command: command, completion: completion)
        }
    }

    private func executeComputerControl(
        _ instruction: String,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        guard PermissionHelper.isAccessibilityTrusted else {
            PermissionHelper.promptAccessibilityIfNeeded()
            finish(accessibilityFailure(intent: "computer_control_runtime", app: application?.localizedName), command: command, completion: completion)
            return
        }

        do {
            let app = try accessibility.frontmostApp(preferred: application)
            let nodes = try accessibility.getAccessibilityTree(for: application, maximumNodes: 500)
            guard !nodes.isEmpty else {
                finish(.failure(
                    intent: "computer_control_runtime",
                    spoken: "I could not find controllable UI elements in \(app.name).",
                    frontmostApp: app.name,
                    message: "No accessible controls were available for the current app."
                ), command: command, completion: completion)
                return
            }

            snapshot.status = "Planning"
            snapshot.frontmostApp = app.name
            snapshot.detectedIntent = "computer_control_runtime"
            snapshot.actionResult = "Inspecting \(nodes.count) controls in \(app.name)"
            publishSnapshot()

            planner.plan(transcript: instruction, frontmostApp: app, nodes: nodes) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.finish(.failure(
                            intent: "computer_control_runtime",
                            spoken: error.localizedDescription,
                            frontmostApp: app.name,
                            message: "The live app was inspected, but no executable local plan was produced."
                        ), command: command, completion: completion)
                    case .success(let plan):
                        self.executePlan(plan, nodes: nodes, app: app, command: command, completion: completion)
                    }
                }
            }
        } catch {
            finish(toolFailure(intent: "computer_control_runtime", error: error, app: application?.localizedName), command: command, completion: completion)
        }
    }

    private func executeKeyboardShortcut(
        intent: String,
        spoken: String,
        key: String,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        do {
            try UIAutomation.pressCommandKey(key)
            finish(success(
                intent: intent,
                spoken: spoken,
                actions: [MacCommandActionRecord(type: "keyboard_shortcut", appName: application?.localizedName, nodeId: nil, target: "Command-\(key)", text: nil)],
                frontmostApp: application?.localizedName,
                target: "Command-\(key)",
                result: spoken
            ), command: command, completion: completion)
        } catch {
            finish(toolFailure(intent: intent, error: error, app: application?.localizedName), command: command, completion: completion)
        }
    }

    private func executeScroll(
        direction: String,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        do {
            try UIAutomation.scroll(direction: direction)
            finish(success(
                intent: "scroll",
                spoken: "Scrolling \(direction).",
                actions: [MacCommandActionRecord(type: "scroll", appName: application?.localizedName, nodeId: nil, target: direction, text: nil)],
                frontmostApp: application?.localizedName,
                target: direction,
                result: "Scrolled \(direction)"
            ), command: command, completion: completion)
        } catch {
            finish(toolFailure(intent: "scroll", error: error, app: application?.localizedName), command: command, completion: completion)
        }
    }

    private func performGeneric(_ action: GenericUIAction, node: AccessibilityNode, app: FrontmostAppInfo) -> MacCommandResponse {
        do {
            let actionRecord: MacCommandActionRecord
            let spoken: String
            let result: String
            switch action {
            case .fill(_, let value):
                guard !value.isEmpty else {
                    return .failure(intent: "fill_field", spoken: "Tell me what text to put into \(node.displayName).", frontmostApp: app.name)
                }
                try accessibility.setElementValue(nodeId: node.id, value: value)
                actionRecord = MacCommandActionRecord(type: "set_value", appName: app.name, nodeId: node.id, target: node.displayName, text: value)
                spoken = "Filled \(node.displayName)."
                result = "Text inserted"
            case .focus:
                try accessibility.focusElement(nodeId: node.id)
                actionRecord = MacCommandActionRecord(type: "focus", appName: app.name, nodeId: node.id, target: node.displayName, text: nil)
                spoken = "Focused \(node.displayName)."
                result = "Control focused"
            case .click:
                if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXSearchFieldSubrole as String].contains(node.role ?? "") {
                    try accessibility.focusElement(nodeId: node.id)
                    actionRecord = MacCommandActionRecord(type: "focus", appName: app.name, nodeId: node.id, target: node.displayName, text: nil)
                    spoken = "Focused \(node.displayName)."
                    result = "Field focused"
                } else {
                    try accessibility.clickElement(nodeId: node.id)
                    actionRecord = MacCommandActionRecord(type: "click", appName: app.name, nodeId: node.id, target: node.displayName, text: nil)
                    spoken = "Pressed \(node.displayName)."
                    result = "Control pressed"
                }
            case .select(let option, _):
                let selected = try accessibility.selectOption(option, from: node.id)
                actionRecord = MacCommandActionRecord(type: "select", appName: app.name, nodeId: selected.id, target: selected.displayName, text: option)
                spoken = "Selected \(option)."
                result = "Option selected"
            }
            let observation = postActionObservation(app: app, actionCount: 1)
            return success(intent: "ui_action", spoken: spoken, actions: [actionRecord], frontmostApp: app.name, target: actionRecord.target, result: "\(result). \(observation)")
        } catch {
            return toolFailure(intent: "ui_action", error: error, app: app.name)
        }
    }

    private func executePlan(
        _ plan: AppActionPlan,
        nodes: [AccessibilityNode],
        app: FrontmostAppInfo,
        command: String,
        completion: @escaping (MacCommandResponse) -> Void,
        confirmed: Bool = false
    ) {
        if plan.type == "clarification" {
            let response = MacCommandResponse(
                ok: false,
                intent: "clarification",
                spoken: plan.spoken,
                actions: [],
                frontmostApp: app.name,
                selectedTarget: nil,
                actionResult: "Waiting for clarification",
                clarification: plan.spoken,
                options: plan.options,
                confirmationRequired: false,
                confirmationId: nil,
                permissionRequired: nil,
                message: nil
            )
            finish(response, command: command, completion: completion)
            return
        }

        if !confirmed, MacActionSafetyPolicy.requiresConfirmation(command: command, target: plannedTargetSummary(plan, nodes: nodes)) {
            let confirmation = makeConfirmation { [weak self] confirmedResponse in
                guard let self else { return }
                confirmedResponse(self.performPlanActions(plan, nodes: nodes, app: app, command: command))
            }
            let response = MacCommandResponse(
                ok: true,
                intent: "computer_control_confirmation",
                spoken: "I’m ready to act in \(app.name). Confirm before I continue.",
                actions: [],
                frontmostApp: app.name,
                selectedTarget: plannedTargetSummary(plan, nodes: nodes),
                actionResult: "Action paused for confirmation",
                clarification: nil,
                options: nil,
                confirmationRequired: true,
                confirmationId: confirmation.id,
                permissionRequired: nil,
                message: nil
            )
            finish(response, command: command, completion: completion)
            return
        }

        finish(performPlanActions(plan, nodes: nodes, app: app, command: command), command: command, completion: completion)
    }

    private func performPlanActions(
        _ plan: AppActionPlan,
        nodes: [AccessibilityNode],
        app: FrontmostAppInfo,
        command: String
    ) -> MacCommandResponse {
        var records: [MacCommandActionRecord] = []
        do {
            for action in plan.actions {
                guard let nodeId = action.args.nodeId,
                      let node = nodes.first(where: { $0.id == nodeId })
                else {
                    throw AccessibilityTreeError.elementUnavailable
                }
                switch action.tool {
                case "focus_element":
                    try accessibility.focusElement(nodeId: nodeId)
                    records.append(MacCommandActionRecord(type: "focus", appName: app.name, nodeId: nodeId, target: node.displayName, text: nil))
                case "click_element":
                    try accessibility.clickElement(nodeId: nodeId)
                    records.append(MacCommandActionRecord(type: "click", appName: app.name, nodeId: nodeId, target: node.displayName, text: nil))
                case "set_element_value":
                    guard let text = action.args.text else { throw AccessibilityTreeError.actionUnsupported("text entry") }
                    try accessibility.setElementValue(nodeId: nodeId, value: text)
                    records.append(MacCommandActionRecord(type: "set_value", appName: app.name, nodeId: nodeId, target: node.displayName, text: text))
                case "select_option":
                    guard let option = action.args.option else { throw AccessibilityTreeError.actionUnsupported("selection") }
                    let selected = try accessibility.selectOption(option, from: nodeId)
                    records.append(MacCommandActionRecord(type: "select", appName: app.name, nodeId: selected.id, target: selected.displayName, text: option))
                default:
                    throw AppActionPlannerError.invalidPlan("The local model requested an unsupported action.")
                }
            }
            return success(
                intent: "ui_action",
                spoken: plan.spoken,
                actions: records,
                frontmostApp: app.name,
                target: records.last?.target,
                result: postActionObservation(app: app, actionCount: records.count)
            )
        } catch {
            return toolFailure(intent: "ui_action", error: error, app: app.name)
        }
    }

    private func postActionObservation(app: FrontmostAppInfo, actionCount: Int) -> String {
        let completed = "Completed \(actionCount) accessibility action\(actionCount == 1 ? "" : "s")"
        guard
            let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier),
            let nodes = try? accessibility.getAccessibilityTree(for: runningApp, maximumNodes: 240)
        else {
            return "\(completed). Re-observation unavailable."
        }

        let snapshot = AppStateSnapshotBuilder.snapshot(app: app, nodes: nodes, maxElements: 12)
        let focused = snapshot.focusedElement.map { "\($0.name) \($0.ref)" } ?? "none"
        let roleSummary = snapshot.roleCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(4)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        return "\(completed). Re-observed \(snapshot.totalNodes) controls; focused: \(focused); roles: \(roleSummary.isEmpty ? "none" : roleSummary)."
    }

    private func plannedTargetSummary(_ plan: AppActionPlan, nodes: [AccessibilityNode]) -> String? {
        let targets = plan.actions.compactMap { action -> String? in
            guard let nodeId = action.args.nodeId,
                  let node = nodes.first(where: { $0.id == nodeId })
            else { return nil }
            return node.displayName
        }
        guard !targets.isEmpty else { return nil }
        return Array(targets.prefix(3)).joined(separator: ", ")
    }

    private func summarizePage(
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        guard PermissionHelper.isAccessibilityTrusted else {
            finish(accessibilityFailure(intent: "summarize_page", app: application?.localizedName), command: command, completion: completion)
            return
        }
        do {
            let app = try accessibility.frontmostApp(preferred: application)
            let nodes = try accessibility.getAccessibilityTree(for: application, maximumNodes: 500)
            let pageText = accessibility.readableText(from: nodes)
            guard !pageText.isEmpty else {
                finish(.failure(intent: "summarize_page", spoken: "I could not find readable page text in \(app.name).", frontmostApp: app.name), command: command, completion: completion)
                return
            }
            planner.summarize(text: pageText) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.finish(.failure(intent: "summarize_page", spoken: error.localizedDescription, frontmostApp: app.name), command: command, completion: completion)
                    case .success(let summary):
                        self.finish(self.success(
                            intent: "summarize_page",
                            spoken: summary,
                            actions: [MacCommandActionRecord(type: "summarize", appName: app.name, nodeId: nil, target: "Active page", text: nil)],
                            frontmostApp: app.name,
                            target: "Active page",
                            result: "Page summarized locally"
                        ), command: command, completion: completion)
                    }
                }
            }
        } catch {
            finish(toolFailure(intent: "summarize_page", error: error, app: application?.localizedName), command: command, completion: completion)
        }
    }

    private func executeLocalConversation(
        _ prompt: String,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        let cleanedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedPrompt.isEmpty else {
            finish(.failure(intent: "local_conversation", spoken: "Tell me what you want to talk about.", frontmostApp: application?.localizedName), command: command, completion: completion)
            return
        }

        snapshot.status = "Thinking"
        snapshot.frontmostApp = application?.localizedName ?? "PadKey"
        snapshot.detectedIntent = "local_conversation"
        snapshot.actionResult = "Asking the local Ollama model"
        publishSnapshot()

        let system = """
        You are PadKey, a local-first macOS voice assistant running on the user's computer.
        Be warm, direct, and useful. Keep answers concise enough to speak aloud.
        If the user asks for a computer action, suggest the exact PadKey command they can say.
        Preserve names, product terms, unusual spellings, and the user's wording when discussing their notes.
        Do not claim to use cloud services or remote APIs.
        """

        localModel.chat(system: system, user: cleanedPrompt, requireJSON: false, temperature: 0.45) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let answer):
                    let cleanedAnswer = Self.cleanModelText(answer, maxCharacters: 1_200)
                    self.finish(self.success(
                        intent: "local_conversation",
                        spoken: cleanedAnswer,
                        actions: [MacCommandActionRecord(type: "local_conversation", appName: "PadKey", nodeId: nil, target: "Ollama", text: cleanedPrompt)],
                        frontmostApp: application?.localizedName ?? "PadKey",
                        target: "Local Ollama model",
                        result: "Answered locally"
                    ), command: command, completion: completion)
                case .failure(let error):
                    self.finish(self.toolFailure(intent: "local_conversation", error: error, app: application?.localizedName ?? "PadKey"), command: command, completion: completion)
                }
            }
        }
    }

    private func createDiagramNote(
        _ topic: String,
        command: String,
        application: NSRunningApplication?,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        let cleanedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTopic.isEmpty else {
            finish(.failure(intent: "create_diagram", spoken: "Tell me what the diagram should show.", frontmostApp: application?.localizedName), command: command, completion: completion)
            return
        }

        snapshot.status = "Diagramming"
        snapshot.frontmostApp = application?.localizedName ?? "PadKey"
        snapshot.detectedIntent = "create_diagram"
        snapshot.actionResult = "Generating a Mermaid diagram locally"
        publishSnapshot()

        let system = """
        Create a concise Mermaid diagram from the user's topic.
        Return Mermaid code only, with no markdown fence and no explanation.
        Prefer flowchart TD unless a sequence diagram is clearly better.
        Use short readable labels. Do not invent private facts.
        """

        localModel.chat(system: system, user: cleanedTopic, requireJSON: false, temperature: 0.2) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let output):
                    let mermaid = Self.cleanMermaid(output)
                    let note = """
                    Voice diagram: \(cleanedTopic)

                    ```mermaid
                    \(mermaid)
                    ```
                    """
                    do {
                        try NotesTool.makeNote(content: note)
                        self.finish(self.success(
                            intent: "create_diagram",
                            spoken: "I created a Mermaid diagram note in Notes.",
                            actions: [MacCommandActionRecord(type: "create_diagram_note", appName: "Notes", nodeId: nil, target: cleanedTopic, text: mermaid)],
                            frontmostApp: "Notes",
                            target: cleanedTopic,
                            result: "Created a diagram note locally"
                        ), command: command, completion: completion)
                    } catch {
                        self.finish(self.toolFailure(intent: "create_diagram", error: error, app: "Notes"), command: command, completion: completion)
                    }
                case .failure(let error):
                    self.finish(self.toolFailure(intent: "create_diagram", error: error, app: application?.localizedName ?? "PadKey"), command: command, completion: completion)
                }
            }
        }
    }

    private static func cleanModelText(_ text: String, maxCharacters: Int) -> String {
        let cleaned = text
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > maxCharacters else { return cleaned }
        return String(cleaned.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func cleanMermaid(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "```mermaid", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            cleaned = "flowchart TD\n    A[Idea] --> B[Next step]"
        }
        let lower = cleaned.lowercased()
        if !lower.hasPrefix("flowchart")
            && !lower.hasPrefix("sequencediagram")
            && !lower.hasPrefix("mindmap") {
            cleaned = "flowchart TD\n    A[\(cleaned.replacingOccurrences(of: "\n", with: " "))]"
        }
        return String(cleaned.prefix(4_000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeConfirmation(
        execute: @escaping (@escaping (MacCommandResponse) -> Void) -> Void
    ) -> PendingConfirmation {
        let id = UUID().uuidString
        let pending = PendingConfirmation(id: id, execute: execute)
        pendingConfirmations[id] = pending
        return pending
    }

    private func finish(
        _ response: MacCommandResponse,
        command: String,
        completion: @escaping (MacCommandResponse) -> Void
    ) {
        snapshot.status = response.confirmationRequired ? "Confirmation needed" : response.ok ? "Complete" : "Needs attention"
        snapshot.frontmostApp = response.frontmostApp ?? "No external app selected"
        snapshot.lastCommand = command.isEmpty ? "No command" : command
        snapshot.detectedIntent = response.intent
        snapshot.accessibilityStatus = PermissionHelper.isAccessibilityTrusted ? "Ready" : "Permission needed"
        snapshot.selectedTarget = response.selectedTarget ?? "—"
        snapshot.actionResult = response.actionResult ?? response.message ?? (response.ok ? "Completed" : "Not completed")
        snapshot.spokenResponse = response.spoken
        snapshot.clarification = response.clarification ?? ""
        snapshot.confirmationId = response.confirmationId
        publishSnapshot()
        if !response.spoken.isEmpty {
            speech.stopSpeaking()
            speech.startSpeaking(response.spoken)
        }
        completion(response)
    }

    private func publishSnapshot() {
        NotificationCenter.default.post(name: .padKeyAgentControlDidUpdate, object: self)
    }

    private func success(
        intent: String,
        spoken: String,
        actions: [MacCommandActionRecord],
        frontmostApp: String?,
        target: String?,
        result: String
    ) -> MacCommandResponse {
        MacCommandResponse(
            ok: true,
            intent: intent,
            spoken: spoken,
            actions: actions,
            frontmostApp: frontmostApp,
            selectedTarget: target,
            actionResult: result,
            clarification: nil,
            options: nil,
            confirmationRequired: false,
            confirmationId: nil,
            permissionRequired: nil,
            message: nil
        )
    }

    private func clarification(spoken: String, app: String?, options: [String]) -> MacCommandResponse {
        MacCommandResponse(
            ok: false,
            intent: "ambiguous_command",
            spoken: spoken,
            actions: [],
            frontmostApp: app,
            selectedTarget: nil,
            actionResult: "Waiting for clarification",
            clarification: spoken,
            options: options,
            confirmationRequired: false,
            confirmationId: nil,
            permissionRequired: nil,
            message: nil
        )
    }

    private func accessibilityFailure(intent: String, app: String?) -> MacCommandResponse {
        MacCommandResponse(
            ok: false,
            intent: intent,
            spoken: "I need Accessibility permission to interact with fields in this app.",
            actions: [],
            frontmostApp: app,
            selectedTarget: nil,
            actionResult: "Accessibility permission is missing",
            clarification: nil,
            options: nil,
            confirmationRequired: false,
            confirmationId: nil,
            permissionRequired: "Accessibility",
            message: "Enable Accessibility for the packaged PadKey app in System Settings."
        )
    }

    private func toolFailure(intent: String, error: Error, app: String?) -> MacCommandResponse {
        if error is AccessibilityTreeError, !PermissionHelper.isAccessibilityTrusted {
            return accessibilityFailure(intent: intent, app: app)
        }
        return MacCommandResponse.failure(
            intent: intent,
            spoken: error.localizedDescription,
            frontmostApp: app,
            message: "The requested action was not completed."
        )
    }
}
