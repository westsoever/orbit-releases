import SwiftUI

struct OrbitFlatButtonStyle: ButtonStyle {
    enum Variant {
        case primary
        case secondary
        case ghost
        case destructive
    }

    enum Size {
        case sm
        case md
        case lg
    }

    var variant: Variant = .secondary
    var size: Size = .md
    var isIconOnly: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, variant: variant, size: size, isIconOnly: isIconOnly)
    }

    private struct StyleBody: View {
        let configuration: ButtonStyleConfiguration
        let variant: Variant
        let size: Size
        let isIconOnly: Bool

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(labelFont)
                .padding(.horizontal, isIconOnly ? iconOnlyPadding : horizontalPadding)
                .padding(.vertical, isIconOnly ? iconOnlyPadding : verticalPadding)
                .frame(maxWidth: variant == .primary && !isIconOnly ? .infinity : nil)
                .frame(minWidth: isIconOnly ? iconOnlyDimension : nil, minHeight: isIconOnly ? iconOnlyDimension : nil)
                .background(background, in: RoundedRectangle(cornerRadius: OrbitShape.radiusControl))
                .overlay(
                    RoundedRectangle(cornerRadius: OrbitShape.radiusControl)
                        .stroke(borderColor, lineWidth: showsBorder ? OrbitShape.borderHairlineWidth : 0)
                )
                .foregroundStyle(foregroundColor)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(OrbitMotion.press, value: configuration.isPressed)
                .animation(OrbitMotion.hover, value: isHovering)
                .onHover { isHovering = isEnabled && $0 }
        }

        private var labelFont: Font {
            switch size {
            case .sm: return .caption.weight(.medium)
            case .md: return .callout.weight(.medium)
            case .lg: return .body.weight(.medium)
            }
        }

        private var horizontalPadding: CGFloat {
            switch size {
            case .sm: return 8
            case .md: return 12
            case .lg: return 16
            }
        }

        private var verticalPadding: CGFloat {
            switch size {
            case .sm: return 4
            case .md: return 6
            case .lg: return 8
            }
        }

        private var iconOnlyPadding: CGFloat {
            switch size {
            case .sm: return 4
            case .md: return 6
            case .lg: return 8
            }
        }

        private var iconOnlyDimension: CGFloat {
            switch size {
            case .sm: return 24
            case .md: return 28
            case .lg: return 32
            }
        }

        private var showsBorder: Bool {
            switch variant {
            case .secondary, .destructive:
                return true
            case .primary, .ghost:
                return false
            }
        }

        private var foregroundColor: Color {
            switch variant {
            case .primary:
                return .white
            case .secondary, .ghost:
                return .primary
            case .destructive:
                return .orbitScoreRed
            }
        }

        private var borderColor: Color {
            switch variant {
            case .destructive:
                return Color.orbitScoreRed.opacity(0.45)
            default:
                return Color.orbitBorderHairline(for: colorScheme)
            }
        }

        private var background: Color {
            switch variant {
            case .primary:
                if configuration.isPressed { return .orbitAccentPressed(for: colorScheme) }
                if isHovering { return .orbitAccentHover(for: colorScheme) }
                return .orbitAccent(for: colorScheme)
            case .secondary:
                if configuration.isPressed { return Color.primary.opacity(0.09) }
                if isHovering { return Color.orbitSurfaceMuted(for: colorScheme) }
                return .clear
            case .ghost:
                if configuration.isPressed { return Color.primary.opacity(0.09) }
                if isHovering { return Color.orbitSurfaceMuted(for: colorScheme) }
                return .clear
            case .destructive:
                if configuration.isPressed { return Color.orbitScoreRed.opacity(0.14) }
                if isHovering { return Color.orbitScoreRed.opacity(0.08) }
                return .clear
            }
        }
    }
}

// MARK: - Labeled button

struct OrbitButton: View {
    let label: String
    var variant: OrbitFlatButtonStyle.Variant = .secondary
    var size: OrbitFlatButtonStyle.Size = .md
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(size == .sm ? .small : .regular)
                }
                Text(label)
            }
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: variant, size: size))
        .disabled(isLoading)
    }
}
