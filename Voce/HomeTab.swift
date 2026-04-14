import AppKit
import SwiftUI
import VoceKit

struct HomeTab: View {
    @EnvironmentObject private var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    let onOpenTapToTalkSettings: () -> Void
    @State private var expandedIDs: Set<UUID> = []
    @State private var hoveredID: UUID?
    @State private var currentTime = Date()
    @State private var showErrorBanner = false
    @State private var dismissedPermissionCallouts: Set<PermissionCalloutKind> = []

    var body: some View {
        GeometryReader { proxy in
            let layout = HomeLayout.make(for: proxy.size.width)

            HStack(alignment: .top, spacing: 0) {
                // Main column
                VStack(alignment: .leading, spacing: 0) {
                    // Greeting + recording controls
                    VStack(alignment: .leading, spacing: VoceDesign.sm) {
                        greetingSection(layout: layout)
                        recordingControlsSection
                    }
                    .padding(.horizontal, layout.mainHorizontalPadding)
                    .padding(.top, VoceDesign.xl)
                    .padding(.bottom, VoceDesign.lg)

                    // History
                    historySection(layout: layout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // Metrics column (right rail)
                metricsColumn(layout: layout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            controller.refreshPermissionStatuses()
            dismissedPermissionCallouts = dismissedPermissionCallouts.intersection(Set(missingPermissionCallouts))
            showErrorBanner = !activeErrorMessage.isEmpty
        }
        .onChange(of: controller.lastError) { _, _ in animateErrorBannerUpdate() }
        .onChange(of: controller.hotkeyRegistrationMessage) { _, _ in animateErrorBannerUpdate() }
        .onChange(of: controller.microphonePermissionStatus) { _, _ in animateErrorBannerUpdate() }
        .onChange(of: controller.speechRecognitionPermissionStatus) { _, _ in animateErrorBannerUpdate() }
        .onChange(of: controller.accessibilityPermissionStatus) { _, _ in animateErrorBannerUpdate() }
        .onChange(of: controller.inputMonitoringPermissionStatus) { _, _ in animateErrorBannerUpdate() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now in
            currentTime = now
        }
    }

    // MARK: - Greeting

    private func greetingSection(layout: HomeLayout) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: VoceDesign.sm) {
                greetingLeadingText(fontSize: layout.greetingFontSize)

                hotkeyButton

                greetingTrailingText(fontSize: layout.greetingFontSize)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                greetingLeadingText(fontSize: layout.greetingFontSize)

                HStack(spacing: VoceDesign.sm) {
                    hotkeyButton
                    greetingTrailingText(fontSize: layout.greetingFontSize)
                }
            }
        }
    }

    private func backdropBanner(height: CGFloat) -> some View {
        GeometryReader { proxy in
            Image("RecordBackground")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height + bannerVerticalOverflow
                )
                .offset(y: bannerVerticalOffset)
        }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [
                            Color.black.opacity(0.18),
                            Color.clear,
                            VoceDesign.windowBackground.opacity(0.12)
                        ]
                        : [
                            Color.white.opacity(0.04),
                            Color.clear,
                            VoceDesign.sage.opacity(0.10)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay(
                RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.06),
                        lineWidth: VoceDesign.borderThin
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            .shadowStyle(.sm)
            .accessibilityHidden(true)
    }

    private var bannerVerticalOffset: CGFloat {
        colorScheme == .light ? 56 : 0
    }

    private var bannerVerticalOverflow: CGFloat {
        abs(bannerVerticalOffset) * 2
    }

    // MARK: - Recording Controls

    @ViewBuilder
    private var recordingControlsSection: some View {
        if controller.recordingLifecycleState == .transcribing {
            HStack(spacing: VoceDesign.sm) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)

                Text(controller.status)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.accent)
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
            .background(VoceDesign.accent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        } else if controller.isRecording {
            VStack(alignment: .leading, spacing: VoceDesign.sm) {
                HStack(spacing: VoceDesign.sm) {
                    Circle()
                        .fill(VoceDesign.error)
                        .frame(width: 8, height: 8)
                        .opacity(reduceMotion ? 1 : 0.8)
                        .scaleEffect(reduceMotion ? 1.0 : 1.2)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: controller.isRecording
                        )

                    Text(controller.status)
                        .font(VoceDesign.captionEmphasis())
                        .foregroundStyle(VoceDesign.accent)

                    Text(formatElapsedTime(controller.recordingElapsed))
                        .font(VoceDesign.caption().monospacedDigit())
                        .foregroundStyle(VoceDesign.textSecondary)

                    Spacer()
                }

                Button {
                    controller.stopActiveRecording()
                } label: {
                    Label(
                        controller.recordingLifecycleState == .recordingPressToTalk
                            ? "Stop hold-to-talk"
                            : "Stop recording",
                        systemImage: "stop.fill"
                    )
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.sm)
            .background(VoceDesign.accent.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Metrics Column (right rail)

    private func metricsColumn(layout: HomeLayout) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Metrics card
                    VStack(alignment: .leading, spacing: VoceDesign.sm) {
                        metricRow(
                            value: formattedMetricValue(controller.wordsDictatedToday),
                            title: "Today",
                            unit: controller.wordsDictatedToday == 1 ? "word" : "words"
                        )
                        metricRow(
                            value: formattedMetricValue(controller.currentUsageStreak),
                            title: "Streak",
                            unit: controller.currentUsageStreak == 1 ? "day" : "days"
                        )
                        metricRow(
                            value: formattedMetricValue(controller.totalWordsDictated),
                            title: "Lifetime",
                            unit: "words"
                        )

                    }
                    .padding(VoceDesign.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                            .fill(VoceDesign.contentBackground)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                            .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
                    )
                    .shadowStyle(.sm)
                    .padding(VoceDesign.md)
                    .padding(.top, VoceDesign.lg)

                    activityHeatmapCard
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.bottom, VoceDesign.md)

                    if !visiblePermissionCallouts.isEmpty {
                        VStack(spacing: VoceDesign.sm) {
                            ForEach(visiblePermissionCallouts, id: \.self) { kind in
                                permissionBannerView(kind)
                            }
                        }
                        .padding(.horizontal, VoceDesign.md)
                        .padding(.bottom, VoceDesign.md)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                    }

                    if showErrorBanner {
                        genericErrorBannerView
                            .padding(.horizontal, VoceDesign.md)
                            .padding(.bottom, VoceDesign.md)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .move(edge: .top).combined(with: .opacity)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: layout.metricsColumnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }

    private var hotkeyButton: some View {
        Button(action: onOpenTapToTalkSettings) {
            hotkeyBadge(controller.tapToTalkHotkeyLabel)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit tap to talk shortcut")
        .accessibilityHint("Opens recording settings for the tap to talk shortcut")
    }

    private func greetingLeadingText(fontSize: CGFloat) -> some View {
        Text("Hey \(controller.displayName), tap")
            .font(VoceDesign.font(size: fontSize, weight: .semibold))
            .foregroundStyle(VoceDesign.textPrimary)
            .minimumScaleFactor(0.9)
            .lineLimit(1)
    }

    private func greetingTrailingText(fontSize: CGFloat) -> some View {
        Text("to talk")
            .font(VoceDesign.font(size: fontSize, weight: .semibold))
            .foregroundStyle(VoceDesign.textPrimary)
            .minimumScaleFactor(0.9)
            .lineLimit(1)
    }

    private func metricRow(value: String, title: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title)
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)
                .frame(width: 52, alignment: .leading)

            Text(value)
                .font(VoceDesign.font(size: 20, weight: .bold))
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(" \(unit)")
                .font(VoceDesign.caption())
                .foregroundStyle(VoceDesign.textSecondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.xs + 1)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .fill(VoceDesign.surface.opacity(0.4))
        }
        .accessibilityElement(children: .combine)
    }

    private func formattedMetricValue(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private var activityHeatmapCard: some View {
        let cells = activityHeatmapGridCells
        let columns = Array(repeating: GridItem(.fixed(activityHeatmapColumnWidth), spacing: activityHeatmapSpacing), count: 7)

        return VStack(alignment: .leading, spacing: VoceDesign.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)

                Spacer(minLength: 0)

                Text("6 weeks")
                    .font(VoceDesign.caption())
                    .foregroundStyle(VoceDesign.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(activityCurrentMonthLabel)
                    .font(VoceDesign.captionEmphasis())
                    .foregroundStyle(VoceDesign.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .center)

                LazyVGrid(
                    columns: columns,
                    alignment: .center,
                    spacing: activityHeatmapSpacing
                ) {
                    ForEach(activityWeekdayLabels, id: \.self) { label in
                        Text(label)
                            .font(VoceDesign.caption())
                            .foregroundStyle(VoceDesign.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(width: activityHeatmapColumnWidth, height: 14, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                LazyVGrid(
                    columns: columns,
                    alignment: .center,
                    spacing: activityHeatmapSpacing
                ) {
                    ForEach(cells) { cell in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(activityHeatmapColor(for: cell.level, isFuture: cell.isFuture))
                            .frame(width: activityHeatmapCellSize, height: activityHeatmapCellSize)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(VoceDesign.border.opacity(cell.level == 0 ? 0.55 : 0.18), lineWidth: VoceDesign.borderThin)
                            )
                            .help(activityTooltip(for: cell))
                            .accessibilityLabel(activityAccessibilityLabel(for: cell))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(VoceDesign.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .fill(VoceDesign.contentBackground)
        }
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusMedium, style: .continuous)
                .stroke(VoceDesign.border, lineWidth: VoceDesign.borderThin)
        )
        .shadowStyle(.sm)
    }

    private var activityHeatmapGridCells: [HomeActivityCell] {
        activityHeatmapWeeks.flatMap(\.self)
    }

    private var activityHeatmapWeeks: [[HomeActivityCell]] {
        let calendar = activityCalendar
        let today = calendar.startOfDay(for: currentTime)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -5, to: currentWeekStart) ?? currentWeekStart

        let statsByDay = Dictionary(uniqueKeysWithValues: controller.dailyUsageActivity.map { stat in
            (calendar.startOfDay(for: stat.day), stat)
        })
        let maxWords = max(statsByDay.values.map(\.wordCount).max() ?? 0, 1)

        return (0..<6).map { weekOffset in
            let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeekStart) ?? firstWeekStart

            return (0..<7).map { dayOffset in
                let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) ?? weekStart
                let isFuture = date > today
                let stat = isFuture ? nil : statsByDay[calendar.startOfDay(for: date)]
                let words = stat?.wordCount ?? 0
                let sessions = stat?.sessionCount ?? 0

                return HomeActivityCell(
                    date: date,
                    wordCount: words,
                    sessionCount: sessions,
                    level: activityHeatmapLevel(wordCount: words, maxWords: maxWords),
                    isFuture: isFuture
                )
            }
        }
    }

    private var activityCurrentMonthLabel: String {
        activityMonthFormatter.string(from: currentTime)
    }

    private var activityWeekdayLabels: [String] {
        ["M", "T", "W", "TH", "F", "SA", "S"]
    }

    private var activityHeatmapCellSize: CGFloat {
        13
    }

    private var activityHeatmapColumnWidth: CGFloat {
        18
    }

    private var activityHeatmapSpacing: CGFloat {
        3
    }

    private var activityCalendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private func activityHeatmapLevel(wordCount: Int, maxWords: Int) -> Int {
        guard wordCount > 0 else { return 0 }
        let scaled = Int(ceil((Double(wordCount) / Double(maxWords)) * 4.0))
        return min(max(scaled, 1), 4)
    }

    private func activityHeatmapColor(for level: Int, isFuture: Bool) -> Color {
        if isFuture {
            return VoceDesign.surfaceSecondary.opacity(0.35)
        }

        switch level {
        case 0:
            return VoceDesign.surfaceSecondary
        case 1:
            return VoceDesign.warmAccentFill.opacity(0.62)
        case 2:
            return VoceDesign.sage.opacity(0.70)
        case 3:
            return VoceDesign.success.opacity(0.82)
        default:
            return VoceDesign.warmAccentText.opacity(0.95)
        }
    }

    private func activityTooltip(for cell: HomeActivityCell) -> String {
        let date = activityDateFormatter.string(from: cell.date)
        if cell.isFuture || cell.wordCount == 0 {
            return "\(date): no dictation"
        }
        let wordUnit = cell.wordCount == 1 ? "word" : "words"
        let sessionUnit = cell.sessionCount == 1 ? "session" : "sessions"
        return "\(date): \(cell.wordCount) \(wordUnit) in \(cell.sessionCount) \(sessionUnit)"
    }

    private func activityAccessibilityLabel(for cell: HomeActivityCell) -> String {
        activityTooltip(for: cell)
    }

    private var activityDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private var activityMonthFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter
    }

    // MARK: - Hotkey Badge (warm color from backdrop palette)

    private func hotkeyBadge(_ label: String) -> some View {
        Text(label)
            .font(VoceDesign.font(size: 13, weight: .semibold))
            .foregroundStyle(VoceDesign.warmAccentText)
            .padding(.horizontal, VoceDesign.md)
            .padding(.vertical, VoceDesign.xs + VoceDesign.xxs)
            .background(VoceDesign.warmAccentFill)
            .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
    }

    // MARK: - History

    private func historySection(layout: HomeLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.recentEntries.isEmpty {
                Spacer()
                VStack(spacing: VoceDesign.sm) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 24))
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.4))
                    Text("No transcripts yet")
                        .font(VoceDesign.font(size: 13))
                        .foregroundStyle(VoceDesign.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        backdropBanner(height: layout.bannerHeight)
                            .padding(.horizontal, layout.mainHorizontalPadding)
                            .padding(.bottom, VoceDesign.lg)

                        ForEach(groupedEntries, id: \.label) { group in
                            dayTable(group, layout: layout)
                        }
                    }
                    .padding(.bottom, VoceDesign.xl)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each day rendered as its own "table" — header + divider-separated rows
    private func dayTable(_ group: HomeDayGroup, layout: HomeLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Day header
            Text(group.label.uppercased())
                .font(VoceDesign.font(size: 11, weight: .semibold))
                .foregroundStyle(VoceDesign.textSecondary)
                .tracking(0.5)
                .padding(.horizontal, VoceDesign.xl)
                .padding(.top, VoceDesign.xl)
                .padding(.bottom, VoceDesign.md)
                .accessibilityAddTraits(.isHeader)

            // Rows with dividers
            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Divider()
                        .padding(.leading, layout.timestampColumnWidth + VoceDesign.lg + VoceDesign.xl)
                        .padding(.trailing, VoceDesign.xl)
                }
                entryRow(entry, layout: layout)
            }
        }
    }

    // MARK: - Entry Row

    private func entryRow(_ entry: TranscriptEntry, layout: HomeLayout) -> some View {
        let isExpanded = expandedIDs.contains(entry.id)
        let showsAISections = (entry.sourceText?.isEmpty == false) && entry.aiWorkflowName != nil

        return HStack(alignment: .top, spacing: VoceDesign.lg) {
            // Timestamp + app icon on hover
            VStack(spacing: VoceDesign.xs) {
                Text(absoluteTimestamp(for: entry.createdAt))
                    .font(VoceDesign.font(size: 13).monospacedDigit())
                    .foregroundStyle(VoceDesign.textSecondary)

                if hoveredID == entry.id {
                    Group {
                        if let icon = appIcon(for: entry.appBundleID) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .help(appName(for: entry.appBundleID))
                        } else {
                            Image(systemName: "app")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(VoceDesign.textSecondary.opacity(0.5))
                                .help(appName(for: entry.appBundleID))
                        }
                    }
                    .transition(AnyTransition.opacity)
                }
            }
            .frame(width: layout.timestampColumnWidth, alignment: .leading)
            .animation(.easeInOut(duration: VoceDesign.animationFast), value: hoveredID == entry.id)

            // Transcript text
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                transcriptBody(entry, isExpanded: isExpanded)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let aiName = entry.aiWorkflowName, !aiName.isEmpty {
                    HStack(spacing: VoceDesign.xxs) {
                        Text(aiName)
                            .font(VoceDesign.font(size: 10, weight: .medium))
                            .foregroundStyle(VoceDesign.accent)
                            .padding(.horizontal, VoceDesign.xs + VoceDesign.xxs)
                            .padding(.vertical, VoceDesign.xxs)
                            .background(
                                Capsule().fill(VoceDesign.accent.opacity(0.08))
                            )

                        rerunAIButton(for: entry)
                    }
                }
            }

            // Expand chevron
            if entryLikelyNeedsExpansion(entry) {
                Button {
                    toggleExpanded(entry.id, isExpanded: isExpanded)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(VoceDesign.font(size: 10))
                        .foregroundStyle(VoceDesign.textSecondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, VoceDesign.xl)
        .padding(.vertical, VoceDesign.md)
        .background {
            if hoveredID == entry.id {
                Rectangle().fill(VoceDesign.textPrimary.opacity(0.03))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in hoveredID = hovering ? entry.id : nil }
        .onTapGesture { controller.copyEntry(entry) }
        .contextMenu {
            if showsAISections {
                Button { controller.copyEntryTranscript(entry) } label: {
                    Label("Copy Transcript", systemImage: "waveform.and.mic")
                }
                Button { controller.copyEntryAIOutput(entry) } label: {
                    Label("Copy AI Output", systemImage: "sparkles")
                }
            } else {
                Button { controller.copyEntry(entry) } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            Divider()
            aiContextMenuItems(for: entry)
            Divider()
            Button(role: .destructive) { controller.deleteEntry(entry) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func rerunAIButton(for entry: TranscriptEntry) -> some View {
        if controller.historyAIProcessingEntryID == entry.id {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Running AI")
        } else if let workflow = matchingWorkflow(for: entry) {
            Button {
                controller.runAIWorkflow(workflow, on: entry)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(VoceDesign.font(size: 10, weight: .semibold))
                    .foregroundStyle(VoceDesign.accent)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Re-run \(workflow.name)")
            .accessibilityLabel("Re-run \(workflow.name)")
        }
    }

    @ViewBuilder
    private func aiContextMenuItems(for entry: TranscriptEntry) -> some View {
        if let workflow = matchingWorkflow(for: entry) {
            Button {
                controller.runAIWorkflow(workflow, on: entry)
            } label: {
                Label("Re-run \(workflow.name)", systemImage: "arrow.clockwise")
            }
        }

        if controller.enabledAIWorkflows.isEmpty {
            Text("No AI workflows enabled")
        } else {
            Menu("Run AI") {
                ForEach(controller.enabledAIWorkflows) { workflow in
                    Button {
                        controller.runAIWorkflow(workflow, on: entry)
                    } label: {
                        Text(workflow.name)
                    }
                }
            }
        }
    }

    private func matchingWorkflow(for entry: TranscriptEntry) -> AIWorkflow? {
        guard let aiWorkflowName = entry.aiWorkflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !aiWorkflowName.isEmpty else {
            return nil
        }

        return controller.enabledAIWorkflows.first { $0.name == aiWorkflowName }
    }

    // MARK: - Permission & Error Banners

    private enum PermissionCalloutKind {
        case microphone, speechRecognition, accessibility, inputMonitoring

        var icon: String {
            switch self {
            case .microphone: return "mic.fill"
            case .speechRecognition: return "waveform"
            case .accessibility: return "hand.raised.fill"
            case .inputMonitoring: return "keyboard.fill"
            }
        }

        var title: String {
            switch self {
            case .microphone: return "Microphone"
            case .speechRecognition: return "Speech"
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
    }

    private func animateErrorBannerUpdate() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
            dismissedPermissionCallouts = dismissedPermissionCallouts.intersection(Set(missingPermissionCallouts))
            showErrorBanner = !activeErrorMessage.isEmpty
        }
    }

    private var missingPermissionCallouts: [PermissionCalloutKind] {
        var kinds: [PermissionCalloutKind] = []
        if controller.microphonePermissionStatus != .granted {
            kinds.append(.microphone)
        }
        if controller.speechRecognitionPermissionStatus != .granted {
            kinds.append(.speechRecognition)
        }
        if controller.accessibilityPermissionStatus != .granted {
            kinds.append(.accessibility)
        }
        if controller.inputMonitoringPermissionStatus != .granted {
            kinds.append(.inputMonitoring)
        }
        return kinds
    }

    private var visiblePermissionCallouts: [PermissionCalloutKind] {
        missingPermissionCallouts.filter { !dismissedPermissionCallouts.contains($0) }
    }

    private var activeErrorMessage: String {
        let parts = [controller.hotkeyRegistrationMessage, controller.lastError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !isResolvedPermissionMessage($0) }
        return parts.joined(separator: " ")
    }

    private func isResolvedPermissionMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()

        if controller.microphonePermissionStatus == .granted,
           (normalized.contains("microphone permission") || normalized == "microphone permission denied") {
            return true
        }

        if controller.speechRecognitionPermissionStatus == .granted,
           normalized.contains("speech") {
            return true
        }

        if controller.accessibilityPermissionStatus == .granted,
           normalized.contains("accessibility") && normalized.contains("permission") {
            return true
        }

        if controller.inputMonitoringPermissionStatus == .granted,
           normalized.contains("input monitoring") {
            return true
        }

        return false
    }

    private func permissionBannerView(_ kind: PermissionCalloutKind) -> some View {
        let message: String = {
            switch kind {
            case .accessibility:
                return "Turn on to type into apps."
            case .microphone:
                return "Allow Microphone to start dictation."
            case .speechRecognition:
                return "Allow Speech to transcribe."
            case .inputMonitoring:
                return "Turn on Input Monitoring for shortcuts."
            }
        }()

        let buttonTitle: String = {
            if kind == .microphone && controller.microphonePermissionStatus == .unknown {
                return "Allow Microphone"
            }
            if kind == .speechRecognition && controller.speechRecognitionPermissionStatus == .unknown {
                return "Allow Speech"
            }
            return "Open Settings"
        }()

        return HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: kind.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VoceDesign.accent)
                .frame(width: 24, height: 24)
                .background(VoceDesign.accent.opacity(0.10))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text(kind.title)
                    .font(VoceDesign.font(size: 12, weight: .semibold))
                    .foregroundStyle(VoceDesign.textPrimary)

                Text(message)
                    .font(VoceDesign.font(size: 11))
                    .foregroundStyle(VoceDesign.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(buttonTitle) {
                    handlePermissionAction(kind)
                }
                .buttonStyle(.plain)
                .font(VoceDesign.font(size: 11, weight: .semibold))
                .foregroundStyle(VoceDesign.warmAccentText)
                .padding(.horizontal, VoceDesign.sm)
                .padding(.vertical, VoceDesign.xs)
                .background(
                    RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                        .fill(VoceDesign.warmAccentFill)
                )
                .padding(.top, VoceDesign.xxs)
            }

            Spacer(minLength: 0)

            dismissPermissionButton(kind)
        }
        .padding(.horizontal, VoceDesign.sm)
        .padding(.vertical, VoceDesign.sm)
        .background(VoceDesign.accent.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .stroke(VoceDesign.accent.opacity(0.12), lineWidth: VoceDesign.borderThin)
        )
    }

    private var genericErrorBannerView: some View {
        HStack(alignment: .top, spacing: VoceDesign.md) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(VoceDesign.error)

            Text(activeErrorMessage)
                .font(VoceDesign.font(size: 12))
                .foregroundStyle(VoceDesign.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            dismissErrorButton
        }
        .padding(VoceDesign.md)
        .background(VoceDesign.errorBackground)
        .clipShape(RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoceDesign.radiusSmall, style: .continuous)
                .stroke(VoceDesign.errorBorder, lineWidth: VoceDesign.borderThin)
        )
    }

    private var dismissErrorButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
                controller.clearErrors()
                showErrorBanner = false
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private func dismissPermissionButton(_ kind: PermissionCalloutKind) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: VoceDesign.animationNormal)) {
                _ = dismissedPermissionCallouts.insert(kind)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(VoceDesign.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss \(kind.title) alert")
    }

    private func handlePermissionAction(_ kind: PermissionCalloutKind) {
        switch kind {
        case .microphone:
            if controller.microphonePermissionStatus == .unknown {
                controller.requestMicrophonePermission()
            } else {
                controller.openMicrophoneSettings()
            }
        case .speechRecognition:
            if controller.speechRecognitionPermissionStatus == .unknown {
                controller.requestSpeechRecognitionPermission()
            } else {
                controller.openSpeechRecognitionSettings()
            }
        case .accessibility:
            controller.openAccessibilitySettings()
        case .inputMonitoring:
            controller.openInputMonitoringSettings()
        }
    }

    // MARK: - Helpers

    private var groupedEntries: [HomeDayGroup] {
        let calendar = Calendar.current
        var groups: [String: [TranscriptEntry]] = [:]
        var order: [String] = []

        for entry in controller.recentEntries {
            let label = dayLabel(for: entry.createdAt, calendar: calendar)
            if groups[label] == nil {
                order.append(label)
                groups[label] = []
            }
            groups[label]?.append(entry)
        }

        return order.map { HomeDayGroup(label: $0, entries: groups[$0] ?? []) }
    }

    private func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func absoluteTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func transcriptBody(_ entry: TranscriptEntry, isExpanded: Bool) -> some View {
        let finalText = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText

        if let sourceText = entry.sourceText, !sourceText.isEmpty, entry.aiWorkflowName != nil {
            VStack(alignment: .leading, spacing: VoceDesign.xs) {
                Text(sourceText)
                    .font(VoceDesign.font(size: 13))
                    .foregroundStyle(VoceDesign.textSecondary)
                    .lineLimit(isExpanded ? nil : 2)
                Text(finalText)
                    .font(VoceDesign.font(size: 13))
                    .foregroundStyle(VoceDesign.textPrimary)
                    .lineLimit(isExpanded ? nil : 3)
            }
        } else {
            Text(finalText)
                .font(VoceDesign.font(size: 13))
                .foregroundStyle(VoceDesign.textPrimary)
                .lineLimit(isExpanded ? nil : 4)
        }
    }

    private func toggleExpanded(_ entryID: UUID, isExpanded: Bool) {
        withAnimation(.easeInOut(duration: VoceDesign.animationFast)) {
            if isExpanded { expandedIDs.remove(entryID) }
            else { expandedIDs.insert(entryID) }
        }
    }

    private func entryLikelyNeedsExpansion(_ entry: TranscriptEntry) -> Bool {
        let finalText = entry.cleanText.isEmpty ? entry.rawText : entry.cleanText
        if let sourceText = entry.sourceText, !sourceText.isEmpty, entry.aiWorkflowName != nil {
            return sourceText.count > 120 || finalText.count > 120
        }
        return finalText.count > 140
    }

    private func appName(for bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "Unknown" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    private func formatElapsedTime(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct HomeDayGroup {
    let label: String
    let entries: [TranscriptEntry]
}

private struct HomeActivityCell: Identifiable {
    var id: String {
        HomeActivityCell.idFormatter.string(from: date)
    }

    let date: Date
    let wordCount: Int
    let sessionCount: Int
    let level: Int
    let isFuture: Bool

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct HomeLayout {
    let mainHorizontalPadding: CGFloat
    let metricsColumnWidth: CGFloat
    let timestampColumnWidth: CGFloat
    let greetingFontSize: CGFloat
    let bannerHeight: CGFloat

    static func make(for totalWidth: CGFloat) -> HomeLayout {
        let compact = totalWidth < 980
        return HomeLayout(
            mainHorizontalPadding: compact ? VoceDesign.lg : VoceDesign.xl,
            metricsColumnWidth: 200,
            timestampColumnWidth: compact ? 60 : 70,
            greetingFontSize: compact ? 20 : 22,
            bannerHeight: compact ? 220 : 300
        )
    }
}
