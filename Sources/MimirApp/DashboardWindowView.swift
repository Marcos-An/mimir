import AppKit
import SwiftUI
import MimirCore

struct DashboardWindowView: View {
    @Bindable var store: SettingsStore
    @Bindable var model: MimirAppModel

    @State private var searchQuery: String = ""
    @State private var showSettings: Bool = false

    var body: some View {
        JournalView(
            history: model.history,
            shortcutCaps: store.settings.activationTrigger.keyCaps,
            searchQuery: $searchQuery
        )
        .background(MimirIdentity.canvas)
        .preferredColorScheme(.light)
        .tint(MimirIdentity.brandBlue)
        .toolbar { windowToolbar }
        .toolbarBackground(MimirIdentity.canvas, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(store: store, isPresented: $showSettings)
                .preferredColorScheme(.light)
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            leadingItem.sharedBackgroundVisibility(.hidden)
            trailingItem.sharedBackgroundVisibility(.hidden)
        } else {
            leadingItem
            trailingItem
        }
    }

    private var leadingItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 16) {
                MimirMark(height: 17)
                    .padding(.leading, 4)
                TranscriptionSearch(searchQuery: $searchQuery)
            }
        }
    }

    private var trailingItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 14) {
                ShortcutHint(caps: store.settings.activationTrigger.keyCaps)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .foregroundStyle(MimirIdentity.secondaryInk)
                .accessibilityLabel("Settings")
                .help("Settings")
            }
        }
    }
}

// MARK: - Settings sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, audio, pipeline, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .audio: return "Audio"
        case .pipeline: return "Pipeline"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .audio: return "mic"
        case .pipeline: return "waveform.path"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Toolbar pieces

/// The "m" of the Mimir wordmark, cropped from the wordmark PDF so the mark and
/// the full logo always come from the same drawing.
private struct MimirMark: View {
    var height: CGFloat = 17

    var body: some View {
        let scale = height / 395
        if let url = MimirResources.bundle.url(forResource: "MimirWordmark", withExtension: "pdf"),
           let wordmark = NSImage(contentsOf: url) {
            Image(nsImage: wordmark)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: 2172 * scale, height: 724 * scale)
                .offset(x: -115 * scale, y: -210 * scale)
                .frame(width: 640 * scale, height: 395 * scale, alignment: .topLeading)
                .clipped()
                .foregroundStyle(MimirIdentity.wordmark)
                .accessibilityLabel("Mimir")
        }
    }
}

private struct TranscriptionSearch: View {
    @Binding var searchQuery: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(MimirIdentity.secondaryInk)
            TextField("Search transcriptions", text: $searchQuery,
                      prompt: Text("Search transcriptions").foregroundStyle(MimirIdentity.secondaryInk))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search transcriptions")
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(MimirIdentity.secondaryInk)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(MimirIdentity.ink)
        .padding(.horizontal, 11)
        .frame(width: 300, height: 32)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(searchFocused ? MimirIdentity.brandBlue : Color.black.opacity(0.07), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

private struct ShortcutHint: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 7) {
            Text(caps.joined(separator: " + "))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MimirIdentity.ink)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
            Text("to dictate")
                .font(.system(size: 13))
                .foregroundStyle(MimirIdentity.secondaryInk)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Journal

private struct JournalView: View {
    @Bindable var history: TranscriptHistoryStore
    let shortcutCaps: [String]
    @Binding var searchQuery: String

    @State private var pendingDeleteID: UUID?
    @State private var showClearAlert = false

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top),
    ]

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [TranscriptEntry] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if history.entries.isEmpty {
                    WelcomeHero(shortcutCaps: shortcutCaps)
                } else if !trimmedQuery.isEmpty {
                    searchResults
                } else {
                    stream
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 44)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MimirIdentity.canvas)
        .alert("Delete this transcription?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDeleteID = nil }
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID { history.delete(id) }
                pendingDeleteID = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Delete everything?", isPresented: $showClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { history.clear() }
        } message: {
            Text("You'll lose \(history.entries.count) transcriptions. This action cannot be undone.")
        }
    }

    @ViewBuilder
    private var stream: some View {
        let entries = history.entries
        if let latest = entries.first {
            card(latest, featured: true, dateStyle: .time)
        }
        ForEach(Self.dayGroups(Array(entries.dropFirst())), id: \.day) { group in
            VStack(alignment: .leading, spacing: 14) {
                GroupHeading(title: group.title, count: group.entries.count)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(group.entries) { entry in
                        card(entry, featured: false, dateStyle: .time)
                    }
                }
            }
        }
        Button("Clear history…") { showClearAlert = true }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .font(.system(size: 12))
            .foregroundStyle(MimirIdentity.secondaryInk)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 6)
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = filtered
        VStack(alignment: .leading, spacing: 14) {
            GroupHeading(title: "Results", count: results.count)
            if results.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing matches “\(trimmedQuery)”.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(MimirIdentity.ink)
                    Text("Try fewer or different words.")
                        .font(.system(size: 13))
                        .foregroundStyle(MimirIdentity.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(results) { entry in
                        card(entry, featured: false, dateStyle: .relative)
                    }
                }
            }
        }
    }

    private func card(_ entry: TranscriptEntry, featured: Bool, dateStyle: TranscriptCard.DateStyle) -> some View {
        TranscriptCard(
            entry: entry,
            allEntries: history.entries,
            isFeatured: featured,
            dateStyle: dateStyle,
            onDelete: { pendingDeleteID = entry.id }
        )
    }

    struct DayGroup {
        let day: Date
        let title: String
        let entries: [TranscriptEntry]
    }

    static func dayGroups(_ entries: [TranscriptEntry]) -> [DayGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [TranscriptEntry]] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { DayGroup(day: $0, title: dayTitle($0, calendar: calendar), entries: buckets[$0] ?? []) }
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Earlier today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let today = calendar.startOfDay(for: Date())
        if let days = calendar.dateComponents([.day], from: day, to: today).day, days < 7 {
            formatter.dateFormat = "EEEE"
        } else {
            formatter.dateFormat = "MMMM d"
        }
        return formatter.string(from: day)
    }
}

private struct GroupHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 19, weight: .medium, design: .serif))
                .foregroundStyle(MimirIdentity.ink)
            Text("\(count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MimirIdentity.secondaryInk)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Welcome

private struct WelcomeHero: View {
    let shortcutCaps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MimirMark(height: 30)

            VStack(alignment: .leading, spacing: 10) {
                Text("Speak, we're listening.")
                    .font(.system(size: 32, weight: .medium, design: .serif))
                    .foregroundStyle(MimirIdentity.ink)
                Text("Use your shortcut in any app to turn speech into text. Audio stays on your Mac. Optional cloud polishing sends only the transcribed text.")
                    .font(.system(size: 15))
                    .foregroundStyle(MimirIdentity.secondaryInk)
                    .lineSpacing(4)
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: "1", text: "Open any app where you type.")
                stepRow(number: "2", text: "Press \(shortcutCaps.joined(separator: " + ")) and speak normally.")
                stepRow(number: "3", text: "Finish dictation to insert the text in your app.")
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .padding(.top, 8)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MimirIdentity.brandBlue)
                .frame(width: 14, alignment: .leading)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(MimirIdentity.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Transcript card

private struct TranscriptCard: View {
    enum DateStyle { case time, relative }

    let entry: TranscriptEntry
    let allEntries: [TranscriptEntry]
    let isFeatured: Bool
    let dateStyle: DateStyle
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var expanded = false
    @State private var showingMetrics = false
    @State private var canExpand = false

    private var fontSize: CGFloat { isFeatured ? 18 : 15 }
    private var maxLines: Int { isFeatured ? 6 : 4 }
    private var radius: CGFloat { isFeatured ? 22 : 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: isFeatured ? 16 : 12) {
            header

            Text(entry.text)
                .font(.system(size: fontSize))
                .foregroundStyle(MimirIdentity.ink)
                .lineSpacing(isFeatured ? 5 : 3)
                .lineLimit(expanded ? nil : maxLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    canExpand = TranscriptTextLayout.isTruncated(entry.text, width: width, fontSize: fontSize, maxLines: maxLines)
                }

            if canExpand || expanded {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MimirIdentity.brandBlue)
                .accessibilityLabel(expanded ? "Collapse transcription" : "Expand transcription")
            }
        }
        .padding(isFeatured ? 26 : 18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if isFeatured {
                HStack(spacing: 6) {
                    Circle()
                        .fill(MimirIdentity.brandBlue)
                        .frame(width: 6, height: 6)
                    Text("Latest")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MimirIdentity.brandBlue)
                }
            }
            Text(metaLine)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MimirIdentity.secondaryInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            actionMenu
            copyButton
        }
        .popover(isPresented: $showingMetrics, arrowEdge: .bottom) {
            if let metrics = entry.sessionMetrics {
                MetricsPopoverContent(entry: entry, metrics: metrics, allEntries: allEntries)
                    .preferredColorScheme(.light)
            }
        }
    }

    private var metaLine: String {
        let when: String
        switch dateStyle {
        case .time:
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            when = formatter.string(from: entry.createdAt)
        case .relative:
            when = humanizedDate(entry.createdAt)
        }
        guard let duration = entry.durationSeconds else { return when }
        return "\(when) · \(Self.formatDuration(duration))"
    }

    private var actionMenu: some View {
        Menu {
            if entry.sessionMetrics != nil {
                Button("Show metrics") {
                    // Let the menu close before the popover opens.
                    DispatchQueue.main.async { showingMetrics = true }
                }
            }
            Button("Delete transcription", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MimirIdentity.secondaryInk)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .pointerStyle(.link)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovering || isFeatured ? 1 : 0.6)
        .accessibilityLabel("Transcription actions")
    }

    @ViewBuilder
    private var copyButton: some View {
        if isFeatured {
            Button(action: copy) {
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(MimirIdentity.brandBlue))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .accessibilityLabel(copied ? "Copied" : "Copy transcription")
        } else {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? MimirIdentity.brandBlue : MimirIdentity.secondaryInk)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .opacity(hovering || copied ? 1 : 0.6)
            .help(copied ? "Copied" : "Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy transcription")
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if isFeatured {
            shape
                .fill(Color.white)
                .overlay(
                    RadialGradient(
                        colors: [MimirIdentity.glow, MimirIdentity.glow.opacity(0)],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 420
                    )
                    .clipShape(shape)
                )
                .overlay(shape.stroke(Color.black.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(0.05), radius: 18, y: 8)
        } else {
            shape
                .fill(hovering ? Color.white : MimirIdentity.card)
                .overlay(shape.stroke(Color.black.opacity(0.06), lineWidth: 1))
                .shadow(color: .black.opacity(hovering ? 0.05 : 0.025), radius: hovering ? 10 : 4, y: 2)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copied = false }
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds / 60)
        let remaining = Int(seconds) % 60
        return "\(minutes)m \(remaining)s"
    }
}

// MARK: - Metrics popover

private struct MetricsPopoverContent: View {
    let entry: TranscriptEntry
    let metrics: SessionMetrics
    let allEntries: [TranscriptEntry]

    @State private var showingTechnicalDetails = false

    // MARK: - Derived

    private var recordingDuration: Double? { entry.durationSeconds }

    /// stop→paste / duração gravada. Menor é melhor.
    private var currentRatio: Double? {
        guard let audio = recordingDuration, audio > 0 else { return nil }
        return metrics.stopToPasteSeconds / audio
    }

    /// Ratios históricos ordenados (última dúzia, excluindo a entry atual).
    private var historicalRatios: [Double] {
        allEntries
            .filter { $0.id != entry.id }
            .prefix(20)
            .compactMap { e in
                guard let audio = e.durationSeconds, audio > 0,
                      let m = e.sessionMetrics else { return nil }
                return m.stopToPasteSeconds / audio
            }
    }

    private var medianHistorical: Double? {
        let sorted = historicalRatios.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    private enum Verdict { case fast, normal, slow }

    private var verdict: Verdict {
        guard let r = currentRatio else { return .normal }
        if let median = medianHistorical {
            if r < median * 0.85 { return .fast }
            if r > median * 1.20 { return .slow }
            return .normal
        }
        // Sem histórico — absolute thresholds empíricos.
        if r < 0.25 { return .fast }
        if r > 0.40 { return .slow }
        return .normal
    }

    private var comparisonText: String {
        guard let r = currentRatio else { return "no reference duration" }
        guard let median = medianHistorical, !historicalRatios.isEmpty else {
            return "first one, nothing to compare yet"
        }
        let delta = (r - median) / median * 100
        let n = historicalRatios.count
        if abs(delta) < 5 {
            return "in line with the last \(n)"
        }
        let word = delta < 0 ? "faster" : "slower"
        return "\(Int(abs(delta)))% \(word) than the median of the last \(n)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
                .padding(.bottom, 14)

            verdictBlock
                .padding(.bottom, 18)

            breakdownSection
                .padding(.bottom, 14)

            Rectangle().fill(Color.black.opacity(0.07)).frame(height: 1)

            disclosureButton
                .padding(.top, 12)

            if showingTechnicalDetails {
                technicalDetails
                    .padding(.top, 14)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Color.white)
    }

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Telemetry")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MimirIdentity.ink)
            Spacer()
            if let audio = recordingDuration {
                Text("\(DurationFormat.short(audio)) audio")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MimirIdentity.secondaryInk)
            }
        }
    }

    // MARK: Verdict

    private var verdictBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(DurationFormat.short(metrics.stopToPasteSeconds))
                    .font(.system(size: 34, weight: .medium, design: .serif))
                    .foregroundStyle(MimirIdentity.ink)
                Text(verdictLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(verdictColor)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(verdictColor.opacity(0.1)))
            }
            Text("From stop to paste. \(comparisonText.prefix(1).uppercased() + comparisonText.dropFirst()).")
                .font(.system(size: 12))
                .foregroundStyle(MimirIdentity.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var verdictLabel: String {
        switch verdict {
        case .fast: return "Fast"
        case .normal: return "Typical"
        case .slow: return "Slow"
        }
    }

    private var verdictColor: Color {
        switch verdict {
        case .fast: return MimirTheme.green
        case .normal: return MimirIdentity.secondaryInk
        case .slow: return MimirTheme.orange
        }
    }

    // MARK: Breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where the time went")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MimirIdentity.secondaryInk)
            breakdownBar
            legend
        }
    }

    private var breakdownSegments: [(label: String, seconds: Double, color: Color)] {
        var items: [(String, Double, Color)] = []
        items.append(("Whisper", metrics.transcriptionSeconds, MimirIdentity.brandBlue))
        // "Polish" e não o nome do provider: a métrica é da sessão passada e o
        // provider das settings pode ter mudado desde então.
        if let p = metrics.postProcessingSeconds { items.append(("Polish", p, MimirIdentity.brandBlue.opacity(0.4))) }
        if let i = metrics.insertionSeconds { items.append(("Paste", i, Color(red: 199 / 255, green: 199 / 255, blue: 204 / 255))) }
        return items.filter { $0.1 > 0 }
    }

    private var breakdownBar: some View {
        GeometryReader { geo in
            let total = breakdownSegments.reduce(0) { $0 + $1.seconds }
            HStack(spacing: 2) {
                ForEach(Array(breakdownSegments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(segment.color)
                        .frame(width: max(4, CGFloat(segment.seconds / total) * (geo.size.width - CGFloat((breakdownSegments.count - 1) * 2))))
                }
            }
        }
        .frame(height: 8)
    }

    private var legend: some View {
        VStack(spacing: 6) {
            ForEach(Array(breakdownSegments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(segment.color)
                        .frame(width: 8, height: 8)
                    Text(segment.label)
                        .font(.system(size: 12))
                        .foregroundStyle(MimirIdentity.ink)
                    Spacer()
                    Text(DurationFormat.short(segment.seconds))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(MimirIdentity.ink)
                    Text(String(format: "%.0f%%", segment.seconds / metrics.stopToPasteSeconds * 100))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(MimirIdentity.secondaryInk)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Disclosure

    private var disclosureButton: some View {
        Button {
            // Keep this state change non-animated. SwiftUI's popover host resizes the
            // underlying NSPopover when the details section appears; animating that
            // resize can crash in AppKit's NSResizeMoveHelper on macOS 26.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                showingTechnicalDetails.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showingTechnicalDetails ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(showingTechnicalDetails ? "Hide technical details" : "Technical details")
                    .font(.system(size: 12))
                Spacer()
            }
            .foregroundStyle(MimirIdentity.secondaryInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            whisperSection
            streamingSection
        }
    }

    private var whisperSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Whisper")
            if let rtf = metrics.whisperRTF {
                row("Real-time factor", String(format: "%.2f×", rtf))
            }
            if let ft = metrics.firstTokenLatency {
                row("First token", DurationFormat.short(ft))
            }
            if let load = metrics.whisperModelLoadSeconds, load > 0 {
                row("Model load", DurationFormat.short(load))
            }
        }
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Segments")
            row("Status",
                value: metrics.streamingUsed ? "Segmented" : "Whole file",
                valueColor: metrics.streamingUsed ? MimirTheme.green : MimirTheme.orange)
            if let reason = metrics.fallbackReason {
                row("Reason", value: reason, valueColor: MimirTheme.orange)
            }
            if metrics.streamingCommitCount > 0 || metrics.incrementalAttemptCount > 0 {
                row("Segments", "\(metrics.streamingCommitCount) of \(metrics.incrementalAttemptCount) attempts")
                if let avg = metrics.streamingAvgCommitSeconds {
                    row("Avg per segment", DurationFormat.short(avg))
                }
            }
            if let cov = metrics.streamingCoverageRatio {
                row("Coverage",
                    value: String(format: "%.0f%%", cov * 100),
                    valueColor: coverageColor(cov))
            }
            if let tail = metrics.tailAudioSeconds {
                row("Tail after stop", value: DurationFormat.short(tail), valueColor: tailColor(tail))
            } else {
                row("Tail after stop", value: "—", valueColor: MimirIdentity.secondaryInk)
            }
            row("Empty segments", value: "\(metrics.incrementalEmptyResultCount)", valueColor: MimirIdentity.secondaryInk)
            row(
                "Errors",
                value: "\(metrics.incrementalErrorCount)",
                valueColor: metrics.incrementalErrorCount > 0 ? MimirTheme.red : MimirIdentity.secondaryInk)
            if let lastError = metrics.lastIncrementalError, !lastError.isEmpty {
                row("Last error", value: shortError(lastError), valueColor: MimirTheme.red)
            } else {
                row("Last error", value: "none", valueColor: MimirIdentity.secondaryInk)
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MimirIdentity.ink)
            .padding(.bottom, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        row(label, value: value, valueColor: MimirIdentity.ink)
    }

    private func row(_ label: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(MimirIdentity.secondaryInk)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func coverageColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.4: return MimirTheme.red
        case ..<0.75: return MimirTheme.orange
        default: return MimirTheme.green
        }
    }

    private func tailColor(_ seconds: Double) -> Color {
        switch seconds {
        case ..<8: return MimirTheme.green
        case ..<15: return MimirTheme.orange
        default: return MimirTheme.red
        }
    }

    private func shortError(_ message: String) -> String {
        guard message.count > 90 else { return message }
        return String(message.prefix(87)) + "…"
    }
}

// MARK: - Settings sheet

private struct SettingsSheetView: View {
    @Bindable var store: SettingsStore
    @Binding var isPresented: Bool
    @State private var selected: SettingsSection = .general
    @State private var confirmRestore = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(MimirTheme.hairline).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(MimirTheme.hairline).frame(height: 1)
                ScrollView {
                    SettingsSectionsRouter(store: store, selectedID: selected.rawValue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(width: 820, height: 600)
        .background(Color.white)
        .alert("Restore default settings?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { store.reset() }
        } message: {
            Text("Shortcuts, models, and preferences go back to their defaults. Your history is kept.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer(minLength: 0)
            Button("Restore defaults") { confirmRestore = true }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .font(.system(size: 12))
                .foregroundStyle(MimirTheme.tertiaryInk)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 250 / 255, green: 250 / 255, blue: 251 / 255))
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selected == section
        return Button {
            selected = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? MimirTheme.ink : MimirTheme.secondaryInk)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? Color.white : Color.clear)
                            .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 2, y: 1)
                    )
                Text(section.title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? MimirTheme.ink : MimirTheme.secondaryInk)
                Spacer(minLength: 0)
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? MimirTheme.softFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var header: some View {
        HStack {
            Text(selected.title)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(MimirTheme.ink)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(MimirTheme.softFill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 28)
        .frame(height: 68)
    }
}

struct SettingsSectionsRouter: View {
    @Bindable var store: SettingsStore
    let selectedID: String

    var body: some View {
        let sections = SettingsSections(store: store)
        switch selectedID {
        case "audio":
            sections.audioSection
        case "pipeline":
            sections.pipelineSection
        case "permissions":
            sections.permissionsSection
        case "about":
            sections.aboutSection
        default:
            sections.generalSection
        }
    }
}

// MARK: - Helpers

func humanizedDate(_ date: Date) -> String {
    let now = Date()
    let diff = now.timeIntervalSince(date)
    let calendar = Calendar.current

    if diff < 60 { return "now" }
    if diff < 3600 { return "\(Int(diff / 60)) min ago" }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")

    if calendar.isDateInToday(date) {
        formatter.dateFormat = "'today,' HH:mm"
        return formatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
        formatter.dateFormat = "'yesterday,' HH:mm"
        return formatter.string(from: date)
    }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date).lowercased()
    }
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}
