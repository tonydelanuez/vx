import Foundation

struct SpokenSubmitCommandResult: Equatable {
    let textToInsert: String
    let shouldSubmit: Bool

    static func textOnly(_ text: String) -> SpokenSubmitCommandResult {
        SpokenSubmitCommandResult(textToInsert: text, shouldSubmit: false)
    }
}

enum SpokenSubmitCommandDetector {
    static func detect(in text: String, phrases: [String]) -> SpokenSubmitCommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .textOnly(trimmed) }

        for phrase in normalizedPhrases(phrases) {
            guard let regex = trailingPhraseRegex(for: phrase) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: nsRange),
                  match.range.location != NSNotFound,
                  let prefixRange = Range(match.range(at: 1), in: trimmed) else { continue }

            let textToInsert = String(trimmed[prefixRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
            return SpokenSubmitCommandResult(textToInsert: textToInsert, shouldSubmit: true)
        }

        return .textOnly(trimmed)
    }

    static func parsePhrases(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedPhrases(_ phrases: [String]) -> [String] {
        phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    private static func trailingPhraseRegex(for phrase: String) -> NSRegularExpression? {
        let words = phrase
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let phrasePattern = words
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let pattern = "^\\s*(.*?)\\s*\\b\(phrasePattern)\\b\\s*[.!?]*\\s*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
