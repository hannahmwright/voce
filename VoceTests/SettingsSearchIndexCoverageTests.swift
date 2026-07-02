import Foundation
import Testing
@testable import Voce

/// Regression canaries for the settings search index.
///
/// Search results scroll to cards via anchors, and an anchor only works when it
/// exactly matches a rendered card title (`settingsCard(_:)` applies
/// `.settingsCardAnchor(title)`). These tests scan the settings source files for
/// card titles and cross-check them against `SettingsSearchResult.all`, so the
/// index can never silently go stale when cards are added, renamed, or removed.

/// Cards that intentionally have no search entry. Keep this list short and
/// justified. Note: conditionally rendered cards (e.g. "App overrides" behind
/// the cloud unlock) should still be indexed — if the anchor isn't on screen,
/// the jump degrades gracefully to selecting the right tab.
private let intentionallyUnindexedCards: Set<String> = []

/// Source files whose cards render outside the Settings window (their own tabs
/// or windows), so settings search can't scroll to them and must not index them.
private let nonSettingsWindowFiles: Set<String> = [
    "SnippetsSettingsSection.swift", // rendered in SnippetsTab
    "CleanupStyleSettingsSection.swift", // rendered in StyleTab
    "StyleTab.swift",
    "SnippetsTab.swift",
]

private func settingsSourceDirectory() -> URL {
    // VoceTests/ sits next to Voce/ in the repo.
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // VoceTests/
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("Voce")
}

/// Card titles as rendered: string literals passed to `settingsCard(`,
/// `settingsCardWithSubtitle(`, or `.settingsCardAnchor(`.
private func renderedCardTitles() throws -> Set<String> {
    let directory = settingsSourceDirectory()
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" && !nonSettingsWindowFiles.contains($0.lastPathComponent) }
    #expect(!files.isEmpty, "Expected Swift sources in \(directory.path)")

    let pattern = #"(?:settingsCard|settingsCardWithSubtitle|settingsCardAnchor)\(\s*"([^"]+)""#
    let regex = try NSRegularExpression(pattern: pattern)

    var titles: Set<String> = []
    for file in files {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let range = NSRange(source.startIndex..., in: source)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match, let titleRange = Range(match.range(at: 1), in: source) else { return }
            titles.insert(String(source[titleRange]))
        }
    }
    return titles
}

/// Row anchors as rendered: `.settingsRowAnchor("Card", "Row")` literals, in
/// the same "Card › Row" form `SettingsSearchResult.anchor` produces.
private func renderedRowAnchors() throws -> Set<String> {
    let directory = settingsSourceDirectory()
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" && !nonSettingsWindowFiles.contains($0.lastPathComponent) }

    let pattern = #"settingsRowAnchor\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\)"#
    let regex = try NSRegularExpression(pattern: pattern)

    var anchors: Set<String> = []
    for file in files {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let range = NSRange(source.startIndex..., in: source)
        regex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match,
                  let cardRange = Range(match.range(at: 1), in: source),
                  let rowRange = Range(match.range(at: 2), in: source) else { return }
            anchors.insert("\(source[cardRange]) › \(source[rowRange])")
        }
    }
    return anchors
}

@Test("Every rendered settings card is findable through search")
func everySettingsCardHasASearchEntry() throws {
    let cardTitles = try renderedCardTitles()
    #expect(cardTitles.count >= 10, "Card scan looks broken: only found \(cardTitles)")

    let indexedAnchors = Set(SettingsSearchResult.all.map(\.anchor))
    let unindexed = cardTitles
        .subtracting(indexedAnchors)
        .subtracting(intentionallyUnindexedCards)

    #expect(
        unindexed.isEmpty,
        "These settings cards have no search-index entry (add one to SettingsSearchResult.all, or list them as intentionally unindexed): \(unindexed.sorted())"
    )
}

@Test("Every search entry anchors to a card or row that actually renders")
func everySearchEntryPointsAtARealTarget() throws {
    let cardTitles = try renderedCardTitles()
    let rowAnchors = try renderedRowAnchors()

    let danglingAnchors = SettingsSearchResult.all
        .filter { entry in
            if entry.parent != nil {
                return !rowAnchors.contains(entry.anchor)
            }
            return !cardTitles.contains(entry.anchor)
        }
        .map(\.anchor)

    #expect(
        danglingAnchors.isEmpty,
        "These search entries scroll to anchors that no longer exist (rename the entry or the card/row so they match): \(danglingAnchors.sorted())"
    )
}

@Test("Every tagged settings row is findable through search")
func everyTaggedRowHasASearchEntry() throws {
    let rowAnchors = try renderedRowAnchors()
    #expect(rowAnchors.count >= 15, "Row scan looks broken: only found \(rowAnchors)")

    let indexedRowAnchors = Set(
        SettingsSearchResult.all.filter { $0.parent != nil }.map(\.anchor)
    )
    let unindexed = rowAnchors.subtracting(indexedRowAnchors)

    #expect(
        unindexed.isEmpty,
        "These tagged rows have no search-index entry (add a row entry with matching parent/title, or remove the settingsRowAnchor): \(unindexed.sorted())"
    )
}

@Test("Row entries name a parent card that exists and is grouped with it")
func rowEntriesReferenceRealParents() throws {
    let cardTitles = try renderedCardTitles().union(intentionallyUnindexedCards)
    let cardGroups = Dictionary(
        SettingsSearchResult.all
            .filter { $0.parent == nil }
            .map { ($0.title, $0.group) },
        uniquingKeysWith: { first, _ in first }
    )

    for entry in SettingsSearchResult.all where entry.parent != nil {
        let parent = entry.parent!
        #expect(cardTitles.contains(parent), "Row entry \(entry.id) names unknown parent card \"\(parent)\"")
        if let parentGroup = cardGroups[parent] {
            #expect(
                parentGroup == entry.group,
                "Row entry \(entry.id) is in group \(entry.group) but its parent card \"\(parent)\" is in \(parentGroup) — the jump would select the wrong tab"
            )
        }
    }
}

@Test("Search entries have unique ids and anchors")
func searchEntriesAreUnique() {
    let ids = SettingsSearchResult.all.map(\.id)
    let anchors = SettingsSearchResult.all.map(\.anchor)
    #expect(Set(ids).count == ids.count, "Duplicate search entry ids")
    #expect(Set(anchors).count == anchors.count, "Duplicate search entry anchors")
}

@Test("Every search entry is found by searching its own title")
func everyEntryMatchesItsOwnTitle() {
    let allGroups = Array(SettingsGroup.allCases)
    for entry in SettingsSearchResult.all {
        let results = SettingsSearchResult.matches(query: entry.title, visibleGroups: allGroups)
        #expect(
            results.contains { $0.id == entry.id },
            "Searching \"\(entry.title)\" does not return the \(entry.id) entry"
        )
    }
}
