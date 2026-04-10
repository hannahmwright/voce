import Foundation

public struct HandsFreeToggleHotkey: Codable, Sendable, Equatable {
    public enum TriggerStyle: String, Codable, CaseIterable, Sendable {
        case singleTap
        case doubleTap
    }

    public var hotkey: HandsFreeHotkey
    public var triggerStyle: TriggerStyle

    public init(
        hotkey: HandsFreeHotkey,
        triggerStyle: TriggerStyle = .singleTap
    ) {
        self.hotkey = hotkey
        self.triggerStyle = triggerStyle
    }
}
