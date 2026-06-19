import SwiftUI

struct LocalFolderSourceHelpButton: View {
    let title: String
    @State private var showingHelp = false

    init(title: String = "How do I add files?") {
        self.title = title
    }

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Label(title, systemImage: "questionmark.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .sheet(isPresented: $showingHelp) {
            LocalFolderSourceHelpView()
        }
    }
}

struct LocalFolderSourceHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: LocalFolderLayoutHelp = .singleFolder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $selection) {
                ForEach(LocalFolderLayoutHelp.allCases) { layout in
                    layoutTab(layout)
                        .tag(layout)
                        .tabItem { Label(layout.title, systemImage: layout.systemImage) }
                }
            }
            .frame(minWidth: 760, minHeight: 500)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Silveran Scans From the Source Folder")
                    .font(.title2.bold())
                Text(
                    "Starting at the top level, Silveran scans the folder source and assumes media is organized in one of these layouts."
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private func layoutTab(_ layout: LocalFolderLayoutHelp) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                Text(layout.title)
                    .font(.title3.bold())
                Text(layout.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(layout.rules, id: \.self) { rule in
                        Label(rule, systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.primary)
                    }
                }

                if let warning = layout.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 12) {
                Text("Example")
                    .font(.headline)
                FileTreeView(nodes: layout.treeNodes)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(24)
    }
}

private struct FileTreeView: View {
    let nodes: [FileTreeNode]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(nodes) { node in
                FileTreeNodeView(node: node, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FileTreeNodeView: View {
    let node: FileTreeNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: node.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(node.isFolder ? .blue : .secondary)
                    .frame(width: 18)
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.vertical, 4)
            .padding(.leading, CGFloat(depth) * 20)

            ForEach(node.children) { child in
                FileTreeNodeView(node: child, depth: depth + 1)
            }
        }
    }
}

private struct FileTreeNode: Identifiable {
    let id = UUID()
    let name: String
    let children: [FileTreeNode]

    init(_ name: String, children: [FileTreeNode] = []) {
        self.name = name
        self.children = children
    }

    var isFolder: Bool {
        !children.isEmpty || name.hasSuffix("/")
    }

    var systemImage: String {
        if isFolder {
            return "folder.fill"
        }
        if name.localizedCaseInsensitiveContains("readaloud") {
            return "waveform.and.book"
        }
        switch name.split(separator: ".").last?.lowercased() {
            case "epub":
                return "book.closed"
            case "mp3", "m4b", "m4a", "aac", "flac", "wav":
                return "headphones"
            default:
                return "doc"
        }
    }
}

private enum LocalFolderLayoutHelp: String, CaseIterable, Identifiable {
    case singleFolder
    case mediaTypeSubfolders
    case collectionFolders

    var id: String { rawValue }

    var title: String {
        switch self {
            case .singleFolder: "One Folder Per Book"
            case .mediaTypeSubfolders: "Media Type Subfolders"
            case .collectionFolders: "Collection Folders"
        }
    }

    var systemImage: String {
        switch self {
            case .singleFolder: "folder"
            case .mediaTypeSubfolders: "square.grid.2x2"
            case .collectionFolders: "folder.badge.plus"
        }
    }

    var summary: String {
        switch self {
            case .singleFolder:
                "Put the ebook, readaloud EPUB, and audiobook files for one work in the same folder. Silveran groups files in that folder when their names share a common prefix."
            case .mediaTypeSubfolders:
                "Put each work in its own folder, then use audio, ebook, and synced subfolders. This is useful when filenames differ or when you want the media types visually separated."
            case .collectionFolders:
                "Put many books in the source folder or in nested collection folders. Silveran uses filename prefixes to group matching media, and files without a match become individual books."
        }
    }

    var rules: [String] {
        switch self {
            case .singleFolder:
                [
                    "Audio files must share a meaningful filename prefix.",
                    "At most one ebook EPUB and one readaloud EPUB are grouped.",
                    "Subfolders are scanned, but each folder is grouped independently.",
                ]
            case .mediaTypeSubfolders:
                [
                    "Use audio for MP3, M4B, and other audiobook files.",
                    "Use ebook for a regular EPUB.",
                    "Use synced for a readaloud EPUB with media overlays.",
                ]
            case .collectionFolders:
                [
                    "Books can be flat at the top level of the source.",
                    "Nested folders can hold collections, series, authors, or any grouping you prefer.",
                    "Media in the same folder is grouped by filename prefix.",
                    "Copying new files into the source is enough; no import step is required.",
                ]
        }
    }

    var warning: String? {
        switch self {
            case .singleFolder:
                "If two EPUBs of the same type are in the same group, Silveran keeps them as separate works."
            case .mediaTypeSubfolders:
                "The folder names audio, ebook, and synced are special only when they are direct children of a work folder."
            case .collectionFolders:
                "Silveran does not group media across different folders. Move files into the same folder when you want them treated as one book."
        }
    }

    var treeNodes: [FileTreeNode] {
        switch self {
            case .singleFolder:
                [
                    FileTreeNode(
                        "My Library/",
                        children: [
                            FileTreeNode(
                                "This Is How You Lose the Time War/",
                                children: [
                                    FileTreeNode("This Is How You Lose the Time War.epub"),
                                    FileTreeNode(
                                        "This Is How You Lose the Time War readaloud.epub"
                                    ),
                                    FileTreeNode("This Is How You Lose the Time War 01.mp3"),
                                    FileTreeNode("This Is How You Lose the Time War 02.mp3"),
                                ],
                            )
                        ],
                    )
                ]
            case .mediaTypeSubfolders:
                [
                    FileTreeNode(
                        "My Library/",
                        children: [
                            FileTreeNode(
                                "This Is How You Lose the Time War/",
                                children: [
                                    FileTreeNode(
                                        "ebook/",
                                        children: [
                                            FileTreeNode("book.epub")
                                        ],
                                    ),
                                    FileTreeNode(
                                        "synced/",
                                        children: [
                                            FileTreeNode("readaloud.epub")
                                        ],
                                    ),
                                    FileTreeNode(
                                        "audio/",
                                        children: [
                                            FileTreeNode("audiobook.m4b")
                                        ],
                                    ),
                                ],
                            )
                        ],
                    )
                ]
            case .collectionFolders:
                [
                    FileTreeNode(
                        "My Library/",
                        children: [
                            FileTreeNode("Book One.epub"),
                            FileTreeNode("Book One 01.mp3"),
                            FileTreeNode("Book One 02.mp3"),
                            FileTreeNode("Book Two.epub"),
                            FileTreeNode("Book Two readaloud.epub"),
                            FileTreeNode("Book Three.epub"),
                            FileTreeNode("Book Three.m4b"),
                            FileTreeNode(
                                "Favorites/",
                                children: [
                                    FileTreeNode("Book Four.epub"),
                                    FileTreeNode("Book Four.m4b"),
                                    FileTreeNode("Book Five.epub"),
                                ],
                            ),
                        ],
                    )
                ]
        }
    }
}
