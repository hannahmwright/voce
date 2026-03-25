import SwiftUI
import VoceKit

struct HistoryTab: View {
    private enum HistoryTimeFilter: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case last7Days = "Last 7 Days"
        case last30Days = "Last 30 Days"

        var title: String { rawValue }
    }

    private enum HistoryAITypeFilter: String, CaseIterable {
        case all = "All"
        case aiOnly = "AI"
        case nonAIOnly = "No AI"

        var title: String { rawValue }
    }

    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchQuery: String = ""
    @State private var expandedIDs: Set<UUID> = []
    @State private var hoveredID: UUID?
    @State private var currentTime = Date()
    @State private var selectedAppFilter: String = "All Apps"
    @State private var selectedTimeFilter: HistoryTimeFilter = .all
    @State private var selectedAITypeFilter: HistoryAITypeFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: VoceDesign.md) {
            // Header bar
            HStack(alignment: .top) {
                Text("History")
                    .font(VoceDesign.heading2())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                VStack(alignment: .trailing, spacing: VoceDesign.xs) {
                    HStack(spacing: VoceDesign.xs) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(VoceDesign.textSecondary)
                            .font(VoceDesign.caption())
                        TextField("Search...", text: $searchQuery)
                            .textFieldStyle(.plain)
                            .font(VoceDesign.callout())
                            .accessibilityLabel("Search transcripts")
                        if !searchQuery.isEmpty {
                            Button {
                                searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(VoceDesign.caption())
                                    .foregroundStyle(VoceDesign.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, VoceDesign.sm)
                    .padding(.vertical, VoceDesign.xs + VoceDesign.xxs)
                    .glassBackground(cornerRadius: VoceDesign.radiusSmall)
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusSmall)
                            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                    )
                    .frame(maxWidth: VoceDesign.searchBarMaxWidth)

                    filterBar
                }
            }

            // Content
            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: VoceDesign.sm) {
                    Image(systemName: searchQuery.isEmpty ? "text.bubble" : "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.5))
                    Text(searchQuery.isEmpty ? "No transcripts yet" : "No matches")
                        .font(VoceDesign.body())
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VoceDesign.sm) {
                        ForEach(groupedEntries, id: \.label) { group in
                            // Day header
                            Text(group.label)
                                .font(VoceDesign.captionEmphasis())
                                .foregroundStyle(VoceDesign.textSecondary)
                                .padding(.top, VoceDesign.sm)
                                .padding(.leading, VoceDesign.xs)
                                .accessibilityAddTraits(.isHeader)

                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        }
                    }
                    .padding(.bottom, VoceDesign.lg)
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal),
                        value: filteredEntries.count
                    )
                }
            }
        }
        .padding(.vertical, VoceDesign.lg)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            currentTime = now
        }
    }

    private var filteredEntries: [TranscriptEntry] {
        controller.recentEntries.filter { entry in
            matchesSearch(entry)
                && matchesAppFilter(entry)
                && matchesTimeFilter(entry)
                && matchesAITypeFilter(entry)
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
        _ = currentTime
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func absoluteTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: TranscriptEntry) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        let showsAISections = (entry.sourceText?.isEmpty == false) && entry.aiWorkflowName != nil
        let showsExpansionChevron = entryLikelyNeedsExpansion(entry)

        return VStack(alignment: .leading, spacing: VoceDesign.sm) {
            // Text + metadata on one line
            HStack(alignment: .top, spacing: VoceDesign.sm) {
                transcriptBody(entry, isExpanded: isExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if showsExpansionChevron {
                    Button {
                        toggleExpanded(entry.id, isExpanded: isExpanded)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10))
                            .foregroundStyle(VoceDesign.textSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                }
            }

            // Bottom row: metadata left, actions right (actions on hover)
            HStack(spacing: VoceDesign.sm) {
                appIdentityView(for: entry.appBundleID)

                Text("\u{00B7}")
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.4))

                Text(relativeTimestamp(for: entry.createdAt))
                    .font(VoceDesign.label())
                    .foregroundStyle(VoceDesign.textSecondary)

                Text(absoluteTimestamp(for: entry.createdAt))
                    .font(VoceDesign.label())
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.8))

                if let processingNote = entry.processingNote, !processingNote.isEmpty {
                    processingNoteBadge(processingNote)
                }

                if let aiWorkflowName = entry.aiWorkflowName, !aiWorkflowName.isEmpty {
                    aiWorkflowBadge(aiWorkflowName)
                }

                statusDot(entry.insertionStatus)

                Spacer()
            }
        }
        .accessibilityElement(children: .contain)
        .cardStyle(elevation: .sm)
        .onHover { hovering in
            hoveredID = hovering ? entry.id : nil
        }
        .contentShape(Rectangle())
        .onTapGesture {
            controller.copyEntry(entry)
        }
        .contextMenu {
            if showsAISections {
                Button {
                    controller.copyEntryTranscript(entry)
                } label: {
                    Label("Copy Transcript", systemImage: "waveform.and.mic")
                }
                Button {
                    controller.copyEntryAIOutput(entry)
                } label: {
                    Label("Copy AI Output", systemImage: "sparkles")
                }
            } else {
                Button {
                    controller.copyEntry(entry)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Divider()
            Button(role: .destructive) {
                controller.deleteEntry(entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Status Dot (replaces verbose pill)

    private func statusDot(_ status: InsertionStatus) -> some View {
        let color: Color = {
            switch status {
            case .inserted: return VoceDesign.success
            case .copiedOnly: return VoceDesign.warning
            case .failed: return VoceDesign.error
            }
        }()

        let label: String = {
            switch status {
            case .inserted: return "Inserted"
            case .copiedOnly: return "Copied"
            case .failed: return "Failed"
            }
        }()

        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Status: \(label)")
            .help(label)
    }

    private func processingNoteBadge(_ note: String) -> some View {
        Text("Recovered")
            .font(VoceDesign.label())
            .foregroundStyle(VoceDesign.warning)
            .padding(.horizontal, VoceDesign.xs)
            .padding(.vertical, VoceDesign.xxs)
            .background(
                Capsule()
                    .fill(VoceDesign.warningBackground)
            )
            .overlay(
                Capsule()
                    .stroke(VoceDesign.warningBorder, lineWidth: VoceDesign.borderThin)
            )
            .help(note)
            .accessibilityLabel(note)
    }

    private func aiWorkflowBadge(_ name: String) -> some View {
        Text(name)
            .font(VoceDesign.label())
            .foregroundStyle(VoceDesign.accent)
            .padding(.horizontal, VoceDesign.xs)
            .padding(.vertical, VoceDesign.xxs)
            .background(
                Capsule()
                    .fill(VoceDesign.accent.opacity(VoceDesign.opacitySubtle))
            )
            .help("Generated by \(name)")
    }

    @ViewBuilder
    private func transcriptBody(_ entry: TranscriptEntry, isExpanded: Bool) -> some View {
        let finalText = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText

        if let sourceText = entry.sourceText,
           !sourceText.isEmpty,
           entry.aiWorkflowName != nil {
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                transcriptSection(
                    title: "Transcribed",
                    text: sourceText,
                    isExpanded: isExpanded,
                    foregroundStyle: VoceDesign.textSecondary
                )
                transcriptSection(
                    title: "AI Output",
                    text: finalText,
                    isExpanded: isExpanded,
                    foregroundStyle: VoceDesign.textPrimary
                )
            }
        } else {
            Text(finalText)
                .font(VoceDesign.callout())
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(isExpanded ? nil : 2)
        }
    }

    private func transcriptSection(
        title: String,
        text: String,
        isExpanded: Bool,
        foregroundStyle: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: VoceDesign.xxs) {
            Text(title)
                .font(VoceDesign.label())
                .foregroundStyle(VoceDesign.textSecondary)
            Text(text)
                .font(VoceDesign.callout())
                .foregroundStyle(foregroundStyle)
                .lineLimit(isExpanded ? nil : 2)
        }
    }

    private func toggleExpanded(_ entryID: UUID, isExpanded: Bool) {
        withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
            if isExpanded {
                expandedIDs.remove(entryID)
            } else {
                expandedIDs.insert(entryID)
            }
        }
    }

    private func appName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    @ViewBuilder
    private func appIdentityView(for bundleID: String) -> some View {
        HStack(spacing: VoceDesign.xs) {
            if let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "app")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.75))
            }

            Text(appName(for: bundleID))
                .font(VoceDesign.label())
                .foregroundStyle(VoceDesign.textSecondary)
        }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 14, height: 14)
        return icon
    }

    private func entryLikelyNeedsExpansion(_ entry: TranscriptEntry) -> Bool {
        let finalText = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText

        if let sourceText = entry.sourceText,
           !sourceText.isEmpty,
           entry.aiWorkflowName != nil {
            return sourceText.count > 120 || finalText.count > 120
        }

        return finalText.count > 140
    }

    private var filterBar: some View {
        HStack(spacing: VoceDesign.xs) {
            filterMenu(
                title: "App",
                selection: selectedAppFilter
            ) {
                Button("All Apps") {
                    selectedAppFilter = "All Apps"
                }
                Divider()
                ForEach(availableApps, id: \.self) { app in
                    Button(app) {
                        selectedAppFilter = app
                    }
                }
            }

            filterMenu(
                title: "Time",
                selection: selectedTimeFilter.title
            ) {
                ForEach(HistoryTimeFilter.allCases, id: \.self) { filter in
                    Button(filter.title) {
                        selectedTimeFilter = filter
                    }
                }
            }

            filterMenu(
                title: "Type",
                selection: selectedAITypeFilter.title
            ) {
                ForEach(HistoryAITypeFilter.allCases, id: \.self) { filter in
                    Button(filter.title) {
                        selectedAITypeFilter = filter
                    }
                }
            }
        }
    }

    private func filterMenu<Content: View>(
        title: String,
        selection: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            HStack(spacing: VoceDesign.xxs) {
                Text(title)
                    .font(VoceDesign.label())
                Text(selection)
                    .font(VoceDesign.label())
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(VoceDesign.textSecondary.opacity(0.75))
            }
            .padding(.horizontal, VoceDesign.sm)
            .padding(.vertical, VoceDesign.xxs + 2)
            .background(VoceDesign.surfaceSecondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private var availableApps: [String] {
        Array(
            Set(controller.recentEntries.map { appName(for: $0.appBundleID) })
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func matchesSearch(_ entry: TranscriptEntry) -> Bool {
        guard !searchQuery.isEmpty else { return true }
        return entry.cleanText.localizedCaseInsensitiveContains(searchQuery)
            || entry.rawText.localizedCaseInsensitiveContains(searchQuery)
            || (entry.sourceText?.localizedCaseInsensitiveContains(searchQuery) ?? false)
            || (entry.aiWorkflowName?.localizedCaseInsensitiveContains(searchQuery) ?? false)
    }

    private func matchesAppFilter(_ entry: TranscriptEntry) -> Bool {
        guard selectedAppFilter != "All Apps" else { return true }
        return appName(for: entry.appBundleID) == selectedAppFilter
    }

    private func matchesTimeFilter(_ entry: TranscriptEntry) -> Bool {
        let calendar = Calendar.current
        switch selectedTimeFilter {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(entry.createdAt)
        case .last7Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -7, to: Date()) else { return true }
            return entry.createdAt >= cutoff
        case .last30Days:
            guard let cutoff = calendar.date(byAdding: .day, value: -30, to: Date()) else { return true }
            return entry.createdAt >= cutoff
        }
    }

    private func matchesAITypeFilter(_ entry: TranscriptEntry) -> Bool {
        switch selectedAITypeFilter {
        case .all:
            return true
        case .aiOnly:
            return entry.aiWorkflowName != nil
        case .nonAIOnly:
            return entry.aiWorkflowName == nil
        }
    }
}

private struct DayGroup {
    let label: String
    let entries: [TranscriptEntry]
}
