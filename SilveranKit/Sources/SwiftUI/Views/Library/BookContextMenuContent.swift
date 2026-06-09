#if os(macOS)
import AppKit
import SwiftUI

struct BookContextMenuContent: View {
    let item: BookMetadata
    var onInfo: ((BookMetadata) -> Void)? = nil
    var onEditMetadata: (([String]) -> Void)? = nil
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let onInfo {
            Button {
                onInfo(item)
            } label: {
                Label("Show Book Information", systemImage: "info.circle")
            }
        }

        if let onEditMetadata {
            Button {
                onEditMetadata([item.uuid])
            } label: {
                Label("Edit Metadata...", systemImage: "pencil")
            }
        }

        deleteSection

        alignSection

        if hasServerActions {
            Divider()

            Menu {
                processingSection

                epubUpgradeSection

                serverMediaSection
            } label: {
                Label("Server Actions", systemImage: "server.rack")
            }
        }
    }

    private var hasServerActions: Bool {
        mediaViewModel.isServerBook(item.id)
    }

    private var canAlignFromSource: Bool {
        item.hasAvailableEbook && item.hasAvailableAudiobook
            && (mediaViewModel.isServerBook(item.id) || mediaViewModel.isLocalFolderBook(item.id))
    }

    private var alignMenuTitle: String {
        item.hasAvailableReadaloud ? "Realign" : "Align"
    }

    private var hasProcessingActions: Bool {
        let status = item.readaloud?.status?.uppercased() ?? ""
        return status == "PROCESSING" || status == "QUEUED" || status == "ALIGNED"
            || status == "ERROR" || status == "STOPPED"
            || (item.hasAvailableEbook && item.hasAvailableAudiobook)
    }

    @ViewBuilder
    private var alignSection: some View {
        if canAlignFromSource {
            Divider()

            Button {
                if let data = LocalReadaloudAlignmentLauncher.data(
                    for: item,
                    mediaViewModel: mediaViewModel,
                ) {
                    openWindow(
                        id: "ReadaloudGenerator",
                        value: data,
                    )
                }
            } label: {
                Label("\(alignMenuTitle) Locally", systemImage: "desktopcomputer")
            }
        }
    }

    @ViewBuilder
    private var processingSection: some View {
        let status = item.readaloud?.status?.uppercased() ?? ""
        let hasEbookAndAudio = item.hasAvailableEbook && item.hasAvailableAudiobook

        if status == "PROCESSING" || status == "QUEUED" {
            Button {
                Task {
                    _ = await BookServiceActor.shared.cancelAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Cancel Processing", systemImage: "xmark.circle")
            }
        } else if status == "ALIGNED" {
            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                        restart: .sync,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Re-align (Fast)", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                        restart: .transcription,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Re-transcribe & Align", systemImage: "waveform")
            }

            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                        restart: .full,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Full Reprocess", systemImage: "arrow.counterclockwise")
            }
        } else if status == "ERROR" || status == "STOPPED" {
            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                        restart: .full,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Retry Processing", systemImage: "arrow.counterclockwise")
            }

            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                        restart: .sync,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Re-align Only", systemImage: "arrow.triangle.2.circlepath")
            }
        } else if hasEbookAndAudio {
            Button {
                Task {
                    _ = await BookServiceActor.shared.startAlignment(
                        for: item.uuid,
                        sourceID: item.sourceID,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Create Readaloud", systemImage: "text.bubble")
            }
        }
    }

    @ViewBuilder
    private var epubUpgradeSection: some View {
        if item.canUpgradeToEpub3 {
            if hasProcessingActions {
                Divider()
            }
            Button {
                Task {
                    _ = await BookServiceActor.shared.upgradeEpub(
                        for: item.uuid,
                        sourceID: item.sourceID,
                    )
                    await BookServiceActor.shared.fetchLibraryInformation()
                }
            } label: {
                Label("Convert to EPUB 3", systemImage: "doc.badge.arrow.up")
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        let ebookCached = mediaViewModel.hasCachedMedia(.ebook, for: item)
        let audioCached = mediaViewModel.hasCachedMedia(.audio, for: item)
        let syncedCached = mediaViewModel.hasCachedMedia(.synced, for: item)
        let isFolderBook = mediaViewModel.isLocalFolderBook(item.id)

        if isFolderBook {
            Divider()

            Menu {
                if item.hasAvailableEbook {
                    Button(role: .destructive) {
                        confirmDeleteSourceAsset(.ebook)
                    } label: {
                        Label("Delete Ebook", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }

                if item.hasAvailableAudiobook {
                    Button(role: .destructive) {
                        confirmDeleteSourceAsset(.audiobook)
                    } label: {
                        Label("Delete Audiobook", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }

                if item.hasAvailableReadaloud {
                    Button(role: .destructive) {
                        confirmDeleteSourceAsset(.readaloud)
                    } label: {
                        Label("Delete Readaloud", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .tint(.red)
                }

                Divider()

                Button(role: .destructive) {
                    confirmDeleteSourceBook()
                } label: {
                    Label("Delete All", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .tint(.red)
            } label: {
                Label("Delete from Folder", systemImage: "trash")
            }
            .tint(.red)
        } else if ebookCached || audioCached || syncedCached {
            Divider()

            if ebookCached {
                Button(role: .destructive) {
                    confirmDeleteLocalDownload(.ebook)
                } label: {
                    Label("Delete Local Ebook", systemImage: "trash")
                }
            }

            if audioCached {
                Button(role: .destructive) {
                    confirmDeleteLocalDownload(.audio)
                } label: {
                    Label("Delete Local Audiobook", systemImage: "trash")
                }
            }

            if syncedCached {
                Button(role: .destructive) {
                    confirmDeleteLocalDownload(.synced)
                } label: {
                    Label("Delete Local Readaloud", systemImage: "trash")
                }
            }
        }
    }

    private func confirmDeleteLocalDownload(_ category: LocalMediaCategory) {
        let label = localMediaLabel(category)
        guard
            confirmDestructiveAction(
                title: "Delete Local \(label)?",
                message: "This will remove the downloaded \(label.lowercased()) from this device.",
                buttonTitle: "Delete",
            )
        else { return }
        mediaViewModel.deleteDownload(for: item, category: category)
    }

    private func confirmDeleteSourceAsset(_ format: StorytellerBookFormat) {
        let label = sourceAssetLabel(format)
        guard
            confirmDestructiveAction(
                title: "Delete \(label) from Folder?",
                message:
                    "This will permanently delete the \(label.lowercased()) file from the folder source. This cannot be undone.",
                buttonTitle: "Delete",
            )
        else { return }
        Task {
            let result = await BookServiceActor.shared.deleteBookAsset(
                item.id,
                sourceID: item.sourceID,
                type: format,
            )
            await mediaViewModel.refreshMetadata(source: "BookContextMenuContent.deleteSourceAsset")
            let didDelete = {
                if case StorytellerActor.DeleteAssetResult.success = result {
                    return true
                }
                return false
            }()
            mediaViewModel.showSyncNotification(
                SyncNotification(
                    message: didDelete
                        ? "Deleted \(label.lowercased()) from folder source"
                        : "Failed to delete \(label.lowercased())",
                    type: didDelete ? .success : .error,
                )
            )
        }
    }

    private func confirmDeleteSourceBook() {
        guard
            confirmDestructiveAction(
                title: "Delete All from Folder?",
                message:
                    "This will permanently delete \(item.title) and all its media from the folder source. This cannot be undone.",
                buttonTitle: "Delete All",
            )
        else { return }
        Task {
            let success = await mediaViewModel.deleteBookFromSource(item)
            mediaViewModel.showSyncNotification(
                SyncNotification(
                    message: success
                        ? "Deleted \(item.title) from folder source"
                        : "Failed to delete \(item.title)",
                    type: success ? .success : .error,
                )
            )
        }
    }

    private func localMediaLabel(_ category: LocalMediaCategory) -> String {
        switch category {
            case .ebook:
                return "Ebook"
            case .audio:
                return "Audiobook"
            case .synced:
                return "Readaloud"
        }
    }

    private func sourceAssetLabel(_ format: StorytellerBookFormat) -> String {
        switch format {
            case .ebook:
                return "Ebook"
            case .audiobook:
                return "Audiobook"
            case .readaloud:
                return "Readaloud"
        }
    }

    private func confirmDestructiveAction(
        title: String,
        message: String,
        buttonTitle: String,
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: buttonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @ViewBuilder
    private var serverMediaSection: some View {
        if mediaViewModel.isServerBook(item.id) {
            if hasProcessingActions || item.canUpgradeToEpub3 {
                Divider()
            }
            Button {
                openWindow(
                    id: "ServerMediaManagement",
                    value: ServerMediaManagementData(bookId: item.id),
                )
            } label: {
                Label("Manage Server Media...", systemImage: "server.rack")
            }
        }
    }
}
#endif
