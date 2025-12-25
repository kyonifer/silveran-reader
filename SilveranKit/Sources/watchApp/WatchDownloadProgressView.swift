#if os(watchOS)
import SilveranKitCommon
import SwiftUI

struct WatchDownloadProgressView: View {
    let book: BookMetadata
    let onCancel: () -> Void
    let onComplete: () -> Void

    @State private var progress: Double = 0
    @State private var bytesDownloaded: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var downloadSpeed: Double = 0
    @State private var lastBytesDownloaded: Int64 = 0
    @State private var lastSpeedUpdate: Date = Date()
    @State private var isComplete = false
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(lineWidth: 8)
                    .opacity(0.2)
                    .foregroundStyle(.blue)

                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .foregroundStyle(.blue)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text(String(format: "%.1f%%", progress * 100))
                        .font(.title2.bold())

                    if totalBytes > 0 {
                        Text(formatBytes(bytesDownloaded))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 120, height: 120)

            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if didFail {
                Text("Download failed")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if isComplete {
                Text("Complete!")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text(timeRemainingText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await startDownload()
        }
    }

    private var timeRemainingText: String {
        guard downloadSpeed > 0, totalBytes > 0 else {
            return "Calculating..."
        }

        let remainingBytes = totalBytes - bytesDownloaded
        let secondsRemaining = Double(remainingBytes) / downloadSpeed

        if secondsRemaining < 60 {
            return "\(Int(secondsRemaining))s remaining"
        } else if secondsRemaining < 3600 {
            let minutes = Int(secondsRemaining / 60)
            let seconds = Int(secondsRemaining) % 60
            return "\(minutes)m \(seconds)s remaining"
        } else {
            let hours = Int(secondsRemaining / 3600)
            let minutes = Int(secondsRemaining / 60) % 60
            return "\(hours)h \(minutes)m remaining"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func startDownload() async {
        await WatchDownloadManager.shared.downloadBook(book) { progressValue in
            Task { @MainActor in
                self.progress = progressValue
            }
        } bytesHandler: { downloaded, total in
            Task { @MainActor in
                let now = Date()
                let elapsed = now.timeIntervalSince(lastSpeedUpdate)

                if elapsed >= 1.0 {
                    let bytesDelta = downloaded - lastBytesDownloaded
                    downloadSpeed = Double(bytesDelta) / elapsed
                    lastBytesDownloaded = downloaded
                    lastSpeedUpdate = now
                }

                bytesDownloaded = downloaded
                totalBytes = total
            }
        }

        await MainActor.run {
            if progress >= 0.99 {
                isComplete = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    onComplete()
                }
            } else {
                didFail = true
            }
        }
    }
}

#endif
