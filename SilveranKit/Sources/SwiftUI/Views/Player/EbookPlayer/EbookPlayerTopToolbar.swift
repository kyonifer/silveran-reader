import SwiftUI

#if os(iOS)
struct EbookPlayerTopToolbar: View {
    let hasAudioNarration: Bool
    let playbackSpeed: Double
    let chapters: [ChapterItem]
    let selectedChapterId: String?
    let isSynced: Bool

    @Binding var showCustomizePopover: Bool
    @Binding var showSearchSheet: Bool

    let searchManager: EbookSearchManager?

    let onDismiss: () -> Void
    let onPlaybackRateChange: (Double) -> Void
    let onChapterSelected: (String) -> Void
    let onSyncToggle: (Bool) async throws -> Void
    let onSearchResultSelected: (SearchResult) -> Void

    let settingsVM: SettingsViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .contentShape(Rectangle())
                }
                .frame(width: 44, height: 44)

                Spacer()

                HStack(spacing: 20) {
                    if hasAudioNarration {
                        PlaybackRateButton(
                            currentRate: playbackSpeed,
                            onRateChange: onPlaybackRateChange,
                            backgroundColor: .white,
                            foregroundColor: .white,
                            transparency: 1.0,
                            showLabel: true,
                            buttonSize: 44,
                            showBackground: false,
                            compactLabel: true
                        )
                        .alignmentGuide(VerticalAlignment.center) { d in
                            d[VerticalAlignment.top] + 22
                        }
                    }

                    ChaptersButton(
                        chapters: chapters,
                        selectedChapterId: selectedChapterId,
                        onChapterSelected: onChapterSelected,
                        backgroundColor: .white,
                        foregroundColor: .white,
                        transparency: 1.0,
                        showLabel: false,
                        buttonSize: 44,
                        showBackground: false
                    )

                    Button {
                        showSearchSheet = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.white)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 44, height: 44)
                    .sheet(isPresented: $showSearchSheet) {
                        NavigationStack {
                            if let manager = searchManager {
                                EbookSearchPanel(
                                    searchManager: manager,
                                    onDismiss: { showSearchSheet = false },
                                    onResultSelected: { result in
                                        onSearchResultSelected(result)
                                        showSearchSheet = false
                                    }
                                )
                                .navigationTitle("Search")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") {
                                            showSearchSheet = false
                                        }
                                    }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }

                    Button {
                        showCustomizePopover = true
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(.white)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 44, height: 44)
                    .sheet(isPresented: $showCustomizePopover) {
                        NavigationStack {
                            ScrollView {
                                EbookPlayerSettings(
                                    settingsVM: settingsVM,
                                    onDismiss: nil
                                )
                                .padding()
                            }
                            .navigationTitle("Customize Reader")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") {
                                        showCustomizePopover = false
                                    }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }

                    if hasAudioNarration {
                        Menu {
                            Button(role: isSynced ? .destructive : nil) {
                                Task {
                                    try? await onSyncToggle(!isSynced)
                                }
                            } label: {
                                Label(
                                    isSynced ? "Don't Follow Audio" : "Follow Audio",
                                    systemImage: "link"
                                )
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(.white)
                                .contentShape(Rectangle())
                        }
                        .frame(width: 44, height: 44)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                Color.black.opacity(0.001)
            )

            Spacer()
        }
    }
}
#endif
