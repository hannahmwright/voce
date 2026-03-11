import AppKit
import SwiftUI
import VoceKit

enum VoceTab: String, CaseIterable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selectedTab: VoceTab = .record
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: VoceDesign.lg) {
                Text("Voce")
                    .font(VoceDesign.heading1())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Picker("Navigation", selection: $selectedTab) {
                    ForEach(VoceTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: VoceDesign.pickerWidth)
                .accessibilityLabel("Tab selection")

                Spacer()

                Button {
                    appMainWindow()?.orderOut(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: VoceDesign.iconMD))
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Hide Window")
                .accessibilityLabel("Hide Window")
            }
            .padding(.horizontal, VoceDesign.lg)
            .padding(.vertical, VoceDesign.md)

            // Divider
            Rectangle()
                .fill(VoceDesign.border)
                .frame(height: VoceDesign.dividerHeight)

            // Tab content
            Group {
                switch selectedTab {
                case .record:
                    RecordTab()
                case .history:
                    HistoryTab()
                case .settings:
                    SettingsView()
                }
            }
            .id(selectedTab)
            .transition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, VoceDesign.lg)
            .background(VoceDesign.background)
        }
        .frame(
            minWidth: VoceDesign.windowMinWidth,
            idealWidth: VoceDesign.windowIdealWidth,
            minHeight: VoceDesign.windowMinHeight,
            idealHeight: VoceDesign.windowIdealHeight
        )
        .background(VoceDesign.surface)
        .task {
            await controller.refreshHistory()
        }
        .onAppear {
            appMainWindow()?.setFrameAutosaveName("VoceMainWindow")
        }
    }

    private func appMainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
            ?? NSApp.windows.first { !($0 is NSPanel) }
    }
}
