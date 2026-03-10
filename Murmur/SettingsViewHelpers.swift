import SwiftUI
import MurmurKit

@MainActor
func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: MurmurDesign.md) {
        Text(title)
            .font(MurmurDesign.heading3())
            .foregroundStyle(MurmurDesign.textPrimary)
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
    VStack(alignment: .leading, spacing: MurmurDesign.md) {
        VStack(alignment: .leading, spacing: MurmurDesign.xs) {
            Text(title)
                .font(MurmurDesign.heading3())
                .foregroundStyle(MurmurDesign.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(MurmurDesign.subheadline())
                .foregroundStyle(MurmurDesign.textSecondary)
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
    HStack(spacing: MurmurDesign.sm) {
        Text(leading)
            .font(MurmurDesign.callout())
            .lineLimit(1)
        Spacer()
        if let trailing = trailing {
            Text(trailing)
                .font(MurmurDesign.caption())
                .foregroundStyle(MurmurDesign.textSecondary)
        }
        if let scope = scope {
            scopeBadge(scope)
        }
        Button("Remove", role: .destructive, action: onRemove)
            .buttonStyle(.link)
            .accessibilityLabel("Remove entry")
            .accessibilityValue(leading)
    }
    .padding(.vertical, MurmurDesign.xs)
    .padding(.horizontal, MurmurDesign.sm)
    .background(MurmurDesign.surfaceSecondary)
    .clipShape(RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall))
}

func scopeBadge(_ scope: Scope) -> some View {
    Text(scopeLabel(scope))
        .font(MurmurDesign.label())
        .padding(.horizontal, MurmurDesign.sm)
        .padding(.vertical, MurmurDesign.xxs)
        .background(MurmurDesign.accent.opacity(MurmurDesign.opacitySubtle))
        .foregroundStyle(MurmurDesign.accent)
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
    VStack(alignment: .leading, spacing: MurmurDesign.xxs) {
        Picker(label, selection: selection) {
            ForEach(Array(T.allCases), id: \.self) { value in
                Text(value.rawValue.capitalized).tag(value)
            }
        }
        .pickerStyle(.menu)

        Text(description)
            .font(MurmurDesign.caption())
            .foregroundStyle(MurmurDesign.textSecondary)
            .padding(.leading, MurmurDesign.xxs)
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
