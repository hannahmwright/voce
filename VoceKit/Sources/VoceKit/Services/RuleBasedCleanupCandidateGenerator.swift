import Foundation

public struct RuleBasedCleanupCandidateGenerator: Sendable {
    public init() {}

    public func generateCandidates(
        raw: RawTranscript,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> [CleanupCandidate] {
        let engine = RuleBasedCleanupEngine()
        // Personal lexicon corrections are explicit user choices, so even the
        // minimal-change candidate carries them; otherwise the ranker could pick
        // the uncorrected text and silently drop the user's dictionary.
        let lexiconCorrected = engine.applyLexicon(text: raw.text, lexicon: lexicon)
        var candidates: [CleanupCandidate] = [
            CleanupCandidate(
                text: lexiconCorrected.text,
                appliedEdits: lexiconCorrected.edits,
                removedFillers: [],
                rulePathID: "raw-pass-through"
            )
        ]
        candidates.append(
            engine.buildCandidate(
                raw: raw,
                profile: profile,
                lexicon: lexicon,
                rulePathID: "configured-profile"
            )
        )

        return deduplicated(candidates)
    }

    private func deduplicated(_ candidates: [CleanupCandidate]) -> [CleanupCandidate] {
        var seenTexts: Set<String> = []
        var result: [CleanupCandidate] = []
        result.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard !seenTexts.contains(candidate.text) else { continue }
            seenTexts.insert(candidate.text)
            result.append(candidate)
        }

        return result
    }
}
