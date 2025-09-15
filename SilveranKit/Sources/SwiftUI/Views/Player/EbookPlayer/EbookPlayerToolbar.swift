import SwiftUI

#if os(macOS)
struct EbookPlayerToolbar: ToolbarContent {
    @Bindable var viewModel: EbookPlayerViewModel

    var body: some ToolbarContent {
        ToolbarItem {
            Spacer()
        }
        ToolbarItem(id: "sidebar-toggle") {
            Button {
                withAnimation(.easeInOut) { viewModel.showAudioSidebar.toggle() }
            } label: {
                Label("Toggle sidebar", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
                    .symbolVariant(viewModel.showAudioSidebar ? .fill : .none)
            }
            .help("Toggle sidebar")
        }
        if viewModel.hasAudioNarration {
            ToolbarItem(id: "sync-toggle") {
                Button {
                    viewModel.isSynced.toggle()
                    viewModel.mediaOverlayManager?.setSyncMode(enabled: viewModel.isSynced)
                } label: {
                    Image(systemName: "link")
                        .imageScale(.medium)
                        .opacity(viewModel.isSynced ? 1.0 : 0.0)
                        .overlay {
                            if !viewModel.isSynced {
                                Image(systemName: "link")
                                    .imageScale(.medium)
                                    .foregroundStyle(Color.gray.opacity(0.4))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(viewModel.isSynced ? "Audio and view are synced - click to detach" : "Audio and view are detached - click to sync")
            }
        }
        ToolbarItem(id: "search-toggle") {
            Button {
                withAnimation(.easeInOut) { viewModel.showSearchPanel.toggle() }
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .help("Search in book")
            .keyboardShortcut("f", modifiers: .command)
            .popover(isPresented: $viewModel.showSearchPanel) {
                if let searchManager = viewModel.searchManager {
                    EbookSearchPanel(
                        searchManager: searchManager,
                        onDismiss: { viewModel.showSearchPanel = false },
                        onResultSelected: { result in
                            viewModel.handleSearchResultNavigation(result)
                        }
                    )
                    .frame(width: 350, height: 450)
                }
            }
        }
        ToolbarItem(id: "customize-toggle") {
            Button {
                withAnimation(.easeInOut) { viewModel.showCustomizePopover.toggle() }
            } label: {
                Label("Customize Reader", systemImage: "textformat.size")
                    .labelStyle(.iconOnly)
            }
            .help("Customize Reader")
            .popover(isPresented: $viewModel.showCustomizePopover) {
                EbookPlayerSettings(
                    settingsVM: viewModel.settingsVM,
                    onDismiss: { viewModel.showCustomizePopover = false }
                )
                .padding()
                .frame(width: 280)
            }
        }
        ToolbarItem(id: "keybindings-help") {
            Button {
                withAnimation(.easeInOut) { viewModel.showKeybindingsPopover.toggle() }
            } label: {
                Label("Keybindings", systemImage: "questionmark.circle")
                    .labelStyle(.iconOnly)
            }
            .help("Keybindings")
            .popover(isPresented: $viewModel.showKeybindingsPopover) {
                EbookKeybindingsHelp()
                    .padding()
                    .frame(width: 280)
            }
        }
    }
}
#endif
