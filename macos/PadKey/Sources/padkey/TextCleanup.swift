import Foundation

enum TextCleanup {
    static func clean(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = applySpokenPunctuation(to: text)
        text = removeDisfluencies(from: text)
        text = normalizeWhitespaceAndPunctuation(in: text)
        text = capitalizeSentences(in: text)
        text = fixStandalonePronounI(in: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applySpokenPunctuation(to input: String) -> String {
        var text = input
        let replacements: [(String, String)] = [
            (#"\bnew\s+paragraph\b"#, "\n\n"),
            (#"\bnew\s+line\b"#, "\n"),
            (#"\bline\s+break\b"#, "\n"),
            (#"\bbullet\s+point\b"#, "\n- "),
            (#"\bbullet\b"#, "\n- "),
            (#"\b(?:period|full\s+stop|dot)\b"#, "."),
            (#"\bcomma\b"#, ","),
            (#"\bquestion\s+mark\b"#, "?"),
            (#"\b(?:exclamation\s+(?:mark|point))\b"#, "!"),
            (#"\bcolon\b"#, ":"),
            (#"\bsemi\s*colon\b"#, ";"),
            (#"\b(?:dash|hyphen)\b"#, " - "),
            (#"\b(?:open|left)\s+paren(?:thesis)?\b"#, "("),
            (#"\b(?:close|right)\s+paren(?:thesis)?\b"#, ")"),
            (#"\b(?:open|begin)\s+quote\b"#, "\""),
            (#"\b(?:close|end)\s+quote\b"#, "\""),
            (#"\bquote\b"#, "\""),
            (#"\bslash\b"#, "/"),
            (#"\bbackslash\b"#, "\\"),
            (#"\bat\s+sign\b"#, "@"),
            (#"\bampersand\b"#, "&")
        ]
        for (pattern, replacement) in replacements {
            text = replace(pattern: pattern, in: text, with: replacement)
        }
        return text
    }

    private static func removeDisfluencies(from input: String) -> String {
        var text = input
        text = replace(pattern: #"(^|[.!?,;:\n]\s*)\b(?:um+|uh+|erm+|hmm+|you know|i mean)\b[ ,]*"#, in: text, with: "$1")
        text = replace(pattern: #"\s+\b(?:um+|uh+|erm+|hmm+)\b[ ,]*"#, in: text, with: " ")
        text = replace(pattern: #"(^|[.!?,;:\n]\s*)\blike\b[ ,]+"#, in: text, with: "$1")
        return text
    }

    private static func normalizeWhitespaceAndPunctuation(in input: String) -> String {
        var text = input
        text = replace(pattern: #"\"\s+([^"\n]+?)\s+\""#, in: text, with: "\"$1\"")
        text = replace(pattern: "\\s+([.,?!:;)])", in: text, with: "$1")
        text = replace(pattern: "([(])\\s+", in: text, with: "$1")
        text = replace(pattern: "\\s+/", in: text, with: "/")
        text = replace(pattern: "/\\s+", in: text, with: "/")
        text = replace(pattern: "\\s+@", in: text, with: "@")
        text = replace(pattern: "@\\s+", in: text, with: "@")
        text = replace(pattern: "[ \\t]{2,}", in: text, with: " ")
        text = replace(pattern: "[ \\t]*\\n[ \\t]*", in: text, with: "\n")
        text = replace(pattern: "\\n{2,}(-\\s)", in: text, with: "\n$1")
        text = replace(pattern: "\\n{3,}", in: text, with: "\n\n")
        text = replace(pattern: #"([.!?])([A-Za-z])"#, in: text, with: "$1 $2")
        text = replace(pattern: #"([,;:])([A-Za-z])"#, in: text, with: "$1 $2")
        text = replace(pattern: #"(@[A-Za-z0-9._%+-]+)\.\s+([A-Za-z]{2,})\b"#, in: text, with: "$1.$2")
        text = replace(pattern: #"\b([A-Za-z0-9-]+)\.\s+(com|org|net|ai|io|co|dev|app|edu|gov)\b"#, in: text, with: "$1.$2")
        return text
    }

    private static func capitalizeSentences(in input: String) -> String {
        var result = ""
        var shouldCapitalize = true
        var sentenceBoundaryPending = false

        for scalar in input.unicodeScalars {
            let character = Character(scalar)
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if sentenceBoundaryPending {
                if isWhitespace {
                    shouldCapitalize = true
                    result.append(character)
                    continue
                }
                sentenceBoundaryPending = false
            }

            if shouldCapitalize, CharacterSet.letters.contains(scalar) {
                result.append(String(character).uppercased())
                shouldCapitalize = false
                continue
            }

            result.append(character)
            if ".!?".unicodeScalars.contains(scalar) {
                sentenceBoundaryPending = true
            } else if CharacterSet.newlines.contains(scalar) {
                shouldCapitalize = true
            } else if !isWhitespace {
                shouldCapitalize = false
            }
        }
        return result
    }

    private static func fixStandalonePronounI(in input: String) -> String {
        var text = input
        text = replace(pattern: #"\bi\b"#, in: text, with: "I")
        text = replace(pattern: #"\bi('(?:m|ll|ve|d|re))\b"#, in: text, with: "I$1")
        text = replace(pattern: #"\bi’m\b"#, in: text, with: "I’m")
        text = replace(pattern: #"\bi’ll\b"#, in: text, with: "I’ll")
        text = replace(pattern: #"\bi’ve\b"#, in: text, with: "I’ve")
        text = replace(pattern: #"\bi’d\b"#, in: text, with: "I’d")
        return text
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
