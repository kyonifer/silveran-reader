public class LibrarySidebarModel {
    public static func getSections() -> [SidebarSectionDescription] {
        defaultSections()
    }

    public static func defaultSections() -> [SidebarSectionDescription] {
        [
            SidebarSectionDescription(
                id: "section.home",
                name: "Home",
                items: [
                    SidebarItemDescription(
                        name: "Dashboard",
                        systemImage: "house",
                        badge: 0,
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
                            )
                        ),
                    ),
                ],
            ),
            SidebarSectionDescription(
                id: "section.library",
                name: "Library",
                items: booksSubItems(parent: "Books"),
            ),
            SidebarSectionDescription(
                id: "section.collections",
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
                            )
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
                            )
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
                            )
                        ),
                    ),
                    SidebarItemDescription(
                        name: "Server Collections",
                        systemImage: "rectangle.stack",
                        badge: -1,
                        content: .collectionsView(.ebook),
                    ),
                    SidebarItemDescription(
                        name: "Currently Downloading",
                        systemImage: "arrow.down.circle.dotted",
                        badge: -1,
                        content: .currentlyDownloading,
                    ),
                ],
            ),
            SidebarSectionDescription(
                id: "section.mediaSources",
                name: "Media Sources",
                items: [
                    SidebarItemDescription(
                        name: "Sources",
                        systemImage: "externaldrive",
                        badge: -1,
                        content: .storytellerServer,
                    )
                ],
            ),
        ]
    }

    private static func booksSubItems(parent: String) -> [SidebarItemDescription] {
        [
            SidebarItemDescription(
                name: "Series",
                systemImage: "books.vertical",
                badge: -1,
                content: .placeholder(title: "\(parent) by Series"),
            ),
            SidebarItemDescription(
                name: "Author",
                systemImage: "person.2",
                badge: -1,
                content: .placeholder(title: "\(parent) by Author"),
            ),
        ]
    }
}
