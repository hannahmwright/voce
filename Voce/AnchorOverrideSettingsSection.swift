import SwiftUI
import VoceKit

struct AnchorOverrideSettingsSection: View {
    @Binding var preferences: AppPreferences
    @EnvironmentObject private var controller: DictationController

    var body: some View {
        settingsCardWithSubtitle(
            "Overlay Position",
            subtitle: "Remembered overlay positions per app"
        ) {
            Text("During dictation, click Reposition Overlay to temporarily make the bubble draggable. Voce remembers that position for the current app and restores it next time. Browser apps are excluded since they already report input positions correctly.")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            Button("Reposition Overlay") {
                controller.beginOverlayRepositionMode()
            }
            .buttonStyle(.borderedProminent)

            if preferences.appAnchorOverrides.isEmpty {
                HStack(spacing: VoceDesign.sm) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: VoceDesign.iconMD))
                        .foregroundStyle(VoceDesign.textSecondary)
                    Text("No saved positions yet. Start dictation, choose Reposition Overlay, then drag the bubble to save a position.")
                        .font(VoceDesign.caption())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .padding(.vertical, VoceDesign.xs)
            } else {
                ForEach(preferences.appAnchorOverrides.keys.sorted(), id: \.self) { bundleID in
                    if let anchor = preferences.appAnchorOverrides[bundleID] {
                        anchorRow(bundleID: bundleID, anchor: anchor)
                    }
                }

                if preferences.appAnchorOverrides.count > 1 {
                    HStack {
                        Spacer()
                        Button("Reset All", role: .destructive) {
                            preferences.appAnchorOverrides.removeAll()
                        }
                        .buttonStyle(.link)
                        .font(VoceDesign.caption())
                    }
                }
            }
        }
    }

    private func anchorRow(bundleID: String, anchor: AppAnchorOverride) -> some View {
        HStack(spacing: VoceDesign.sm) {
            VStack(alignment: .leading, spacing: VoceDesign.xxs) {
                Text(appDisplayName(for: bundleID))
                    .font(VoceDesign.callout())
                    .lineLimit(1)

                Text(bundleID)
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Reset", role: .destructive) {
                preferences.appAnchorOverrides.removeValue(forKey: bundleID)
            }
            .buttonStyle(.link)
            .accessibilityLabel("Reset saved overlay position")
            .accessibilityValue(bundleID)
        }
        .padding(.vertical, VoceDesign.xs)
        .padding(.horizontal, VoceDesign.sm)
        .background(VoceDesign.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
    }

    /// Try to resolve a human-friendly app name from the bundle ID.
    private func appDisplayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        // Fall back to last component of the bundle ID.
        return bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
    }
}
