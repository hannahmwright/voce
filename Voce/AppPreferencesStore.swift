import Foundation
import OSLog
import VoceKit

actor AppPreferencesStore {
    private let storageURL: URL
    private var hasPreparedStorageDirectory = false
    /// Set when an unreadable preferences file could not be moved or copied
    /// aside; saving would destroy it, so saves are skipped for this run.
    private var isPersistenceBlocked = false
    /// Orders snapshot saves; sequence numbers are taken synchronously by callers.
    private nonisolated let saveSequencer = LatestWinsSequencer()
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "AppPreferencesStore")
    private static let legacyModelCleanupMarkerName = ".legacy-model-cleanup-v2"

    init(storageURL: URL = AppPreferencesStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    func load() -> AppPreferences {
        Self.migrateIfNeeded()
        Self.cleanupLegacyTranscriptionModelFilesIfNeeded()
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return .default
        }

        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            let report = LossyDecodingReport()
            decoder.attach(report)
            var prefs = try decoder.decode(AppPreferences.self, from: data)
            if report.skippedValueCount > 0 {
                // Part of the file could not be read and will be dropped by the
                // next save; keep the original alongside.
                let backup = CorruptFilePreserver.preserve(fileAt: storageURL, moving: false)
                isPersistenceBlocked = backup == nil
                Self.logger.error(
                    "Preferences loaded with \(report.skippedValueCount, privacy: .public) unreadable value(s); original preserved: \(backup != nil, privacy: .public)"
                )
            }
            prefs.normalize()
            return prefs
        } catch {
            // Move the unreadable file aside so saving defaults can never
            // overwrite the user's lexicon, snippets and workflows.
            let backup = CorruptFilePreserver.preserve(fileAt: storageURL, moving: true)
            if backup == nil, FileManager.default.fileExists(atPath: storageURL.path) {
                isPersistenceBlocked = true
            }
            Self.logger.error(
                "Preferences load failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .public); original preserved at \(backup?.path ?? "nowhere", privacy: .private)"
            )
            return .default
        }
    }

    /// Saves a full preferences snapshot, latest-wins.
    ///
    /// Callers fire saves from independent `Task`s, which can reach this actor
    /// out of order. The sequence number is taken synchronously on the
    /// caller's executor (`nonisolated(nonsending)`), i.e. in the order the
    /// main-actor tasks run, before hopping to the actor; the actor then drops
    /// any snapshot older than one it has already written, so an older
    /// snapshot can never overwrite a newer one.
    nonisolated(nonsending) func save(_ preferences: AppPreferences) async {
        let sequence = saveSequencer.nextSequence()
        await write(preferences, sequence: sequence)
    }

    private func write(_ preferences: AppPreferences, sequence: UInt64) {
        guard saveSequencer.claimWrite(sequence) else {
            Self.logger.notice("Skipped stale preferences snapshot \(sequence, privacy: .public)")
            return
        }
        guard !isPersistenceBlocked else {
            Self.logger.error("Preferences save skipped: unreadable preferences file could not be preserved.")
            return
        }
        var normalized = preferences
        normalized.normalize()

        do {
            try ensureStorageDirectoryExists()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Self.logger.error(
                "Preferences save failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func ensureStorageDirectoryExists() throws {
        guard !hasPreparedStorageDirectory else { return }
        let dir = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hasPreparedStorageDirectory = true
    }

    private static func defaultStorageURL() -> URL {
        VoceRuntimeConfiguration.applicationSupportDirectory(fileName: "preferences.json")
    }

    private static func migrateIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldDir = appSupport.appendingPathComponent("WhisperClone", isDirectory: true)
        let newDir = appSupport.appendingPathComponent(VoceRuntimeConfiguration.supportDirectoryName, isDirectory: true)

        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            do {
                try fm.copyItem(at: oldDir, to: newDir)
            } catch {
                logger.error(
                    "Preferences migration copy failed from \(oldDir.path, privacy: .private) to \(newDir.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func cleanupLegacyTranscriptionModelFilesIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let voceDir = appSupport.appendingPathComponent(VoceRuntimeConfiguration.supportDirectoryName, isDirectory: true)
        let markerURL = voceDir.appendingPathComponent(legacyModelCleanupMarkerName)
        guard !fm.fileExists(atPath: markerURL.path) else { return }

        do {
            try fm.createDirectory(at: voceDir, withIntermediateDirectories: true)
        } catch {
            logger.error(
                "Legacy model cleanup could not prepare Voce directory \(voceDir.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        let legacyModelsURL = voceDir.appendingPathComponent("MoonshineModels", isDirectory: true)
        if fm.fileExists(atPath: legacyModelsURL.path) {
            do {
                try fm.removeItem(at: legacyModelsURL)
                logger.log("Removed legacy transcription models at \(legacyModelsURL.path, privacy: .private).")
            } catch {
                logger.error(
                    "Legacy model cleanup failed for \(legacyModelsURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }

        fm.createFile(atPath: markerURL.path, contents: Data())
    }
}
