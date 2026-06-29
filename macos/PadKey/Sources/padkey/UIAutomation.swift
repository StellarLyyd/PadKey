import AppKit
import Foundation

enum UIAutomationError: LocalizedError {
    case appNotFound(String)
    case ambiguousApp(String, [String])
    case launchFailed(String)
    case appleScriptFailed(String)
    case invalidURL
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "\(name) is not installed on this Mac."
        case .ambiguousApp(let name, let options): return "\(name) matches more than one app: \(options.joined(separator: ", "))."
        case .launchFailed(let name): return "\(name) could not be opened."
        case .appleScriptFailed(let message): return message
        case .invalidURL: return "The requested address is invalid."
        case .unsupported(let message): return message
        }
    }
}

enum UIAutomation {
    struct ResolvedApplication: Equatable {
        let displayName: String
        let url: URL
    }

    @discardableResult
    static func openApplication(named name: String) throws -> NSRunningApplication? {
        let resolved = try resolveApplication(named: name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [resolved.url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UIAutomationError.launchFailed(resolved.displayName)
        }
        guard process.terminationStatus == 0 else { throw UIAutomationError.appNotFound(name) }
        return NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.caseInsensitiveCompare(resolved.displayName) == .orderedSame
        }
    }

    static func resolveApplication(named rawName: String) throws -> ResolvedApplication {
        let query = normalizedAppName(rawName)
        let aliases: [String: [String]] = [
            "chrome": ["google chrome"],
            "browser": ["google chrome", "safari"],
            "settings": ["system settings"],
            "system preferences": ["system settings"],
            "facetime": ["facetime"],
            "x code": ["xcode"],
            "vs code": ["visual studio code"],
            "music": ["music"],
            "apple music": ["music"]
        ]
        let candidateQueries = aliases[query] ?? [query]
        let apps = installedApplications()

        var matches: [ResolvedApplication] = []
        for candidate in candidateQueries {
            matches.append(contentsOf: apps.filter { app in
                let normalized = normalizedAppName(app.displayName)
                return normalized == candidate || normalized.hasSuffix(" \(candidate)")
            })
        }
        if matches.isEmpty {
            matches = apps.filter { normalizedAppName($0.displayName).contains(query) }
        }

        let unique = Dictionary(grouping: matches, by: { $0.url.path })
            .compactMap { $0.value.first }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        guard !unique.isEmpty else { throw UIAutomationError.appNotFound(rawName) }
        if unique.count > 1 {
            let names = unique.prefix(5).map(\.displayName)
            throw UIAutomationError.ambiguousApp(rawName, Array(names))
        }
        return unique[0]
    }

    private static func installedApplications() -> [ResolvedApplication] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        var seen = Set<String>()
        var apps: [ResolvedApplication] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "app" {
                guard seen.insert(url.path).inserted else { continue }
                apps.append(ResolvedApplication(displayName: url.deletingPathExtension().lastPathComponent, url: url))
            }
        }
        return apps
    }

    private static func normalizedAppName(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"^(?:the\s+)?(?:app\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+app$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
