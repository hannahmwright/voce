import SwiftUI
import MurmurKit

struct HistoryTab: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchQuery: String = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var currentTime = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: MurmurDesign.md) {
            // Header bar
            HStack {
                Text("History")
                    .font(MurmurDesign.heading2())
                    .foregroundStyle(MurmurDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                HStack(spacing: MurmurDesign.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(MurmurDesign.textSecondary)
                        .font(MurmurDesign.caption())
                    TextField("Search transcripts...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(MurmurDesign.callout())
                        .accessibilityLabel("Search transcripts")
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(MurmurDesign.caption())
                                .foregroundStyle(MurmurDesign.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, MurmurDesign.sm)
                .padding(.vertical, MurmurDesign.xs + MurmurDesign.xxs)
                .background(MurmurDesign.surfaceSecondary)
                .clipShape(RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MurmurDesign.radiusSmall)
                        .stroke(MurmurDesign.border, lineWidth: MurmurDesign.borderNormal)
                )
                .frame(maxWidth: MurmurDesign.searchBarMaxWidth)
            }

            // Content
            if filteredEntries.isEmpty {
                Spacer()
                Text(searchQuery.isEmpty ? "No transcripts yet" : "No matching transcripts")
                    .font(MurmurDesign.body())
                    .foregroundStyle(MurmurDesign.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MurmurDesign.sm) {
                        ForEach(groupedEntries, id: \.label) { group in
                            // Day header
                            Text(group.label)
                                .font(MurmurDesign.bodyEmphasis())
                                .foregroundStyle(MurmurDesign.textSecondary)
                                .padding(.top, MurmurDesign.sm)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, MurmurDesign.lg)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: MurmurDesign.animationNormal),
                        value: filteredEntries.count
                    )
                }
            }
        }
        .padding(.vertical, MurmurDesign.lg)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            currentTime = now
        }
    }

    private var filteredEntries: [TranscriptEntry] {
        if searchQuery.isEmpty {
            return controller.recentEntries
        }
        return controller.recentEntries.filter {
            $0.cleanText.localizedCaseInsensitiveContains(searchQuery)
            || $0.rawText.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var groupedEntries: [DayGroup] {
        let calendar = Calendar.current
        var groups: [String: [TranscriptEntry]] = [:]
        var order: [String] = []

        for entry in filteredEntries {
            let label = dayLabel(for: entry.createdAt, calendar: calendar)
            if groups[label] == nil {
                order.append(label)
                groups[label] = []
            }
            groups[label]?.append(entry)
        }

        return order.map { DayGroup(label: $0, entries: groups[$0] ?? []) }
    }

    private func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

    private func relativeTimestamp(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        // Use currentTime to force refresh
        _ = currentTime
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func entryRow(_ entry: TranscriptEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)

        return VStack(alignment: .leading, spacing: MurmurDesign.sm) {
            // Top line: app name + status pill
            HStack {
                Text(appName(for: entry.appBundleID))
                    .font(MurmurDesign.captionEmphasis())
                    .foregroundStyle(MurmurDesign.textSecondary)
                Spacer()
                statusPill(entry.insertionStatus)
            }

            // Body text
            HStack(alignment: .top, spacing: MurmurDesign.xs) {
                Text(entry.cleanText.isEmpty ? entry.rawText : entry.cleanText)
                    .font(MurmurDesign.callout())
                    .foregroundStyle(MurmurDesign.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: MurmurDesign.animationFast)) {
                            if isExpanded {
                                expandedIDs.remove(entry.id)
                            } else {
                                expandedIDs.insert(entry.id)
                            }
                        }
                    }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(MurmurDesign.caption())
                    .foregroundStyle(MurmurDesign.textSecondary)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            }

            // Bottom line: timestamp + copy/paste
            HStack {
                Text(relativeTimestamp(for: entry.createdAt))
                    .font(MurmurDesign.caption())
                    .foregroundStyle(MurmurDesign.textSecondary)
                Spacer()

                CopyButtonView {
                    controller.copyEntry(entry)
                }

                Button {
                    controller.pasteEntry(entry)
                } label: {
                    HStack(spacing: MurmurDesign.xs) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste")
                    }
                    .font(MurmurDesign.caption())
                    .foregroundStyle(MurmurDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste transcript")
            }
        }
        .accessibilityElement(children: .contain)
        .cardStyle()
        .contextMenu {
            Button {
                controller.copyEntry(entry)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                controller.pasteEntry(entry)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            Divider()
            Button(role: .destructive) {
                controller.deleteEntry(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func statusPill(_ status: InsertionStatus) -> some View {
        let (label, bgColor): (String, Color) = {
            switch status {
            case .inserted:
                return ("Inserted", MurmurDesign.successBackground)
            case .copiedOnly:
                return ("Copied", MurmurDesign.warningBackground)
            case .failed:
                return ("Failed", MurmurDesign.errorBackground)
            }
        }()

        let fgColor: Color = {
            switch status {
            case .inserted: return MurmurDesign.success
            case .copiedOnly: return MurmurDesign.warning
            case .failed: return MurmurDesign.error
            }
        }()

        return Text(label)
            .font(MurmurDesign.labelEmphasis())
            .foregroundStyle(fgColor)
            .padding(.horizontal, MurmurDesign.sm)
            .padding(.vertical, MurmurDesign.xxs)
            .background(bgColor)
            .clipShape(Capsule())
            .accessibilityLabel("Status: \(label)")
    }

    private func appName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

private struct DayGroup {
    let label: String
    let entries: [TranscriptEntry]
}
