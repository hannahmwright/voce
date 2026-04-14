import Foundation

public enum StyleTone: String, Sendable, Codable, Equatable, CaseIterable {
    case natural
    case professional
    case concise
    case friendly
    case technical
}

public enum StructureMode: String, Sendable, Codable, Equatable, CaseIterable {
    case natural
    case paragraph
    case bullets
    case email
    case command
}

public enum FillerPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case minimal
    case balanced
    case aggressive
}

public enum CommandPolicy: String, Sendable, Codable, Equatable, CaseIterable {
    case passthrough
    case transform
}

public struct StyleProfile: Sendable, Codable, Equatable {
    public var name: String
    public var tone: StyleTone
    public var structureMode: StructureMode
    public var fillerPolicy: FillerPolicy
    public var commandPolicy: CommandPolicy

    public init(
        name: String,
        tone: StyleTone,
        structureMode: StructureMode,
        fillerPolicy: FillerPolicy,
        commandPolicy: CommandPolicy
    ) {
        self.name = name
        self.tone = tone
        self.structureMode = structureMode
        self.fillerPolicy = fillerPolicy
        self.commandPolicy = commandPolicy
    }
}

public enum Scope: Sendable, Codable, Equatable {
    case global
    case app(bundleID: String)
}

public struct LexiconEntry: Sendable, Codable, Equatable {
    public var term: String
    public var preferred: String
    public var scope: Scope

    public init(term: String, preferred: String, scope: Scope) {
        self.term = term
        self.preferred = preferred
        self.scope = scope
    }
}

public struct PersonalLexicon: Sendable, Codable, Equatable {
    public var entries: [LexiconEntry]

    /// Entries are sorted longest-term-first so longer multi-word phrases
    /// match before shorter substrings during lexicon application.
    public init(entries: [LexiconEntry] = []) {
        self.entries = entries.sorted { $0.term.count > $1.term.count }
    }
}

public struct Snippet: Sendable, Codable, Equatable, Identifiable {
    public static let defaultGroupName = "General"

    public var id: UUID
    public var name: String
    public var trigger: String
    public var expansion: String
    public var scope: Scope
    public var groupName: String

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        trigger: String,
        expansion: String,
        scope: Scope = .global,
        groupName: String = Snippet.defaultGroupName
    ) {
        self.id = id
        self.name = Self.normalizedName(name, fallback: trigger)
        self.trigger = trigger
        self.expansion = expansion
        self.scope = scope
        self.groupName = Self.normalizedGroupName(groupName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case trigger
        case expansion
        case scope
        case groupName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        trigger = try container.decode(String.self, forKey: .trigger)
        expansion = try container.decode(String.self, forKey: .expansion)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .global
        name = Self.normalizedName(
            try container.decodeIfPresent(String.self, forKey: .name),
            fallback: trigger
        )
        groupName = Self.normalizedGroupName(
            try container.decodeIfPresent(String.self, forKey: .groupName) ?? Self.defaultGroupName
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(expansion, forKey: .expansion)
        try container.encode(scope, forKey: .scope)
        try container.encode(groupName, forKey: .groupName)
    }

    private static func normalizedName(_ name: String?, fallback: String) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? "Shortcut" : trimmedFallback
    }

    private static func normalizedGroupName(_ groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultGroupName : trimmed
    }
}
