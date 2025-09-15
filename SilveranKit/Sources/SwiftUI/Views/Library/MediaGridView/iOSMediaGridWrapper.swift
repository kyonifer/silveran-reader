#if os(iOS)
import SwiftUI

struct iOSMediaGridWrapper: View {
    let title: String
    let searchText: String
    let mediaKind: MediaKind
    let tagFilter: String?
    let seriesFilter: String?
    let statusFilter: String?
    let defaultSort: String?
    let initialNarrationFilterOption: NarrationFilter

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                MediaGridView(
                    title: title,
                    searchText: searchText,
                    mediaKind: mediaKind,
                    tagFilter: tagFilter,
                    seriesFilter: seriesFilter,
                    statusFilter: statusFilter,
                    defaultSort: defaultSort,
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    onReadNow: { _ in },
                    onRename: { _ in },
                    onDelete: { _ in },
                    initialNarrationFilterOption: initialNarrationFilterOption
                )
            }
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: mediaKind)
            }
        }
    }
}
#endif
