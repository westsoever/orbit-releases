import SwiftUI

enum OrbitShape {
    static let radiusCard: CGFloat = 8
    static let radiusChip: CGFloat = 6
    static let radiusControl: CGFloat = 4
    static let borderHairlineWidth: CGFloat = 0.5
    static let surfaceMutedOpacity: Double = 0.04
    static let borderHairlineOpacity: Double = 0.08
    static let dividerHairlineOpacity: Double = 0.06

    static let radiusSidecard: CGFloat = 12

    // Elevation — cards
    static let cardShadowRadius: CGFloat = 8
    static let cardShadowYOffset: CGFloat = 2

    // Elevation — overlays (sidebane rail, sidecard widgets, popovers)
    static let overlayShadowRadius: CGFloat = 14
    static let overlayShadowYOffset: CGFloat = 6

    // Card borders soften now that shadow carries elevation
    static let cardBorderOpacityLight: Double = 0.05
    static let cardBorderOpacityDark: Double = 0.14

    // Shared "track" colour — one value, two consumers (timeline rail, score gauge track)
    static let trackOpacity: Double = 0.10
}

extension Color {
    static func orbitSurfaceMuted(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(OrbitShape.surfaceMutedOpacity)
    }

    static func orbitBorderHairline(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(OrbitShape.borderHairlineOpacity)
    }

    static func orbitDividerHairline(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(OrbitShape.dividerHairlineOpacity)
    }

    static func orbitCardBorder(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(
            colorScheme == .dark ? OrbitShape.cardBorderOpacityDark
                                 : OrbitShape.cardBorderOpacityLight
        )
    }

    static func orbitTrack(for colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(OrbitShape.trackOpacity)
    }
}

extension View {
    func orbitHairlineBorder(
        cornerRadius: CGFloat = OrbitShape.radiusCard,
        colorScheme: ColorScheme
    ) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.orbitBorderHairline(for: colorScheme),
                    lineWidth: OrbitShape.borderHairlineWidth
                )
        )
    }

    /// Card surface + softened border + card-level shadow. Replaces the
    /// `.background(cardSurface, in:) + .orbitHairlineBorder(...)` pair.
    func orbitCardChrome(
        cornerRadius: CGFloat = OrbitShape.radiusCard,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .background(Color.orbitCardSurface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.orbitCardBorder(for: colorScheme),
                            lineWidth: OrbitShape.borderHairlineWidth)
            )
            .shadow(
                color: .orbitCardShadow(for: colorScheme),
                radius: OrbitShape.cardShadowRadius,
                y: OrbitShape.cardShadowYOffset
            )
    }

    /// Same, with the deeper shadow reserved for surfaces that genuinely
    /// overlay the chat canvas (the rail, sidecard widgets, popovers).
    func orbitOverlayChrome(
        cornerRadius: CGFloat = OrbitShape.radiusSidecard,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .background(Color.orbitCardSurface(for: colorScheme),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.orbitCardBorder(for: colorScheme),
                            lineWidth: OrbitShape.borderHairlineWidth)
            )
            .shadow(
                color: .orbitOverlayShadow(for: colorScheme),
                radius: OrbitShape.overlayShadowRadius,
                y: OrbitShape.overlayShadowYOffset
            )
    }
}
