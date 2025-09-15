public class LibrarySidebarModel {
    public static func getSections() -> [SidebarSectionDescription] {
        // TODO: Support user custom sections
        defaultSections()
    }

    /** The default sections that all GUIs should show, before custom user sections are added
     */
    public static func defaultSections() -> [SidebarSectionDescription] {
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
                        name: "Books",
                        systemImage: "book",
                        badge: 112,
                        children: booksSubItems(parent: "Books"),
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Books",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                            ),
                        ),
                    ),
                ],
            ),
            SidebarSectionDescription(
                name: "Collections",
                items: [
                    SidebarItemDescription(
                        name: "Next Up",
                        systemImage: "bookmark",
                        badge: 8,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Next Up",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                tagFilter: "next-up",
                            ),
                        ),
                    ),
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
                                tagFilter: "currently-reading",
                            ),
                        ),
                    ),
                    SidebarItemDescription(
                        name: "Completed",
                        systemImage: "checkmark.circle",
                        badge: 12,
                        content: .mediaGrid(
                            MediaGridConfiguration(
                                title: "Completed Books",
                                mediaKind: .ebook,
                                preferredTileWidth: 120,
                                minimumTileWidth: 50,
                                tagFilter: "completed",
                            ),
                        ),
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
                    SidebarItemDescription(
                        name: "Add Custom Bookshelf...",
                        systemImage: "plus",
                        badge: -1,
                        content: .placeholder(title: "Add Custom Bookshelf"),
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
                        content: .placeholder(title: "Storyteller Server"),
                    ),
                    SidebarItemDescription(
                        name: "Audiobookshelf Server",
                        systemImage: "server.rack",
                        badge: -1,
                        content: .placeholder(title: "Audiobookshelf Server"),
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

    // TODO: This might be over-engineered, now that all the other subitems are removed
    private static func booksSubItems(parent: String) -> [SidebarItemDescription] {
        [
            SidebarItemDescription(
                name: "By Series",
                systemImage: "books.vertical",
                badge: -1,
                content: .placeholder(title: "\(parent) by Series"),
            ),
            SidebarItemDescription(
                name: "By Author",
                systemImage: "person.2",
                badge: -1,
                content: .placeholder(title: "\(parent) by Author"),
            ),
        ]
    }
}
