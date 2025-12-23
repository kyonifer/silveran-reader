import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct ImportLocalFileView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var showFileImporter = false
    @State private var importedBookId: String?
    @State private var localFiles: [BookMetadata] = []

    private var allowedContentTypes: [UTType] {
        let types = LocalMediaActor.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }

    var body: some View {
        content
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                    case .success(let urls):
                        if let url = urls.first {
                            importSelectedFile(from: url)
                        }
                    case .failure:
                        break
                }
            }
            .task {
                await refreshLocalFiles()
            }
            .onChange(of: mediaViewModel.library.bookMetaData.count) {
                Task {
                    await refreshLocalFiles()
                }
            }
    }

    private func refreshLocalFiles() async {
        let metadata = await LocalMediaActor.shared.localStandaloneMetadata
        await MainActor.run {
            localFiles = metadata.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private func importSelectedFile(from sourceURL: URL) {
        Task {
            do {
                let accessing = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                let category = try LocalMediaActor.category(forFileURL: sourceURL)
                var bookName = sourceURL.deletingPathExtension().lastPathComponent
                if bookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    bookName = sourceURL.lastPathComponent
                }
                _ = try await LocalMediaActor.shared.importMedia(
                    from: sourceURL,
                    domain: .local,
                    category: category,
                    bookName: bookName
                )
                await refreshLocalFiles()
                await MainActor.run {
                    if let newBook = localFiles.first(where: {
                        $0.title.localizedCaseInsensitiveCompare(bookName) == .orderedSame
                    }) {
                        importedBookId = newBook.id
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            await MainActor.run {
                                if importedBookId == newBook.id {
                                    importedBookId = nil
                                }
                            }
                        }
                    }
                }
            } catch {
                debugLog("[ImportLocalFileView] Failed to import file: \(error.localizedDescription)")
            }
        }
    }

    private func deleteLocalFile(_ book: BookMetadata) {
        Task {
            do {
                try await LocalMediaActor.shared.deleteLocalStandaloneMedia(for: book.id)
                await refreshLocalFiles()
            } catch {
                debugLog("[ImportLocalFileView] Failed to delete file: \(error.localizedDescription)")
            }
        }
    }

    private var content: some View {
        #if os(macOS)
        MacContent(
            showFileImporter: $showFileImporter,
            localFiles: localFiles,
            importedBookId: importedBookId,
            onDelete: deleteLocalFile
        )
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private struct MacContent: View {
        @Binding var showFileImporter: Bool
        let localFiles: [BookMetadata]
        let importedBookId: String?
        let onDelete: (BookMetadata) -> Void
        @State private var isDropTargeted = false
        private let dropTypeIdentifier: String = "public.file-url"

        var body: some View {
            ScrollView {
                VStack(spacing: 20) {
                    dropZone
                    Text(
                        "Alternatively, you can directly manage the Local Media folder:"
                    )
                    .multilineTextAlignment(.center)
                    Button {
                        openLocalMediaDirectory()
                    } label: {
                        Label("Open Local Media Folder", systemImage: "folder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    Text("Supports .epub and .m4b files.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !localFiles.isEmpty {
                        LocalFilesList(
                            localFiles: localFiles,
                            importedBookId: importedBookId,
                            onDelete: onDelete
                        )
                    }
                }
                .padding(32)
                .frame(maxWidth: 500)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        private func openLocalMediaDirectory() {
            Task {
                do {
                    try await LocalMediaActor.shared.ensureLocalStorageDirectories()
                    let url = await LocalMediaActor.shared.getDomainDirectory(for: .local)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    debugLog(
                        "[ImportLocalFileView] Failed to open directory: \(error.localizedDescription)"
                    )
                }
            }
        }

        private var dropZone: some View {
            Button {
                showFileImporter = true
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            isDropTargeted
                                ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05)
                        )
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        Text("Drag & Drop Files Here")
                            .font(.headline)
                        Text("Supports .epub and .m4b")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("or click to select a file")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
                .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 420)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onDrop(
                of: [dropTypeIdentifier],
                isTargeted: $isDropTargeted,
                perform: handleDrop(providers:)
            )
        }

        private func handleDrop(providers: [NSItemProvider]) -> Bool {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(dropTypeIdentifier) {
                    provider.loadItem(forTypeIdentifier: dropTypeIdentifier, options: nil) {
                        item,
                        error in
                        guard error == nil else { return }
                        guard let url = Self.resolveURL(from: item) else { return }
                        guard Self.isAllowed(url: url) else { return }

                        Task { @MainActor [url] in
                            importSelectedFileMac(from: url)
                        }
                    }
                    return true
                }
            }
            return false
        }

        private nonisolated static func resolveURL(from item: NSSecureCoding?) -> URL? {
            if let url = item as? URL { return url }
            if let nsurl = item as? NSURL { return nsurl as URL }
            if let data = item as? Data {
                return URL(dataRepresentation: data, relativeTo: nil)
            }
            if let path = item as? String { return URL(fileURLWithPath: path) }
            return nil
        }

        private nonisolated static func isAllowed(url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            if ext.isEmpty {
                return false
            }
            return LocalMediaActor.allowedExtensions.contains(ext)
        }
    }
    #endif

    #if os(iOS)
    private var iOSContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text("Local Media")
                        .font(.title2.weight(.semibold))
                    Text("Import EPUB or M4B files from the Files app.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Choose File...", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if !localFiles.isEmpty {
                    LocalFilesList(
                        localFiles: localFiles,
                        importedBookId: importedBookId,
                        onDelete: deleteLocalFile
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    #endif
}

private struct LocalFilesList: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let localFiles: [BookMetadata]
    let importedBookId: String?
    let onDelete: (BookMetadata) -> Void
    @State private var bookToDelete: BookMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local Files")
                .font(.headline)
                .padding(.top, 8)

            ForEach(localFiles) { book in
                LocalFileRow(
                    book: book,
                    isNewlyImported: book.id == importedBookId,
                    onDelete: { bookToDelete = book }
                )
            }
        }
        .confirmationDialog(
            "Delete \(bookToDelete?.title ?? "this file")?",
            isPresented: Binding(
                get: { bookToDelete != nil },
                set: { if !$0 { bookToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let book = bookToDelete {
                    onDelete(book)
                }
                bookToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                bookToDelete = nil
            }
        } message: {
            Text("This will permanently remove the file from your device.")
        }
    }
}

private struct LocalFileRow: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    let book: BookMetadata
    let isNewlyImported: Bool
    let onDelete: () -> Void

    private let coverSize: CGFloat = 50

    var body: some View {
        HStack(spacing: 12) {
            coverImage
                .frame(width: coverSize, height: coverSize * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                    .lineLimit(2)
                if let author = book.authors?.first?.name {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                mediaTypeLabel
            }

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isNewlyImported ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
        }
        .overlay {
            if isNewlyImported {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.green, lineWidth: 2)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isNewlyImported)
    }

    @ViewBuilder
    private var coverImage: some View {
        let image = mediaViewModel.coverImage(for: book, variant: .standard)
        ZStack {
            Color.secondary.opacity(0.2)
            if let image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            mediaViewModel.ensureCoverLoaded(for: book, variant: .standard)
        }
    }

    @ViewBuilder
    private var mediaTypeLabel: some View {
        HStack(spacing: 4) {
            if book.hasAvailableEbook {
                Label("eBook", systemImage: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if book.hasAvailableAudiobook {
                Label("Audio", systemImage: "headphones")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if os(macOS)
private func importSelectedFileMac(from sourceURL: URL) {
    Task {
        do {
            let category = try LocalMediaActor.category(forFileURL: sourceURL)
            var bookName = sourceURL.deletingPathExtension().lastPathComponent
            if bookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bookName = sourceURL.lastPathComponent
            }
            _ = try await LocalMediaActor.shared.importMedia(
                from: sourceURL,
                domain: .local,
                category: category,
                bookName: bookName
            )
            debugLog("[ImportLocalFileView] Imported file to local media")
        } catch {
            debugLog("[ImportLocalFileView] Failed to import file: \(error.localizedDescription)")
        }
    }
}
#endif
