import SwiftUI

extension Color {
    // Accent — ink-blue family, per docs/design-kit.md "Ink-Blue revision" (plan 54 phase 1).
    // Replaces the terracotta accent (plan 28) — a deliberate move away from a hue that read as
    // "nearly copy-alike" with Claude Code's own accent.
    // Per-scheme now: light and dark use different rest/hover/pressed triples (see
    // orbitAccent(for:) below), not one shared value, because the dark base is deliberately
    // LIGHTER than the light base (the one stated exception below) — that can't be expressed as
    // a bare `static let`, so these became functions, matching orbitCardSurface(for:) below.
    //
    // Within each scheme, states still go DARKER, never lighter — the .primary button label is
    // white, so a lighter fill would cut contrast. ΔL* computed via standard sRGB→linear→XYZ
    // (D65)→CIELAB, same method the terracotta comment this replaces used:
    //   light: rest L* 27.2 → hover L* 22.0 (ΔL* -5.2) → pressed L* 17.3 (ΔL* -4.7)
    //   dark:  rest L* 36.3 → hover L* 31.1 (ΔL* -5.2) → pressed L* 24.2 (ΔL* -6.9)
    // Exception (per docs/design-kit.md, cross-scheme, NOT a within-scheme lightening): dark rest
    // (L* 36.3) is lighter than light rest (L* 27.2) — dark mode's whole accent triple sits higher
    // on the L* scale than light mode's by design. Hover/pressed still go darker than rest inside
    // each scheme; the rule isn't broken, just scoped per-scheme.
    //
    // White-on-fill contrast (sRGB relative-luminance method), rest only — hover/pressed are
    // strictly darker so their contrast is strictly higher, same monotonic logic as before:
    //   light rest #2C4066 → 10.33:1 (clears WCAG AAA, 7:1, for normal text)
    //   dark rest  #3C5680 → 7.39:1  (just clears AAA — don't lighten further without re-checking)
    // Real accessibility win over terracotta's 3.12:1 (barely above AA-large, below AA-normal),
    // not just a hue change.
    // Caveat, still applies (OrbitFlatButtonStyle.swift:48, unchanged by this plan): pressed state
    // also gets .opacity(0.85) on the whole button, so the *rendered* pressed fill composites
    // lighter than this token — ~8.86:1 over a white card (light), ~12.18:1 over orbitCardDark
    // (dark). Both still clear AAA, so this is a smaller-margin caveat now than for terracotta,
    // not a new risk. Transient, pre-existing.
    static func orbitAccent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x3C5680) : Color(hex: 0x2C4066)
    }

    static func orbitAccentHover(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x324A6E) : Color(hex: 0x25354F)
    }

    static func orbitAccentPressed(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(hex: 0x283A56) : Color(hex: 0x1E2B3F)
    }

    static let orbitCardDark = Color(hex: 0x1C1F29)
    static let orbitCardLight = Color.white
    static let orbitSecondaryTextDark = Color(hex: 0x9BA3B4)
    static let orbitSecondaryTextLight = Color(hex: 0x63697A)

    // Canvas — the app background
    static let orbitCanvasLight = Color(hex: 0xE5EAF2)   // ink-blue gradient midpoint (flat fallback)
    // Dark flat canvas is biased to the darker gradient stop (#10141C), not the exact midpoint
    // (#161B26), per plan 54 §0.3's flagged risk: the midpoint left only a (+6,+4,+3) RGB delta
    // against orbitCardDark (#1C1F29) — about half the old app's canvas/card delta of (+8,+8,+10)
    // (#141414 vs #1C1C1E; the plan's own draft cited (+12,+12,+14), which does not check out against
    // those two hex values and has been corrected here). Biasing to #10141C restores a (+12,+11,+13)
    // delta — slightly better separation than the old app had — and raises the WCAG relative-luminance
    // contrast ratio vs the card from ~1.048:1 (midpoint) to ~1.122:1 (still far below any WCAG
    // text/UI threshold, as expected for an elevation cue rather than a text-contrast pair, but
    // directionally the right way and consistent with the pre-existing app's own separation margin).
    static let orbitCanvasDark  = Color(hex: 0x10141C)   // ink-blue gradient's darker stop (flat fallback, biased for card separation)

    static func orbitCanvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .orbitCanvasDark : .orbitCanvasLight
    }

    // Card surface — single resolver for the light/dark card fill.
    static func orbitCardSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .orbitCardDark : .orbitCardLight
    }

    // Elevation — shadow colour, paired with OrbitShape tokens in 1.2
    static func orbitCardShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.06)
    }

    static func orbitOverlayShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.55) : Color.black.opacity(0.10)
    }

    static let orbitScoreRed = Color(hex: 0xD6564A)
    static let orbitScoreAmber = Color(hex: 0xC98A2E)
    static let orbitScoreLime = Color(hex: 0x7A8B3F)
    static let orbitScoreEmerald = Color(hex: 0x2F8F6D)

    // Agent palette — moved from Models/AgentType+UI.swift (plan 21 §5.3)
    static let orbitAgentWriting = Color(hex: 0x4A90E2)
    static let orbitAgentResearch = Color(hex: 0x9B59B6)
    static let orbitAgentCode = Color(hex: 0x27AE60)
    static let orbitAgentAdmin = Color(hex: 0xE67E22)
    static let orbitAgentData = Color(hex: 0x00B5D8)
    static let orbitAgentCommunication = Color(hex: 0x5B73E8)

    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }

    static func orbitSecondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .orbitSecondaryTextDark : .orbitSecondaryTextLight
    }

    static func orbitScoreColor(for score: Double) -> Color {
        switch score {
        case ..<5: return .orbitScoreRed
        case ..<7: return .orbitScoreAmber
        case ..<8.5: return .orbitScoreLime
        default: return .orbitScoreEmerald
        }
    }

    static func orbitScoreLabel(for score: Double) -> String {
        switch score {
        case ..<5: return "Needs improvement"
        case ..<7: return "Moderate"
        case ..<8.5: return "Good"
        default: return "Excellent"
        }
    }
}
