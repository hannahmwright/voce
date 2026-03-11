import Foundation

/// Downloads Moonshine model files from the official CDN.
///
/// Each model preset consists of several `.ort` files plus a tokenizer and config.
/// Files are downloaded individually to `~/Library/Application Support/Voce/MoonshineModels/<preset>/`.
@MainActor
final class MoonshineModelDownloader: ObservableObject {
    enum Status: Equatable {
        case idle
        case downloading(fileIndex: Int, fileCount: Int, fileProgress: Double)
        case completed
        case failed(String)
    }

    @Published var status: Status = .idle

    private var downloadTask: Task<Void, Never>?

    /// Overall progress from 0.0 to 1.0 across all files.
    var overallProgress: Double {
        switch status {
        case .downloading(let fileIndex, let fileCount, let fileProgress):
            guard fileCount > 0 else { return 0 }
            return (Double(fileIndex) + fileProgress) / Double(fileCount)
        case .completed:
            return 1.0
        default:
            return 0
        }
    }

    /// Returns true when the given preset has all required files on disk.
    static func isModelReady(preset: MoonshineModelPreset) -> Bool {
        let path = MoonshineModelPaths.defaultModelDirectoryPath(for: preset)
        return MoonshineModelPaths.missingFiles(in: path, preset: preset).isEmpty
    }

    /// Downloads any missing files for the given preset. Skips files already on disk.
    func download(preset: MoonshineModelPreset) {
        downloadTask?.cancel()
        downloadTask = Task {
            await performDownload(preset: preset)
        }
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        status = .idle
    }

    private nonisolated func performDownload(preset: MoonshineModelPreset) async {
        let destinationDir = MoonshineModelPaths.defaultModelDirectoryPath(for: preset)
        let destinationURL = URL(fileURLWithPath: destinationDir, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        } catch {
            await MainActor.run { status = .failed("Failed to create model directory: \(error.localizedDescription)") }
            return
        }

        let missing = MoonshineModelPaths.missingFiles(in: destinationDir, preset: preset)
        guard !missing.isEmpty else {
            await MainActor.run { status = .completed }
            return
        }

        let baseURL = Self.cdnBaseURL(for: preset)

        for (index, fileName) in missing.enumerated() {
            if Task.isCancelled { await MainActor.run { status = .idle }; return }

            await MainActor.run {
                status = .downloading(fileIndex: index, fileCount: missing.count, fileProgress: 0)
            }

            let remoteURL = baseURL.appendingPathComponent(fileName)
            let localURL = destinationURL.appendingPathComponent(fileName)

            do {
                try await downloadFile(from: remoteURL, to: localURL, fileIndex: index, fileCount: missing.count)
            } catch is CancellationError {
                await MainActor.run { status = .idle }
                return
            } catch {
                await MainActor.run { status = .failed("Failed to download \(fileName): \(error.localizedDescription)") }
                return
            }
        }

        await MainActor.run { status = .completed }
    }

    private nonisolated func downloadFile(
        from remoteURL: URL,
        to localURL: URL,
        fileIndex: Int,
        fileCount: Int
    ) async throws {
        let (tempDownloadURL, response) = try await URLSession.shared.download(from: remoteURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DownloadError.httpError(code)
        }

        try Task.checkCancellation()

        let tempURL = localURL.appendingPathExtension("download")

        // Move the URLSession temp file to our staging location.
        try? FileManager.default.removeItem(at: tempURL)
        try FileManager.default.moveItem(at: tempDownloadURL, to: tempURL)

        await MainActor.run {
            status = .downloading(fileIndex: fileIndex, fileCount: fileCount, fileProgress: 1.0)
        }

        // Atomic move into place.
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    private nonisolated static func cdnBaseURL(for preset: MoonshineModelPreset) -> URL {
        // Pattern: https://download.moonshine.ai/model/{directoryName}/quantized/
        URL(string: "https://download.moonshine.ai/model/\(preset.directoryName)/quantized/")!
    }

    private enum DownloadError: LocalizedError {
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Server returned HTTP \(code)"
            }
        }
    }
}
