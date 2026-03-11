import SwiftUI
import VoceKit

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.md) {
        Text(title)
            .font(VoceDesign.heading3())
            .foregroundStyle(VoceDesign.textPrimary)
            .accessibilityAddTraits(.isHeader)
        content()
    }
    .cardStyle()
}

@MainActor
func settingsCardWithSubtitle<Content: View>(
    _ title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: VoceDesign.md) {
        VStack(alignment: .leading, spacing: VoceDesign.xs) {
            Text(title)
                .font(VoceDesign.heading3())
                .foregroundStyle(VoceDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(VoceDesign.subheadline())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        content()
    }
    .cardStyle()
}

func entryRow(
    leading: String,
    trailing: String? = nil,
    scope: Scope? = nil,
    onRemove: @escaping () -> Void
) -> some View {
    HStack(spacing: VoceDesign.sm) {
        Text(leading)
            .font(VoceDesign.callout())
            .lineLimit(1)
        Spacer()
        if let trailing = trailing {
            Text(trailing)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
        }
        if let scope = scope {
            scopeBadge(scope)
        }
        Button("Remove", role: .destructive, action: onRemove)
            .buttonStyle(.link)
            .accessibilityLabel("Remove entry")
            .accessibilityValue(leading)
    }
    .padding(.vertical, VoceDesign.xs)
    .padding(.horizontal, VoceDesign.sm)
    .background(VoceDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall))
}

func scopeBadge(_ scope: Scope) -> some View {
    Text(scopeLabel(scope))
        .font(VoceDesign.label())
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.xxs)
        .background(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
        .foregroundStyle(VoceDesign.accent)
        .clipShape(Capsule())
}

func scopeLabel(_ scope: Scope) -> String {
    switch scope {
    case .global:
        return "Global"
    case .app(let bundleID):
        return bundleID
    }
}

func describedPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    description: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    VStack(alignment: .leading, spacing: VoceDesign.xxs) {
        Picker(label, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { value in
                Text(value.rawValue.capitalized).tag(value)
            }
        }
        .pickerStyle(.menu)

        Text(description)
            .font(VoceDesign.caption())
            .foregroundStyle(VoceDesign.textSecondary)
            .padding(.leading, VoceDesign.xxs)
    }
}

func enumPicker<T: Hashable & CaseIterable & RawRepresentable>(
    _ label: String,
    selection: Binding<T>
) -> some View where T.RawValue == String {
    Picker(label, selection: selection) {
        ForEach(Array(T.allCases), id: \.self) { value in
            Text(value.rawValue.capitalized).tag(value)
        }
    }
    .pickerStyle(.menu)
}

struct ScopePickerRow: View {
    @Binding var isGlobal: Bool
    @Binding var bundleID: String

    var body: some View {
        HStack {
            Toggle("All apps", isOn: $isGlobal)
                .fixedSize()
            if !isGlobal {
                TextField("Bundle ID", text: $bundleID)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
