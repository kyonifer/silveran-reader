import SwiftUI

@available(macOS 14.0, iOS 17.0, *)
struct HighlightCreationSheet: View {
    let selectedText: String
    let onSave: (HighlightColor?, String?) -> Void
    let onCancel: () -> Void

    @State private var selectedColor: HighlightColor? = .yellow
    @State private var note: String = ""
    @State private var isBookmarkOnly: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                selectedTextPreview

                if !isBookmarkOnly {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        colorPicker
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("Bookmark only (no highlight color)", isOn: $isBookmarkOnly)
                    .font(.subheadline)

                Spacer()
            }
            .padding()
            .navigationTitle("Add Highlight")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let color = isBookmarkOnly ? nil : selectedColor
                        let noteText = note.isEmpty ? nil : note
                        onSave(color, noteText)
                    }
                }
            }
            #else
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let color = isBookmarkOnly ? nil : selectedColor
                        let noteText = note.isEmpty ? nil : note
                        onSave(color, noteText)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(width: 400, height: 450)
        #endif
    }

    private var selectedTextPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected Text")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(selectedText)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isBookmarkOnly ? Color.secondary.opacity(0.1) : (selectedColor?.color ?? Color.yellow.opacity(0.4)))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorPicker: some View {
        HStack(spacing: 12) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Button {
                    selectedColor = color
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if selectedColor == color {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(selectedColor == color ? Color.primary : Color.clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
