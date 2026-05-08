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

    // Dictionary quick fix and snippet creation are reachable through the new
    // "tap Cmd+Option" Voce action picker (see `voceActionsTapEnabled`).
    // The keyCode-based shortcuts below remain available as opt-in *direct*
    // bypass shortcuts for power users who want one-press access without the
    // picker step. They are dormant unless the user sets a non-empty modifier
    // set in Advanced Settings — `.disabledSentinel` is the off state.
    //
    // The `*Default` constants below are what the recorder field's "Restore
    // default" button writes when the user explicitly opts in. They were
    // chosen as a compromise between ergonomics and global-tap safety: easier
    // to press than the historical hyper-key combo (Ctrl+Opt+Cmd+letter) but
    // safer than a single Control letter (the hotkey monitor swallows matched
    // keys system-wide, and Control+F is a standard Cocoa text shortcut).
    public static let dictionaryCorrectionDefault = VoceKeyboardShortcut(
        keyCode: 3,
        modifiers: [.control, .option]
    )

    public static let snippetCreationDefault = VoceKeyboardShortcut(
        keyCode: 1,
        modifiers: [.control, .option]
    )

    /// Sentinel value meaning "no direct shortcut bound" — recognised by the
    /// hotkey monitor (empty modifiers short-circuit matching) so the keyCode
    /// is irrelevant. Used as the new-install default so fresh users only see
    /// the Cmd+Option tap entry point and don't have hidden global shortcuts
    /// silently swallowing keys.
    public static let disabledSentinel = VoceKeyboardShortcut(
        keyCode: 0,
        modifiers: []
    )

    /// True when this shortcut is bound to something the monitor can match.
    /// An empty modifier set means "no shortcut" — see `disabledSentinel`.
    public var isBound: Bool { !modifiers.isEmpty }

    private static func normalizedModifiers(_ modifiers: [Modifier]) -> [Modifier] {
        let order = Dictionary(uniqueKeysWithValues: Modifier.allCases.enumerated().map { ($1, $0) })
        return Array(Set(modifiers)).sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }
}
