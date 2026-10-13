import Foundation

public actor SnippetService {
    private struct CompiledSnippets: Sendable {
        var regex: NSRegularExpression
        /// Expansion keyed by lowercased trigger. App-specific snippets win over
        /// global snippets that share a trigger.
        var expansionsByTrigger: [String: String]
    }

    private var snippets: [Snippet]
    /// Compiled matchers keyed by the app bundle ID they were built for
    /// (empty string for "no app"). Invalidated on mutation.
    private var compiledCache: [String: CompiledSnippets] = [:]

    public init(snippets: [Snippet] = []) {
        self.snippets = snippets
    }

    public func upsert(_ snippet: Snippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        compiledCache.removeAll()
    }

    public func remove(id: UUID) {
        snippets.removeAll { $0.id == id }
        compiledCache.removeAll()
    }

    public func list() -> [Snippet] {
        snippets
    }

    /// Expands snippet triggers in a single left-to-right pass.
    ///
    /// - Longer triggers win over shorter triggers they contain
    ///   ("my work address" beats "my work").
    /// - App-specific snippets win over global snippets with the same trigger.
    /// - Expanded text is never re-scanned, so an expansion that happens to
    ///   contain another trigger is inserted verbatim.
    public func apply(to text: String, appContext: AppContext?) -> String {
        guard !text.isEmpty, let compiled = compiled(for: appContext?.bundleIdentifier) else {
            return text
        }

        let nsText = text as NSString
        let matches = compiled.regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let matchedTrigger = nsText.substring(with: match.range)
            guard let expansion = compiled.expansionsByTrigger[matchedTrigger.lowercased()] else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += expansion
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    private func compiled(for bundleIdentifier: String?) -> CompiledSnippets? {
        let cacheKey = bundleIdentifier ?? ""
        if let cached = compiledCache[cacheKey] {
            return cached
        }

        var appSpecific: [Snippet] = []
        var global: [Snippet] = []
        for snippet in snippets where !snippet.trigger.isEmpty {
            switch snippet.scope {
            case .global:
                global.append(snippet)
            case .app(let bundleID):
                if bundleID == bundleIdentifier {
                    appSpecific.append(snippet)
                }
            }
        }

        var expansionsByTrigger: [String: String] = [:]
        // App-specific first so they claim a trigger before a global duplicate;
        // within a scope the first-defined snippet wins (matches prior behaviour).
        for snippet in appSpecific + global {
            let key = snippet.trigger.lowercased()
            if expansionsByTrigger[key] == nil {
                expansionsByTrigger[key] = snippet.expansion
            }
        }
        guard !expansionsByTrigger.isEmpty else { return nil }

        // Regex alternation is ordered, so listing longer triggers first makes
        // the longest trigger win at any given position.
        let alternatives = expansionsByTrigger.keys
            .sorted { lhs, rhs in
                lhs.count != rhs.count ? lhs.count > rhs.count : lhs < rhs
            }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        let pattern = TextMatching.termStartBoundary + "(?:" + alternatives + ")" + TextMatching.termEndBoundary
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let compiled = CompiledSnippets(regex: regex, expansionsByTrigger: expansionsByTrigger)
        compiledCache[cacheKey] = compiled
        return compiled
    }
}
