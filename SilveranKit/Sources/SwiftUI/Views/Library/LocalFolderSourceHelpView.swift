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
                    ScrollView {
                        layoutTab(layout)
                    }
                    .tag(layout)
                    .tabItem { Label(layout.title, systemImage: layout.systemImage) }
                }
            }
        }
        #if os(macOS)
        .frame(width: 820, height: 700)
        #endif
        .textSelection(.enabled)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How Silveran Finds Your Books")
                        .font(.title2.bold())
                    Text("Simply copy files into this folder and they will appear. Silveran automatically groups different media into books according to a set of rules, described below.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How files are combined into one book")
                        .font(.headline)
                    matchingRule(
                        "Two files in the same folder combine only when one filename is the start of the other, like \"Jade City.epub\" and \"Jade City - Fonda Lee.m4b\". Names that share a common prefix but then differ are kept separate."
                    )
                    matchingRule(
                        "When names are compared, capitalization, punctuation, a trailing number, and format words like readaloud, unabridged, ebook, and audiobook are ignored."
                    )
                    matchingRule(
                        "A book's title and cover come from the file's own embedded details when available, otherwise from the shared name."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Three common folder layouts are supported, shown in the tabs below.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func matchingRule(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
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
                "Put all the files for one book (the ebook, a readaloud EPUB, and the audio tracks) in their own folder. Silveran combines files in that folder when one filename is the start of another."
            case .mediaTypeSubfolders:
                "Give each book its own folder, then sort its files into audio, ebook, and synced subfolders. Here the subfolders do the grouping, so the filenames don't need to match."
            case .collectionFolders:
                "Drop many books straight into the source folder, or sort them into nested folders for collections, series, or authors. Within each folder, files combine when one filename is the start of another; anything without a match becomes its own book."
        }
    }

    var rules: [String] {
        switch self {
            case .singleFolder:
                [
                    "Names are matched after ignoring case, punctuation, a trailing number, and format words.",
                    "The shortest name anchors the book; a longer name that starts with it (a title plus an author, say) joins it.",
                    "One ebook EPUB and one readaloud EPUB per book; the remaining audio files are kept together as the audiobook.",
                    "Each folder is grouped on its own, so you can keep one book per folder.",
                ]
            case .mediaTypeSubfolders:
                [
                    "Put the regular EPUB in ebook.",
                    "Put a readaloud EPUB (with media overlays) in synced.",
                    "Put the audiobook files (MP3, M4B, and similar) in audio.",
                    "Everything inside one book folder is treated as a single book, whatever the files are named.",
                ]
            case .collectionFolders:
                [
                    "Books can sit loose at the top level or inside nested folders.",
                    "Files are only combined with others in the same folder, never across folders.",
                    "Within a folder, two files combine when one name is the start of the other, ignoring case, punctuation, trailing numbers, and format words.",
                    "Just copy files in. There's no import step.",
                ]
        }
    }

    var warning: String? {
        switch self {
            case .singleFolder:
                "Two files only combine when one name starts with the other. Different spellings of the same title, or a typo, are treated as separate books."
            case .mediaTypeSubfolders:
                "The names audio, ebook, and synced only have this meaning directly inside a book's folder."
            case .collectionFolders:
                "To combine files into one book, put them in the same folder. Files in different folders are never merged."
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
                                "Jade City/",
                                children: [
                                    FileTreeNode("Jade City - Fonda Lee.epub"),
                                    FileTreeNode("Jade City readaloud.epub"),
                                    FileTreeNode("Jade City 01.mp3"),
                                    FileTreeNode("Jade City 02.mp3"),
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
                                "Jade City/",
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
