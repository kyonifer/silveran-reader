#if os(iOS) || os(macOS)
import SwiftUI

public enum PlaybackSpeedControls {
    case single(currentRate: Double, rate: Binding<Double>)
    case dual(
        currentRate: Double,
        listeningRate: Binding<Double>,
        readaloudRate: Binding<Double>,
    )

    public var currentRate: Double {
        switch self {
            case .single(let currentRate, _), .dual(let currentRate, _, _):
                currentRate
        }
    }

    var isDual: Bool {
        if case .dual = self {
            return true
        }
        return false
    }
}

#endif
