import Foundation

public enum HistoryStoreError: Error, LocalizedError {
    case missingEntry
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .missingEntry:
            return "Transcript entry not found"
        case .persistenceFailed:
            return "Unable to persist transcript history"
        }
    }
}

public actor HistoryStore: HistoryStoreProtocol {
    private var entries: [TranscriptEntry] = []
    private var hasLoaded = false
    /// Set when an unreadable history file could not be preserved; persisting
    /// would then destroy it, so writes fail instead.
    private var isPersistenceBlocked = false
    private var hasPreparedStorageDirectory = false
    private let storageURL: URL
    private let clipboardService: ClipboardService
    private let maxEntries: Int

    public init(
        storageURL: URL? = nil,
        clipboardService: ClipboardService,
        maxEntries: Int = 500
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.clipboardService = clipboardService
        self.maxEntries = maxEntries
    }

    private func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            let report = LossyDecodingReport()
            entries = try Self.loadEntries(from: storageURL, report: report)
            if report.skippedValueCount > 0 {
                // Some entries/fields were unreadable; keep the original file
                // before the next persist rewrites it without them.
                isPersistenceBlocked = CorruptFilePreserver.preserve(fileAt: storageURL, moving: false) == nil
            }
        } catch {
            // Never let the next append overwrite an unreadable history file.
            entries = []
            if CorruptFilePreserver.preserve(fileAt: storageURL, moving: true) == nil {
                isPersistenceBlocked = FileManager.default.fileExists(atPath: storageURL.path)
            }
        }
    }

    public func append(entry: TranscriptEntry) async throws {
        ensureLoaded()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        try persist()
    }

    public func update(entry: TranscriptEntry) async throws {
        ensureLoaded()
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            throw HistoryStoreError.missingEntry
        }
        entries[index] = entry
        try persist()
    }

    public func delete(entryID: UUID) async throws {
        ensureLoaded()
        entries.removeAll { $0.id == entryID }
        try persist()
    }

    public func recent(limit: Int) async -> [TranscriptEntry] {
        ensureLoaded()
        guard limit > 0 else { return [] }
        return Array(entries.prefix(limit))
    }

    public func search(query: String) async -> [TranscriptEntry] {
        ensureLoaded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        return entries.filter {
            $0.rawText.localizedCaseInsensitiveContains(trimmed)
            || $0.cleanText.localizedCaseInsensitiveContains(trimmed)
            || ($0.sourceText?.localizedCaseInsensitiveContains(trimmed) ?? false)
            || $0.appBundleID.localizedCaseInsensitiveContains(trimmed)
            || ($0.aiWorkflowName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    public func retry(
        entryID: UUID,
        using cleanupEngine: CleanupEngine,
        profile: StyleProfile,
        lexicon: PersonalLexicon
    ) async throws -> CleanTranscript {
        ensureLoaded()
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw HistoryStoreError.missingEntry
        }

        let raw = RawTranscript(text: entry.rawText, durationMS: 0)
        let retried = try await cleanupEngine.cleanup(raw: raw, profile: profile, lexicon: lexicon)

        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            var updated = entries[index]
            updated.cleanText = retried.text
            entries[index] = updated
            try persist()
        }

        return retried
    }

    @discardableResult
    public func pasteLast() async throws -> TranscriptEntry? {
        ensureLoaded()
        guard let latest = entries.first else {
            return nil
        }

        let text = latest.cleanText.isEmpty ? latest.rawText : latest.cleanText
        try await clipboardService.setString(text)
        return latest
    }

    private func persist() throws {
        guard !isPersistenceBlocked else {
            throw HistoryStoreError.persistenceFailed
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        encoder.dateEncodingStrategy = .iso8601

        do {
            try ensureStorageDirectoryExists()
            let data = try encoder.encode(entries)
            try data.write(to: storageURL, options: [.atomic])
        } catch {
            throw HistoryStoreError.persistenceFailed
        }
    }

    private func ensureStorageDirectoryExists() throws {
        guard !hasPreparedStorageDirectory else { return }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hasPreparedStorageDirectory = true
    }

    private static func loadEntries(from url: URL, report: LossyDecodingReport) throws -> [TranscriptEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.attach(report)
        // Element-by-element so one bad entry does not discard the whole history.
        return try decoder.decode(LossyDecodableArray<TranscriptEntry>.self, from: data).elements
    }

    private static func defaultStorageURL() -> URL {
        VoceRuntimeConfiguration.applicationSupportDirectory(fileName: "transcript-history.json")
    }
}
