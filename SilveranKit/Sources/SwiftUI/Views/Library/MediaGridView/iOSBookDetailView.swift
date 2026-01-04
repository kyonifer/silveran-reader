#if os(iOS)
import SwiftUI

struct iOSBookDetailView: View {
    let item: BookMetadata
    let mediaKind: MediaKind
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var showingSyncHistory = false
    @State private var currentChapter: String?
    @State private var forceCompactButtons = false

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
        .sheet(isPresented: $showingSyncHistory) {
            SyncHistorySheet(bookId: item.uuid, bookTitle: item.title)
        }
        .task {
            await loadCurrentChapter()
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
        VStack(alignment: .leading, spacing: 24) {
            titleTopSection
            GeometryReader { geo in
                let autoCompact = geo.size.width < 380
                let useCompact = autoCompact || forceCompactButtons
                let expandedLeftWidth = useCompact ? geo.size.width - 80 : leftColumnWidth
                ZStack(alignment: .topLeading) {
                    leftInfoColumn(width: expandedLeftWidth)
                    VStack(alignment: .trailing, spacing: 8) {
                        ForEach(mediaOptions) { option in
                            CompactMediaButton(item: item, option: option, useCompactLayout: useCompact)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !autoCompact {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    forceCompactButtons.toggle()
                                }
                            } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .rotationEffect(.degrees(forceCompactButtons ? 180 : 0))
                                    .frame(width: 44, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 0, y: 32)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(height: max(CGFloat(mediaOptions.count) * 40, 140))
        }
    }

    private let leftColumnWidth: CGFloat = 200

    private let labelWidth: CGFloat = 90

    @ViewBuilder
    private func leftInfoColumn(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let author = item.authors?.first?.name {
                HStack(alignment: .top, spacing: 0) {
                    Text("Written by")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(author)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            if let narrator = item.narrators?.first?.name {
                HStack(alignment: .top, spacing: 0) {
                    Text("Narrated by")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(narrator)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            CompactStatusPicker(item: item, labelWidth: labelWidth)

            if let chapter = currentChapter {
                HStack(alignment: .top, spacing: 0) {
                    Text("Chapter")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    Text(chapter)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var titleTopSection: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(item.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)

            if let series = item.series?.first {
                HStack(spacing: 4) {
                    Text(series.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let position = series.position {
                        Text("•")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Book \(position)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var coverSection: some View {
        let variant = mediaViewModel.coverVariant(for: item)
        let image = mediaViewModel.coverImage(for: item, variant: variant)
        let placeholderColor = Color(white: 0.2)

        return HStack {
            Spacer()
            ZStack {
                placeholderColor
                if let image {
                    image
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                }
            }
            .frame(width: 200, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8)
            .task {
                mediaViewModel.ensureCoverLoaded(for: item, variant: variant)
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

private struct CompactMediaButton: View {
    let item: BookMetadata
    let option: MediaDownloadOption
    let useCompactLayout: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    @State private var showConnectionAlert = false
    @State private var swipeOffset: CGFloat = 0
    @State private var showingDelete = false

    private let cornerRadius: CGFloat = 8
    private let deleteButtonWidth: CGFloat = 60

    private var totalWidth: CGFloat {
        useCompactLayout ? 64 : 155
    }

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

    var body: some View {
        ZStack(alignment: .trailing) {
            if isDownloaded {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingDelete = false
                        swipeOffset = 0
                    }
                    mediaViewModel.deleteDownload(for: item, category: option.category)
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: deleteButtonWidth, height: 32)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
                .buttonStyle(.plain)
                .opacity(swipeOffset < -10 ? 1 : 0)
            }

            HStack(spacing: 0) {
                mainActionArea
                trailingSection
            }
            .frame(width: totalWidth, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .offset(x: swipeOffset)
            .highPriorityGesture(
                isDownloaded ? DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        if value.translation.width < 0 {
                            swipeOffset = max(value.translation.width, -deleteButtonWidth - 8)
                        } else if showingDelete {
                            swipeOffset = min(0, -deleteButtonWidth - 8 + value.translation.width)
                        }
                    }
                    .onEnded { value in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if value.translation.width < -30 {
                                showingDelete = true
                                swipeOffset = -deleteButtonWidth - 8
                            } else {
                                showingDelete = false
                                swipeOffset = 0
                            }
                        }
                    } : nil
            )
            .contextMenu {
                if isDownloaded {
                    Button(role: .destructive) {
                        mediaViewModel.deleteDownload(for: item, category: option.category)
                    } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }
            }
        }
        .alert("Connection Error", isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cannot download while disconnected from the server.")
        }
    }

    @ViewBuilder
    private var mainActionArea: some View {
        if isDownloaded {
            NavigationLink(value: makePlayerBookData()) {
                pillContent(icon: playIcon)
            }
            .buttonStyle(.plain)
        } else if isDownloading {
            pillContent(icon: downloadingIcon)
        } else {
            Button {
                if hasConnectionError {
                    showConnectionAlert = true
                } else {
                    mediaViewModel.startDownload(for: item, category: option.category)
                }
            } label: {
                pillContent(icon: downloadIcon)
            }
            .buttonStyle(.plain)
        }
    }

    private func pillContent(icon: some View) -> some View {
        HStack(spacing: 0) {
            icon
            if !useCompactLayout {
                Text(buttonLabel)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color(.secondarySystemBackground))
            }
        }
        .contentShape(Rectangle())
    }

    private var playIcon: some View {
        ZStack {
            Color.green
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }

    private var downloadIcon: some View {
        ZStack {
            Color.blue
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
    }

    private var downloadingIcon: some View {
        ZStack {
            Color.blue
            CircularDownloadProgress(progress: downloadProgress)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var trailingSection: some View {
        if isDownloading {
            Button {
                mediaViewModel.cancelDownload(for: item, category: option.category)
            } label: {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: mediaTypeIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 32, height: 32)
        }
    }

    private var mediaTypeIcon: String {
        switch option.category {
        case .ebook: return "book.fill"
        case .audio: return "headphones"
        case .synced: return "waveform"
        }
    }

    private func makePlayerBookData() -> PlayerBookData {
        let freshMetadata = mediaViewModel.library.bookMetaData.first { $0.id == item.id } ?? item
        let path = mediaViewModel.localMediaPath(for: item.id, category: option.category)
        let variant: MediaViewModel.CoverVariant =
            freshMetadata.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: freshMetadata, variant: variant)
        return PlayerBookData(
            metadata: freshMetadata,
            localMediaPath: path,
            category: option.category,
            coverArt: cover
        )
    }
}

private struct CircularDownloadProgress: View {
    let progress: Double?
    @State private var rotation: Double = 0

    private let size: CGFloat = 16
    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: lineWidth)
                .frame(width: size, height: size)

            if let progress {
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(progress)))
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-90))
                    .frame(width: size, height: size)
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .foregroundStyle(.white)
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
    let labelWidth: CGFloat
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
        HStack(alignment: .top, spacing: 0) {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
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
                        Text(selectedStatusName ?? "Status")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
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
                    .foregroundStyle(.secondary)
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
#endif
