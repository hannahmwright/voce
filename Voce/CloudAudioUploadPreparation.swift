import AVFoundation
import Foundation
import OSLog
import VoceKit

enum CloudAudioUploadPreparation {
    private static let logger = Logger(subsystem: "io.voceapp.voce", category: "CloudAudioUpload")

    static func preparedUploadURL(for originalURL: URL) async throws -> URL {
        let supportedExtensions: Set<String> = ["wav", "m4a", "mp3", "webm"]
        let ext = originalURL.pathExtension.lowercased()
        guard !ext.isEmpty, !supportedExtensions.contains(ext) else {
            logger.notice(
                "Cloud upload using captured audio without conversion [ext=\(ext, privacy: .public), bytes=\(fileSizeBytes(for: originalURL), privacy: .public)]"
            )
            return originalURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voce-cloud-upload-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let originalSize = fileSizeBytes(for: originalURL)
        let clock = ContinuousClock()
        let startedAt = clock.now
        do {
            let result = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/afconvert"),
                arguments: [
                    "-f", "m4af",
                    "-d", "aac",
                    "-b", "64000",
                    originalURL.path,
                    outputURL.path
                ]
            )
            guard result.terminationStatus == 0 else {
                let stderr = String(data: result.standardError, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "afconvert failed."
                logger.error(
                    "afconvert failed for \(originalURL.lastPathComponent, privacy: .private(mask: .hash)): \(stderr, privacy: .public)"
                )
                throw CloudDictationError.invalidAudioFile
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = attributes[.size] as? NSNumber
            guard let fileSize, fileSize.intValue > 0 else {
                logger.error(
                    "afconvert produced an empty m4a for \(originalURL.lastPathComponent, privacy: .private(mask: .hash))"
                )
                throw CloudDictationError.invalidAudioFile
            }
            let convertedSize = fileSize.intValue
            let ratio = originalSize > 0 ? Double(convertedSize) / Double(originalSize) : 0
            logger.notice(
                "Converted cloud upload audio to m4a in \(seconds(from: startedAt.duration(to: clock.now)), format: .fixed(precision: 2))s [sourceExt=\(ext, privacy: .public), sourceBytes=\(originalSize, privacy: .public), uploadBytes=\(convertedSize, privacy: .public), ratio=\(ratio, format: .fixed(precision: 2))]"
            )
        } catch {
            logger.error(
                "Failed to convert captured audio \(originalURL.lastPathComponent, privacy: .private(mask: .hash)) to m4a: \(error.localizedDescription, privacy: .public)"
            )
            try? FileManager.default.removeItem(at: outputURL)
            throw CloudDictationError.invalidAudioFile
        }

        return outputURL
    }

    static func fileSizeBytes(for url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }

    static func audioDurationMilliseconds(for url: URL) async -> Int {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds * 1_000)
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }

    mutating func appendMultipartField(named name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(
        named name: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(data)
        appendString("\r\n")
    }
}
