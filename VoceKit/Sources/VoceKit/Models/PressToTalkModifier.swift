import Foundation

public enum PressToTalkModifier: String, Codable, CaseIterable, Sendable {
    case option
    case control
    case command
    case shift

    public var displayName: String {
        switch self {
        case .option: return "Option"
        case .control: return "Control"
        case .command: return "Command"
        case .shift: return "Shift"
        }
    }
}
