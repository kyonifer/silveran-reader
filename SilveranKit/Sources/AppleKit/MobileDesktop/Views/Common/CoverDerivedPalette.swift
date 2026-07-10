#if os(iOS) || os(macOS)
import CoreGraphics
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A small semantic palette derived from cover artwork.
///
/// `surface` is suitable for a large background, while `accent` and
/// `accentBackground` form a contrasting foreground/background pair for compact controls.
struct CoverDerivedPalette {
    let surface: Color
    let accent: Color
    let brightAccent: Color
    let mutedAccent: Color
    let accentBackground: Color
    let contentBackground: Color
    let cardBackground: Color
    let cardBorder: Color
    let lightSurface: Color
    let lightContentBackground: Color
    let lightCardBackground: Color
    let lightCardBorder: Color

    var accentTrack: Color {
        accent.opacity(0.3)
    }

    func resolved(for colorScheme: ColorScheme) -> CoverDerivedPalette {
        guard colorScheme == .light else { return self }
        return CoverDerivedPalette(
            surface: lightSurface,
            accent: accent,
            brightAccent: brightAccent,
            mutedAccent: mutedAccent,
            accentBackground: accentBackground,
            contentBackground: lightContentBackground,
            cardBackground: lightCardBackground,
            cardBorder: lightCardBorder,
            lightSurface: lightSurface,
            lightContentBackground: lightContentBackground,
            lightCardBackground: lightCardBackground,
            lightCardBorder: lightCardBorder,
        )
    }

    static func fallback() -> CoverDerivedPalette {
        makePalette(hue: 0.56, saturation: 0.34, brightness: 0.28)
    }

    static func make(from cgImage: CGImage) -> CoverDerivedPalette? {
        guard let average = averageRGB(of: cgImage) else { return nil }
        let source = hsv(red: average.red, green: average.green, blue: average.blue)
        let surfaceSaturation =
            source.saturation < 0.08
            ? 0.06 : min(max(source.saturation * 1.15, 0.28), 0.78)
        let surfaceBrightness = min(max(source.brightness * 0.58, 0.18), 0.38)
        return makePalette(
            hue: source.hue,
            saturation: surfaceSaturation,
            brightness: surfaceBrightness,
        )
    }

    #if os(macOS)
    static func make(from image: NSImage) -> CoverDerivedPalette? {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard
            let cgImage = image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil,
            )
        else { return nil }
        return make(from: cgImage)
    }
    #else
    static func make(from image: UIImage) -> CoverDerivedPalette? {
        guard let cgImage = image.cgImage else { return nil }
        return make(from: cgImage)
    }
    #endif

    private static func makePalette(
        hue: Double,
        saturation: Double,
        brightness: Double,
    ) -> CoverDerivedPalette {
        let surface = Color(
            hue: hue,
            saturation: saturation,
            brightness: brightness,
        )

        guard saturation >= 0.08 else {
            return CoverDerivedPalette(
                surface: surface,
                accent: Color(white: 0.86),
                brightAccent: Color(white: 0.98),
                mutedAccent: Color(white: 0.68),
                accentBackground: Color(white: 0.14).opacity(0.94),
                contentBackground: Color(white: 0.19),
                cardBackground: Color(white: 0.22),
                cardBorder: Color.white.opacity(0.1),
                lightSurface: Color(white: 0.92),
                lightContentBackground: Color(white: 0.92),
                lightCardBackground: Color(white: 0.98),
                lightCardBorder: Color.black.opacity(0.1),
            )
        }

        return CoverDerivedPalette(
            surface: surface,
            accent: Color(
                hue: hue,
                saturation: min(max(saturation * 0.72, 0.24), 0.62),
                brightness: 0.9,
            ),
            brightAccent: Color(
                hue: hue,
                saturation: min(max(saturation * 0.48, 0.14), 0.42),
                brightness: 1,
            ),
            mutedAccent: Color(
                hue: hue,
                saturation: min(max(saturation * 0.07, 0.015), 0.06),
                brightness: 0.72,
            ),
            accentBackground: Color(
                hue: hue,
                saturation: min(max(saturation * 1.08, 0.3), 0.78),
                brightness: min(max(brightness * 0.62, 0.1), 0.24),
                opacity: 0.94,
            ),
            contentBackground: Color(
                hue: hue,
                saturation: min(max(saturation * 0.82, 0.2), 0.6),
                brightness: min(max(brightness * 0.84, 0.19), 0.32),
            ),
            cardBackground: Color(
                hue: hue,
                saturation: min(max(saturation * 0.74, 0.17), 0.52),
                brightness: min(max(brightness * 0.9, 0.22), 0.35),
            ),
            cardBorder: Color(
                hue: hue,
                saturation: min(max(saturation * 0.58, 0.18), 0.5),
                brightness: 0.82,
                opacity: 0.16,
            ),
            lightSurface: Color(
                hue: hue,
                saturation: min(max(saturation * 0.24, 0.055), 0.16),
                brightness: 0.92,
            ),
            lightContentBackground: Color(
                hue: hue,
                saturation: min(max(saturation * 0.28, 0.06), 0.18),
                brightness: 0.93,
            ),
            lightCardBackground: Color(
                hue: hue,
                saturation: min(max(saturation * 0.16, 0.035), 0.11),
                brightness: 0.985,
            ),
            lightCardBorder: Color(
                hue: hue,
                saturation: min(max(saturation * 0.45, 0.12), 0.32),
                brightness: 0.42,
                opacity: 0.18,
            ),
        )
    }

    private static func averageRGB(of image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        let sampleWidth = 8
        let sampleHeight = 8
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else { return false }

            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard didDraw else { return nil }

        var red = 0.0
        var green = 0.0
        var blue = 0.0
        var weight = 0.0

        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.05 else { continue }
            red += Double(pixels[offset]) * alpha
            green += Double(pixels[offset + 1]) * alpha
            blue += Double(pixels[offset + 2]) * alpha
            weight += alpha
        }

        guard weight > 0 else { return nil }
        return (red / weight / 255, green / weight / 255, blue / weight / 255)
    }

    private static func hsv(red: Double, green: Double, blue: Double) -> (
        hue: Double, saturation: Double, brightness: Double
    ) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum

        let hue: Double
        if delta == 0 {
            hue = 0
        } else if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6) / 6
        } else if maximum == green {
            hue = ((blue - red) / delta + 2) / 6
        } else {
            hue = ((red - green) / delta + 4) / 6
        }

        return (hue < 0 ? hue + 1 : hue, saturation, maximum)
    }
}

#endif
