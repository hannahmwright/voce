import AppKit
import SwiftUI
import VoceKit

enum VoceTab: String, Hashable {
    case home = "Home"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case scratchPad = "Scratchpad"
    case settings = "Settings"

    static let navigationTabs: [VoceTab] = [.home, .dictionary, .snippets, .style, .scratchPad]

    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "text.book.closed"
        case .snippets: return "sparkles"
        case .style: return "textformat"
        case .scratchPad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var updaterController: UpdaterController
    @State private var selectedTab: VoceTab = .home
    @State private var lastNonSettingsTab: VoceTab = .home
    @State private var settingsLaunchTarget: SettingsLaunchTarget?
    @State private var preferencesDraft: AppPreferences = .default
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let shellOuterPadding = proxy.size.width < 920 ? 2.0 : VoceDesign.sm
            let shellInnerPadding = proxy.size.width < 920 ? 4.0 : VoceDesign.sm
            let shellCornerRadius = proxy.size.width < 920 ? 32.0 : 38.0
            let contentCornerRadius = proxy.size.width < 920 ? 26.0 : 30.0
            let sidebarWidth = VoceDesign.sidebarWidth
            let shellContentWidth = max(0, proxy.size.width - (shellOuterPadding * 2) - (shellInnerPadding * 2))
            let shellContentHeight = max(0, proxy.size.height - (shellOuterPadding * 2) - (shellInnerPadding * 2))

            ZStack(alignment: .topLeading) {
                VoceWindowBackdrop()

                HStack(spacing: shellInnerPadding) {
                    sidebar(width: sidebarWidth, height: shellContentHeight, cornerRadius: contentCornerRadius)
                    mainContentPane(cornerRadius: contentCornerRadius)
                }
                .frame(width: shellContentWidth, height: shellContentHeight, alignment: .topLeading)
                .padding(shellInnerPadding)
                .background {
                    RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                        .fill(VoceDesign.surface.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                                .fill(.ultraThinMaterial.opacity(0.42))
                        )
                }
                .overlay(
                    RoundedRectangle(cornerRadius: shellCornerRadius, style: .continuous)
                        .stroke(
                            colorScheme == .dark
                                ? Color.white.opacity(0.12)
                                : Color.black.opacity(0.06),
                            lineWidth: VoceDesign.borderThin
                        )
                )
                .shadowStyle(.xl)
                .padding(shellOuterPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(
            minWidth: VoceDesign.windowMinWidth,
            idealWidth: VoceDesign.windowIdealWidth,
            minHeight: VoceDesign.windowMinHeight,
            idealHeight: VoceDesign.windowIdealHeight
        )
        .onAppear {
            preferencesDraft = controller.preferences
        }
        .onChange(of: controller.preferences) { _, newValue in
            if newValue != preferencesDraft {
                preferencesDraft = newValue
            }
        }
        .onChange(of: preferencesDraft) { _, newValue in
            var normalized = newValue
            normalized.normalize()
            guard normalized != controller.preferences else { return }

            if normalized.requiresRuntimeRebuild(comparedTo: controller.preferences) {
                controller.applySettingsDraft(preferences: newValue, announceImmediateSave: false)
            } else {
                controller.savePreferencesQuietly(preferences: newValue)
            }
        }
        .task {
            await controller.refreshHistory()
        }
    }

    // MARK: - Sidebar

    private func sidebar(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> some View {
        let isCompact = height < 700
        let railBottomInset = isCompact ? VoceDesign.sm : VoceDesign.md

        return VStack(alignment: .leading, spacing: 0) {
            sidebarBrand(isCompact: isCompact)
            sidebarNavigation(isCompact: isCompact)
            Spacer(minLength: 0)
            sidebarSettings(isCompact: isCompact)
        }
        .padding(.bottom, railBottomInset)
        .frame(width: width, height: height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.30), lineWidth: VoceDesign.borderThin)
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func sidebarBrand(isCompact: Bool) -> some View {
        HStack(spacing: VoceDesign.sm) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(VoceDesign.accent)
            Text("Voce")
                .font(VoceDesign.font(size: 18, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .padding(.horizontal, VoceDesign.lg)
        .padding(.top, isCompact ? VoceDesign.md : VoceDesign.xl + VoceDesign.sm)
        .padding(.bottom, isCompact ? VoceDesign.sm : VoceDesign.xl)
    }

    private func sidebarNavigation(isCompact: Bool) -> some View {
        VStack(spacing: VoceDesign.xxs) {
            ForEach(VoceTab.navigationTabs, id: \.self) { tab in
                sidebarButton(tab, isCompact: isCompact)
            }
        }
        .padding(.horizontal, VoceDesign.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sidebarSettings(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal, VoceDesign.lg)

            Button {
                openSettings()
            } label: {
                HStack(spacing: VoceDesign.md) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: selectedTab == .settings ? .semibold : .medium))
                        .foregroundStyle(selectedTab == .settings ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                        .frame(width: 20)
                    Text("Settings")
                        .font(VoceDesign.font(size: 13, weight: selectedTab == .settings ? .semibold : .medium))
                        .foregroundStyle(selectedTab == .settings ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: isCompact ? 34 : 38, alignment: .leading)
                .padding(.horizontal, VoceDesign.lg)
                .padding(.top, isCompact ? VoceDesign.xs : VoceDesign.sm)
                .padding(.bottom, isCompact ? VoceDesign.sm : VoceDesign.lg)
                .background {
                    if selectedTab == .settings {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                            .fill(VoceDesign.accent.opacity(0.08))
                            .padding(.horizontal, VoceDesign.md)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityAddTraits(selectedTab == .settings ? .isSelected : [])
        }
        .padding(.bottom, isCompact ? VoceDesign.xs : VoceDesign.sm)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }

    private func mainContentPane(cornerRadius: CGFloat) -> some View {
        ZStack {
            VoceDesign.contentBackground

            ZStack {
                HomeTab {
                    openSettings(.handsFreeGlobalHotkey)
                }
                .tabContentVisibility(selectedTab == .home)

                DictionaryTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .dictionary)

                SnippetsTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .snippets)

                StyleTab(preferences: $preferencesDraft)
                    .tabContentVisibility(selectedTab == .style)

                ScratchPadTab(content: $preferencesDraft.scratchPadContent)
                    .tabContentVisibility(selectedTab == .scratchPad)

                SettingsView(
                    initialLaunchTarget: settingsLaunchTarget,
                    onClose: closeSettings
                )
                .environmentObject(controller)
                .environmentObject(updaterController)
                .tabContentVisibility(selectedTab == .settings)
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04),
                    lineWidth: VoceDesign.borderThin
                )
        )
    }

    private func sidebarButton(_ tab: VoceTab, isCompact: Bool = false) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                lastNonSettingsTab = tab
                settingsLaunchTarget = nil
                selectedTab = tab
            }
        } label: {
            HStack(spacing: VoceDesign.md) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(VoceDesign.font(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? VoceDesign.textPrimary : VoceDesign.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Spacer()
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, isCompact ? VoceDesign.xs : VoceDesign.sm)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .fill(VoceDesign.accent.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func openSettings(_ launchTarget: SettingsLaunchTarget? = nil) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast)) {
            if selectedTab != .settings {
                lastNonSettingsTab = selectedTab
            }
            settingsLaunchTarget = launchTarget
            selectedTab = .settings
        }
    }

    private func closeSettings() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast)) {
            selectedTab = lastNonSettingsTab
            settingsLaunchTarget = nil
        }
    }
}

enum SettingsLaunchTarget: Equatable {
    case handsFreeGlobalHotkey
}

// MARK: - Tab Visibility Modifier

private struct TabContentVisibilityModifier: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isVisible ? 1 : 0)
    }
}

private extension View {
    func tabContentVisibility(_ isVisible: Bool) -> some View {
        modifier(TabContentVisibilityModifier(isVisible: isVisible))
    }
}
