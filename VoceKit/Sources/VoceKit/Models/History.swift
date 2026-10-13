import Foundation

public struct TranscriptEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var appBundleID: String
    public var rawText: String
    public var sourceText: String?
    public var cleanText: String
    public var audioURL: URL?
    public var insertionStatus: InsertionStatus
    public var processingNote: String?
    public var completionAction: String?
    public var aiWorkflowName: String?
    public var aiProvider: AIProvider?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        appBundleID: String,
        rawText: String,
        sourceText: String? = nil,
        cleanText: String,
        audioURL: URL?,
        insertionStatus: InsertionStatus,
        processingNote: String? = nil,
        completionAction: String? = nil,
        aiWorkflowName: String? = nil,
        aiProvider: AIProvider? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.appBundleID = appBundleID
        self.rawText = rawText
        self.sourceText = sourceText
        self.cleanText = cleanText
        self.audioURL = audioURL
        self.insertionStatus = insertionStatus
        self.processingNote = processingNote
        self.completionAction = completionAction
        self.aiWorkflowName = aiWorkflowName
        self.aiProvider = aiProvider
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case appBundleID
        case rawText
        case sourceText
        case cleanText
        case audioURL
        case insertionStatus
        case processingNote
        case completionAction
        case aiWorkflowName
        case aiProvider
    }

    /// Tolerant decoding so one malformed or future-format field does not make
    /// the entry (or the whole history file) undecodable. The core content —
    /// `createdAt`, `rawText`, `cleanText` — is still required.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLenientIfPresent(UUID.self, forKey: .id, decoder: decoder) ?? UUID()
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        appBundleID = container.decodeLenientIfPresent(String.self, forKey: .appBundleID, decoder: decoder) ?? ""
        rawText = try container.decode(String.self, forKey: .rawText)
        sourceText = container.decodeLenientIfPresent(String.self, forKey: .sourceText, decoder: decoder)
        cleanText = try container.decode(String.self, forKey: .cleanText)
        audioURL = container.decodeLenientIfPresent(URL.self, forKey: .audioURL, decoder: decoder)
        // An unknown status (e.g. written by a newer version) falls back to the
        // neutral "copied" state rather than dropping the entry.
        insertionStatus = container.decodeLenientIfPresent(InsertionStatus.self, forKey: .insertionStatus, decoder: decoder)
            ?? .copiedOnly
        processingNote = container.decodeLenientIfPresent(String.self, forKey: .processingNote, decoder: decoder)
        completionAction = container.decodeLenientIfPresent(String.self, forKey: .completionAction, decoder: decoder)
        aiWorkflowName = container.decodeLenientIfPresent(String.self, forKey: .aiWorkflowName, decoder: decoder)
        aiProvider = container.decodeLenientIfPresent(AIProvider.self, forKey: .aiProvider, decoder: decoder)
    }
}
