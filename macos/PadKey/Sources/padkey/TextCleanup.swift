import Foundation

enum TextCleanup {
    static func clean(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        text = replace(pattern: "\\bnew paragraph\\b", in: text, with: "\n\n")
        text = replace(pattern: "\\bnew line\\b", in: text, with: "\n")
        text = replace(pattern: "\\bbullet point\\b", in: text, with: "\n- ")
        text = replace(pattern: "\\bbullet\\b", in: text, with: "\n- ")
        text = replace(pattern: "\\bperiod\\b", in: text, with: ".")
        text = replace(pattern: "\\bcomma\\b", in: text, with: ",")
        text = replace(pattern: "\\bquestion mark\\b", in: text, with: "?")
        text = replace(pattern: "\\bexclamation mark\\b", in: text, with: "!")
        text = replace(pattern: "\\bcolon\\b", in: text, with: ":")
        text = replace(pattern: "\\bsemicolon\\b", in: text, with: ";")
        text = replace(pattern: "\\b(um+|uh+|erm+|hmm+|you know)\\b[ ,]*", in: text, with: "")
        text = replace(pattern: "\\s+([.,?!:;])", in: text, with: "$1")
        text = replace(pattern: "[ \\t]{2,}", in: text, with: " ")
        text = replace(pattern: "[ \\t]*\\n[ \\t]*", in: text, with: "\n")
        text = replace(pattern: "\\n{2,}(-\\s)", in: text, with: "\n$1")
        text = replace(pattern: "\\n{3,}", in: text, with: "\n\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
