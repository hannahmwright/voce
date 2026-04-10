import SwiftUI
import VoceKit

enum VoceTab: String, CaseIterable {
    case home = "Home"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case scratchPad = "Scratchpad"

    var icon: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "text.book.closed"
        case .snippets: return "sparkles"
        case .style: return "textformat"
        case .scratchPad: return "note.text"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @EnvironmentObject private var updaterController: UpdaterController
    @State private var selectedTab: VoceTab = .home
    @State private var showSettings = false
    @State private var settingsLaunchTarget: SettingsLaunchTarget?
    @State private var preferencesDraft: AppPreferences = .default
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            VoceWindowBackdrop()

            HStack(spacing: VoceDesign.sm) {
                sidebar
                mainContentPane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(VoceDesign.sm)
            .background {
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .fill(VoceDesign.surface.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 38, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.42))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: 38, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.12)
                            : Color.black.opacity(0.06),
                        lineWidth: VoceDesign.borderThin
                    )
            )
            .shadowStyle(.xl)
            .padding(VoceDesign.sm)

            if showSettings {
                settingsOverlay
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.98).combined(with: .opacity),
                                removal: .opacity
                            )
                    )
                    .zIndex(10)
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

    private var settingsOverlay: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeSettings()
                    }

                SettingsView(
                    initialLaunchTarget: settingsLaunchTarget,
                    onClose: closeSettings
                )
                .environmentObject(controller)
                .environmentObject(updaterController)
                .frame(
                    width: min(820, max(720, proxy.size.width - 140)),
                    height: min(620, max(520, proxy.size.height - 140))
                )
                .shadowStyle(.xl)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            HStack(spacing: VoceDesign.sm) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(VoceDesign.accent)
                Text("Voce")
                    .font(VoceDesign.font(size: 18, weight: .bold))
                    .foregroundStyle(VoceDesign.textPrimary)
            }
            .padding(.horizontal, VoceDesign.lg)
            .padding(.top, VoceDesign.xl + VoceDesign.sm)
            .padding(.bottom, VoceDesign.xl)

            // Navigation
            VStack(spacing: VoceDesign.xxs) {
                ForEach(VoceTab.allCases, id: \.self) { tab in
                    sidebarButton(tab)
                }
            }
            .padding(.horizontal, VoceDesign.md)

            Spacer()

            // Settings at bottom
            VStack(spacing: 0) {
                Divider()
                    .padding(.horizontal, VoceDesign.lg)
                    .padding(.bottom, VoceDesign.sm)

                Button {
                    settingsLaunchTarget = nil
                    showSettings = true
                } label: {
                    HStack(spacing: VoceDesign.md) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(VoceDesign.textSecondary)
                            .frame(width: 20)
                        Text("Settings")
                            .font(VoceDesign.font(size: 13, weight: .medium))
                            .foregroundStyle(VoceDesign.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, VoceDesign.lg)
                    .padding(.vertical, VoceDesign.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.bottom, VoceDesign.lg)
        }
        .frame(width: VoceDesign.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.42))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.30), lineWidth: VoceDesign.borderThin)
                )
        }
    }

    private var mainContentPane: some View {
        ZStack {
            VoceDesign.contentBackground

            ZStack {
                HomeTab {
                    settingsLaunchTarget = .handsFreeGlobalHotkey
                    showSettings = true
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
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.06)
                        : Color.black.opacity(0.04),
                    lineWidth: VoceDesign.borderThin
                )
        )
    }

    private func sidebarButton(_ tab: VoceTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
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

                Spacer()
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
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

    private func closeSettings() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationFast)) {
            showSettings = false
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
