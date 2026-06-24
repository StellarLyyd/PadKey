import AppKit
import Foundation

final class PadKeyStore {
    static let shared = PadKeyStore()

    private(set) var snapshot: PadKeySnapshot
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cachedGeminiAPIKey = ""

    private init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PadKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        fileURL = supportDirectory.appendingPathComponent("padkey-state.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601

        if
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode(PadKeySnapshot.self, from: data)
        {
            snapshot = decoded.withDefaults()
        } else {
            snapshot = PadKeySnapshot.defaults()
            save()
        }

        migrateGeminiKeyToKeychainIfNeeded()
        refreshGeminiKeyCache()
    }

    func save() {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    @discardableResult
    func addHistory(
        text: String,
        rawText: String,
        appName: String?,
        duration: TimeInterval,
        targetBundleID: String? = nil,
        inserted: Bool? = nil,
        insertionStrategy: String? = nil,
        insertionError: String? = nil,
        insertionAttempts: [InsertionAttempt]? = nil,
        recognitionEngine: String? = nil,
        usedRobustRetry: Bool? = nil,
        polishUsed: Bool? = nil,
        polishProvider: String? = nil,
        latency: PipelineLatency? = nil
    ) -> TranscriptRecord {
        let wordCount = Self.wordCount(text)
        let storedRawText = pipelineSettings.keepRawHistory ? rawText : ""
        let record = TranscriptRecord(
            id: UUID(),
            createdAt: Date(),
            text: text,
            rawText: storedRawText,
            appName: appName ?? "Unknown app",
            wordCount: wordCount,
            duration: duration,
            targetBundleID: targetBundleID,
            inserted: inserted,
            insertionStrategy: insertionStrategy,
            insertionError: insertionError,
            insertionAttempts: insertionAttempts,
            recognitionEngine: recognitionEngine,
            usedRobustRetry: usedRobustRetry,
            polishUsed: polishUsed,
            polishProvider: polishProvider,
            latency: latency
        )

        snapshot.history.insert(record, at: 0)
        snapshot.history = Array(snapshot.history.prefix(250))
        snapshot.totalWords += wordCount
        snapshot.sessions += 1
        save()
        return record
    }

    func updateHistoryInsertion(id: UUID, result: InsertionResult, latency: PipelineLatency? = nil) {
        guard let index = snapshot.history.firstIndex(where: { $0.id == id }) else { return }
        snapshot.history[index].inserted = result.inserted
        snapshot.history[index].insertionStrategy = result.strategy.displayName
        snapshot.history[index].insertionError = result.errorDescription
        snapshot.history[index].insertionAttempts = result.attempts
        snapshot.history[index].targetBundleID = result.targetBundleID
        if let latency {
            snapshot.history[index].latency = latency
        } else {
            snapshot.history[index].latency?.insertionDuration = result.elapsedSeconds
        }
        save()
    }

    @discardableResult
    func createNote(title: String = "Untitled", body: String = "") -> ScratchNote {
        let note = ScratchNote(id: UUID(), title: title, body: body, createdAt: Date(), updatedAt: Date(), pinned: false)
        snapshot.notes.insert(note, at: 0)
        save()
        return note
    }

    func updateNote(id: UUID, title: String? = nil, body: String? = nil) {
        guard let index = snapshot.notes.firstIndex(where: { $0.id == id }) else { return }
        if let title {
            snapshot.notes[index].title = title
        }
        if let body {
            snapshot.notes[index].body = body
        }
        snapshot.notes[index].updatedAt = Date()
        snapshot.notes.sort {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            return $0.updatedAt > $1.updatedAt
        }
        save()
    }

    func addDictionaryEntry(_ phrase: String, replacement: String? = nil) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !snapshot.dictionary.contains(where: { $0.phrase.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        snapshot.dictionary.insert(DictionaryEntry(id: UUID(), phrase: trimmed, replacement: replacement, createdAt: Date()), at: 0)
        save()
    }

    func addSnippet(trigger: String, expansion: String) {
        let trimmedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedExpansion = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTrigger.isEmpty, !trimmedExpansion.isEmpty else { return }
        snapshot.snippets.insert(SnippetEntry(id: UUID(), trigger: trimmedTrigger, expansion: trimmedExpansion, createdAt: Date()), at: 0)
        save()
    }

    func addTransform(name: String, prompt: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty else { return }
        let shortcutIndex = min(9, snapshot.transforms.count + 1)
        snapshot.transforms.insert(
            TransformEntry(
                id: UUID(),
                name: trimmedName,
                shortcut: "Opt \(shortcutIndex)",
                prompt: trimmedPrompt,
                enabled: true
            ),
            at: 0
        )
        save()
    }

    func updateHistoryRecord(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = snapshot.history.firstIndex(where: { $0.id == id }) else { return }
        snapshot.history[index].text = trimmed
        snapshot.history[index].wordCount = Self.wordCount(trimmed)
        save()
    }

    @discardableResult
    func addVoiceSyncSample(prompt: String, transcript: String, duration: TimeInterval) -> VoiceSyncSample {
        let sample = VoiceSyncSample(
            id: UUID(),
            createdAt: Date(),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            wordCount: Self.wordCount(transcript),
            duration: duration
        )

        var samples = voiceSyncSamples
        samples.insert(sample, at: 0)
        snapshot.voiceSyncSamples = Array(samples.prefix(24))
        save()
        return sample
    }

    func clearVoiceSyncSamples() {
        snapshot.voiceSyncSamples = []
        save()
    }

    func updatePipelineSettings(_ update: (inout PipelineSettings) -> Void) {
        var settings = pipelineSettings
        update(&settings)
        snapshot.pipelineSettings = settings.normalized()
        save()
    }

    func setGeminiAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedGeminiAPIKey = trimmed
        KeychainStore.saveGeminiAPIKey(trimmed)
        snapshot.geminiAPIKey = ""
        snapshot.geminiKeyStored = !trimmed.isEmpty
        save()
    }

    func setGeminiKeyDetails(name: String, projectName: String, projectNumber: String) {
        snapshot.geminiKeyDetails = GeminiKeyDetails(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines),
            projectNumber: projectNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        save()
    }

    func addGeminiUsage(promptCharacters: Int, responseCharacters: Int) {
        snapshot.geminiUsage.totalRequests += 1
        snapshot.geminiUsage.estimatedInputTokens += max(1, promptCharacters / 4)
        snapshot.geminiUsage.estimatedOutputTokens += max(1, responseCharacters / 4)
        snapshot.geminiUsage.lastUsedAt = Date()
        snapshot.geminiUsage.lastError = nil
        save()
    }

    func addGeminiFailure(_ message: String) {
        snapshot.geminiUsage.totalRequests += 1
        snapshot.geminiUsage.lastUsedAt = Date()
        snapshot.geminiUsage.lastError = Self.redactedGeminiError(message)
        save()
    }

    func applyPersonalRules(to text: String) -> String {
        var output = text

        for snippet in snapshot.snippets {
            if output.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(snippet.trigger) == .orderedSame
            {
                output = snippet.expansion
            }
        }

        for entry in snapshot.dictionary {
            guard let replacement = entry.replacement, !replacement.isEmpty else { continue }
            output = output.replacingOccurrences(
                of: entry.phrase,
                with: replacement,
                options: [.caseInsensitive, .diacriticInsensitive]
            )
        }

        return output
    }

    var totalWords: Int {
        max(snapshot.totalWords, snapshot.history.reduce(0) { $0 + $1.wordCount })
    }

    var averageWPM: Int {
        let spokenRecords = snapshot.history.filter { $0.duration > 0 && $0.wordCount > 0 }
        let totalWords = spokenRecords.reduce(0) { $0 + $1.wordCount }
        let totalMinutes = spokenRecords.reduce(0.0) { $0 + ($1.duration / 60.0) }
        guard totalMinutes > 0 else { return 0 }
        return Int((Double(totalWords) / totalMinutes).rounded())
    }

    var currentStreak: Int {
        let calendar = Calendar.current
        let days = Set(snapshot.history.map { calendar.startOfDay(for: $0.createdAt) })
        var date = calendar.startOfDay(for: Date())
        var streak = 0

        while days.contains(date) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }

        return streak
    }

    var appBreakdown: [(name: String, words: Int)] {
        let grouped = Dictionary(grouping: snapshot.history, by: { $0.appName })
        return grouped.map { key, records in
            (key, records.reduce(0) { $0 + $1.wordCount })
        }
        .sorted { $0.words > $1.words }
    }

    var insertionSuccessRate: Double {
        let attempted = snapshot.history.filter { $0.inserted != nil }
        guard !attempted.isEmpty else { return 0 }
        let successes = attempted.filter { $0.inserted == true }.count
        return Double(successes) / Double(attempted.count)
    }

    var medianInsertionLatency: TimeInterval? {
        let values = snapshot.history.compactMap { $0.latency?.insertionDuration }.sorted()
        guard !values.isEmpty else { return nil }
        let midpoint = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[midpoint - 1] + values[midpoint]) / 2
        }
        return values[midpoint]
    }

    var robustRetryCount: Int {
        snapshot.history.filter { $0.usedRobustRetry == true }.count
    }

    var recentInsertionDiagnostics: [TranscriptRecord] {
        Array(snapshot.history.prefix(12))
    }

    var geminiAPIKey: String {
        cachedGeminiAPIKey
    }

    var hasGeminiAPIKey: Bool {
        snapshot.geminiKeyStored == true || !cachedGeminiAPIKey.isEmpty
    }

    var pipelineSettings: PipelineSettings {
        (snapshot.pipelineSettings ?? .defaults).normalized()
    }

    var voiceSyncSamples: [VoiceSyncSample] {
        snapshot.voiceSyncSamples ?? []
    }

    var voiceSyncPrompt: String {
        var parts: [String] = []

        let preferredSpellings = snapshot.dictionary
            .map { $0.replacement?.isEmpty == false ? $0.replacement! : $0.phrase }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(24)

        if !preferredSpellings.isEmpty {
            parts.append("Preferred spellings and names: \(preferredSpellings.joined(separator: ", ")).")
        }

        let sampleText = voiceSyncSamples
            .prefix(8)
            .map(\.transcript)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if !sampleText.isEmpty {
            parts.append("Recent phrasing examples: \(sampleText.joined(separator: " | "))")
        }

        let prompt = parts.joined(separator: " ")
        guard prompt.count > 900 else { return prompt }
        return "\(prompt.prefix(900))"
    }

    var maskedGeminiAPIKey: String {
        let key = cachedGeminiAPIKey
        guard !key.isEmpty else { return hasGeminiAPIKey ? "Stored" : "Not configured" }
        guard key.count > 8 else { return hasGeminiAPIKey ? "Stored" : "Not configured" }
        return "\(key.prefix(4))...\(key.suffix(4))"
    }

    private func refreshGeminiKeyCache() {
        let key = KeychainStore.readGeminiAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cachedGeminiAPIKey = key
        let stored = !key.isEmpty
        if snapshot.geminiKeyStored != stored {
            snapshot.geminiKeyStored = stored
            save()
        }
    }

    private func migrateGeminiKeyToKeychainIfNeeded() {
        let legacyKey = snapshot.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return }
        cachedGeminiAPIKey = legacyKey
        KeychainStore.saveGeminiAPIKey(legacyKey)
        snapshot.geminiAPIKey = ""
        snapshot.geminiKeyStored = true
        save()
    }

    static func wordCount(_ text: String) -> Int {
        text
            .split { $0.isWhitespace || $0.isNewline }
            .filter { !$0.isEmpty }
            .count
    }

    private static func redactedGeminiError(_ message: String) -> String {
        let redacted = message.replacingOccurrences(
            of: #"AIza[0-9A-Za-z_\-]+"#,
            with: "[redacted-key]",
            options: .regularExpression
        )
        guard redacted.count > 220 else { return redacted }
        return "\(redacted.prefix(220))..."
    }
}

struct PadKeySnapshot: Codable {
    var totalWords: Int
    var sessions: Int
    var history: [TranscriptRecord]
    var notes: [ScratchNote]
    var dictionary: [DictionaryEntry]
    var snippets: [SnippetEntry]
    var transforms: [TransformEntry]
    var voiceSyncSamples: [VoiceSyncSample]?
    var pipelineSettings: PipelineSettings?
    var geminiAPIKey: String
    var geminiKeyStored: Bool?
    var geminiKeyDetails: GeminiKeyDetails?
    var geminiUsage: GeminiUsage

    static func defaults() -> PadKeySnapshot {
        PadKeySnapshot(
            totalWords: 0,
            sessions: 0,
            history: [],
            notes: [
                ScratchNote(id: UUID(), title: "Open thoughts", body: "Use this scratchpad for drafts, prompts, and notes you want to polish before sending.", createdAt: Date(), updatedAt: Date(), pinned: true)
            ],
            dictionary: [
                DictionaryEntry(id: UUID(), phrase: "PadKey", replacement: nil, createdAt: Date()),
                DictionaryEntry(id: UUID(), phrase: "Codex", replacement: nil, createdAt: Date()),
                DictionaryEntry(id: UUID(), phrase: "Gemini", replacement: nil, createdAt: Date())
            ],
            snippets: [
                SnippetEntry(id: UUID(), trigger: "organize thoughts prompt", expansion: "Organize these unstructured thoughts into a clear, polished version with headings, decisions, and next actions.", createdAt: Date()),
                SnippetEntry(id: UUID(), trigger: "rewrite prompt", expansion: "Rewrite this to be concise, warm, and easy to act on.", createdAt: Date())
            ],
            transforms: [
                TransformEntry(id: UUID(), name: "Polish", shortcut: "Opt 1", prompt: "Improve clarity, grammar, punctuation, and concision while preserving meaning.", enabled: true),
                TransformEntry(id: UUID(), name: "Prompt Engineer", shortcut: "Opt 2", prompt: "Turn this into a clear, structured prompt with context, task, constraints, and output format.", enabled: true),
                TransformEntry(id: UUID(), name: "Make a List", shortcut: "Opt 3", prompt: "Turn this into a short, scannable list.", enabled: true)
            ],
            voiceSyncSamples: [],
            pipelineSettings: .defaults,
            geminiAPIKey: "",
            geminiKeyStored: false,
            geminiKeyDetails: nil,
            geminiUsage: GeminiUsage(totalRequests: 0, estimatedInputTokens: 0, estimatedOutputTokens: 0, lastUsedAt: nil, lastError: nil)
        )
    }

    func withDefaults() -> PadKeySnapshot {
        var copy = self
        let defaults = PadKeySnapshot.defaults()
        if copy.dictionary.isEmpty { copy.dictionary = defaults.dictionary }
        if copy.snippets.isEmpty { copy.snippets = defaults.snippets }
        if copy.transforms.isEmpty { copy.transforms = defaults.transforms }
        if copy.voiceSyncSamples == nil { copy.voiceSyncSamples = [] }
        if copy.pipelineSettings == nil { copy.pipelineSettings = .defaults }
        copy.pipelineSettings = copy.pipelineSettings?.normalized()
        if copy.geminiKeyStored == nil { copy.geminiKeyStored = !copy.geminiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let details = copy.geminiKeyDetails {
            let isLegacyPlaceholder = details.name == "PADKEY API Key"
                && !details.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !details.projectNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let isEmpty = details.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && details.projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && details.projectNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isLegacyPlaceholder || isEmpty {
                copy.geminiKeyDetails = nil
            }
        }
        return copy
    }
}

struct TranscriptRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    var text: String
    var rawText: String
    let appName: String
    var wordCount: Int
    let duration: TimeInterval
    var targetBundleID: String?
    var inserted: Bool?
    var insertionStrategy: String?
    var insertionError: String?
    var insertionAttempts: [InsertionAttempt]?
    var recognitionEngine: String?
    var usedRobustRetry: Bool?
    var polishUsed: Bool?
    var polishProvider: String?
    var latency: PipelineLatency?
}

struct ScratchNote: Codable, Identifiable {
    let id: UUID
    var title: String
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var pinned: Bool
}

struct DictionaryEntry: Codable, Identifiable {
    let id: UUID
    var phrase: String
    var replacement: String?
    let createdAt: Date
}

struct SnippetEntry: Codable, Identifiable {
    let id: UUID
    var trigger: String
    var expansion: String
    let createdAt: Date
}

struct TransformEntry: Codable, Identifiable {
    let id: UUID
    var name: String
    var shortcut: String
    var prompt: String
    var enabled: Bool
}

struct VoiceSyncSample: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let prompt: String
    let transcript: String
    let wordCount: Int
    let duration: TimeInterval
}

struct PipelineSettings: Codable {
    var recognitionEngine: RecognitionEngine?
    var sessionTimeoutSeconds: Int
    var autoPolishAfterDictation: Bool
    var commandModeEnabled: Bool
    var copyFallbackEnabled: Bool
    var keepRawHistory: Bool
    var robustRetryEnabled: Bool?
    var robustRetryMinDurationSeconds: Double?

    static let defaults = PipelineSettings(
        recognitionEngine: .autoRobust,
        sessionTimeoutSeconds: 90,
        autoPolishAfterDictation: false,
        commandModeEnabled: true,
        copyFallbackEnabled: true,
        keepRawHistory: true,
        robustRetryEnabled: true,
        robustRetryMinDurationSeconds: 2.0
    )

    var effectiveRecognitionEngine: RecognitionEngine {
        recognitionEngine ?? .autoRobust
    }

    var effectiveRobustRetryEnabled: Bool {
        robustRetryEnabled ?? true
    }

    var effectiveRobustRetryMinDurationSeconds: Double {
        robustRetryMinDurationSeconds ?? 2.0
    }

    func normalized() -> PipelineSettings {
        var copy = self
        if copy.recognitionEngine == nil {
            copy.recognitionEngine = Self.defaults.recognitionEngine
        }
        if copy.robustRetryEnabled == nil {
            copy.robustRetryEnabled = Self.defaults.robustRetryEnabled
        }
        if copy.robustRetryMinDurationSeconds == nil || copy.effectiveRobustRetryMinDurationSeconds < 0 {
            copy.robustRetryMinDurationSeconds = Self.defaults.robustRetryMinDurationSeconds
        }
        let allowedTimeouts = [0, 30, 60, 90, 120, 180]
        if !allowedTimeouts.contains(copy.sessionTimeoutSeconds) {
            copy.sessionTimeoutSeconds = Self.defaults.sessionTimeoutSeconds
        }
        return copy
    }
}

struct GeminiUsage: Codable {
    var totalRequests: Int
    var estimatedInputTokens: Int
    var estimatedOutputTokens: Int
    var lastUsedAt: Date?
    var lastError: String?
}

struct GeminiKeyDetails: Codable {
    var name: String
    var projectName: String
    var projectNumber: String
}
