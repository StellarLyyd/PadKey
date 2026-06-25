import Foundation

enum InsertionStrategy: String, Codable {
    case accessibilitySelectedText
    case accessibilityValueReplacement
    case accessibilityCurrentFocus
    case globalUnicodeTyping
    case unicodeTyping
    case systemEventsPaste
    case pasteboard
    case savedOnly
    case none

    var displayName: String {
        switch self {
        case .accessibilitySelectedText: return "AX selected text"
        case .accessibilityValueReplacement: return "AX value range"
        case .accessibilityCurrentFocus: return "AX current focus"
        case .globalUnicodeTyping: return "Global keyboard typing"
        case .unicodeTyping: return "Keyboard typing"
        case .systemEventsPaste: return "System Events paste"
        case .pasteboard: return "Clipboard paste"
        case .savedOnly: return "Saved only"
        case .none: return "None"
        }
    }
}

struct InsertionAttempt: Codable {
    var strategy: InsertionStrategy
    var succeeded: Bool
    var detail: String
}

struct InsertionResult: Codable {
    var inserted: Bool
    var strategy: InsertionStrategy
    var targetAppName: String
    var targetBundleID: String?
    var targetRole: String?
    var attempts: [InsertionAttempt]
    var errorDescription: String?
    var elapsedSeconds: TimeInterval

    static func savedOnly(appName: String, bundleID: String?, reason: String) -> InsertionResult {
        InsertionResult(
            inserted: false,
            strategy: .savedOnly,
            targetAppName: appName,
            targetBundleID: bundleID,
            targetRole: nil,
            attempts: [InsertionAttempt(strategy: .savedOnly, succeeded: true, detail: reason)],
            errorDescription: reason,
            elapsedSeconds: 0
        )
    }
}

struct PipelineLatency: Codable {
    var recordingDuration: TimeInterval?
    var asrDuration: TimeInterval?
    var polishDuration: TimeInterval?
    var insertionDuration: TimeInterval?
    var totalDuration: TimeInterval?
}

struct DictationResult {
    var transcript: String
    var engine: RecognitionEngine
    var usedRobustRetry: Bool
    var fallbackReason: String?
    var asrDuration: TimeInterval?
    var inputSource: PadKeyInputSource? = nil
    var audioURL: URL? = nil
}

enum TranscriptQuality {
    static func shouldRetryWithRobustASR(_ transcript: String, duration: TimeInterval?, liveTranscript: String = "") -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveTrimmed = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return true
        }

        let seconds = duration ?? 0
        if seconds >= 2.0 && trimmed.count < 4 {
            return true
        }

        let lowercased = trimmed.lowercased()
        let failureNeedles = [
            "thank you for watching",
            "thanks for watching",
            "subscribe",
            "music",
            "[music]",
            "inaudible",
            "foreign",
            "you"
        ]

        if seconds >= 4.0, failureNeedles.contains(where: { lowercased == $0 || lowercased.contains("[\($0)]") }) {
            return true
        }

        let words = lowercased
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if words.count >= 5 {
            let grouped = Dictionary(grouping: words, by: { $0 })
            let mostRepeated = grouped.values.map(\.count).max() ?? 0
            if Double(mostRepeated) / Double(words.count) >= 0.72 {
                return true
            }
        }

        if !liveTrimmed.isEmpty, trimmed.count < max(6, liveTrimmed.count / 5) {
            return true
        }

        return false
    }
}

struct PolishContext {
    var targetAppName: String?
    var targetBundleID: String?

    var category: String {
        let combined = "\(targetAppName ?? "") \(targetBundleID ?? "")".lowercased()
        if combined.contains("mail") || combined.contains("gmail") || combined.contains("outlook") {
            return "email"
        }
        if combined.contains("slack") || combined.contains("discord") || combined.contains("messages") {
            return "chat"
        }
        if combined.contains("xcode") || combined.contains("cursor") || combined.contains("code") || combined.contains("terminal") {
            return "code editor"
        }
        if combined.contains("safari") || combined.contains("chrome") || combined.contains("firefox") || combined.contains("arc") {
            return "browser"
        }
        if combined.contains("notes") || combined.contains("textedit") {
            return "notes"
        }
        return "general writing"
    }

    static let unknown = PolishContext(targetAppName: nil, targetBundleID: nil)
}

struct PolishResult {
    var text: String
    var usedAI: Bool
    var provider: String
    var duration: TimeInterval
    var fallbackReason: String?
}

enum PolishPromptBuilder {
    static func prompt(input: String, instruction: String, voiceContext: String, context: PolishContext) -> String {
        var sections = [
            "Rewrite instruction:\n\(instruction)",
            "Target context:\nApp: \(context.targetAppName ?? "Unknown")\nBundle: \(context.targetBundleID ?? "Unknown")\nCategory: \(context.category)"
        ]

        if !voiceContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Voice profile:\n\(voiceContext)")
        }

        sections.append("Dictated text:\n\(input)")
        return sections.joined(separator: "\n\n")
    }
}
