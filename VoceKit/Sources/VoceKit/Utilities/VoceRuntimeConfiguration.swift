import Foundation

public enum VoceRuntimeConfiguration {
    public static let bundleIdentifier: String = {
        Bundle.main.bundleIdentifier ?? "io.voceapp.voce"
    }()

    public static let isDevApp: Bool = {
        bundleIdentifier == "io.voceapp.voce.dev"
    }()

    public static let supportDirectoryName: String = {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "VoceSupportDirectoryName") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String {
            let trimmed = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "Voce"
    }()

    public static let windowTitle: String = {
        if let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return supportDirectoryName
    }()

    public static let updaterFallbackFeedURLString: String? = {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "VoceFallbackFeedURL") as? String else {
            return nil
        }

        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    public static func applicationSupportDirectory(fileName: String) -> URL {
        let appSupport: URL
        if let resolved = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            appSupport = resolved
        } else {
            appSupport = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            VoceKitDiagnostics.logger.fault(
                "Application Support directory lookup failed. Falling back to \(appSupport.path, privacy: .private)."
            )
        }

        return appSupport
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
