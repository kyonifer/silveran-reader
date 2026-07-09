#if os(iOS)
import SwiftUI

struct iOSBookDetailView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @Environment(\.editMetadataAction) private var editMetadataAction
    @State private var showingSyncHistory = false
    @State private var currentChapter: String?
    @State private var selectedStatusName: String?
    @State private var isUpdatingStatus = false
    @State private var showOfflineError = false
    @State private var showingOptionsSheet = false
    @State private var attributedDescription: AttributedString?
    @AppStorage("showEbookCoverInAudioView") private var showEbookCover = false

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var mediaOptions: [MediaDownloadOption] {
        MediaGridViewUtilities.mediaDownloadOptions(for: currentItem)
    }

    private var primaryMediaOptions: [MediaDownloadOption] {
        if shouldShowSeparateComicButton {
            return mediaOptions.filter { $0.category != .ebook }
        }
        return mediaOptions
    }

    private var isComicBook: Bool {
        guard let filepath = currentItem.ebook?.filepath else { return false }
        return URL(fileURLWithPath: filepath).pathExtension.lowercased() == "cbz"
    }

    private var shouldShowSeparateComicButton: Bool {
        isComicBook
            && mediaOptions.contains { $0.category == .ebook }
            && mediaOptions.contains { $0.category != .ebook }
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
                availableStatuses: sortedStatuses,
                selectedStatusName: $selectedStatusName,
                isUpdatingStatus: $isUpdatingStatus,
                showOfflineError: $showOfflineError,
                editMetadataAction: editMetadataAction,
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
                viewOptionsKey: "seriesView.\(mediaKind.rawValue)",
                tagFilter: nil,
                seriesFilter: series.name,
                statusFilter: nil,
                defaultSort: "seriesPosition",
                preferredTileWidth: 110,
                minimumTileWidth: 90,
                columnBreakpoints: [
                    MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                ],
                initialNarrationFilterOption: .both,
            )
            .navigationTitle(series.name)
        }
    }

    private func loadCurrentChapter() async {
        let history = await ProgressSyncActor.shared.getSyncHistory(for: item.uuid)
        if let entry = history.last(where: {
            !$0.locationDescription.isEmpty
                && !$0.locationDescription.lowercased().contains("unknown")
        }) {
            var chapter = entry.locationDescription
            if let commaRange = chapter.range(of: ", \\d+%$", options: .regularExpression) {
                chapter = String(chapter[..<commaRange.lowerBound])
            }
            currentChapter = chapter
        }
    }

    private func displayName(for statusName: String) -> String {
        switch statusName.lowercased() {
            case "read": return "Completed"
            case "reading": return "Currently Reading"
            case "to read": return "To Read"
            default: return statusName
        }
    }

    private var sortedStatuses: [BookStatus] {
        guard let sourceID = currentItem.sourceID else { return [] }
        return mediaViewModel.availableStatusesBySourceID[sourceID] ?? []
    }

    private func updateStatus(to statusName: String) async {
        let sourceID = currentItem.sourceID
        guard
            await BookServiceActor.shared.connectionStatus(sourceID: sourceID) == .connected
        else {
            showOfflineError = true
            selectedStatusName = currentItem.status?.name
            return
        }

        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        let success = await BookServiceActor.shared.updateStatus(
            forBooks: [item.uuid],
            sourceID: sourceID,
            toStatusNamed: statusName,
        )

        if !success {
            selectedStatusName = currentItem.status?.name
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
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(primaryMediaOptions) { option in
                    iOSMediaButton(
                        item: currentItem,
                        option: option,
                        labelOverride: isComicBook && option.category == .ebook ? "Comic" : nil,
                    )
                }
                if currentItem.canShowCreateReadaloud {
                    iOSCreateReadaloudButton(item: currentItem)
                }
            }
            if shouldShowSeparateComicButton,
                let ebookOption = mediaOptions.first(where: { $0.category == .ebook })
            {
                iOSMediaButton(item: currentItem, option: ebookOption, labelOverride: "Comic")
                    .frame(maxWidth: 180)
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

            if let seriesList = item.series, !seriesList.isEmpty {
                VStack(spacing: 4) {
                    ForEach(seriesList, id: \.name) { series in
                        NavigationLink(value: SeriesNavIdentifier(name: series.name)) {
                            HStack(spacing: 4) {
                                Text(series.name)
                                    .font(.subheadline)
                                if let formatted = series.formattedPosition {
                                    Text("•")
                                        .font(.subheadline)
                                    Text("Book \(formatted)")
                                        .font(.subheadline)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progress, total: 1)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.45), value: progress)

            HStack {
                if let chapter = currentChapter {
                    Text("Chapter: \(chapter)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !sortedStatuses.isEmpty {
                    Menu {
                        ForEach(sortedStatuses, id: \.name) { status in
                            Button {
                                guard status.name != selectedStatusName else { return }
                                Task { await updateStatus(to: status.name) }
                            } label: {
                                if status.name == selectedStatusName {
                                    Label(displayName(for: status.name), systemImage: "checkmark")
                                } else {
                                    Text(displayName(for: status.name))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isUpdatingStatus {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(
                                displayName(
                                    for: selectedStatusName ?? currentItem.status?.name ?? "-"
                                )
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingStatus)
                } else if let statusName = currentItem.status?.name {
                    Text(displayName(for: statusName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if let description = item.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(attributedDescription ?? AttributedString())
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .task(id: description) {
                attributedDescription = await Task.detached(priority: .userInitiated) {
                    BookDescriptionText.attributed(from: description)
                }.value
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

    private func formatDate(_ isoString: String) -> String {
        guard let date = SilveranDate.parse(isoString, field: .lastRead) else { return isoString }
        return SilveranDate.dateTimeWithZone(date)
    }
}

private struct iOSMediaButton: View {
    let item: BookMetadata
    let option: MediaDownloadOption
    var labelOverride: String? = nil
    @Environment(MediaViewModel.self) private var mediaViewModel

    @State private var showConnectionAlert = false

    private var isDownloaded: Bool {
        mediaViewModel.isCategoryDownloaded(option.category, for: item)
    }

    private var isDownloading: Bool {
        mediaViewModel.isCategoryDownloadInProgress(for: item, category: option.category)
    }

    private var isFailed: Bool {
        !isDownloading
            && mediaViewModel.isCategoryDownloadFailed(for: item, category: option.category)
    }

    private var downloadProgress: Double? {
        mediaViewModel.downloadProgressFraction(for: item, category: option.category)
    }

    private var hasConnectionError: Bool {
        mediaViewModel.hasConnectionError(forSourceID: item.sourceID)
    }

    private var buttonLabel: String {
        if let labelOverride { return labelOverride }
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
            } else if isFailed {
                Button {
                    mediaViewModel.startDownload(for: item, category: option.category)
                } label: {
                    failedButtonContent
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
            if isDownloaded && mediaViewModel.hasCachedMedia(option.category, for: item) {
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

    private var failedButtonContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
            Text("Retry \(buttonLabel)")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.15))
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
        let ebookCover =
            freshMetadata.hasAvailableAudiobook
            ? mediaViewModel.coverImage(for: freshMetadata, variant: .standard)
            : nil
        return PlayerBookData(
            metadata: freshMetadata,
            localMediaPath: path,
            category: option.category,
            coverArt: cover,
            ebookCoverArt: ebookCover,
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

private struct iOSCreateReadaloudButton: View {
    let item: BookMetadata
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var isStartingAlignment = false
    @State private var isCancelingAlignment = false
    @State private var showConfirmation = false

    private var readaloudStatus: String? {
        item.readaloud?.status?.uppercased()
    }

    private var isProcessingOrQueued: Bool {
        readaloudStatus == "PROCESSING" || readaloudStatus == "QUEUED"
    }

    private var isErrorOrStopped: Bool {
        readaloudStatus == "ERROR" || readaloudStatus == "STOPPED"
    }

    private var canCreateOnServer: Bool {
        mediaViewModel.isServerBook(item.id)
    }

    private var canCreateLocally: Bool {
        mediaViewModel.isServerBook(item.id) || mediaViewModel.isLocalFolderBook(item.id)
    }

    private var statusText: String? {
        guard let readaloud = item.readaloud else { return nil }
        if let stage = readaloud.currentStage, let progress = readaloud.stageProgress {
            return "\(stage): \(Int(progress * 100))%"
        } else if let pos = readaloud.queuePosition {
            return "Queued (#\(pos))"
        } else if readaloudStatus == "QUEUED" {
            return "Queued"
        } else if readaloudStatus == "PROCESSING" {
            return "Processing..."
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 4) {
            if isProcessingOrQueued {
                processingButton
            } else {
                createButton
            }
            if isProcessingOrQueued, let status = statusText {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.green.opacity(0.7))
            } else if isErrorOrStopped {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                    Text(readaloudStatus?.capitalized ?? "Error")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.red)
            }
        }
        .alert("Create Readaloud", isPresented: $showConfirmation) {
            Button("Create") {
                startServerAlignment()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will create a synchronized readaloud on the server by aligning the audiobook with the ebook."
            )
        }
    }

    private var createButton: some View {
        Menu {
            if canCreateOnServer {
                Button {
                    showConfirmation = true
                } label: {
                    Label("Create on Server", systemImage: "server.rack")
                }
            }

            if canCreateLocally {
                Button {
                    openLocalGenerator()
                } label: {
                    Label("Create Locally", systemImage: "iphone")
                }
            }
        } label: {
            createButtonContent
        }
        .buttonStyle(.plain)
        .disabled(isStartingAlignment || (!canCreateOnServer && !canCreateLocally))
    }

    private var createButtonContent: some View {
        HStack(spacing: 6) {
            if isStartingAlignment {
                ProgressView()
                    .controlSize(.small)
                    .tint(.green)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            Text("Readaloud")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(.green.opacity(0.5))
        )
    }

    private func startServerAlignment() {
        Task {
            isStartingAlignment = true
            _ = await BookServiceActor.shared.startAlignment(
                for: item.uuid,
                sourceID: item.sourceID,
                restart: isErrorOrStopped ? .full : .none,
            )
            await BookServiceActor.shared.fetchLibraryInformation()
            isStartingAlignment = false
        }
    }

    private func openLocalGenerator() {
        if let data = LocalReadaloudAlignmentLauncher.data(
            for: item,
            mediaViewModel: mediaViewModel,
        ) {
            NotificationCenter.default.post(name: .silveranCreateReadaloud, object: data)
        }
    }

    private var processingButton: some View {
        Button {
            Task {
                isCancelingAlignment = true
                _ = await BookServiceActor.shared.cancelAlignment(
                    for: item.uuid,
                    sourceID: item.sourceID,
                )
                await BookServiceActor.shared.fetchLibraryInformation()
                isCancelingAlignment = false
            }
        } label: {
            HStack(spacing: 6) {
                if isCancelingAlignment {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.green)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.green)
                }
                Text("Readaloud")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.green)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(.green.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isCancelingAlignment)
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
        guard let sourceID = currentItem.sourceID else { return [] }
        return mediaViewModel.availableStatusesBySourceID[sourceID] ?? []
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
        let sourceID = currentItem.sourceID
        guard
            await BookServiceActor.shared.connectionStatus(sourceID: sourceID) == .connected
        else {
            showOfflineError = true
            selectedStatusName = currentItem.status?.name
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        let success = await BookServiceActor.shared.updateStatus(
            forBooks: [item.uuid],
            sourceID: sourceID,
            toStatusNamed: statusName,
        )

        if !success {
            selectedStatusName = currentItem.status?.name
        }
    }
}

private struct BookOptionsSheet: View {
    let item: BookMetadata
    let availableStatuses: [BookStatus]
    @Binding var selectedStatusName: String?
    @Binding var isUpdatingStatus: Bool
    @Binding var showOfflineError: Bool
    let editMetadataAction: MetadataEditorAction?
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.uuid == item.uuid } ?? item
    }

    private var sortedStatuses: [BookStatus] {
        availableStatuses.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    StatusPickerView(
                        item: item,
                        availableStatuses: sortedStatuses,
                        selectedStatusName: $selectedStatusName,
                        isUpdatingStatus: $isUpdatingStatus,
                        showOfflineError: $showOfflineError,
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

                if let editMetadataAction {
                    Button {
                        dismiss()
                        Task { @MainActor in
                            await Task.yield()
                            editMetadataAction([item.uuid])
                        }
                    } label: {
                        Label("Edit Metadata...", systemImage: "pencil")
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
    let availableStatuses: [BookStatus]
    @Binding var selectedStatusName: String?
    @Binding var isUpdatingStatus: Bool
    @Binding var showOfflineError: Bool
    @Environment(\.dismiss) private var dismiss

    private var sortedStatuses: [BookStatus] {
        availableStatuses.sorted {
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
        let sourceID = item.sourceID
        guard
            await BookServiceActor.shared.connectionStatus(sourceID: sourceID) == .connected
        else {
            showOfflineError = true
            return
        }

        isUpdatingStatus = true
        defer { isUpdatingStatus = false }

        let success = await BookServiceActor.shared.updateStatus(
            forBooks: [item.uuid],
            sourceID: sourceID,
            toStatusNamed: statusName,
        )

        if success {
            selectedStatusName = statusName
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
