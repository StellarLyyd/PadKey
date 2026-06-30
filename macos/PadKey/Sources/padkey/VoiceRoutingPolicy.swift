import Foundation

enum VoiceRouteDestination: String, Equatable {
    case agent
    case dictation
}

struct VoiceRoutingDecision: Equatable {
    let destination: VoiceRouteDestination
    let reason: String
    let parsedCommand: ParsedMacCommand

    var routesToAgent: Bool {
        destination == .agent
    }
}

enum VoiceRoutingPolicy {
    static func route(
        transcript: String,
        commandModeEnabled: Bool,
        hasFocusedTextTarget: Bool,
        targetIsPasteboardOnly: Bool = false,
        agentFallbackEnabled: Bool = true
    ) -> VoiceRoutingDecision {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = MacCommandParser.parse(trimmed)

        guard commandModeEnabled else {
            return VoiceRoutingDecision(
                destination: .dictation,
                reason: "Command mode is off",
                parsedCommand: parsed
            )
        }

        guard !trimmed.isEmpty else {
            return VoiceRoutingDecision(
                destination: .dictation,
                reason: "No transcript",
                parsedCommand: parsed
            )
        }

        if parsed != .unknown {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "Recognized agent intent",
                parsedCommand: parsed
            )
        }

        if MacCommandParser.hasWakePhrase(trimmed) {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "PadKey was addressed",
                parsedCommand: parsed
            )
        }

        if isAgentAddress(trimmed) || isQuestionLike(trimmed) {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "Conversational agent speech",
                parsedCommand: parsed
            )
        }

        if hasFocusedTextTarget && isLikelyDictation(trimmed) {
            return VoiceRoutingDecision(
                destination: .dictation,
                reason: targetIsPasteboardOnly ? "Prose with pasteboard-only text context" : "Prose with focused text target",
                parsedCommand: parsed
            )
        }

        if agentFallbackEnabled && !hasFocusedTextTarget {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "No focused text target; using agent fallback",
                parsedCommand: parsed
            )
        }

        if agentFallbackEnabled && targetIsPasteboardOnly && isShortOrImperative(trimmed) {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "Pasteboard-only target with short instruction",
                parsedCommand: parsed
            )
        }

        if agentFallbackEnabled && isShortOrImperative(trimmed) {
            return VoiceRoutingDecision(
                destination: .agent,
                reason: "Short agent-like utterance",
                parsedCommand: parsed
            )
        }

        return VoiceRoutingDecision(
            destination: .dictation,
            reason: "Dictation fallback",
            parsedCommand: parsed
        )
    }

    private static func isAgentAddress(_ text: String) -> Bool {
        let lower = normalized(text)
        return lower.contains("padkey")
            || lower.contains("pad key")
            || lower.range(of: #"^(?:can|could|would|will)\s+you\b"#, options: .regularExpression) != nil
            || lower.range(of: #"^i\s+(?:need|want|would like)\s+you\s+to\b"#, options: .regularExpression) != nil
            || lower.range(of: #"^(?:help me|tell me|explain|answer this)\b"#, options: .regularExpression) != nil
    }

    private static func isQuestionLike(_ text: String) -> Bool {
        let lower = normalized(text)
        if lower.hasSuffix("?") {
            return true
        }
        return lower.range(
            of: #"^(?:what|why|how|who|when|where|which|should i|do you|are you|is this|can this|could this)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isShortOrImperative(_ text: String) -> Bool {
        let lower = normalized(text)
        if wordCount(lower) <= 8 {
            return true
        }
        return lower.range(
            of: #"^(?:do|fix|continue|finish|build|implement|revise|change|update|test|run|debug|inspect|analyze|control|use|show|open|close|click|press|choose|select|find|make|create|start|search|switch|move|resize)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func isLikelyDictation(_ text: String) -> Bool {
        let lower = normalized(text)
        if isQuestionLike(lower) || isAgentAddress(lower) {
            return false
        }
        if lower.range(
            of: #"^(?:open|launch|start|switch|click|press|select|choose|scroll|copy|paste|go back|close|new note|make new|create new|find|fill|focus|type)\b"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        let words = wordCount(lower)
        if words >= 9 {
            return true
        }
        if text.range(of: #"[.!?,;:]"#, options: .regularExpression) != nil, words >= 5 {
            return true
        }
        return lower.range(
            of: #"^(?:i|we|this|that|the|a|an|my|our|it|they|there)\b"#,
            options: .regularExpression
        ) != nil && words >= 6
    }

    private static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
