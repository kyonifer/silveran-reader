#if os(iOS)
import SwiftUI

struct iOSBookDetailView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var showingSyncHistory = false
    @State private var currentChapter: String?
    @State private var selectedStatusName: String?
    @State private var isUpdatingStatus = false
    @State private var showOfflineError = false
    @State private var showingOptionsSheet = false
    @AppStorage("showEbookCoverInAudioView") private var showEbookCover = false

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var mediaOptions: [MediaDownloadOption] {
        MediaGridViewUtilities.mediaDownloadOptions(for: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                coverSection
                headerSection
                progressSection
                descriptionSection
                debugInfoSection
                syncHistoryButton
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .navigationTitle("Book Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingOptionsSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showingOptionsSheet) {
            BookOptionsSheet(
                item: item,
                selectedStatusName: $selectedStatusName,
                isUpdatingStatus: $isUpdatingStatus,
                showOfflineError: $showOfflineError
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSyncHistory) {
            SyncHistorySheet(bookId: item.uuid, bookTitle: item.title)
        }
        .task {
            await loadCurrentChapter()
        }
        .onAppear {
            selectedStatusName = currentItem.status?.name
        }
        .onChange(of: currentItem.status?.name) { _, newValue in
            selectedStatusName = newValue
        }
        .alert("Cannot Change Status", isPresented: $showOfflineError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please connect to the server to change the book status.")
        }
        .navigationDestination(for: SeriesNavIdentifier.self) { series in
            MediaGridView(
                title: series.name,
                searchText: "",
                mediaKind: mediaKind,
                tagFilter: nil,
                seriesFilter: series.name,
                statusFilter: nil,
                defaultSort: "seriesPosition",
                preferredTileWidth: 110,
                minimumTileWidth: 90,
                columnBreakpoints: [
                    MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                ],
                initialNarrationFilterOption: .both
            )
            .navigationTitle(series.name)
        }
    }

    private func loadCurrentChapter() async {
        let history = await ProgressSyncActor.shared.getSyncHistory(for: item.uuid)
        if let entry = history.last(where: {
            !$0.locationDescription.isEmpty &&
            !$0.locationDescription.lowercased().contains("unknown")
        }) {
            var chapter = entry.locationDescription
            if let commaRange = chapter.range(of: ", \\d+%$", options: .regularExpression) {
                chapter = String(chapter[..<commaRange.lowerBound])
            }
            currentChapter = chapter
        }
    }

    private var headerSection: some View {
        VStack(alignment: .center, spacing: 20) {
            titleTopSection
            mediaButtonsRow
            infoSection
        }
    }

    private var mediaButtonsRow: some View {
        HStack(spacing: 12) {
            ForEach(mediaOptions) { option in
                iOSMediaButton(item: item, option: option)
            }
        }
    }

    private let labelWidth: CGFloat = 90

    private var infoSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                if let authors = item.authors, let first = authors.first?.name {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Written by")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        Text(first)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if authors.count > 1 {
                            Menu {
                                ForEach(authors, id: \.name) { author in
                                    if let name = author.name {
                                        Text(name)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let narrators = item.narrators, let first = narrators.first?.name {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Narrated by")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        Text(first)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if narrators.count > 1 {
                            Menu {
                                ForEach(narrators, id: \.name) { narrator in
                                    if let name = narrator.name {
                                        Text(name)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            StarRatingView(rating: item.rating)
                .offset(y: -2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private var titleTopSection: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(item.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if let series = item.series?.first {
                NavigationLink(value: SeriesNavIdentifier(name: series.name)) {
                    HStack(spacing: 4) {
                        Text(series.name)
                            .font(.subheadline)
                        if let position = series.position {
                            Text("•")
                                .font(.subheadline)
                            Text("Book \(position)")
                                .font(.subheadline)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var audioCover: Image? {
        mediaViewModel.coverImage(for: item, variant: .audioSquare)
    }

    private var ebookCover: Image? {
        mediaViewModel.coverImage(for: item, variant: .standard)
    }

    private var canToggleCover: Bool {
        audioCover != nil && ebookCover != nil
    }

    private var showingSquareCover: Bool {
        if showEbookCover {
            return audioCover != nil && ebookCover == nil
        } else {
            return audioCover != nil
        }
    }

    private var displayedCoverImage: Image? {
        if showEbookCover {
            return ebookCover ?? audioCover
        } else {
            return audioCover ?? ebookCover
        }
    }

    private var coverSection: some View {
        let placeholderColor = Color(white: 0.2)

        return HStack {
            Spacer()
            let coverView = Group {
                if showingSquareCover {
                    ZStack {
                        placeholderColor
                        if let image = displayedCoverImage {
                            image
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFill()
                        }
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 8)
                } else if canToggleCover {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .frame(height: 300)
                        .overlay {
                            ZStack {
                                placeholderColor
                                if let image = displayedCoverImage {
                                    image
                                        .resizable()
                                        .interpolation(.medium)
                                        .scaledToFill()
                                }
                            }
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(radius: 8)
                        }
                } else {
                    ZStack {
                        placeholderColor
                        if let image = displayedCoverImage {
                            image
                                .resizable()
                                .interpolation(.medium)
                                .scaledToFill()
                        }
                    }
                    .frame(width: 200, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 8)
                }
            }
            .task {
                mediaViewModel.ensureCoverLoaded(for: item, variant: .standard)
                if item.hasAvailableAudiobook {
                    mediaViewModel.ensureCoverLoaded(for: item, variant: .audioSquare)
                }
            }

            if canToggleCover {
                coverView
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEbookCover.toggle()
                        }
                    }
            } else {
                coverView
            }
            Spacer()
        }
    }

    private var progressSection: some View {
        let progress = mediaViewModel.progress(for: item.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reading Progress")
                    .font(.callout)
                    .fontWeight(.medium)
                SyncStatusIndicators(bookId: item.id)
                Spacer()
                if let chapter = currentChapter {
                    Text(chapter)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.45), value: progress)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = item.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(htmlToPlainText(description))
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var debugInfoSection: some View {
        if let positionUpdatedAt = currentItem.position?.updatedAt {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last Read Date")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(formatDate(positionUpdatedAt))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var syncHistoryButton: some View {
        Button {
            showingSyncHistory = true
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text("View Sync History")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private func htmlToPlainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatDate(_ isoString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        inputFormatter.timeZone = TimeZone(identifier: "UTC")
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = inputFormatter.date(from: isoString) else {
            return "Parse failed: \(isoString)"
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .medium
        outputFormatter.timeZone = TimeZone.current
        outputFormatter.locale = Locale.current

        let timeZoneName =
            TimeZone.current.localizedName(for: .shortStandard, locale: .current)
            ?? TimeZone.current.identifier
        return "\(outputFormatter.string(from: date)) (\(timeZoneName))"
    }
}

private struct iOSMediaButton: View {
    let item: BookMetadata
    let option: MediaDownloadOption
    @Environment(MediaViewModel.self) private var mediaViewModel

    @State private var showConnectionAlert = false

    private var isDownloaded: Bool {
        mediaViewModel.isCategoryDownloaded(option.category, for: item)
    }

    private var isDownloading: Bool {
        mediaViewModel.isCategoryDownloadInProgress(for: item, category: option.category)
    }

    private var downloadProgress: Double? {
        mediaViewModel.downloadProgressFraction(for: item, category: option.category)
    }

    private var hasConnectionError: Bool {
        if mediaViewModel.lastNetworkOpSucceeded == false { return true }
        if case .error = mediaViewModel.connectionStatus { return true }
        return false
    }

    private var buttonLabel: String {
        switch option.category {
        case .ebook: return "Ebook"
        case .audio: return "Audiobook"
        case .synced: return "Readaloud"
        }
    }

    private var tintColor: Color {
        isDownloaded ? .green : Color.accentColor
    }

    var body: some View {
        Group {
            if isDownloaded {
                NavigationLink(value: makePlayerBookData()) {
                    playButtonContent
                }
                .buttonStyle(.plain)
            } else if isDownloading {
                Button {
                    mediaViewModel.cancelDownload(for: item, category: option.category)
                } label: {
                    downloadingContent
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if hasConnectionError {
                        showConnectionAlert = true
                    } else {
                        mediaViewModel.startDownload(for: item, category: option.category)
                    }
                } label: {
                    downloadButtonContent
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            if isDownloaded {
                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: item, category: option.category)
                } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            }
        }
        .alert("Connection Error", isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cannot download while disconnected from the server.")
        }
    }

    private var playButtonContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
            Text(buttonLabel)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(tintColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(tintColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private var downloadButtonContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14, weight: .semibold))
            Text(buttonLabel)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(tintColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(tintColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private var downloadingContent: some View {
        HStack(spacing: 6) {
            iOSCircularProgress(progress: downloadProgress)
            Text(buttonLabel)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.15))
        .clipShape(Capsule())
    }

    private func makePlayerBookData() -> PlayerBookData {
        let freshMetadata = mediaViewModel.library.bookMetaData.first { $0.id == item.id } ?? item
        let path = mediaViewModel.localMediaPath(for: item.id, category: option.category)
        let variant: MediaViewModel.CoverVariant =
            freshMetadata.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: freshMetadata, variant: variant)
        let ebookCover = freshMetadata.hasAvailableAudiobook
            ? mediaViewModel.coverImage(for: freshMetadata, variant: .standard)
            : nil
        return PlayerBookData(
            metadata: freshMetadata,
            localMediaPath: path,
            category: option.category,
            coverArt: cover,
            ebookCoverArt: ebookCover
        )
    }
}

private struct iOSCircularProgress: View {
    let progress: Double?
    @State private var rotation: Double = 0

    private let size: CGFloat = 18
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.3), lineWidth: lineWidth)
                .frame(width: size, height: size)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(progress)))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(Color.accentColor)
                    .rotationEffect(.degrees(rotation))
                    .frame(width: size, height: size)
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }
        }
    }
}

private struct CompactStatusPicker: View {
    let item: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel

    @State private var selectedStatusName: String?
    @State private var isUpdating = false
    @State private var showOfflineError = false

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var sortedStatuses: [BookStatus] {
        mediaViewModel.availableStatuses.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if !sortedStatuses.isEmpty {
                Menu {
                    ForEach(sortedStatuses, id: \.name) { status in
                        Button {
                            guard status.name != selectedStatusName else { return }
                            Task { await updateStatus(to: status.name) }
                        } label: {
                            if status.name == selectedStatusName {
                                Label(status.name, systemImage: "checkmark")
                            } else {
                                Text(status.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedStatusName ?? "-")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isUpdating)
            } else if let statusName = currentItem.status?.name {
                Text(statusName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            if isUpdating {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .onAppear {
            selectedStatusName = currentItem.status?.name
        }
        .onChange(of: currentItem.status?.name) { _, newValue in
            selectedStatusName = newValue
        }
        .alert("Cannot Change Status", isPresented: $showOfflineError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please connect to the server to change the book status.")
        }
    }

    private func updateStatus(to statusName: String) async {
        guard mediaViewModel.connectionStatus == .connected else {
            showOfflineError = true
            selectedStatusName = currentItem.status?.name
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let success = await StorytellerActor.shared.updateStatus(
            forBooks: [item.uuid],
            toStatusNamed: statusName
        )

        if success {
            if let newStatus = mediaViewModel.availableStatuses.first(where: { $0.name == statusName }) {
                await LocalMediaActor.shared.updateBookStatus(
                    bookId: item.uuid,
                    status: newStatus
                )
            }
        } else {
            selectedStatusName = currentItem.status?.name
        }
    }
}

private struct BookOptionsSheet: View {
    let item: BookMetadata
    @Binding var selectedStatusName: String?
    @Binding var isUpdatingStatus: Bool
    @Binding var showOfflineError: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var sortedStatuses: [BookStatus] {
        mediaViewModel.availableStatuses.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    StatusPickerView(
                        item: item,
                        selectedStatusName: $selectedStatusName,
                        isUpdatingStatus: $isUpdatingStatus,
                        showOfflineError: $showOfflineError
                    )
                } label: {
                    HStack {
                        Label("Status", systemImage: "bookmark")
                        Spacer()
                        if isUpdatingStatus {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(selectedStatusName ?? "-")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if selectedStatusName == nil {
                selectedStatusName = currentItem.status?.name
            }
        }
    }
}

private struct StatusPickerView: View {
    let item: BookMetadata
    @Binding var selectedStatusName: String?
    @Binding var isUpdatingStatus: Bool
    @Binding var showOfflineError: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss

    private var sortedStatuses: [BookStatus] {
        mediaViewModel.availableStatuses.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        let statuses = sortedStatuses
        return List {
            ForEach(statuses, id: \.name) { (status: BookStatus) in
                Button {
                    Task { await updateStatus(to: status.name) }
                } label: {
                    HStack {
                        Text(status.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if status.name == selectedStatusName {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .disabled(isUpdatingStatus)
            }
        }
        .navigationTitle("Status")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func updateStatus(to statusName: String) async {
        guard statusName != selectedStatusName else { return }
        guard mediaViewModel.connectionStatus == .connected else {
            showOfflineError = true
            return
        }

        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        let success = await StorytellerActor.shared.updateStatus(
            forBooks: [item.uuid],
            toStatusNamed: statusName
        )

        if success {
            if let newStatus = mediaViewModel.availableStatuses.first(where: { $0.name == statusName }) {
                await LocalMediaActor.shared.updateBookStatus(
                    bookId: item.uuid,
                    status: newStatus
                )
                selectedStatusName = statusName
            }
            dismiss()
        }
    }
}

private struct StarRatingView: View {
    let rating: Double?

    private var roundedRating: Double {
        guard let rating else { return 0 }
        return (rating * 2).rounded() / 2
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                starImage(for: index)
                    .font(.system(size: 14))
                    .foregroundStyle(rating == nil ? Color.gray.opacity(0.4) : .yellow)
            }
        }
    }

    private func starImage(for index: Int) -> Image {
        let starValue = Double(index) + 1
        if roundedRating >= starValue {
            return Image(systemName: "star.fill")
        } else if roundedRating >= starValue - 0.5 {
            return Image(systemName: "star.leadinghalf.filled")
        } else {
            return Image(systemName: "star")
        }
    }
}
#endif
