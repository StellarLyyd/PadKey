import AppKit
import ApplicationServices
import Carbon
import os

struct TextInsertionTarget {
    let application: NSRunningApplication
    let element: AXUIElement
    let focusedWindow: AXUIElement?
    let mouseLocation: CGPoint?
    let pasteboardOnly: Bool
    let role: String?
    let roleDescription: String?
    let selectedText: String?

    var appName: String {
        application.localizedName ?? "Unknown app"
    }

    var bundleIdentifier: String? {
        application.bundleIdentifier
    }
}

final class TextInjector {
    private static let logger = Logger(subsystem: "com.stellarlyyd.padkey", category: "Insertion")

    private enum KeyboardDelivery {
        case frontmostEventTap
        case targetProcess
    }

    private struct AppInsertionProfile {
        var preferPasteboardAfterDirectAX: Bool
        var focusDelay: TimeInterval
        var pasteDelay: TimeInterval
        var typingDelay: TimeInterval
    }

    func supportsPasteboardFallbackTarget(_ application: NSRunningApplication?) -> Bool {
        guard let application, !application.isTerminated else { return false }
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        return isReasonablePasteboardDestination(application)
    }

    func captureFocusedEditableTarget() -> TextInsertionTarget? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focusedElement = focusedElement() else { return nil }

        var processID = pid_t()
        guard AXUIElementGetPid(focusedElement, &processID) == .success,
              let application = NSRunningApplication(processIdentifier: processID)
        else {
            return nil
        }

        let role = stringAttribute(kAXRoleAttribute, from: focusedElement)
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute, from: focusedElement)
        let selectedText = selectedText(from: focusedElement)
        let focusedWindow = focusedWindow(for: application, element: focusedElement)
        let mouseLocation = CGEvent(source: nil)?.location

        Self.logger.info(
            "Captured target app=\(application.localizedName ?? "Unknown", privacy: .public) bundle=\(application.bundleIdentifier ?? "unknown", privacy: .public) role=\(role ?? "unknown", privacy: .public) roleDescription=\(roleDescription ?? "unknown", privacy: .public)"
        )

        if isEditableTextElement(focusedElement) {
            return TextInsertionTarget(
                application: application,
                element: focusedElement,
                focusedWindow: focusedWindow,
                mouseLocation: mouseLocation,
                pasteboardOnly: false,
                role: role,
                roleDescription: roleDescription,
                selectedText: selectedText
            )
        }

        if shouldUsePasteboardTarget(for: focusedElement, application: application) {
            return TextInsertionTarget(
                application: application,
                element: focusedElement,
                focusedWindow: focusedWindow,
                mouseLocation: mouseLocation,
                pasteboardOnly: true,
                role: role,
                roleDescription: roleDescription,
                selectedText: selectedText
            )
        }

        return nil
    }

    func insert(
        _ text: String,
        into application: NSRunningApplication?,
        mouseLocation: CGPoint? = nil,
        allowPasteboardFallback: Bool = true,
        completion: ((InsertionResult) -> Void)? = nil
    ) {
        let startedAt = Date()
        let appName = application?.localizedName ?? "Unknown app"
        let bundleID = application?.bundleIdentifier
        var attempts: [InsertionAttempt] = []

        guard AXIsProcessTrusted() else {
            PermissionHelper.promptAccessibilityIfNeeded()
            attempts.append(InsertionAttempt(strategy: .none, succeeded: false, detail: "PadKey is not enabled in macOS Accessibility, so synthetic typing and paste events are blocked."))
            completion?(InsertionResult(
                inserted: false,
                strategy: .none,
                targetAppName: appName,
                targetBundleID: bundleID,
                targetRole: nil,
                attempts: attempts,
                errorDescription: "Enable PadKey in System Settings > Privacy & Security > Accessibility, then quit and reopen PadKey.",
                elapsedSeconds: Date().timeIntervalSince(startedAt)
            ))
            return
        }

        activate(application)

        DispatchQueue.main.asyncAfter(deadline: .now() + profile(for: application).focusDelay) { [weak self] in
            guard let self else { return }

            if let focused = self.focusedElement(),
               self.insertWithSelectedText(text, into: focused)
            {
                attempts.append(InsertionAttempt(strategy: .accessibilityCurrentFocus, succeeded: true, detail: "Inserted into the current focused element."))
                completion?(InsertionResult(
                    inserted: true,
                    strategy: .accessibilityCurrentFocus,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: self.stringAttribute(kAXRoleAttribute, from: focused),
                    attempts: attempts,
                    errorDescription: nil,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .accessibilityCurrentFocus, succeeded: false, detail: "The frontmost focused element did not accept AX selected text."))

            if let focused = self.focusedElement(),
               self.insertWithValueReplacement(text, into: focused)
            {
                attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: true, detail: "Replaced text through the current focused AX value."))
                completion?(InsertionResult(
                    inserted: true,
                    strategy: .accessibilityValueReplacement,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: self.stringAttribute(kAXRoleAttribute, from: focused),
                    attempts: attempts,
                    errorDescription: nil,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: false, detail: "The frontmost focused element did not expose a writable AX value/range."))

            let systemPasteResult = self.insertWithSystemEventsPaste(text, into: application, mouseLocation: mouseLocation)
            if systemPasteResult.succeeded {
                attempts.append(InsertionAttempt(strategy: .systemEventsPaste, succeeded: true, detail: systemPasteResult.detail))
                completion?(InsertionResult(
                    inserted: true,
                    strategy: .systemEventsPaste,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: nil,
                    attempts: attempts,
                    errorDescription: nil,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .systemEventsPaste, succeeded: false, detail: systemPasteResult.detail))

            if self.insertWithGlobalUnicodeTyping(text, into: application, mouseLocation: mouseLocation) {
                attempts.append(InsertionAttempt(strategy: .globalUnicodeTyping, succeeded: true, detail: "Typed Unicode text through the frontmost keyboard event stream."))
                completion?(InsertionResult(
                    inserted: true,
                    strategy: .globalUnicodeTyping,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: nil,
                    attempts: attempts,
                    errorDescription: nil,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .globalUnicodeTyping, succeeded: false, detail: "Global keyboard typing fallback could not return focus to the target app."))

            if self.insertWithTargetedUnicodeTyping(text, into: application, mouseLocation: mouseLocation) {
                attempts.append(InsertionAttempt(strategy: .unicodeTyping, succeeded: true, detail: "Typed Unicode text directly to the target app process."))
                completion?(InsertionResult(
                    inserted: true,
                    strategy: .unicodeTyping,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: nil,
                    attempts: attempts,
                    errorDescription: nil,
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .unicodeTyping, succeeded: false, detail: "Keyboard typing fallback could not return focus to the target app."))

            guard allowPasteboardFallback else {
                completion?(InsertionResult(
                    inserted: false,
                    strategy: .none,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: nil,
                    attempts: attempts,
                    errorDescription: "Direct insertion failed and clipboard fallback is off.",
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
                return
            }

            self.insertWithPasteboard(text, into: application, mouseLocation: mouseLocation) { pasted, detail in
                attempts.append(InsertionAttempt(strategy: .pasteboard, succeeded: pasted, detail: detail))
                completion?(InsertionResult(
                    inserted: pasted,
                    strategy: pasted ? .pasteboard : .none,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetRole: nil,
                    attempts: attempts,
                    errorDescription: pasted ? nil : "Clipboard fallback failed.",
                    elapsedSeconds: Date().timeIntervalSince(startedAt)
                ))
            }
        }
    }

    func insert(
        _ text: String,
        into target: TextInsertionTarget,
        allowPasteboardFallback: Bool = true,
        completion: ((InsertionResult) -> Void)? = nil
    ) {
        let startedAt = Date()
        var attempts: [InsertionAttempt] = []
        let profile = profile(for: target.application)

        guard AXIsProcessTrusted() else {
            PermissionHelper.promptAccessibilityIfNeeded()
            attempts.append(InsertionAttempt(strategy: .none, succeeded: false, detail: "PadKey is not enabled in macOS Accessibility, so synthetic typing and paste events are blocked."))
            completion?(result(
                inserted: false,
                strategy: .none,
                target: target,
                attempts: attempts,
                error: "Enable PadKey in System Settings > Privacy & Security > Accessibility, then quit and reopen PadKey.",
                startedAt: startedAt
            ))
            return
        }

        activate(target.application)

        DispatchQueue.main.asyncAfter(deadline: .now() + profile.focusDelay) { [weak self] in
            guard let self else { return }

            self.focus(target)

            if !target.pasteboardOnly, self.insertWithSelectedText(text, into: target.element) {
                attempts.append(InsertionAttempt(strategy: .accessibilitySelectedText, succeeded: true, detail: "Target element accepted selected-text insertion."))
                completion?(self.result(
                    inserted: true,
                    strategy: .accessibilitySelectedText,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            if !target.pasteboardOnly {
                attempts.append(InsertionAttempt(strategy: .accessibilitySelectedText, succeeded: false, detail: "Target element rejected selected-text insertion."))
            }

            if !target.pasteboardOnly, self.insertWithValueReplacement(text, into: target.element) {
                attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: true, detail: "Replaced the AX selected range in the target value."))
                completion?(self.result(
                    inserted: true,
                    strategy: .accessibilityValueReplacement,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            if !target.pasteboardOnly {
                attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: false, detail: "Target value/range was not safely writable."))
            }

            if let focused = self.focusedElement(), self.insertWithSelectedText(text, into: focused) {
                attempts.append(InsertionAttempt(strategy: .accessibilityCurrentFocus, succeeded: true, detail: "Inserted after refocusing the current element."))
                completion?(self.result(
                    inserted: true,
                    strategy: .accessibilityCurrentFocus,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .accessibilityCurrentFocus, succeeded: false, detail: "Focused element did not accept AX selected text."))

            if let focused = self.focusedElement(), self.insertWithValueReplacement(text, into: focused) {
                attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: true, detail: "Replaced text through the refocused AX value."))
                completion?(self.result(
                    inserted: true,
                    strategy: .accessibilityValueReplacement,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .accessibilityValueReplacement, succeeded: false, detail: "Refocused element did not expose a writable AX value/range."))

            let systemPasteResult = self.insertWithSystemEventsPaste(text, into: target, delay: profile.pasteDelay)
            if systemPasteResult.succeeded {
                attempts.append(InsertionAttempt(strategy: .systemEventsPaste, succeeded: true, detail: systemPasteResult.detail))
                completion?(self.result(
                    inserted: true,
                    strategy: .systemEventsPaste,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .systemEventsPaste, succeeded: false, detail: systemPasteResult.detail))

            if self.insertWithGlobalUnicodeTyping(text, into: target, delay: profile.typingDelay) {
                attempts.append(InsertionAttempt(strategy: .globalUnicodeTyping, succeeded: true, detail: "Typed Unicode text through the frontmost keyboard event stream after restoring the captured target."))
                completion?(self.result(
                    inserted: true,
                    strategy: .globalUnicodeTyping,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .globalUnicodeTyping, succeeded: false, detail: "Global keyboard typing fallback could not restore the captured target."))

            if self.insertWithTargetedUnicodeTyping(text, into: target, delay: profile.typingDelay) {
                attempts.append(InsertionAttempt(strategy: .unicodeTyping, succeeded: true, detail: "Typed Unicode text directly to the captured target app process."))
                completion?(self.result(
                    inserted: true,
                    strategy: .unicodeTyping,
                    target: target,
                    attempts: attempts,
                    error: nil,
                    startedAt: startedAt
                ))
                return
            }

            attempts.append(InsertionAttempt(strategy: .unicodeTyping, succeeded: false, detail: "Keyboard typing fallback could not restore the captured target."))

            guard allowPasteboardFallback else {
                completion?(self.result(
                    inserted: false,
                    strategy: .none,
                    target: target,
                    attempts: attempts,
                    error: "Direct insertion failed and clipboard fallback is off.",
                    startedAt: startedAt
                ))
                return
            }

            self.focus(target)
            self.insertWithPasteboard(text, into: target.application, mouseLocation: target.mouseLocation, delay: profile.pasteDelay, beforePaste: { [weak self] in
                self?.focus(target)
            }) { pasted, detail in
                attempts.append(InsertionAttempt(strategy: .pasteboard, succeeded: pasted, detail: detail))
                completion?(self.result(
                    inserted: pasted,
                    strategy: pasted ? .pasteboard : .none,
                    target: target,
                    attempts: attempts,
                    error: pasted ? nil : "Clipboard fallback failed.",
                    startedAt: startedAt
                ))
            }
        }
    }

    func selectedText() -> String? {
        guard AXIsProcessTrusted(), let focusedElement = focusedElement() else { return nil }
        let trimmed = selectedText(from: focusedElement)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? selectedText(from: focusedElement) : nil
    }

    func focusedTextValue(in application: NSRunningApplication?) -> String? {
        activate(application)
        _ = waitForFrontmost(application, timeout: 0.45)
        guard AXIsProcessTrusted(), let focusedElement = focusedElement() else { return nil }
        return textValue(from: focusedElement)
    }

    func pressEnter() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeReturn: CGKeyCode = 36

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: true)
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeReturn, keyDown: false)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func result(
        inserted: Bool,
        strategy: InsertionStrategy,
        target: TextInsertionTarget,
        attempts: [InsertionAttempt],
        error: String?,
        startedAt: Date
    ) -> InsertionResult {
        InsertionResult(
            inserted: inserted,
            strategy: strategy,
            targetAppName: target.appName,
            targetBundleID: target.bundleIdentifier,
            targetRole: target.role,
            attempts: attempts,
            errorDescription: error,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )

        guard focusedResult == .success, let focusedObject else {
            return nil
        }

        guard CFGetTypeID(focusedObject) == AXUIElementGetTypeID() else {
            return nil
        }

        return (focusedObject as! AXUIElement)
    }

    private func insertWithSelectedText(_ text: String, into element: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let selectedTextResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return selectedTextResult == .success
    }

    private func insertWithValueReplacement(_ text: String, into element: AXUIElement) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        var valueSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
              valueSettable.boolValue
        else {
            return false
        }

        var valueObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueObject) == .success,
              let currentValue = valueObject as? String
        else {
            return false
        }

        var rangeObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeObject) == .success,
              let axRange = rangeObject
        else {
            return false
        }

        guard CFGetTypeID(axRange) == AXValueGetTypeID() else {
            return false
        }

        var selectedRange = CFRange()
        guard AXValueGetValue((axRange as! AXValue), .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length >= 0
        else {
            return false
        }

        let nsRange = NSRange(location: selectedRange.location, length: selectedRange.length)
        guard let swiftRange = Range(nsRange, in: currentValue) else { return false }

        var updatedValue = currentValue
        updatedValue.replaceSubrange(swiftRange, with: text)

        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success else {
            return false
        }

        var newRange = CFRange(location: selectedRange.location + (text as NSString).length, length: 0)
        if let newAXRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newAXRange)
        }

        return true
    }

    @discardableResult
    private func focus(_ target: TextInsertionTarget) -> Bool {
        activate(target.application)

        var processID = pid_t()
        guard AXUIElementGetPid(target.element, &processID) == .success else { return false }

        let appElement = AXUIElementCreateApplication(processID)

        if let focusedWindow = target.focusedWindow {
            AXUIElementPerformAction(focusedWindow, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(
                appElement,
                kAXFocusedWindowAttribute as CFString,
                focusedWindow
            )
        }

        AXUIElementPerformAction(appElement, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            target.element
        )
        AXUIElementPerformAction(target.element, kAXRaiseAction as CFString)
        return isFrontmost(target.application)
    }

    private func activate(_ application: NSRunningApplication?) {
        guard let application, !application.isTerminated else { return }
        application.activate(options: [.activateIgnoringOtherApps])
    }

    private func isFrontmost(_ application: NSRunningApplication?) -> Bool {
        guard let application else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(kAXRoleAttribute, from: element) {
            let editableRoles = [
                kAXTextFieldRole as String,
                kAXTextAreaRole as String,
                kAXComboBoxRole as String
            ]
            if editableRoles.contains(role) || role.localizedCaseInsensitiveContains("Text") {
                return true
            }
        }

        var selectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedTextSettable) == .success,
           selectedTextSettable.boolValue
        {
            return true
        }

        var valueSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable) == .success,
           valueSettable.boolValue
        {
            return stringAttribute(kAXRoleAttribute, from: element)?.localizedCaseInsensitiveContains("Text") == true
        }

        return false
    }

    private func shouldUsePasteboardTarget(for element: AXUIElement, application: NSRunningApplication) -> Bool {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }

        if hasTextSelectionContext(element) {
            return true
        }

        guard isReasonablePasteboardDestination(application) else {
            return false
        }

        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let roleDescription = stringAttribute(kAXRoleDescriptionAttribute, from: element) ?? ""
        let combinedRole = "\(role) \(roleDescription)".lowercased()

        return combinedRole.contains("web")
            || combinedRole.contains("group")
            || combinedRole.contains("scroll")
            || combinedRole.contains("text")
            || combinedRole.contains("editor")
    }

    private func isReasonablePasteboardDestination(_ application: NSRunningApplication) -> Bool {
        let appName = (application.localizedName ?? "").lowercased()
        let bundleID = (application.bundleIdentifier ?? "").lowercased()
        let blockedHints = [
            "padkey",
            "finder",
            "system settings",
            "system preferences",
            "activity monitor",
            "loginwindow",
            "dock"
        ]

        return !blockedHints.contains { appName.contains($0) || bundleID.contains($0) }
    }

    private func hasTextSelectionContext(_ element: AXUIElement) -> Bool {
        var selectedTextRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedTextRange
        ) == .success {
            return true
        }

        var selectedText: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedText
        ) == .success {
            return true
        }

        return false
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selectedObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedObject
        ) == .success else {
            return nil
        }
        return selectedObject as? String
    }

    private func textValue(from element: AXUIElement) -> String? {
        var valueObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueObject) == .success else {
            return nil
        }
        return valueObject as? String
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var object: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &object) == .success else {
            return nil
        }
        return object as? String
    }

    private func profile(for application: NSRunningApplication?) -> AppInsertionProfile {
        let bundleID = (application?.bundleIdentifier ?? "").lowercased()
        let appName = (application?.localizedName ?? "").lowercased()
        let combined = "\(bundleID) \(appName)"

        let browserOrElectron = [
            "safari",
            "chrome",
            "chromium",
            "arc",
            "firefox",
            "chatgpt",
            "codex",
            "slack",
            "discord"
        ].contains { combined.contains($0) }

        let codeEditor = [
            "cursor",
            "visual studio code",
            "vscode",
            "xcode"
        ].contains { combined.contains($0) }

        return AppInsertionProfile(
            preferPasteboardAfterDirectAX: browserOrElectron || codeEditor,
            focusDelay: browserOrElectron ? 0.28 : 0.16,
            pasteDelay: browserOrElectron || codeEditor ? 0.26 : 0.16,
            typingDelay: browserOrElectron || codeEditor ? 0.18 : 0.10
        )
    }

    @discardableResult
    private func insertWithGlobalUnicodeTyping(_ text: String, into target: TextInsertionTarget, delay: TimeInterval) -> Bool {
        focus(target)
        guard waitForFrontmost(target.application, timeout: delay + 0.25) else {
            return false
        }
        focus(target)
        restoreMouseFocus(at: target.pasteboardOnly ? target.mouseLocation : nil, in: target.application)
        return typeUnicodeText(text, to: target.application, delivery: .frontmostEventTap)
    }

    @discardableResult
    private func insertWithGlobalUnicodeTyping(_ text: String, into application: NSRunningApplication?, mouseLocation: CGPoint?) -> Bool {
        activate(application)
        guard waitForFrontmost(application, timeout: profile(for: application).typingDelay + 0.25) else {
            return false
        }
        restoreMouseFocus(at: mouseLocation, in: application)
        return typeUnicodeText(text, to: application, delivery: .frontmostEventTap)
    }

    @discardableResult
    private func insertWithTargetedUnicodeTyping(_ text: String, into target: TextInsertionTarget, delay: TimeInterval) -> Bool {
        focus(target)
        guard waitForFrontmost(target.application, timeout: delay + 0.25) else {
            return false
        }
        focus(target)
        restoreMouseFocus(at: target.pasteboardOnly ? target.mouseLocation : nil, in: target.application)
        return typeUnicodeText(text, to: target.application, delivery: .targetProcess)
    }

    @discardableResult
    private func insertWithTargetedUnicodeTyping(_ text: String, into application: NSRunningApplication?, mouseLocation: CGPoint?) -> Bool {
        activate(application)
        guard waitForFrontmost(application, timeout: profile(for: application).typingDelay + 0.25) else {
            return false
        }
        restoreMouseFocus(at: mouseLocation, in: application)
        return typeUnicodeText(text, to: application, delivery: .targetProcess)
    }

    private func insertWithSystemEventsPaste(
        _ text: String,
        into target: TextInsertionTarget,
        delay: TimeInterval
    ) -> (succeeded: Bool, detail: String) {
        focus(target)
        guard waitForFrontmost(target.application, timeout: delay + 0.25) else {
            return (false, "Could not return focus to \(target.appName) before System Events paste.")
        }
        focus(target)
        return systemEventsPaste(text, into: target.application, mouseLocation: target.pasteboardOnly ? target.mouseLocation : nil)
    }

    private func insertWithSystemEventsPaste(
        _ text: String,
        into application: NSRunningApplication?,
        mouseLocation: CGPoint?
    ) -> (succeeded: Bool, detail: String) {
        activate(application)
        guard waitForFrontmost(application, timeout: profile(for: application).pasteDelay + 0.25) else {
            return (false, "Could not return focus to \(application?.localizedName ?? "the target app") before System Events paste.")
        }
        return systemEventsPaste(text, into: application, mouseLocation: mouseLocation)
    }

    private func systemEventsPaste(
        _ text: String,
        into application: NSRunningApplication?,
        mouseLocation: CGPoint?
    ) -> (succeeded: Bool, detail: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        restoreMouseFocus(at: mouseLocation, in: application)

        let scriptSource = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: scriptSource)?.executeAndReturnError(&errorInfo)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            snapshot.restore(to: pasteboard)
        }

        if result != nil {
            return (true, "Pasted through System Events after restoring \(application?.localizedName ?? "the target app") focus.")
        }

        let message = (errorInfo?[NSAppleScript.errorMessage] as? String)
            ?? errorInfo?.description
            ?? "System Events paste failed."
        return (false, message)
    }

    private func insertWithPasteboard(
        _ text: String,
        into application: NSRunningApplication?,
        mouseLocation: CGPoint? = nil,
        delay: TimeInterval? = nil,
        beforePaste: (() -> Void)? = nil,
        completion: @escaping (Bool, String) -> Void
    ) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let pasteDelay = delay ?? profile(for: application).pasteDelay

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            guard let self else {
                completion(false, "PadKey stopped before the paste event could be sent.")
                return
            }

            beforePaste?()
            self.activate(application)
            self.restoreMouseFocus(at: mouseLocation, in: application)

            let finishPaste = { [weak self] in
                guard let self else {
                    completion(false, "PadKey stopped before the paste event could be sent.")
                    return
                }

                let activeBeforePaste = self.isFrontmost(application)
                guard activeBeforePaste else {
                    completion(false, "Could not return focus to \(application?.localizedName ?? "the target app") before pasting.")
                    return
                }

                let sent = self.sendCommandV()
                let detail = sent
                    ? "Pasted through clipboard fallback after restoring \(application?.localizedName ?? "the target app") focus."
                    : "Could not create paste keyboard events."
                completion(sent, detail)
            }

            if self.isFrontmost(application) {
                finishPaste()
            } else {
                self.activate(application)
                beforePaste?()
                self.restoreMouseFocus(at: mouseLocation, in: application)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: finishPaste)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            snapshot.restore(to: pasteboard)
        }
    }

    @discardableResult
    private func sendCommandV() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .combinedSessionState)
        let keyCodeV = CGKeyCode(kVK_ANSI_V)
        let keyCodeCommand = CGKeyCode(kVK_Command)

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)
        else {
            return false
        }

        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    private func waitForFrontmost(_ application: NSRunningApplication?, timeout: TimeInterval) -> Bool {
        guard let application else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isFrontmost(application) {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return isFrontmost(application)
    }

    @discardableResult
    private func typeUnicodeText(_ text: String, to application: NSRunningApplication?, delivery: KeyboardDelivery) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .combinedSessionState)
        var sentAny = false

        for character in text {
            let units = Array(String(character).utf16)
            guard !units.isEmpty else { continue }

            if character == "\n" {
                if sendKeyCode(CGKeyCode(kVK_Return), to: application, source: source, delivery: delivery) {
                    sentAny = true
                }
                continue
            }

            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                continue
            }

            units.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                keyDown.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: baseAddress)
            }

            post(keyDown, to: application, delivery: delivery)
            post(keyUp, to: application, delivery: delivery)
            sentAny = true

            if text.count > 80 {
                usleep(1_000)
            }
        }

        return sentAny
    }

    @discardableResult
    private func sendKeyCode(_ keyCode: CGKeyCode, to application: NSRunningApplication?, source: CGEventSource?, delivery: KeyboardDelivery) -> Bool {
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }

        post(keyDown, to: application, delivery: delivery)
        post(keyUp, to: application, delivery: delivery)
        return true
    }

    private func post(_ event: CGEvent, to application: NSRunningApplication?, delivery: KeyboardDelivery) {
        if delivery == .targetProcess, let application, !application.isTerminated {
            event.postToPid(application.processIdentifier)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private func restoreMouseFocus(at location: CGPoint?, in application: NSRunningApplication?) {
        guard let location else { return }
        activate(application)

        let source = CGEventSource(stateID: .hidSystemState) ?? CGEventSource(stateID: .combinedSessionState)
        guard
            let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
            let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
        else {
            return
        }

        mouseDown.post(tap: .cghidEventTap)
        mouseUp.post(tap: .cghidEventTap)
        usleep(180_000)
    }

    private func focusedWindow(for application: NSRunningApplication, element: AXUIElement) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject) == .success,
           let windowObject
        {
            guard CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
                return nil
            }
            return (windowObject as! AXUIElement)
        }

        return ancestorWindow(for: element)
    }

    private func ancestorWindow(for element: AXUIElement) -> AXUIElement? {
        var current = element

        for _ in 0..<10 {
            if stringAttribute(kAXRoleAttribute, from: current) == (kAXWindowRole as String) {
                return current
            }

            var parentObject: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentObject) == .success,
                  let parentObject
            else {
                return nil
            }

            guard CFGetTypeID(parentObject) == AXUIElementGetTypeID() else {
                return nil
            }
            current = (parentObject as! AXUIElement)
        }

        return nil
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { storedItem in
            let item = NSPasteboardItem()
            storedItem.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
