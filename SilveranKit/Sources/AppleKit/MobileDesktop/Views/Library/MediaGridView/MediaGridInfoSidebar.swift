#if os(iOS) || os(macOS)
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct MediaGridInfoSidebar: View {
    let item: BookMetadata
    let mediaKind: MediaKind?
    let onClose: () -> Void
    let onReadNow: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onSeriesSelected: ((String) -> Void)?

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var animatedProgress: Double = 0
    @State private var showingSyncHistory = false
    @State private var attributedDescription: AttributedString? = nil
    @State private var descriptionTask: Task<Void, Never>? = nil

    init(
        item: BookMetadata,
        mediaKind: MediaKind? = nil,
        onClose: @escaping () -> Void,
        onReadNow: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSeriesSelected: ((String) -> Void)? = nil,
    ) {
        self.item = item
        self.mediaKind = mediaKind
        self.onClose = onClose
        self.onReadNow = onReadNow
        self.onRename = onRename
        self.onDelete = onDelete
        self.onSeriesSelected = onSeriesSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .padding(.vertical, 12)
            ScrollView {
                content
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(.thinMaterial)
        #endif
        .onAppear {
            prepareForDisplay()
            loadDescription()
        }
        .onChange(of: item.id) { _, _ in
            prepareForDisplay()
            loadDescription()
        }
        .onChange(of: mediaViewModel.progress(for: item.id)) { _, newValue in
            withAnimation(.easeOut(duration: 0.45)) {
                animatedProgress = newValue
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let seriesList = item.series, !seriesList.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(seriesList, id: \.name) { series in
                            if let onSeriesSelected {
                                Button {
                                    onSeriesSelected(series.name)
                                } label: {
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
                                .fixedSize(horizontal: false, vertical: true)
                            } else {
                                HStack(spacing: 4) {
                                    Text(series.name)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let formatted = series.formattedPosition {
                                        Text("•")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text("Book \(formatted)")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            }
                        }
                    }
                }
                if let authors = item.authors, let first = authors.first?.name {
                    HStack(spacing: 4) {
                        Text(first)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
                                    .frame(width: 24, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let narrators = item.narrators, let first = narrators.first?.name {
                    HStack(spacing: 4) {
                        Text("Narrated by \(first)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
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
                                    .frame(width: 24, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            progressSection
            BookStatusSection(item: item)
            MediaGridDownloadSection(item: item)
            descriptionSection
            lastReadDateSection
            syncHistoryButton
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .sheet(isPresented: $showingSyncHistory) {
            SyncHistorySheet(bookId: item.id, bookTitle: item.title)
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
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reading Progress")
                    .font(.callout)
                    .fontWeight(.medium)
                SyncStatusIndicators(bookId: item.id)
                Spacer()
                Text(progressLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: animatedProgress, total: 1)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.45), value: animatedProgress)
        }
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if item.description?.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.callout)
                    .fontWeight(.medium)
                if let attributedDescription {
                    Text(attributedDescription)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Loading description...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var lastReadDateSection: some View {
        if let positionUpdatedAt = item.position?.updatedAt {
            VStack(alignment: .leading, spacing: 6) {
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

    private var progressLabel: String {
        "\(Int((mediaViewModel.progress(for: item.id) * 100).rounded()))%"
    }

    private func prepareForDisplay() {
        animatedProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) {
                self.animatedProgress = self.mediaViewModel.progress(for: self.item.id)
            }
        }
    }

    private func loadDescription() {
        descriptionTask?.cancel()
        descriptionTask = nil
        attributedDescription = nil

        guard let description = item.description, !description.isEmpty else { return }
        let itemID = item.id
        let html = description

        descriptionTask = Task.detached(priority: .userInitiated) { [html, itemID] in
            let parsed = BookDescriptionText.attributed(from: html)
            await MainActor.run {
                guard !Task.isCancelled, itemID == self.item.id else {
                    self.descriptionTask = nil
                    return
                }
                self.attributedDescription = parsed
                self.descriptionTask = nil
            }
        }
    }

    private func formatDate(_ isoString: String) -> String {
        guard let date = SilveranDate.parse(isoString, field: .lastRead) else { return isoString }
        return SilveranDate.dateTimeWithZone(date)
    }
}

#endif
