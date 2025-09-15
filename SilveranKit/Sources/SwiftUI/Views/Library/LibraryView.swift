import SwiftUI

public struct LibraryView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    // TODO: wire up search
    @State private var searchText: String = ""
    @State private var isSearchFocused: Bool = false
    @State private var selectedItem: SidebarItemDescription? = SidebarItemDescription(
        name: "Home",
        systemImage: "house",
        badge: 0,
        content: .home
    )
    @State private var showSettings = false
    // TODO: ConfigActor should handle this
    @State private var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    // TODO: Anchor to offset, not content
    @State private var gridScrollPositions: [String: BookMetadata.ID?] = [:]

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
            SidebarView(
                sections: sections,
                selectedItem: $selectedItem,
                searchText: $searchText,
                isSearchFocused: $isSearchFocused
            )
        } detail: {
            if let selected = selectedItem {
                detailView(
                    for: selected,
                    sections: $sections,
                    selectedItem: $selectedItem,
                )
            } else {
                PlaceholderDetailView(title: "Select an item")
            }
        }
        #if os(macOS)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command)
                    && event.charactersIgnoringModifiers == "f"
                {
                    isSearchFocused = true
                    return nil
                }
                return event
            }
        }
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
            .presentationDragIndicator(.visible)
        }
        #endif

            if let notification = mediaViewModel.syncNotification {
                VStack {
                    SyncNotificationView(
                        notification: notification,
                        onDismiss: {
                            mediaViewModel.dismissSyncNotification()
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: notification.id)
                    .padding(.top, 16)

                    Spacer()
                }
                .zIndex(1000)
            }
        }
    }

    @ViewBuilder
    func detailView(
        for item: SidebarItemDescription,
        sections: Binding<[SidebarSectionDescription]>,
        selectedItem: Binding<SidebarItemDescription?>
    ) -> some View {
        switch item.content {
            case .home:
                #if os(iOS)
                HomeView(
                    searchText: $searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #else
                HomeView(
                    searchText: searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #endif
            case .mediaGrid(let configuration):
                let preferred = configuration.preferredTileWidth.map { CGFloat($0) } ?? 250
                let minimum = configuration.minimumTileWidth.map { CGFloat($0) } ?? 10
                let identity = gridIdentity(for: configuration)
                let scrollBinding: Binding<BookMetadata.ID?>? = Binding(
                    get: { gridScrollPositions[identity] ?? nil },
                    set: { gridScrollPositions[identity] = $0 },
                )
                MediaGridView(
                    title: configuration.title,
                    searchText: searchText,
                    mediaKind: configuration.mediaKind,
                    tagFilter: configuration.tagFilter,
                    seriesFilter: configuration.seriesFilter,
                    statusFilter: configuration.statusFilter,
                    defaultSort: configuration.defaultSort,
                    preferredTileWidth: preferred,
                    minimumTileWidth: minimum,
                    initialNarrationFilterOption: configuration.narrationFilter,
                    scrollPosition: scrollBinding
                )
                .id(identity)
            case .seriesView(let mediaKind):
                #if os(iOS)
                SeriesView(
                    mediaKind: mediaKind,
                    searchText: $searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #else
                SeriesView(
                    mediaKind: mediaKind,
                    searchText: searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #endif
            case .authorView(let mediaKind):
                #if os(iOS)
                AuthorView(
                    mediaKind: mediaKind,
                    searchText: $searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #else
                AuthorView(
                    mediaKind: mediaKind,
                    searchText: searchText,
                    sidebarSections: sections,
                    selectedSidebarItem: selectedItem,
                    showSettings: $showSettings
                )
                #endif
            case .placeholder(let title):
                PlaceholderDetailView(title: title)
                    .border(.yellow)
            case .importLocalFile:
                ImportLocalFileView()
            case .storytellerServer:
                StorytellerServerSettingsView()
        }
    }

    func gridIdentity(for config: MediaGridConfiguration) -> String {
        config.title
    }
}
