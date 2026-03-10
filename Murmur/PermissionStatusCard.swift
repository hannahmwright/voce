import SwiftUI

struct PermissionStatusCard: View {
    let title: String
    let description: String
    let status: PermissionDiagnostics.AccessStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: MurmurDesign.md) {
            Image(systemName: statusIconName)
                .font(.system(size: MurmurDesign.iconLG))
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: MurmurDesign.xxs) {
                Text(title)
                    .font(MurmurDesign.bodyEmphasis())
                    .foregroundStyle(MurmurDesign.textPrimary)

                Text(description)
                    .font(MurmurDesign.caption())
                    .foregroundStyle(MurmurDesign.textSecondary)
            }

            Spacer()

            Text(status.rawValue)
                .font(MurmurDesign.label())
                .foregroundStyle(statusColor)
                .padding(.horizontal, MurmurDesign.sm)
                .padding(.vertical, MurmurDesign.xxs)
                .background(statusColor.opacity(MurmurDesign.opacitySubtle))
                .clipShape(Capsule())
                .accessibilityLabel("Status: \(status.rawValue)")

            actionButton
        }
        .padding(MurmurDesign.md)
        .background(MurmurDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall)
                .stroke(statusBorderColor, lineWidth: MurmurDesign.borderNormal)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(status.rawValue). \(description)")
    }

    private var statusIconName: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return MurmurDesign.success
        case .denied: return MurmurDesign.error
        case .unknown: return MurmurDesign.warning
        }
    }

    private var statusBorderColor: Color {
        switch status {
        case .granted: return MurmurDesign.successBorder
        case .denied: return MurmurDesign.errorBorder
        case .unknown: return MurmurDesign.border
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .granted:
            EmptyView()
        case .denied:
            Button("Open Settings") {
                onOpenSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Open \(title) settings")
        case .unknown:
            Button("Grant") {
                onRequest()
            }
            .buttonStyle(.borderedProminent)
            .tint(MurmurDesign.accent)
            .controlSize(.small)
            .accessibilityLabel("Grant \(title) permission")
        }
    }
}
