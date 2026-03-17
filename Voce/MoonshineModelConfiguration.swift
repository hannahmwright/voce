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

    static var voceSupportedOptions: [MoonshineModelPreset] {
        [.tinyStreaming, .smallStreaming, .mediumStreaming]
    }

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

    var isVoceSupported: Bool {
        Self.voceSupportedOptions.contains(self)
    }

    var pickerTitle: String {
        switch self {
        case .tinyStreaming:
            return "Tiny Streaming"
        case .baseStreaming:
            return "Base Streaming"
        case .smallStreaming:
            return "Small Streaming"
        case .mediumStreaming:
            return "Medium Streaming"
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        }
    }

    var pickerLabel: String {
        switch self {
        case .tinyStreaming:
            return "Tiny Streaming - Lightest"
        case .baseStreaming:
            return "Base Streaming - Balanced"
        case .smallStreaming:
            return "Small Streaming - Recommended"
        case .mediumStreaming:
            return "Medium Streaming - Best Accuracy"
        case .tiny:
            return "Tiny"
        case .base:
            return "Base"
        }
    }

    var approxDownloadSize: String {
        switch self {
        case .tinyStreaming:
            return "~50 MB"
        case .baseStreaming:
            return "~95 MB"
        case .smallStreaming:
            return "~160 MB"
        case .mediumStreaming:
            return "~320 MB"
        case .tiny:
            return "~40 MB"
        case .base:
            return "~80 MB"
        }
    }

    var selectionSummary: String {
        switch self {
        case .tinyStreaming:
            return "Fastest and lightest. Best for older Macs or if you want the smallest memory footprint."
        case .baseStreaming:
            return "A middle-ground option with a bit more accuracy than Tiny, while staying fairly light."
        case .smallStreaming:
            return "The best default for most people. Good live accuracy without getting too heavy."
        case .mediumStreaming:
            return "Highest accuracy in Voce's live lineup, but it uses the most CPU and memory."
        case .tiny, .base:
            return "Legacy non-streaming preset."
        }
    }

    var selectionFootnote: String {
        switch self {
        case .tinyStreaming:
            return "Choose this if speed and low resource use matter most."
        case .baseStreaming:
            return "Choose this if you want a balanced step up from Tiny."
        case .smallStreaming:
            return "Choose this if you want the safest all-around recommendation."
        case .mediumStreaming:
            return "Choose this if your Mac has plenty of headroom and you want the strongest live transcription."
        case .tiny, .base:
            return "Not recommended in Voce."
        }
    }

    var recommendationBadge: String? {
        switch self {
        case .smallStreaming:
            return "Recommended"
        case .tinyStreaming:
            return "Lightest"
        case .mediumStreaming:
            return "Most accurate"
        case .baseStreaming, .tiny, .base:
            return nil
        }
    }

    var normalizedForVoce: MoonshineModelPreset {
        switch self {
        case .tiny:
            return .tinyStreaming
        case .base, .baseStreaming:
            return .smallStreaming
        case .tinyStreaming, .smallStreaming, .mediumStreaming:
            return self
        }
    }
}

enum MoonshineModelPaths {
    static var rootDirectoryPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Voce/MoonshineModels", isDirectory: true)
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
