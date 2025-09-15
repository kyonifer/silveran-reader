import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct ImportLocalFileView: View {
    @State private var showFileImporter = false

    private var allowedContentTypes: [UTType] {
        let types = LocalMediaActor.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.item] : types
    }

    var body: some View {
        content
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: allowedContentTypes,
                allowsMultipleSelection: false,
            ) { result in
                switch result {
                    case .success(let urls):
                        if let url = urls.first {
                            importSelectedFile(from: url)
                        }
                    case .failure:
                        // TODO: handle this
                        break
                }
            }
    }

    private var content: some View {
        #if os(macOS)
        MacContent(showFileImporter: $showFileImporter)
        #else
        iOSContent
        #endif
    }

    #if os(macOS)
    private struct MacContent: View {
        @Binding var showFileImporter: Bool
        @State private var isDropTargeted = false
        private let dropTypeIdentifier: String = "public.file-url"

        var body: some View {
            VStack(spacing: 20) {
                dropZone
                Text(
                    "Alternatively, you can directly manage the Local Media folder:",
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
            }
            .padding(32)
            .frame(maxWidth: 500, maxHeight: .infinity, alignment: .top)
        }

        private func openLocalMediaDirectory() {
            Task {
                do {
                    try await LocalMediaActor.shared.ensureLocalStorageDirectories()
                    let url = await LocalMediaActor.shared.getDomainDirectory(for: .local)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    debugLog("[ImportLocalFileView] Failed to open directory: \(error.localizedDescription)")
                }
            }
        }

        private var dropZone: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        isDropTargeted
                            ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05),
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
            .onTapGesture { showFileImporter = true }
            .onDrop(
                of: [dropTypeIdentifier],
                isTargeted: $isDropTargeted,
                perform: handleDrop(providers:),
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
                            importSelectedFile(from: url)
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

    #else
    // TODO: finish iOS file import
    private var iOSContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Add Local Media")
                    .font(.title2.weight(.semibold))
                Text("Tap the button below to import an EPUB or M4B file from the Files app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showFileImporter = true
            } label: {
                Label("Choose File…", systemImage: "doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: 420, maxHeight: .infinity, alignment: .top)
    }
    #endif
}

private func importSelectedFile(from sourceURL: URL) {
    Task {
        do {
            let category = try LocalMediaActor.category(forFileURL: sourceURL)
            var bookName = sourceURL.deletingPathExtension().lastPathComponent
            if bookName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bookName = sourceURL.lastPathComponent
            }
            let destinationURL = try await LocalMediaActor.shared.importMedia(
                from: sourceURL,
                domain: .local,
                category: category,
                bookName: bookName
            )
            debugLog("[ImportLocalFileView] Imported file to: \(destinationURL.path)")
        } catch {
            debugLog("[ImportLocalFileView] Failed to import file: \(error.localizedDescription)")
        }
    }
}
