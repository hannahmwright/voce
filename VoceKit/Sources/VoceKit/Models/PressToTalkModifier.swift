import Foundation

public struct PressToTalkHotkey: Codable, Sendable, Equatable, Hashable {
    public enum Modifier: String, Codable, CaseIterable, Sendable, Hashable {
        case option
        case control
        case command
        case shift
        case function

        public var displayName: String {
            switch self {
            case .option: return "Option"
            case .control: return "Control"
            case .command: return "Command"
            case .shift: return "Shift"
            case .function: return "Globe/Fn"
            }
        }
    }

    public static let `default` = PressToTalkHotkey(modifiers: [.option])

    public let modifiers: [Modifier]

    public init(modifiers: [Modifier]) {
        let normalized = Self.normalize(modifiers)
        self.modifiers = normalized.isEmpty ? Self.default.modifiers : normalized
    }

    public var displayName: String {
        modifiers.map(\.displayName).joined(separator: "+")
    }

    public func contains(_ modifier: Modifier) -> Bool {
        modifiers.contains(modifier)
    }

    private static func normalize(_ modifiers: [Modifier]) -> [Modifier] {
        let deduped = Set(modifiers)
        return Modifier.allCases.filter { deduped.contains($0) }
    }
}

public enum PressToTalkModifier: String, Codable, CaseIterable, Sendable {
    case option
    case control
    case command
    case shift

    public var asHotkey: PressToTalkHotkey {
        PressToTalkHotkey(modifiers: [asModifier])
    }

    public var asModifier: PressToTalkHotkey.Modifier {
        switch self {
        case .option: return .option
        case .control: return .control
        case .command: return .command
        case .shift: return .shift
        }
    }
}
