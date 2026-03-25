import Foundation

public enum VoceKitAssembly {
    public static func makeLocalFirstCoordinator(
        captureService: AudioCaptureService,
        transcriptionEngine: TranscriptionEngine,
        cleanupEngine: CleanupEngine,
        clipboardService: ClipboardService,
        directInsertion: InsertionTransport? = nil,
        accessibilityInsertion: InsertionTransport? = nil,
        historyStorageURL: URL? = nil
    ) -> SessionCoordinator {
        _ = historyStorageURL
        _ = clipboardService
        _ = directInsertion
        _ = accessibilityInsertion
        let lexiconService = PersonalLexiconService()
        let styleService = StyleProfileService()

        return SessionCoordinator(
            captureService: captureService,
            transcriptionEngine: transcriptionEngine,
            cleanupEngine: cleanupEngine,
            lexiconService: lexiconService,
            styleProfileService: styleService
        )
    }
}
