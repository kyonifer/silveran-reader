import SwiftUI

struct DebugLogView: View {
    @State private var messages: [String] = []
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(messages.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                Button("Refresh") {
                    loadMessages()
                }
                Button("Clear") {
                    DebugLogBuffer.shared.clear()
                    loadMessages()
                }
                Button("Copy All") {
                    let text = messages.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .padding(8)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                            Text(message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: messages.count) { _, _ in
                    if autoScroll, let lastIndex = messages.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            loadMessages()
        }
    }

    private func loadMessages() {
        messages = DebugLogBuffer.shared.getMessages()
    }
}
