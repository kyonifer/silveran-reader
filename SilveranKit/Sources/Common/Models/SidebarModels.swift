import Foundation

@PublicInit
public struct SidebarSectionDescription: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var items: [SidebarItemDescription]
}

@PublicInit
public struct SidebarItemDescription: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var systemImage: String
    public var badge: Int32
    public var children: [SidebarItemDescription]? = nil
    public var content: SidebarContentKind
}

public enum SidebarContentKind: Hashable, Sendable {
    case home
    case mediaGrid(MediaGridConfiguration)
    case seriesView(MediaKind)
    case authorView(MediaKind)
    case placeholder(title: String)
    case importLocalFile
    case storytellerServer
}

public enum NarrationFilter: Hashable, Sendable {
    case both
    case withAudio
    case withoutAudio
}

public enum MediaKind: String, CaseIterable, Sendable {
    case ebook
    case audiobook
}

public struct MediaGridConfiguration: Hashable, Sendable {
    public var title: String
    public var mediaKind: MediaKind
    public var preferredTileWidth: Double?
    public var minimumTileWidth: Double?
    public var narrationFilter: NarrationFilter
    public var tagFilter: String?
    public var seriesFilter: String?
    public var statusFilter: String?
    public var defaultSort: String?

    public init(
        title: String,
        mediaKind: MediaKind,
        preferredTileWidth: Double? = nil,
        minimumTileWidth: Double? = nil,
        narrationFilter: NarrationFilter = .both,
        tagFilter: String? = nil,
        seriesFilter: String? = nil,
        statusFilter: String? = nil,
        defaultSort: String? = nil
    ) {
        self.title = title
        self.mediaKind = mediaKind
        self.preferredTileWidth = preferredTileWidth
        self.minimumTileWidth = minimumTileWidth
        self.narrationFilter = narrationFilter
        self.tagFilter = tagFilter
        self.seriesFilter = seriesFilter
        self.statusFilter = statusFilter
        self.defaultSort = defaultSort
    }
}

public enum LibrarySidebarDefaults {
    public static func getSections() -> [SidebarSectionDescription] {
        [
            SidebarSectionDescription(
                name: "Library",
                items: [
                    SidebarItemDescription(
                        name: "Home",
                        systemImage: "house",
                        badge: 112,
                        content: .home,
                    ),
                    SidebarItemDescription(
                        name: "All Books",
                        systemImage: "book",
                        badge: 112,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "All Books",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                            ),
                        ),
                    ),
                    SidebarItemDescription(
                        name: "Books by Series",
                        systemImage: "books.vertical",
                        badge: -1,
                        content: .seriesView(.ebook),
                    ),
                    SidebarItemDescription(
                        name: "Books by Author",
                        systemImage: "person.2",
                        badge: -1,
                        content: .authorView(.ebook),
                    ),
                ],
            ),
            SidebarSectionDescription(
                name: "Collections",
                items: [
                    SidebarItemDescription(
                        name: "Currently Reading",
                        systemImage: "arrow.right.circle",
                        badge: 8,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Currently Reading",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                statusFilter: "Reading",
                                defaultSort: "recentlyRead"
                            )
                        )
                    ),
                    SidebarItemDescription(
                        name: "Start Reading",
                        systemImage: "bookmark",
                        badge: 8,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Start Reading",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                statusFilter: "To read",
                                defaultSort: "recentlyAdded"
                            )
                        )
                    ),
                    SidebarItemDescription(
                        name: "Recently Added",
                        systemImage: "clock",
                        badge: 12,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Recently Added",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                defaultSort: "recentlyAdded"
                            )
                        )
                    ),
                    SidebarItemDescription(
                        name: "Completed",
                        systemImage: "checkmark.circle",
                        badge: 12,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Completed",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                statusFilter: "Read",
                                defaultSort: "recentlyRead"
                            )
                        )
                    ),
                    SidebarItemDescription(
                        name: "Fantasy Shelf",
                        systemImage: "books.vertical",
                        badge: 4,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Fantasy Shelf",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                tagFilter: "fantasy",
                            ),
                        ),
                    ),
                    SidebarItemDescription(
                        name: "Sci-fi Shelf",
                        systemImage: "books.vertical",
                        badge: 3,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Sci-fi Shelf",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                tagFilter: "sci-fi",
                            ),
                        ),
                    ),
                ],
            ),
            SidebarSectionDescription(
                name: "Media Sources",
                items: [
                    SidebarItemDescription(
                        name: "Storyteller Server",
                        systemImage: "server.rack",
                        badge: -1,
                        content: .storytellerServer
                    ),
                    SidebarItemDescription(
                        name: "Local Files",
                        systemImage: "folder",
                        badge: -1,
                        content: .importLocalFile,
                    ),
                ],
            ),
        ]
    }
}
