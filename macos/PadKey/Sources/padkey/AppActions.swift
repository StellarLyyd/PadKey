import AppKit
import ApplicationServices
import Foundation

enum NotesTool {
    static func makeNote(content: String) throws {
        let body = "<div>\(UIAutomation.htmlEscaped(content))</div>"
        let escaped = UIAutomation.appleScriptString(body)
        _ = try UIAutomation.runAppleScript("""
        set noteBody to "\(escaped)"
        tell application "Notes"
            activate
            set targetFolder to default folder of default account
            set createdNote to make new note at targetFolder with properties {body:noteBody}
            show createdNote
        end tell
        """)
    }

    static func newNote() throws {
        try makeNote(content: "")
    }

    static func appendToCurrentNote(_ text: String) throws {
        let body = "<div>\(UIAutomation.htmlEscaped(text))</div>"
        let escaped = UIAutomation.appleScriptString(body)
        _ = try UIAutomation.runAppleScript("""
        set appendedBody to "\(escaped)"
        tell application "Notes"
            activate
            set selectedNotes to selection
            if (count of selectedNotes) is 0 then error "Select a note before appending."
            set targetNote to item 1 of selectedNotes
            set body of targetNote to (body of targetNote) & appendedBody
            show targetNote
        end tell
        """)
    }
}

enum FaceTimeTool {
    static func openFaceTime() throws {
        try UIAutomation.openApplication(named: "FaceTime")
    }

    static func prepareContact(
        _ contactName: String,
        accessibility: AccessibilityTreeService = .shared
    ) throws -> AccessibilityNode? {
        try openFaceTime()
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FaceTime").first else {
            return nil
        }
        let searchRoles: Set<String> = [
            kAXSearchFieldSubrole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String
        ]
        guard let search = try accessibility.findElementByDescription(
            "search contact",
            preferredRoles: searchRoles,
            application: app
        ) ?? accessibility.findElementByDescription(
            "search",
            preferredRoles: searchRoles,
            application: app
        ) else {
            return nil
        }
        try accessibility.setElementValue(nodeId: search.id, value: contactName)
        return search
    }

    static func startConfirmedCall(contactName: String) throws {
        guard let encoded = contactName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "facetime://\(encoded)")
        else {
            throw UIAutomationError.invalidURL
        }
        try UIAutomation.openURL(url)
    }
}

enum BrowserTool {
    static func focusAddressBar() throws {
        try UIAutomation.pressCommandKey("l")
    }

    static func searchWeb(_ query: String) throws {
        guard var components = URLComponents(string: "https://www.google.com/search") else {
            throw UIAutomationError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw UIAutomationError.invalidURL }
        try UIAutomation.openURL(url)
    }

    static func clickLinkByText(
        _ text: String,
        application: NSRunningApplication?,
        accessibility: AccessibilityTreeService = .shared
    ) throws -> AccessibilityNode {
        let roles: Set<String> = ["AXLink", kAXButtonRole as String]
        guard let node = try accessibility.findElementByDescription(
            text,
            preferredRoles: roles,
            application: application
        ) else {
            throw AccessibilityTreeError.elementUnavailable
        }
        try accessibility.clickElement(nodeId: node.id)
        return node
    }

    static func fillBrowserField(
        labelOrPlaceholder: String,
        value: String,
        application: NSRunningApplication?,
        accessibility: AccessibilityTreeService = .shared
    ) throws -> AccessibilityNode {
        let roles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXSearchFieldSubrole as String,
            kAXComboBoxRole as String
        ]
        guard let node = try accessibility.findElementByDescription(
            labelOrPlaceholder,
            preferredRoles: roles,
            application: application
        ) else {
            throw AccessibilityTreeError.elementUnavailable
        }
        try accessibility.setElementValue(nodeId: node.id, value: value)
        return node
    }
}

enum MessagesTool {
    static func sendMessage(contact: String, message: String) throws {
        throw UIAutomationError.unsupported("Message sending is not enabled in this release.")
    }
}
