import Foundation

public struct SmartShelf: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var conditions: [ShelfCondition]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        conditions: [ShelfCondition] = [],
        createdAt: Date = Date(),
    ) {
        self.id = id
        self.name = name
        self.conditions = conditions
        self.createdAt = createdAt
    }

    public func matchesAll(
        _ book: BookMetadata,
        progress: Double,
        locationInfo: ShelfLocationInfo = .init(),
    ) -> Bool {
        guard !conditions.isEmpty else { return false }

        // Split conditions into OR-separated groups.
        // Each group's conditions are ANDed, groups are ORed.
        var groups: [[ShelfCondition]] = [[]]
        for condition in conditions {
            if case .orSeparator = condition {
                groups.append([])
            } else {
                groups[groups.count - 1].append(condition)
            }
        }

        // Remove empty groups (e.g. leading/trailing OR separators)
        groups = groups.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return false }

        return groups.contains { group in
            group.allSatisfy { $0.matches(book, progress: progress, locationInfo: locationInfo) }
        }
    }
}

public struct ShelfLocationInfo: Sendable {
    public let isDownloaded: Bool
    public let isLocalStandalone: Bool

    public init(isDownloaded: Bool = false, isLocalStandalone: Bool = false) {
        self.isDownloaded = isDownloaded
        self.isLocalStandalone = isLocalStandalone
    }
}

public enum ShelfCondition: Codable, Hashable, Sendable {
    case format(mode: InclusionMode, conditions: [FormatCondition])
    case status(mode: InclusionMode, values: [String])
    case location(mode: InclusionMode, conditions: [LocationCondition])
    case rating(comparison: RatingComparison, value: Int)
    case progress(mode: InclusionMode, conditions: [ProgressCondition])
    case tag(mode: InclusionMode, values: [String])
    case series(mode: InclusionMode, values: [String])
    case author(mode: InclusionMode, values: [String])
    case narrator(mode: InclusionMode, values: [String])
    case translator(mode: InclusionMode, values: [String])
    case publicationYear(mode: InclusionMode, values: [String])
    case publicationYearComparison(comparison: YearComparison, value: Int)
    case hasAuthor
    case hasNarrator
    case hasTranslator
    case hasSeries
    case hasRating
    case hasPublicationYear
    case hasTag
    case noAuthor
    case noNarrator
    case noTranslator
    case noSeries
    case noRating
    case noPublicationYear
    case noTag
    case orSeparator

    public func matches(
        _ book: BookMetadata,
        progress: Double,
        locationInfo: ShelfLocationInfo = .init(),
    ) -> Bool {
        switch self {
            case .format(let mode, let conditions):
                let matches = conditions.contains { formatConditionMatches($0, book) }
                return mode == .include ? matches : !matches

            case .status(let mode, let values):
                let bookStatuses: [String]
                if let name = book.status?.name {
                    bookStatuses = [name.lowercased()]
                } else {
                    bookStatuses = []
                }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookStatuses, targets: targets)

            case .location(let mode, let conditions):
                let matches = conditions.contains {
                    locationConditionMatches($0, locationInfo: locationInfo)
                }
                return mode == .include ? matches : !matches

            case .rating(let comparison, let value):
                let bookRating = Int((book.rating ?? 0).rounded())
                switch comparison {
                    case .greaterThanOrEqual: return bookRating >= value
                    case .lessThanOrEqual: return bookRating <= value
                    case .equal: return bookRating == value
                }

            case .progress(let mode, let conditions):
                let matches = conditions.contains {
                    progressConditionMatches($0, progress: progress)
                }
                return mode == .include ? matches : !matches

            case .tag(let mode, let values):
                let bookTags = book.tagNames.map { $0.lowercased() }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookTags, targets: targets)

            case .series(let mode, let values):
                let bookSeries = (book.series ?? []).map { $0.name.lowercased() }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookSeries, targets: targets)

            case .author(let mode, let values):
                let bookAuthors = (book.authors ?? []).compactMap { $0.name?.lowercased() }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookAuthors, targets: targets)

            case .narrator(let mode, let values):
                let bookNarrators = (book.narrators ?? []).compactMap { $0.name?.lowercased() }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookNarrators, targets: targets)

            case .translator(let mode, let values):
                let translators = (book.creators ?? []).filter { $0.role == "trl" }
                let bookTranslators = translators.compactMap { $0.name?.lowercased() }
                let targets = values.map { $0.lowercased() }
                return matchesInclusion(mode: mode, bookValues: bookTranslators, targets: targets)

            case .publicationYear(let mode, let values):
                let year = book.sortablePublicationYear
                let bookYears = year.isEmpty ? [String]() : [year]
                let targets = values.compactMap { BookMetadata.publicationYear(from: $0) }
                return matchesInclusion(mode: mode, bookValues: bookYears, targets: targets)

            case .publicationYearComparison(let comparison, let value):
                guard let bookYear = Int(book.sortablePublicationYear) else { return false }
                switch comparison {
                    case .newerThan: return bookYear > value
                    case .olderThan: return bookYear < value
                    case .exactly: return bookYear == value
                }

            case .hasAuthor:
                return !(book.authors ?? []).isEmpty

            case .hasNarrator:
                return !(book.narrators ?? []).isEmpty

            case .hasTranslator:
                return (book.creators ?? []).contains { $0.role == "trl" }

            case .hasSeries:
                return !(book.series ?? []).isEmpty

            case .hasRating:
                return book.rating != nil && book.rating! > 0

            case .hasPublicationYear:
                return !book.sortablePublicationYear.isEmpty

            case .hasTag:
                return !book.tagNames.isEmpty

            case .noAuthor:
                return (book.authors ?? []).isEmpty

            case .noNarrator:
                return (book.narrators ?? []).isEmpty

            case .noTranslator:
                return !(book.creators ?? []).contains { $0.role == "trl" }

            case .noSeries:
                return (book.series ?? []).isEmpty

            case .noRating:
                return book.rating == nil || book.rating! <= 0

            case .noPublicationYear:
                return book.sortablePublicationYear.isEmpty

            case .noTag:
                return book.tagNames.isEmpty

            case .orSeparator:
                return true
        }
    }

    private func formatConditionMatches(_ condition: FormatCondition, _ book: BookMetadata) -> Bool
    {
        switch condition {
            case .ebook: return book.hasAvailableEbook
            case .audiobook: return book.hasAvailableAudiobook
            case .readaloud: return book.hasAvailableReadaloud
            case .missingReadaloud: return !book.hasAvailableReadaloud
            case .ebookOnly: return book.isEbookOnly
            case .audiobookOnly: return book.isAudiobookOnly
        }
    }

    private func progressConditionMatches(_ condition: ProgressCondition, progress: Double) -> Bool
    {
        switch condition {
            case .notStarted: return progress <= 0
            case .inProgress: return progress > 0 && progress < 1
            case .completed: return progress >= 1
        }
    }

    private func locationConditionMatches(
        _ condition: LocationCondition,
        locationInfo: ShelfLocationInfo,
    ) -> Bool {
        switch condition {
            case .downloaded: return locationInfo.isDownloaded
            case .serverOnly: return !locationInfo.isDownloaded && !locationInfo.isLocalStandalone
            case .localFiles: return locationInfo.isLocalStandalone
        }
    }

    private func matchesInclusion(mode: InclusionMode, bookValues: [String], targets: [String])
        -> Bool
    {
        switch mode {
            case .include:
                return targets.contains { target in bookValues.contains(target) }
            case .exclude:
                return !targets.contains { target in bookValues.contains(target) }
        }
    }

    public var displayLabel: String {
        switch self {
            case .format(let m, let c):
                return "Format \(m.label): \(c.map(\.label).joined(separator: ", "))"
            case .status(let m, let v): return "Status \(m.label): \(v.joined(separator: ", "))"
            case .location(let m, let c):
                return "Location \(m.label): \(c.map(\.label).joined(separator: ", "))"
            case .rating(let cmp, let v): return "Rating \(cmp.symbol) \(v)"
            case .progress(let m, let c):
                return "Progress \(m.label): \(c.map(\.label).joined(separator: ", "))"
            case .tag(let m, let v): return "Tags \(m.label): \(v.joined(separator: ", "))"
            case .series(let m, let v): return "Series \(m.label): \(v.joined(separator: ", "))"
            case .author(let m, let v): return "Author \(m.label): \(v.joined(separator: ", "))"
            case .narrator(let m, let v): return "Narrator \(m.label): \(v.joined(separator: ", "))"
            case .translator(let m, let v):
                return "Translator \(m.label): \(v.joined(separator: ", "))"
            case .publicationYear(let m, let v):
                return "Year \(m.label): \(v.joined(separator: ", "))"
            case .publicationYearComparison(let cmp, let v):
                return "Year \(cmp.label.lowercased()) \(v)"
            case .hasAuthor: return "Any Author Present"
            case .hasNarrator: return "Any Narrator Present"
            case .hasTranslator: return "Any Translator Present"
            case .hasSeries: return "Any Series Present"
            case .hasRating: return "Any Rating Present"
            case .hasPublicationYear: return "Any Publication Year Present"
            case .hasTag: return "Any Tag Present"
            case .noAuthor: return "No Author Present"
            case .noNarrator: return "No Narrator Present"
            case .noTranslator: return "No Translator Present"
            case .noSeries: return "No Series Present"
            case .noRating: return "No Rating Present"
            case .noPublicationYear: return "No Publication Year Present"
            case .noTag: return "No Tag Present"
            case .orSeparator: return "OR"
        }
    }
}

public enum FormatCondition: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case ebook
    case audiobook
    case readaloud
    case missingReadaloud
    case ebookOnly
    case audiobookOnly

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .ebook: return "Has Ebook"
            case .audiobook: return "Has Audiobook"
            case .readaloud: return "Has Readaloud"
            case .missingReadaloud: return "Missing Readaloud"
            case .ebookOnly: return "Ebook Only"
            case .audiobookOnly: return "Audiobook Only"
        }
    }
}

public enum LocationCondition: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case downloaded
    case serverOnly
    case localFiles

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .downloaded: return "Downloaded"
            case .serverOnly: return "Server Only"
            case .localFiles: return "Folder Source"
        }
    }
}

public enum RatingComparison: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case greaterThanOrEqual
    case lessThanOrEqual
    case equal

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .greaterThanOrEqual: return "At Least"
            case .lessThanOrEqual: return "At Most"
            case .equal: return "Exactly"
        }
    }

    public var symbol: String {
        switch self {
            case .greaterThanOrEqual: return ">="
            case .lessThanOrEqual: return "<="
            case .equal: return "="
        }
    }
}

public enum YearComparison: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case newerThan
    case olderThan
    case exactly

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .newerThan: return "Newer Than"
            case .olderThan: return "Older Than"
            case .exactly: return "Exactly"
        }
    }
}

public enum ProgressCondition: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case notStarted
    case inProgress
    case completed

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .notStarted: return "Not Started"
            case .inProgress: return "In Progress"
            case .completed: return "Completed"
        }
    }
}

public enum InclusionMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case include
    case exclude

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .include: return "includes"
            case .exclude: return "excludes"
        }
    }
}

public enum ShelfConditionType: String, CaseIterable, Identifiable, Sendable {
    case format
    case status
    case location
    case rating
    case progress
    case tag
    case series
    case author
    case narrator
    case translator
    case publicationYear
    case boolean

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .format: return "Format"
            case .status: return "Reading Status"
            case .location: return "Location"
            case .rating: return "Rating"
            case .progress: return "Progress"
            case .tag: return "Tag"
            case .series: return "Series"
            case .author: return "Author"
            case .narrator: return "Narrator"
            case .translator: return "Translator"
            case .publicationYear: return "Publication Year"
            case .boolean: return "Boolean"
        }
    }

    public var systemImage: String {
        switch self {
            case .format: return "doc"
            case .status: return "bookmark"
            case .location: return "externaldrive"
            case .rating: return "star"
            case .progress: return "chart.bar"
            case .tag: return "tag"
            case .series: return "books.vertical"
            case .author: return "person"
            case .narrator: return "mic"
            case .translator: return "character.book.closed.fill"
            case .publicationYear: return "calendar"
            case .boolean: return "arrow.triangle.branch"
        }
    }
}
