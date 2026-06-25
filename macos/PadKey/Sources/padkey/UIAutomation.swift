import AppKit
import Foundation

enum UIAutomationError: LocalizedError {
    case appNotFound(String)
    case launchFailed(String)
    case appleScriptFailed(String)
    case invalidURL
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "\(name) is not installed on this Mac."
        case .launchFailed(let name): return "\(name) could not be opened."
        case .appleScriptFailed(let message): return message
        case .invalidURL: return "The requested address is invalid."
        case .unsupported(let message): return message
        }
    }
}

enum UIAutomation {
    @discardableResult
    static func openApplication(named name: String) throws -> NSRunningApplication? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UIAutomationError.launchFailed(name)
        }
        guard process.terminationStatus == 0 else { throw UIAutomationError.appNotFound(name) }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    static func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            throw UIAutomationError.appleScriptFailed("The Mac automation script could not be prepared.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "macOS rejected the requested app automation."
            throw UIAutomationError.appleScriptFailed(message)
        }
        return result
    }

    static func pressCommandKey(_ key: String) throws {
        let escaped = appleScriptString(key)
        _ = try runAppleScript("""
        tell application "System Events"
            keystroke "\(escaped)" using command down
        end tell
        """)
    }

    static func scroll(direction: String) throws {
        let keyCode: Int
        switch direction.lowercased() {
        case "up":
            keyCode = 116 // page up
        case "left":
            keyCode = 123 // left arrow
        case "right":
            keyCode = 124 // right arrow
        default:
            keyCode = 121 // page down
        }
        _ = try runAppleScript("""
        tell application "System Events"
            key code \(keyCode)
        end tell
        """)
    }

    static func openURL(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw UIAutomationError.invalidURL }
    }

    static func appleScriptString(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func htmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
