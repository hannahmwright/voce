import AppKit
import CoreText
import SwiftUI

enum VoceDesign {
    static let appFontName = "Manrope"

    // MARK: - Colors

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        }))
    }

    // Monet accent palette (from the app icon — used sparingly for color pops)
    static let wheat = Color(red: 0.82, green: 0.74, blue: 0.52)        // golden wheat highlight
    static let sage = Color(red: 0.58, green: 0.68, blue: 0.52)         // soft sage green
    static let skyBlue = Color(red: 0.62, green: 0.78, blue: 0.90)      // light impressionist sky
    static let lavender = Color(red: 0.72, green: 0.70, blue: 0.84)     // soft purple haze
    static let roseLight = Color(red: 0.86, green: 0.74, blue: 0.72)    // soft pinkish warmth
    static let photoAccent = Color(red: 0.70, green: 0.54, blue: 0.36)  // warm bronze from hero imagery
    static let warmAccentFill = Color(red: 0.84, green: 0.89, blue: 0.76)   // light olive green
    static let warmAccentText = Color(red: 0.27, green: 0.34, blue: 0.19)   // deep grassy olive

    // Primary accent: bright sky cerulean (Monet's Water Lilies sky)
    static let accent = Color(red: 0.32, green: 0.60, blue: 0.82)       // #5299D1
    static let accentSecondary = skyBlue

    // Clean glass surfaces — light, cool, airy
    static let background = adaptive(
        light: Color(red: 0.965, green: 0.970, blue: 0.980),            // cool near-white
        dark: Color(red: 0.09, green: 0.09, blue: 0.11)                 // deep cool charcoal
    )
    static let surface = adaptive(
        light: Color.white.opacity(0.88),
        dark: Color(red: 0.18, green: 0.19, blue: 0.21).opacity(0.90)
    )
    static let surfaceSecondary = adaptive(
        light: Color.white.opacity(0.80),
        dark: Color(red: 0.21, green: 0.22, blue: 0.24).opacity(0.86)
    )
    static let surfaceSolid = adaptive(
        light: Color(red: 0.972, green: 0.976, blue: 0.985),
        dark: Color(red: 0.16, green: 0.17, blue: 0.19)
    )
    /// Opaque content area background — warm off-white (light) / near-black (dark)
    static let contentBackground = adaptive(
        light: Color(red: 0.98, green: 0.975, blue: 0.965),             // warm cream white
        dark: Color(red: 0.11, green: 0.11, blue: 0.12)                 // deep neutral
    )
    static let windowBackground = adaptive(
        light: Color(red: 0.952, green: 0.960, blue: 0.972),
        dark: Color(red: 0.115, green: 0.12, blue: 0.135)
    )
    static let textPrimary = adaptive(
        light: Color(red: 0.12, green: 0.13, blue: 0.15),               // cool near-black
        dark: Color(red: 0.93, green: 0.94, blue: 0.95)                 // cool off-white
    )
    static let textSecondary = adaptive(
        light: Color(red: 0.34, green: 0.37, blue: 0.41),               // darker cool grey for glass readability
        dark: Color(red: 0.58, green: 0.60, blue: 0.64)                 // cool light-grey
    )
    static let border = adaptive(
        light: Color.black.opacity(0.06),                                // very subtle cool border
        dark: Color.white.opacity(0.10)
    )

    // Semantic colors (clean and modern, lightly tinted)
    static let success = Color(red: 0.49, green: 0.61, blue: 0.35)      // muted olive green
    static let successBackground = success.opacity(0.10)
    static let successBorder = success.opacity(0.20)
    static let warning = Color(red: 0.90, green: 0.68, blue: 0.25)      // #E6AD40  warm gold
    static let warningBackground = warning.opacity(0.10)
    static let warningBorder = warning.opacity(0.20)
    static let error = Color(red: 0.75, green: 0.42, blue: 0.36)        // muted terracotta red
    static let errorBackground = error.opacity(0.08)
    static let errorBorder = error.opacity(0.18)

    // MARK: - Gradients (Monet-inspired)

    /// Accent gradient for the mic button and highlights
    static let accentGradient = LinearGradient(
        colors: [accent, skyBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Warm glow gradient for recording state
    static let recordingGradient = LinearGradient(
        colors: [accent, lavender, skyBlue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Typography

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: appFontName, size: size) != nil {
            return .custom(appFontName, size: size).weight(weight)
        }
        return .system(size: size, weight: weight)
    }

    static func heading1() -> Font { font(size: 24, weight: .bold) }
    static func heading2() -> Font { font(size: 20, weight: .semibold) }
    static func heading3() -> Font { font(size: 17, weight: .semibold) }
    static func body() -> Font { font(size: 14) }
    static func bodyEmphasis() -> Font { font(size: 14, weight: .semibold) }
    static func callout() -> Font { font(size: 13, weight: .medium) }
    static func subheadline() -> Font { font(size: 14, weight: .medium) }
    static func caption() -> Font { font(size: 12, weight: .medium) }
    static func captionEmphasis() -> Font { font(size: 12, weight: .medium) }
    static func label() -> Font { font(size: 11, weight: .medium) }
    static func labelEmphasis() -> Font { font(size: 11, weight: .semibold) }

    static func registerBundledFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        for url in Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // MARK: - Opacity

    static let opacityDisabled: Double = 0.5
    static let opacitySubtle: Double = 0.12
    static let opacityMuted: Double = 0.2
    static let opacityBorder: Double = 0.3
    static let opacityHover: Double = 0.08
    static let opacityGlowMax: Double = 0.8
    static let opacityGlass: Double = 0.70
    static let opacityGlassBorder: Double = 0.18
    static let opacityWindowGlass: Double = 0.52

    // MARK: - Spacing

    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 48

    // MARK: - Radii

    static let radiusTiny: CGFloat = 2
    static let radiusSmall: CGFloat = 10
    static let radiusMedium: CGFloat = 14
    static let radiusLarge: CGFloat = 20
    static let radiusPill: CGFloat = 999

    // MARK: - Border Widths

    static let borderThin: CGFloat = 0.5
    static let borderNormal: CGFloat = 1.0
    static let borderThick: CGFloat = 2.0
    static let borderHeavy: CGFloat = 3.0

    // MARK: - Icon Sizes

    static let iconSM: CGFloat = 12
    static let iconMD: CGFloat = 16
    static let iconLG: CGFloat = 20
    static let iconXL: CGFloat = 34

    // MARK: - Animation Durations

    static let animationFast: Double = 0.15
    static let animationNormal: Double = 0.3
    static let animationSlow: Double = 0.5
    static let animationGlow: Double = 1.2

    // MARK: - Shadow System

    enum ShadowLevel {
        case none, sm, md, lg, xl, recording, idle

        var style: ShadowStyle {
            switch self {
            case .none:
                return ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
            case .sm:
                return ShadowStyle(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
            case .md:
                return ShadowStyle(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
            case .lg:
                return ShadowStyle(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
            case .xl:
                return ShadowStyle(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
            case .recording:
                return ShadowStyle(color: VoceDesign.accent.opacity(0.30), radius: 16, x: 0, y: 2)
            case .idle:
                return ShadowStyle(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            }
        }

        var darkStyle: ShadowStyle {
            switch self {
            case .none:
                return ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
            case .sm:
                return ShadowStyle(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
            case .md:
                return ShadowStyle(color: .black.opacity(0.30), radius: 6, x: 0, y: 2)
            case .lg:
                return ShadowStyle(color: .black.opacity(0.35), radius: 10, x: 0, y: 4)
            case .xl:
                return ShadowStyle(color: .black.opacity(0.45), radius: 16, x: 0, y: 6)
            case .recording:
                return ShadowStyle(color: VoceDesign.accent.opacity(0.35), radius: 16, x: 0, y: 2)
            case .idle:
                return ShadowStyle(color: .black.opacity(0.30), radius: 8, x: 0, y: 2)
            }
        }
    }

    // MARK: - Component Sizes

    static let micButtonGlowSize: CGFloat = 132
    static let micButtonSize: CGFloat = 104
    static let micButtonGlowScale: CGFloat = 1.2
    static let dividerHeight: CGFloat = 1
    static let sidebarWidth: CGFloat = 180
    static let settingsSidebarMinWidth: CGFloat = 160
    static let settingsSidebarIdealWidth: CGFloat = 200
    static let settingsDialogIdealWidth: CGFloat = 820
    static let settingsDialogIdealHeight: CGFloat = 620
    static let settingsDialogWindowInset: CGFloat = 24
    static let settingsWindowMinContentWidth: CGFloat = settingsDialogIdealWidth + (settingsDialogWindowInset * 2)
    static let settingsWindowMinContentHeight: CGFloat = settingsDialogIdealHeight + (settingsDialogWindowInset * 2)
    static let windowMinWidth: CGFloat = 780
    static let windowIdealWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 600
    static let windowIdealHeight: CGFloat = 700
    static let searchBarMaxWidth: CGFloat = 220
    static let insertionListHeight: CGFloat = 120
}

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

// MARK: - Shadow Modifier

struct ShadowModifier: ViewModifier {
    let level: VoceDesign.ShadowLevel
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let s = colorScheme == .dark ? level.darkStyle : level.style
        content.shadow(color: s.color, radius: s.radius, x: s.x, y: s.y)
    }
}

// MARK: - Glass Card Style

struct CardStyle: ViewModifier {
    var elevation: VoceDesign.ShadowLevel = .md
    var padding: CGFloat = VoceDesign.md

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .fill(VoceDesign.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                            .fill(
                                colorScheme == .dark
                                    ? AnyShapeStyle(.regularMaterial.opacity(0.20))
                                    : AnyShapeStyle(.regularMaterial.opacity(0.35))
                            )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.06)
                            : Color.white.opacity(0.50),
                        lineWidth: VoceDesign.borderThin
                    )
            )
            .shadowStyle(elevation)
    }
}

// MARK: - Interactive Glass Card Style

struct InteractiveCardStyle: ViewModifier {
    var elevation: VoceDesign.ShadowLevel = .md
    var padding: CGFloat = VoceDesign.md

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .fill(isHovering ? VoceDesign.surface : VoceDesign.surfaceSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                            .fill(
                                colorScheme == .dark
                                    ? AnyShapeStyle(.regularMaterial.opacity(isHovering ? 0.24 : 0.18))
                                    : AnyShapeStyle(.regularMaterial.opacity(isHovering ? 0.40 : 0.30))
                            )
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusMedium)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(isHovering ? 0.10 : 0.06)
                            : Color.white.opacity(isHovering ? 0.60 : 0.50),
                        lineWidth: VoceDesign.borderThin
                    )
            )
            .shadowStyle(isHovering ? .lg : elevation)
            .scaleEffect(isHovering ? 1.005 : 1.0)
            .animation(.easeInOut(duration: VoceDesign.animationFast), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

// MARK: - Pressable Button Style

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.1, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

struct SettingsInputChromeModifier: ViewModifier {
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .font(VoceDesign.callout())
            .foregroundStyle(VoceDesign.textPrimary)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? VoceDesign.surfaceSolid : VoceDesign.surfaceSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? AnyShapeStyle(Color.white.opacity(0.03))
                                    : AnyShapeStyle(.regularMaterial.opacity(0.18))
                            )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        colorScheme == .dark ? Color.white.opacity(0.12) : VoceDesign.border,
                        lineWidth: VoceDesign.borderThin
                    )
            )
    }
}

// MARK: - Copy Button View

struct CopyButtonView: View {
    let action: () -> Void
    var label: String = "Copy transcript"

    @State private var didCopy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            action()
            didCopy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(VoceDesign.caption())
                .foregroundStyle(didCopy ? VoceDesign.success : VoceDesign.textSecondary)
                .scaleEffect(didCopy && !reduceMotion ? 1.15 : 1.0)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.6),
                    value: didCopy
                )
        }
        .buttonStyle(.plain)
        .help("Copy")
        .accessibilityLabel(label)
    }
}

// MARK: - Window Background

struct VoceWindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(colorScheme == .dark ? 1.10 : 1.05)
                .saturation(colorScheme == .dark ? 0.86 : 0.96)
                .overlay {
                    Rectangle()
                        .fill(backdropTint)
                }
                .blur(radius: colorScheme == .dark ? 1.8 : 0.6)

            Rectangle()
                .fill(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.08 : 0.05))

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.04 : 0.12),
                            Color.clear,
                            VoceDesign.wheat.opacity(colorScheme == .dark ? 0.08 : 0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.06 : 0.10),
                            Color.clear
                        ],
                        center: .top,
                        startRadius: 40,
                        endRadius: 460
                    )
                )
        }
        .ignoresSafeArea()
    }

    private var backdropTint: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    VoceDesign.windowBackground.opacity(0.28),
                    VoceDesign.background.opacity(0.42),
                    Color.black.opacity(0.14)
                ]
                : [
                    Color.white.opacity(0.03),
                    VoceDesign.windowBackground.opacity(0.22),
                    VoceDesign.sage.opacity(0.08)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - View Extensions

extension View {
    func shadowStyle(_ level: VoceDesign.ShadowLevel) -> some View {
        modifier(ShadowModifier(level: level))
    }

    func cardStyle(elevation: VoceDesign.ShadowLevel = .md, padding: CGFloat = VoceDesign.md) -> some View {
        modifier(CardStyle(elevation: elevation, padding: padding))
    }

    func interactiveCardStyle(elevation: VoceDesign.ShadowLevel = .md, padding: CGFloat = VoceDesign.md) -> some View {
        modifier(InteractiveCardStyle(elevation: elevation, padding: padding))
    }

    func glassBackground(cornerRadius: CGFloat = VoceDesign.radiusMedium) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(VoceDesign.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(VoceDesign.surfaceSolid.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.regularMaterial.opacity(VoceDesign.opacityWindowGlass))
                    )
            }
    }

    func windowGlassPanel(cornerRadius: CGFloat = 30) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(VoceDesign.surface.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.42))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.34), lineWidth: VoceDesign.borderThin)
                    )
                    .shadowStyle(.xl)
            }
    }

    func settingsInputChrome(cornerRadius: CGFloat = VoceDesign.radiusSmall) -> some View {
        modifier(SettingsInputChromeModifier(cornerRadius: cornerRadius))
    }
}
