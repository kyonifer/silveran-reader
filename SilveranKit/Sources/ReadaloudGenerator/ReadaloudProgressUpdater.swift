import Foundation
import StoryAlignCore

public final class ReadaloudProgressListener: ProgressListener, @unchecked Sendable {
    private let onUpdate: @Sendable (ProgressStage, String, Double) -> Void
    private let updateQueue = DispatchQueue(label: "com.silveran.readaloud.progress")

    public init(onUpdate: @escaping @Sendable (ProgressStage, String, Double) -> Void) {
        self.onUpdate = onUpdate
    }

    public func show(_ snapshot: ProgressSnapshot) {
        updateQueue.async {
            let stage = snapshot.stage
            let message = ProgressFormatter().detailedStageText(snapshot)
            let progress = snapshot.timeEstimateProgress()
            self.onUpdate(stage, message, progress)
        }
    }
}

extension ProgressStage {
    var displayName: String {
        switch self {
            case .epub: return "Parsing EPUB"
            case .audio: return "Processing Audio"
            case .model: return "Loading Model"
            case .transcribe: return "Transcribing"
            case .align: return "Aligning"
            case .alignWords: return "Aligning Words"
            case .xml: return "Generating SMIL"
            case .export: return "Exporting"
            case .report: return "Creating Report"
        }
    }
}
