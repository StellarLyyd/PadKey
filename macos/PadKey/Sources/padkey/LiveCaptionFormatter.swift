import Foundation

enum LiveCaptionFormatter {
    static func clean(_ transcript: String, store: PadKeyStore = .shared) -> String {
        store.applyPersonalRules(to: TextCleanup.clean(transcript))
    }

    static func batches(from text: String, wordsPerBatch: Int = 18, maxBatches: Int = 8) -> [String] {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
        guard !normalized.isEmpty else { return [] }

        let words = normalized
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        var batches: [String] = []
        var current: [String] = []

        for word in words {
            current.append(word)
            let endsSentence = word.last.map { ".?!".contains($0) } ?? false
            let reachedHardLimit = current.count >= wordsPerBatch + 6
            if (endsSentence && current.count >= 6) || reachedHardLimit {
                batches.append(current.joined(separator: " "))
                current.removeAll()
            }
        }

        if !current.isEmpty {
            batches.append(current.joined(separator: " "))
        }

        return Array(batches.suffix(maxBatches))
    }

    static func audienceText(from text: String) -> String {
        batches(from: text, wordsPerBatch: 16, maxBatches: 1).last
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
