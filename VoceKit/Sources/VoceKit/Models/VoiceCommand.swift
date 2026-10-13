import Foundation

/// A trigger phrase that executes an action during dictation.
///
/// Voice commands are detected in the cleaned transcript text and replaced
/// with their action output (inserted text, punctuation, or whitespace).
public struct VoiceCommand: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var trigger: String
    public var action: Action
    public var isEnabled: Bool
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        trigger: String,
        action: Action,
        isEnabled: Bool = true,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
    }

    public enum Action: Sendable, Codable, Equatable {
        /// Replace the trigger with the given text.
        case insertText(String)
        /// Remove the sentence immediately before the trigger.
        case deletePrevious
    }

    /// Built-in commands that ship with the app.
    public static let builtIns: [VoiceCommand] = [
        // Punctuation
        .init(trigger: "period", action: .insertText("."), isBuiltIn: true),
        .init(trigger: "full stop", action: .insertText("."), isBuiltIn: true),
        .init(trigger: "comma", action: .insertText(","), isBuiltIn: true),
        .init(trigger: "question mark", action: .insertText("?"), isBuiltIn: true),
        .init(trigger: "exclamation point", action: .insertText("!"), isBuiltIn: true),
        .init(trigger: "exclamation mark", action: .insertText("!"), isBuiltIn: true),
        .init(trigger: "colon", action: .insertText(":"), isBuiltIn: true),
        .init(trigger: "semicolon", action: .insertText(";"), isBuiltIn: true),
        .init(trigger: "open quote", action: .insertText("\u{201C}"), isBuiltIn: true),
        .init(trigger: "close quote", action: .insertText("\u{201D}"), isBuiltIn: true),
        .init(trigger: "open paren", action: .insertText("("), isBuiltIn: true),
        .init(trigger: "close paren", action: .insertText(")"), isBuiltIn: true),
        .init(trigger: "dash", action: .insertText(" \u{2014} "), isBuiltIn: true),
        .init(trigger: "hyphen", action: .insertText("-"), isBuiltIn: true),
        .init(trigger: "ellipsis", action: .insertText("\u{2026}"), isBuiltIn: true),

        // Whitespace & structure
        .init(trigger: "new line", action: .insertText("\n"), isBuiltIn: true),
        .init(trigger: "newline", action: .insertText("\n"), isBuiltIn: true),
        .init(trigger: "new paragraph", action: .insertText("\n\n"), isBuiltIn: true),
        .init(trigger: "tab key", action: .insertText("\t"), isBuiltIn: true),
        .init(trigger: "space", action: .insertText(" "), isBuiltIn: true),

        // Editing
        .init(trigger: "delete that", action: .deletePrevious, isBuiltIn: true),
        .init(trigger: "scratch that", action: .deletePrevious, isBuiltIn: true),
    ]

    /// Reconciles persisted commands with the current built-in definitions.
    ///
    /// Preferences persist the full built-in list, so without this an updated
    /// built-in definition would never reach existing users. The result:
    /// - contains every current built-in, in canonical order, using the current
    ///   action but keeping the stored `id` and `isEnabled` choice when the user
    ///   already had that trigger;
    /// - drops stored built-ins that no longer ship;
    /// - keeps every custom (non built-in) command, in its stored order, after
    ///   the built-ins.
    public static func mergingBuiltIns(into stored: [VoiceCommand]) -> [VoiceCommand] {
        func key(_ trigger: String) -> String {
            trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var storedBuiltInsByTrigger: [String: VoiceCommand] = [:]
        for command in stored where command.isBuiltIn {
            let trigger = key(command.trigger)
            if storedBuiltInsByTrigger[trigger] == nil {
                storedBuiltInsByTrigger[trigger] = command
            }
        }

        let refreshedBuiltIns = builtIns.map { builtIn -> VoiceCommand in
            guard let existing = storedBuiltInsByTrigger[key(builtIn.trigger)] else { return builtIn }
            var refreshed = builtIn
            refreshed.id = existing.id
            refreshed.isEnabled = existing.isEnabled
            return refreshed
        }

        return refreshedBuiltIns + stored.filter { !$0.isBuiltIn }
    }
}
