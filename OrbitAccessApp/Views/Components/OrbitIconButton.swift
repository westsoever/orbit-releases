import SwiftUI

struct OrbitIconButton: View {
    let label: String
    let systemImage: String
    var variant: OrbitFlatButtonStyle.Variant = .ghost
    var size: OrbitFlatButtonStyle.Size = .md
    var isLoading: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    init(
        label: String,
        systemImage: String,
        variant: OrbitFlatButtonStyle.Variant = .ghost,
        size: OrbitFlatButtonStyle.Size = .md,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        precondition(!label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "OrbitIconButton requires a non-empty label")
        self.label = label
        self.systemImage = systemImage
        self.variant = variant
        self.size = size
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(size == .sm ? .small : .regular)
                } else {
                    Image(systemName: systemImage)
                }
            }
        }
        .buttonStyle(OrbitFlatButtonStyle(variant: variant, size: size, isIconOnly: true))
        .disabled(isDisabled || isLoading)
        .help(label)
        .accessibilityLabel(label)
    }
}
