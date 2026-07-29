import Foundation

enum OpenAIRealtimeTranscriptionConfiguration {
    static let defaultModel = "gpt-live-transcribe"

    static func payload(
        model: String,
        localeIdentifier: String,
        hints: [String]
    ) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": model
        ]
        let language = effectiveLanguageCode(from: localeIdentifier)

        if usesModernContextFields(model: model) {
            transcription["languages"] = [language]
            let keywords = sanitizedKeywords(from: hints)
            if !keywords.isEmpty {
                transcription["keywords"] = keywords
            }
        } else {
            transcription["language"] = language
        }

        return transcription
    }

    static func sanitizedKeywords(from hints: [String]) -> [String] {
        var seen = Set<String>()
        var keywords: [String] = []

        for hint in hints {
            let keyword = hint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty,
                  keyword.rangeOfCharacter(from: CharacterSet(charactersIn: "<>\r\n")) == nil
            else {
                continue
            }

            let deduplicationKey = keyword.lowercased()
            guard seen.insert(deduplicationKey).inserted else { continue }
            keywords.append(keyword)
            if keywords.count == 200 {
                break
            }
        }

        return keywords
    }

    private static func usesModernContextFields(model: String) -> Bool {
        model == "gpt-live-transcribe" || model == "gpt-transcribe"
    }

    private static func effectiveLanguageCode(from localeIdentifier: String) -> String {
        let normalized = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return components.first.map(String.init) ?? "en"
    }
}
