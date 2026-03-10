import AppKit
import SwiftUI
import MurmurKit

enum MurmurTab: String, CaseIterable {
    case record = "Record"
    case history = "History"
    case settings = "Settings"
}

struct ContentView: View {
    @EnvironmentObject private var controller: DictationController
    @State private var selectedTab: MurmurTab = .record
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack(spacing: MurmurDesign.lg) {
                Text("Murmur")
                    .font(MurmurDesign.heading1())
                    .foregroundStyle(MurmurDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                Picker("Navigation", selection: $selectedTab) {
                    ForEach(MurmurTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: MurmurDesign.pickerWidth)
                .accessibilityLabel("Tab selection")

                Spacer()

                Button {
                    appMainWindow()?.orderOut(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: MurmurDesign.iconMD))
                        .foregroundStyle(MurmurDesign.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Hide Window")
                .accessibilityLabel("Hide Window")
            }
            .padding(.horizontal, MurmurDesign.lg)
            .padding(.vertical, MurmurDesign.md)

            // Divider
            Rectangle()
                .fill(MurmurDesign.border)
                .frame(height: MurmurDesign.dividerHeight)

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
                reduceMotion ? nil : .easeInOut(duration: MurmurDesign.animationNormal),
                value: selectedTab
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, MurmurDesign.lg)
            .background(MurmurDesign.background)
        }
        .frame(
            minWidth: MurmurDesign.windowMinWidth,
            idealWidth: MurmurDesign.windowIdealWidth,
            minHeight: MurmurDesign.windowMinHeight,
            idealHeight: MurmurDesign.windowIdealHeight
        )
        .background(MurmurDesign.surface)
        .task {
            await controller.refreshHistory()
        }
        .onAppear {
            appMainWindow()?.setFrameAutosaveName("StenoMainWindow")
        }
    }

    private func appMainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
            ?? NSApp.windows.first { !($0 is NSPanel) }
    }
}
