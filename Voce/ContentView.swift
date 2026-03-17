import SwiftUI
import VoceKit

enum VoceTab: String, CaseIterable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .record: return "mic.fill"
        case .history: return "clock.fill"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selectedTab: VoceTab = .record
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VoceWindowBackdrop()

            VStack(spacing: 0) {
                HStack {
                    Text("Voce")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(VoceDesign.textPrimary)
                        .padding(.leading, 48)
                        .accessibilityAddTraits(.isHeader)

                    Spacer()
                }
                .padding(.top, 22)
                .padding(.horizontal, VoceDesign.lg)
                .padding(.bottom, VoceDesign.md)
                .overlay {
                    HStack(spacing: VoceDesign.xxs) {
                        ForEach(VoceTab.allCases, id: \.self) { tab in
                            tabButton(tab)
                        }
                    }
                    .padding(VoceDesign.xs)
                    .glassBackground(cornerRadius: VoceDesign.radiusPill)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.36), lineWidth: VoceDesign.borderThin)
                    )
                }
                .background {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(.ultraThinMaterial.opacity(0.18))
                }

                ZStack {
                    RecordTab()
                        .tabContentVisibility(selectedTab == .record)

                    HistoryTab()
                        .tabContentVisibility(selectedTab == .history)

                    SettingsView()
                        .tabContentVisibility(selectedTab == .settings)
                }
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                    value: selectedTab
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, VoceDesign.lg)
                .padding(.bottom, VoceDesign.lg)
            }
            .windowGlassPanel(cornerRadius: 38)
            .padding(VoceDesign.sm)
        }
        .frame(
            minWidth: VoceDesign.windowMinWidth,
            idealWidth: VoceDesign.windowIdealWidth,
            minHeight: VoceDesign.windowMinHeight,
            idealHeight: VoceDesign.windowIdealHeight
        )
        .task {
            await controller.refreshHistory()
        }
    }

    private func tabButton(_ tab: VoceTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: VoceDesign.xs) {
                Image(systemName: tab.icon)
                    .font(.system(size: VoceDesign.iconSM))
                if selectedTab == tab {
                    Text(tab.rawValue)
                        .font(VoceDesign.captionEmphasis())
                }
            }
            .foregroundStyle(selectedTab == tab ? VoceDesign.accent : VoceDesign.textSecondary)
            .padding(.horizontal, selectedTab == tab ? VoceDesign.md : VoceDesign.sm)
            .padding(.vertical, VoceDesign.xs + VoceDesign.xxs)
            .background(
                selectedTab == tab
                    ? AnyShapeStyle(VoceDesign.accent.opacity(0.10))
                    : AnyShapeStyle(Color.clear)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }
}

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
