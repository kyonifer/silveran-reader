import Foundation

public enum FolderSourceBulkImportRole: String, CaseIterable, Codable, Sendable, Hashable {
    case ebook
    case readaloud
    case audiobook
    case skip

    public var displayName: String {
        switch self {
            case .ebook:
                return "Ebook"
            case .readaloud:
                return "Readaloud"
            case .audiobook:
                return "Audiobook"
            case .skip:
                return "Skip"
        }
    }

    public var localMediaCategory: LocalMediaCategory? {
        switch self {
            case .ebook:
                return .ebook
            case .readaloud:
                return .synced
            case .audiobook:
                return .audio
            case .skip:
                return nil
        }
    }
}

public struct FolderSourceBulkImportAsset: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let relativePath: String
    public let filename: String
    public let fileSize: Int64?
    public let detectedTitle: String?
    public let detectedRole: FolderSourceBulkImportRole
    public var selectedRole: FolderSourceBulkImportRole
    public var warnings: [String]

    public init(
        id: String = UUID().uuidString,
        url: URL,
        relativePath: String,
        filename: String,
        fileSize: Int64?,
        detectedTitle: String?,
        detectedRole: FolderSourceBulkImportRole,
        selectedRole: FolderSourceBulkImportRole,
        warnings: [String] = [],
    ) {
        self.id = id
        self.url = url
        self.relativePath = relativePath
        self.filename = filename
        self.fileSize = fileSize
        self.detectedTitle = detectedTitle
        self.detectedRole = detectedRole
        self.selectedRole = selectedRole
        self.warnings = warnings
    }
}

public struct FolderSourceBulkImportGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var bookUUID: String
    public var isSelected: Bool
    public var assets: [FolderSourceBulkImportAsset]
    public var warnings: [String]

    public init(
        id: String = UUID().uuidString,
        title: String,
        bookUUID: String = UUID().uuidString,
        isSelected: Bool = true,
        assets: [FolderSourceBulkImportAsset],
        warnings: [String] = [],
    ) {
        self.id = id
        self.title = title
        self.bookUUID = bookUUID
        self.isSelected = isSelected
        self.assets = assets
        self.warnings = warnings
    }

    public var importableAssets: [FolderSourceBulkImportAsset] {
        assets.filter { $0.selectedRole != .skip }
    }
}

public struct FolderSourceBulkImportSkippedFile: Identifiable, Sendable, Hashable {
    public let id: String
    public let relativePath: String
    public let reason: String

    public init(
        id: String = UUID().uuidString,
        relativePath: String,
        reason: String,
    ) {
        self.id = id
        self.relativePath = relativePath
        self.reason = reason
    }
}

public struct FolderSourceBulkImportPlan: Sendable, Hashable {
    public let rootURL: URL
    public var groups: [FolderSourceBulkImportGroup]
    public var skippedFiles: [FolderSourceBulkImportSkippedFile]

    public init(
        rootURL: URL,
        groups: [FolderSourceBulkImportGroup],
        skippedFiles: [FolderSourceBulkImportSkippedFile] = [],
    ) {
        self.rootURL = rootURL
        self.groups = groups
        self.skippedFiles = skippedFiles
    }
}

public struct FolderSourceBulkImportCommitResult: Sendable, Hashable {
    public let importedCount: Int
    public let skippedCount: Int
    public let failures: [String]

    public init(importedCount: Int, skippedCount: Int, failures: [String]) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
        self.failures = failures
    }
}
