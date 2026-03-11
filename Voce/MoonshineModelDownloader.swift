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

    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// 5 MB per chunk — small enough to never stall, large enough to be efficient.
    private nonisolated static let chunkSize: Int64 = 5 * 1_024 * 1_024

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

    /// Downloads a file using chunked HTTP Range requests.
    /// Each chunk is a simple URLSession.data call — no streaming, no delegates, no deadlocks.
    /// Retries each chunk up to 3 times on failure.
    private nonisolated func downloadFile(
        from remoteURL: URL,
        to localURL: URL,
        fileIndex: Int,
        fileCount: Int
    ) async throws {
        // First, get the file size with a HEAD request.
        var headRequest = URLRequest(url: remoteURL)
        headRequest.httpMethod = "HEAD"
        let (_, headResponse) = try await Self.session.data(for: headRequest)

        guard let httpResponse = headResponse as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (headResponse as? HTTPURLResponse)?.statusCode ?? -1
            throw DownloadError.httpError(code)
        }

        let totalSize = httpResponse.expectedContentLength
        guard totalSize > 0 else {
            throw DownloadError.unknownFileSize
        }

        let tempURL = localURL.appendingPathExtension("download")
        try? FileManager.default.removeItem(at: tempURL)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)

        var offset: Int64 = 0
        let chunk = Self.chunkSize

        while offset < totalSize {
            try Task.checkCancellation()

            let end = min(offset + chunk - 1, totalSize - 1)

            // Retry each chunk up to 3 times.
            var chunkData: Data?
            var lastError: Error?

            for attempt in 0..<3 {
                if attempt > 0 {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                }
                do {
                    var request = URLRequest(url: remoteURL)
                    request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                    let (data, response) = try await Self.session.data(for: request)

                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard statusCode == 206 || statusCode == 200 else {
                        throw DownloadError.httpError(statusCode)
                    }
                    chunkData = data
                    lastError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }

            guard let data = chunkData else {
                handle.closeFile()
                try? FileManager.default.removeItem(at: tempURL)
                throw lastError!
            }

            handle.write(data)
            offset += Int64(data.count)

            let progress = min(Double(offset) / Double(totalSize), 1.0)
            await MainActor.run {
                status = .downloading(fileIndex: fileIndex, fileCount: fileCount, fileProgress: progress)
            }
        }

        handle.closeFile()

        // Atomic move into place.
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: tempURL, to: localURL)
    }

    private nonisolated static func cdnBaseURL(for preset: MoonshineModelPreset) -> URL {
        URL(string: "https://download.moonshine.ai/model/\(preset.directoryName)/quantized/")!
    }

    private enum DownloadError: LocalizedError {
        case httpError(Int)
        case unknownFileSize

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Server returned HTTP \(code)"
            case .unknownFileSize:
                return "Could not determine file size"
            }
        }
    }
}
