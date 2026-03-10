import Foundation
import MoonshineVoice

enum MoonshineModelPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiny
    case base
    case tinyStreaming
    case baseStreaming
    case smallStreaming
    case mediumStreaming

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        case .tinyStreaming:
            return "Tiny Streaming"
        case .baseStreaming:
            return "Base Streaming"
        case .smallStreaming:
            return "Small Streaming"
        case .mediumStreaming:
            return "Medium Streaming"
        }
    }

    var directoryName: String {
        switch self {
        case .tiny:
            return "tiny-en"
        case .base:
            return "base-en"
        case .tinyStreaming:
            return "tiny-streaming-en"
        case .baseStreaming:
            return "base-streaming-en"
        case .smallStreaming:
            return "small-streaming-en"
        case .mediumStreaming:
            return "medium-streaming-en"
        }
    }

    var requiredFiles: [String] {
        switch self {
        case .tiny, .base:
            return ["encoder_model.ort", "decoder_model_merged.ort", "tokenizer.bin"]
        case .tinyStreaming, .baseStreaming, .smallStreaming, .mediumStreaming:
            return [
                "adapter.ort",
                "cross_kv.ort",
                "decoder_kv.ort",
                "encoder.ort",
                "frontend.ort",
                "streaming_config.json",
                "tokenizer.bin",
            ]
        }
    }

    var moonshineArch: ModelArch {
        switch self {
        case .tiny:
            return .tiny
        case .base:
            return .base
        case .tinyStreaming:
            return .tinyStreaming
        case .baseStreaming:
            return .baseStreaming
        case .smallStreaming:
            return .smallStreaming
        case .mediumStreaming:
            return .mediumStreaming
        }
    }
}

enum MoonshineModelPaths {
    static var rootDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Murmur/MoonshineModels", isDirectory: true)
            .path
    }

    static func defaultModelDirectoryPath(for preset: MoonshineModelPreset) -> String {
        URL(fileURLWithPath: rootDirectoryPath, isDirectory: true)
            .appendingPathComponent(preset.directoryName, isDirectory: true)
            .path
    }

    static func missingFiles(in modelDirectoryPath: String, preset: MoonshineModelPreset) -> [String] {
        guard !modelDirectoryPath.isEmpty else {
            return preset.requiredFiles
        }

        let fileManager = FileManager.default
        let modelURL = URL(fileURLWithPath: modelDirectoryPath, isDirectory: true)
        return preset.requiredFiles.filter { fileName in
            !fileManager.fileExists(atPath: modelURL.appendingPathComponent(fileName).path)
        }
    }

    static func validationMessage(for modelDirectoryPath: String, preset: MoonshineModelPreset) -> String {
        guard !modelDirectoryPath.isEmpty else {
            return "Enter a model directory path"
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelDirectoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Directory not found"
        }

        let missing = missingFiles(in: modelDirectoryPath, preset: preset)
        guard !missing.isEmpty else {
            return "All required files found"
        }

        return "Missing: \(missing.joined(separator: ", "))"
    }
}
