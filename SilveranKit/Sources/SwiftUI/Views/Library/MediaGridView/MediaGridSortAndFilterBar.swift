import SwiftUI

struct MediaGridSortAndFilterBar: View {
    @Binding var selectedSortOption: MediaGridView.SortOption
    @Binding var selectedFormatFilter: MediaGridView.FormatFilterOption
    @Binding var selectedTag: String?
    @Binding var selectedSeries: String?
    @Binding var selectedAuthor: String?
    @Binding var selectedNarrator: String?
    @Binding var selectedStatus: String?
    @Binding var selectedLocation: MediaGridView.LocationFilterOption
    @Binding var showAudioIndicator: Bool
    @Binding var showSourceBadge: Bool
    let availableTags: [String]
    let availableSeries: [String]
    let availableAuthors: [String]
    let availableNarrators: [String]
    let availableStatuses: [String]
    let filtersSummaryText: String

    var body: some View {
        HStack(spacing: 12) {
            sortMenu
            formatMenu
            Spacer()
            viewOptionsMenu
        }
        .font(.callout)
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(MediaGridView.SortOption.allCases) { option in
                Button {
                    selectedSortOption = option
                } label: {
                    menuRowLabel(text: option.label, isSelected: option == selectedSortOption)
                }
            }
        } label: {
            #if os(iOS)
            Label("Sort", systemImage: "arrow.up.arrow.down")
            #else
            Label(
                "Sort: \(selectedSortOption.shortLabel)",
                systemImage: "arrow.up.arrow.down"
            )
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    @ViewBuilder
    private var formatMenu: some View {
        Menu {
            clearMenuItem
            formatSection
            statusSection
            locationSection
            otherSection
        } label: {
            #if os(iOS)
            Label("Filters", systemImage: "line.3.horizontal.decrease")
            #else
            Label(
                "Filters: \(filtersSummaryText)",
                systemImage: "line.3.horizontal.decrease"
            )
            #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    @ViewBuilder
    private var formatSection: some View {
        Section("Format") {
            ForEach(MediaGridView.FormatFilterOption.allCases) { option in
                Button {
                    selectedFormatFilter = option
                } label: {
                    menuRowLabel(text: option.label, isSelected: option == selectedFormatFilter)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        let statuses = availableStatuses
        if statuses.isEmpty {
            EmptyView()
        } else {
            Divider()
            Section("Status") {
                Button {
                    selectedStatus = nil
                } label: {
                    menuRowLabel(
                        text: "All Statuses",
                        isSelected: selectedStatus == nil
                    )
                }

                ForEach(statuses, id: \.self) { status in
                    Button {
                        selectedStatus = status
                    } label: {
                        menuRowLabel(text: status, isSelected: selectedStatus == status)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var otherSection: some View {
        let tags = availableTags
        let series = availableSeries
        let authors = availableAuthors
        let narrators = availableNarrators

        if !tags.isEmpty || !series.isEmpty || !authors.isEmpty || !narrators.isEmpty {
            Divider()
            Section("Other") {
                if !tags.isEmpty {
                    Menu {
                        Button {
                            selectedTag = nil
                        } label: {
                            menuRowLabel(text: "All Tags", isSelected: selectedTag == nil)
                        }

                        ForEach(tags, id: \.self) { tag in
                            Button {
                                selectedTag = tag
                            } label: {
                                menuRowLabel(text: tag, isSelected: selectedTag == tag)
                            }
                        }
                    } label: {
                        Label("Select Tag", systemImage: "tag")
                    }
                }

                if !series.isEmpty {
                    Menu {
                        Button {
                            selectedSeries = nil
                        } label: {
                            menuRowLabel(text: "All Series", isSelected: selectedSeries == nil)
                        }

                        ForEach(series, id: \.self) { seriesName in
                            Button {
                                selectedSeries = seriesName
                            } label: {
                                menuRowLabel(
                                    text: seriesName,
                                    isSelected: selectedSeries == seriesName
                                )
                            }
                        }
                    } label: {
                        Label("Select Series", systemImage: "books.vertical")
                    }
                }

                if !authors.isEmpty {
                    Menu {
                        Button {
                            selectedAuthor = nil
                        } label: {
                            menuRowLabel(text: "All Authors", isSelected: selectedAuthor == nil)
                        }

                        ForEach(authors, id: \.self) { authorName in
                            Button {
                                selectedAuthor = authorName
                            } label: {
                                menuRowLabel(
                                    text: authorName,
                                    isSelected: selectedAuthor == authorName
                                )
                            }
                        }
                    } label: {
                        Label("Select Author", systemImage: "person.2")
                    }
                }

                if !narrators.isEmpty {
                    Menu {
                        Button {
                            selectedNarrator = nil
                        } label: {
                            menuRowLabel(text: "All Narrators", isSelected: selectedNarrator == nil)
                        }

                        ForEach(narrators, id: \.self) { narratorName in
                            Button {
                                selectedNarrator = narratorName
                            } label: {
                                menuRowLabel(
                                    text: narratorName,
                                    isSelected: selectedNarrator == narratorName
                                )
                            }
                        }
                    } label: {
                        Label("Select Narrator", systemImage: "mic")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        Divider()
        Section("Location") {
            ForEach(MediaGridView.LocationFilterOption.allCases) { option in
                Button {
                    selectedLocation = option
                } label: {
                    menuRowLabel(text: option.label, isSelected: selectedLocation == option)
                }
            }
        }
    }

    @ViewBuilder
    private func menuRowLabel(text: String, isSelected: Bool) -> some View {
        HStack {
            Text(text)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .imageScale(.small)
            }
        }
    }

    @ViewBuilder
    private var clearMenuItem: some View {
        if canClearFilters {
            Button {
                clearFilters()
            } label: {
                menuRowLabel(text: "Clear Filters", isSelected: false)
            }
        }
    }

    private var canClearFilters: Bool {
        selectedFormatFilter != .all
            || selectedTag != nil
            || selectedSeries != nil
            || selectedAuthor != nil
            || selectedNarrator != nil
            || selectedStatus != nil
            || selectedLocation != .all
    }

    private func clearFilters() {
        selectedFormatFilter = .all
        selectedTag = nil
        selectedSeries = nil
        selectedAuthor = nil
        selectedNarrator = nil
        selectedStatus = nil
        selectedLocation = .all
    }

    @ViewBuilder
    private var viewOptionsMenu: some View {
        Menu {
            Button {
                showAudioIndicator.toggle()
            } label: {
                HStack {
                    Text("Show Audio Indicator")
                    Spacer()
                    if showAudioIndicator {
                        Image(systemName: "checkmark")
                            .imageScale(.small)
                    }
                }
            }

            Button {
                showSourceBadge.toggle()
            } label: {
                HStack {
                    Text("Show Source Badge")
                    Spacer()
                    if showSourceBadge {
                        Image(systemName: "checkmark")
                            .imageScale(.small)
                    }
                }
            }
        } label: {
            Label("View Options", systemImage: "ellipsis.circle")
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }
}
