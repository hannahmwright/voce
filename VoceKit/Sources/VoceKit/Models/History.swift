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
}
