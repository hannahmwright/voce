import Foundation

public struct VoceKeyboardShortcut: Codable, Sendable, Equatable, Hashable {
    public enum Modifier: String, Codable, CaseIterable, Sendable, Hashable {
        case control
        case option
        case command
        case shift

        public var displayName: String {
            switch self {
            case .control: return "Control"
            case .option: return "Option"
            case .command: return "Command"
            case .shift: return "Shift"
            }
        }
    }

    public var keyCode: UInt16
    public var modifiers: [Modifier]

    public init(keyCode: UInt16, modifiers: [Modifier]) {
        self.keyCode = keyCode
        self.modifiers = Self.normalizedModifiers(modifiers)
    }

    public static let dictionaryCorrectionDefault = VoceKeyboardShortcut(
        keyCode: 2,
        modifiers: [.control, .option, .command]
    )

    public static let snippetCreationDefault = VoceKeyboardShortcut(
        keyCode: 1,
        modifiers: [.control, .option, .command]
    )

    private static func normalizedModifiers(_ modifiers: [Modifier]) -> [Modifier] {
        let order = Dictionary(uniqueKeysWithValues: Modifier.allCases.enumerated().map { ($1, $0) })
        return Array(Set(modifiers)).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }
}
