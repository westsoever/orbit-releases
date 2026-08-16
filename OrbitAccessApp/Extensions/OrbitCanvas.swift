import SwiftUI
import CoreGraphics

enum OrbitCanvasMetrics {
    static let grainOpacity: Double = 0.02
    static let grainTileDimension = 128
}

// Deterministic xorshift64, not SystemRandomNumberGenerator: the grain must render
// identically every launch (no shimmer), and this is seeded with a fixed constant below.
private struct OrbitCanvasNoiseGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// Built once per launch (static let), not per render pass: this sits behind the whole
// window, so a per-frame noise computation would be a real, measurable cost.
private enum OrbitCanvasGrain {
    static let tile: CGImage = makeTile()

    private static func makeTile() -> CGImage {
        let dimension = OrbitCanvasMetrics.grainTileDimension
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        var generator = OrbitCanvasNoiseGenerator(seed: 0x9E3779B97F4A7C15)
        var pixels = [UInt8](repeating: 0, count: dimension * dimension)
        for index in pixels.indices {
            pixels[index] = UInt8.random(in: 0...255, using: &generator)
        }

        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let image = CGImage(
               width: dimension,
               height: dimension,
               bitsPerComponent: 8,
               bitsPerPixel: 8,
               bytesPerRow: dimension,
               space: colorSpace,
               bitmapInfo: bitmapInfo,
               provider: provider,
               decode: nil,
               shouldInterpolate: false,
               intent: .defaultIntent
           ) {
            return image
        }

        // Unreachable in practice (fixed-size buffer, valid provider) — a flat
        // mid-gray fallback tiles as a no-op grain rather than crashing the window chrome.
        let fallbackProvider = CGDataProvider(data: Data([128]) as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: 1,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: fallbackProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private struct OrbitCanvasLayer: View {
    let colorScheme: ColorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(hex: 0x10141C), Color(hex: 0x1B2230)]
                    : [Color(hex: 0xEEF1F6), Color(hex: 0xDCE3EE)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(decorative: OrbitCanvasGrain.tile, scale: 1, orientation: .up)
                .resizable(resizingMode: .tile)
                .opacity(OrbitCanvasMetrics.grainOpacity)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Drop-in replacement for `.background(Color.orbitCanvas(for: colorScheme).ignoresSafeArea())`.
    func orbitCanvasBackground(colorScheme: ColorScheme) -> some View {
        background(
            OrbitCanvasLayer(colorScheme: colorScheme)
                .ignoresSafeArea()
        )
    }
}
