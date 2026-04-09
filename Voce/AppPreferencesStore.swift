import Foundation
import OSLog

actor AppPreferencesStore {
    private let storageURL: URL
    private var hasPreparedStorageDirectory = false
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
            var prefs = try decoder.decode(AppPreferences.self, from: data)
            prefs.normalize()
            return prefs
        } catch {
            Self.logger.error(
                "Preferences load failed for path \(self.storageURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)"
            )
            return .default
        }
    }

    func save(_ preferences: AppPreferences) {
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
        let appSupport: URL
        if let resolved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = resolved
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            logger.fault(
                "Application Support directory lookup failed. Falling back to \(appSupport.path, privacy: .private)."
            )
        }
        return appSupport
            .appendingPathComponent("Voce", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    private static func migrateIfNeeded() {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let oldDir = appSupport.appendingPathComponent("WhisperClone", isDirectory: true)
        let newDir = appSupport.appendingPathComponent("Voce", isDirectory: true)

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

        let voceDir = appSupport.appendingPathComponent("Voce", isDirectory: true)
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
