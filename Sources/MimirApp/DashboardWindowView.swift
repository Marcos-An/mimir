import AppKit
import SwiftUI
import MimirCore

struct DashboardWindowView: View {
    @Bindable var store: SettingsStore
    @Bindable var model: MimirAppModel

    @State private var searchQuery: String = ""
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            JournalTopBar(
                searchQuery: $searchQuery,
                onSettings: { showSettings = true }
            )

            JournalView(
                history: model.history,
                shortcutLabel: store.settings.activationTrigger.label,
                searchQuery: searchQuery
            )
        }
        .background(MimirTheme.surface)
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(store: store, isPresented: $showSettings)
        }
    }
}

// MARK: - Settings sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, audio, pipeline, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Geral"
        case .audio: return "Áudio"
        case .pipeline: return "Pipeline"
        case .permissions: return "Permissões"
        case .about: return "Sobre"
        }
    }
}

// MARK: - Top bar

private struct JournalTopBar: View {
    @Binding var searchQuery: String
    let onSettings: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var searchExpanded: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            BrandMark()
                .frame(width: 22, height: 22)
            Text("Mimir")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(MimirTheme.ink)
                .tracking(0.2)

            Spacer()

            searchField

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ajustes")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            MimirTheme.surface
                .overlay(
                    Rectangle()
                        .fill(MimirTheme.hairline)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(searchFocused ? MimirTheme.ink : MimirTheme.secondaryInk)

            if searchExpanded || !searchQuery.isEmpty || searchFocused {
                ZStack(alignment: .leading) {
                    if searchQuery.isEmpty {
                        Text("Buscar no diário…")
                            .font(.system(size: 12))
                            .foregroundStyle(MimirTheme.tertiaryInk)
                    }
                    TextField("", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(MimirTheme.ink)
                        .focused($searchFocused)
                }
                .frame(width: 200)

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchFocused = false
                        searchExpanded = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MimirTheme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(MimirTheme.surfaceSunken)
        )
        .overlay(
            Capsule().stroke(
                searchFocused ? MimirTheme.brandBlue.opacity(0.6) : MimirTheme.hairline,
                lineWidth: 1
            )
        )
        .shadow(
            color: searchFocused ? MimirTheme.brandBlue.opacity(0.18) : .clear,
            radius: 6
        )
        .contentShape(Capsule())
        .onTapGesture {
            searchExpanded = true
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if !focused && searchQuery.isEmpty {
                searchExpanded = false
            }
        }
    }
}

private struct BrandMark: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MimirTheme.brandGradient)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }
}

// MARK: - Journal

private struct JournalView: View {
    @Bindable var history: TranscriptHistoryStore
    let shortcutLabel: String
    let searchQuery: String

    @State private var pendingDeleteID: UUID?
    @State private var showClearAlert = false

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [TranscriptEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return history.entries }
        return history.entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !isSearching {
                    if history.entries.isEmpty {
                        WelcomeHero(shortcutLabel: shortcutLabel)
                    } else {
                        StatsHero(history: history, shortcutLabel: shortcutLabel)
                    }
                }

                streamSection
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, 48)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .alert("Apagar esta transcrição?", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("Cancelar", role: .cancel) { pendingDeleteID = nil }
            Button("Apagar", role: .destructive) {
                if let id = pendingDeleteID { history.delete(id) }
                pendingDeleteID = nil
            }
        } message: {
            Text("Essa ação não pode ser desfeita.")
        }
        .alert("Apagar tudo?", isPresented: $showClearAlert) {
            Button("Cancelar", role: .cancel) {}
            Button("Apagar", role: .destructive) { history.clear() }
        } message: {
            Text("Você vai perder \(history.entries.count) transcrições. Essa ação não pode ser desfeita.")
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        if history.entries.isEmpty { EmptyView() }
        else if isSearching && filtered.isEmpty {
            searchEmptyState
        } else {
            VStack(alignment: .leading, spacing: 4) {
                streamHeader
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        QuoteCard(
                            entry: entry,
                            allEntries: history.entries,
                            onDelete: { pendingDeleteID = entry.id }
                        )
                    }
                }
            }
        }
    }

    private var streamHeader: some View {
        HStack {
            Text(isSearching ? "Resultados" : "Diário")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MimirTheme.secondaryInk)
                .kerning(1.4)
            Spacer()
            if !isSearching && !history.entries.isEmpty {
                Button {
                    showClearAlert = true
                } label: {
                    Text("Limpar tudo")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MimirTheme.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 6)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(MimirTheme.ink.opacity(0.2))
            Text("Nada por aqui.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MimirTheme.ink)
            Text("Tente outros termos.")
                .font(.system(size: 12))
                .foregroundStyle(MimirTheme.secondaryInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Hero

private struct StatsHero: View {
    @Bindable var history: TranscriptHistoryStore
    let shortcutLabel: String

    private let ink = Color.white
    private let dimInk = Color.white.opacity(0.72)
    private let mutedInk = Color.white.opacity(0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center) {
                Text(dateLabel.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(mutedInk)
                    .kerning(1.6)
                Spacer()
                darkShortcutChip
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(greeting)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(ink)
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(dimInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 0) {
                statPill(number: "\(weekCount)", label: "ditados 7 dias")
                divider
                statPill(number: "\(history.entries.count)", label: "total")
                divider
                statPill(number: "\(history.totalWords)", label: "palavras")
                divider
                statPill(number: formatDuration(history.totalSeconds), label: "falando")
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(28)
        .background(heroBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 20, y: 10)
    }

    private var heroBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(MimirTheme.surfaceRaised)
            .overlay(
                // Glow superior com as cores da marca, discreto.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [MimirTheme.accentCyan.opacity(0.22), Color.clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 320
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [MimirTheme.accentPurple.opacity(0.18), Color.clear],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: 280
                        )
                    )
            )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .frame(width: 1, height: 32)
            .padding(.horizontal, 22)
    }

    private var darkShortcutChip: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("ATALHO")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(mutedInk)
                .kerning(1.2)
            Text(shortcutLabel)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        }
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "EEEE, d 'de' MMMM"
        return f.string(from: Date())
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<6: return "Boa madrugada."
        case 6..<12: return "Bom dia."
        case 12..<18: return "Boa tarde."
        default: return "Boa noite."
        }
    }

    private var summary: String {
        if weekCount == 0 {
            return "Nada ditado nos últimos 7 dias. Aperta o atalho em qualquer app e fala uma frase — vai ficar instantâneo."
        } else if weekCount == 1 {
            return "Você ditou uma vez esta semana. Segue o ritmo."
        } else {
            return "Você ditou \(weekCount) vezes nos últimos 7 dias. Bom ritmo."
        }
    }

    private var weekCount: Int {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return history.entries.filter { $0.createdAt >= cutoff }.count
    }

    private func statPill(number: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [MimirTheme.accentCyan, MimirTheme.accentPurple],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(mutedInk)
                .kerning(0.8)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return String(format: "%.1fh", seconds / 3600)
    }
}

private extension Color {
    init(hex: UInt64, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private struct WelcomeHero: View {
    let shortcutLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                brandArt
                Spacer()
                ShortcutChip(label: shortcutLabel)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Fala que a gente ouve.")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(MimirTheme.ink)
                Text("Aperte o atalho em qualquer app, dite em voz alta e o Mimir transcreve, polui e cola pra você. Tudo rodando local — seu áudio não sobe pra lugar nenhum.")
                    .font(.system(size: 15))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: "1", text: "Abra qualquer app onde você escreve.")
                stepRow(number: "2", text: "Aperte \(shortcutLabel) e fale normalmente.")
                stepRow(number: "3", text: "Solte. O texto polido aparece no lugar.")
            }
            .padding(.top, 4)
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MimirTheme.accentCyan.opacity(0.26),
                            MimirTheme.accentPurple.opacity(0.16),
                            Color.white.opacity(0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(MimirTheme.hairline, lineWidth: 1)
        )
    }

    private var brandArt: some View {
        Group {
            if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
               let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(MimirTheme.brandGradient)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: 72, height: 72)
        .shadow(color: MimirTheme.accentPurple.opacity(0.3), radius: 16, y: 8)
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(MimirTheme.brandGradient))
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(MimirTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShortcutChip: View {
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("ATALHO")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MimirTheme.secondaryInk)
                .kerning(1.2)
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(MimirTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MimirTheme.brandGradient, lineWidth: 1)
                )
        }
    }
}

// MARK: - Quote card (entry in stream)

private struct QuoteCard: View {
    let entry: TranscriptEntry
    let allEntries: [TranscriptEntry]
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var copied = false
    @State private var expanded = false
    @State private var showingMetrics = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.text)
                .font(.system(size: 17, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(MimirTheme.ink.opacity(0.92))
                .lineSpacing(4)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Rectangle()
                    .fill(MimirTheme.brandGradient)
                    .frame(width: 14, height: 1.5)
                Text(humanizedDate(entry.createdAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MimirTheme.secondaryInk)
                if let duration = entry.durationSeconds {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(MimirTheme.secondaryInk.opacity(0.6))
                    Text(formatDuration(duration))
                        .font(.system(size: 11))
                        .foregroundStyle(MimirTheme.secondaryInk)
                }
                if let metricsText = metricsLine, let metrics = entry.sessionMetrics {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(MimirTheme.secondaryInk.opacity(0.6))
                    Button {
                        showingMetrics.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(metricsText)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(MimirTheme.secondaryInk)
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MimirTheme.secondaryInk.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingMetrics, arrowEdge: .bottom) {
                        MetricsPopoverContent(
                            entry: entry,
                            metrics: metrics,
                            allEntries: allEntries
                        )
                    }
                }
                Spacer()
                actionCluster
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
        .overlay(
            Rectangle()
                .fill(MimirTheme.hairline)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var metricsLine: String? {
        guard let m = entry.sessionMetrics else { return nil }
        var parts: [String] = []
        parts.append("📝" + fmtSeconds(m.transcriptionSeconds))
        if let post = m.postProcessingSeconds {
            parts.append("✨" + fmtSeconds(post))
        }
        parts.append(m.streamingUsed ? "🔗" : "⚠︎")
        return parts.joined(separator: " · ")
    }

    private func fmtSeconds(_ seconds: TimeInterval) -> String {
        DurationFormat.short(seconds)
    }

    private var actionCluster: some View {
        HStack(spacing: 2) {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(copied ? "Copiado" : "Copiar")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MimirTheme.red.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Apagar")
        }
        .opacity(hovering ? 1 : 0)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copied = false }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
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
        guard let r = currentRatio else { return "sem duração de referência" }
        guard let median = medianHistorical, !historicalRatios.isEmpty else {
            return "primeira transcrição · \(String(format: "%.0f", r * 100))% do áudio em bloqueio"
        }
        let delta = (r - median) / median * 100
        let n = historicalRatios.count
        if abs(delta) < 5 {
            return "típica · igual à mediana das últimas \(n)"
        }
        let word = delta < 0 ? "rápida" : "lenta"
        return "\(Int(abs(delta)))% mais \(word) que a mediana das últimas \(n)"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            verdictCard

            breakdownSection

            Divider().opacity(0.3)

            disclosureButton

            if showingTechnicalDetails {
                technicalDetails
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 13, weight: .semibold))
            Text("Telemetria")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let audio = recordingDuration {
                Text("\(DurationFormat.short(audio)) áudio")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Verdict card

    private var verdictCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                verdictBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(DurationFormat.short(metrics.stopToPasteSeconds))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("bloqueio stop→paste")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(comparisonText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(verdictColor.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(verdictColor.opacity(0.3), lineWidth: 1)
                )
        )
    }

    private var verdictBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: verdictIcon)
                .font(.system(size: 11, weight: .bold))
            Text(verdictLabel)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
        }
        .foregroundStyle(verdictColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(verdictColor.opacity(0.22))
        )
    }

    private var verdictLabel: String {
        switch verdict {
        case .fast: return "RÁPIDA"
        case .normal: return "NORMAL"
        case .slow: return "LENTA"
        }
    }

    private var verdictIcon: String {
        switch verdict {
        case .fast: return "hare.fill"
        case .normal: return "equal.circle.fill"
        case .slow: return "tortoise.fill"
        }
    }

    private var verdictColor: Color {
        switch verdict {
        case .fast: return .green
        case .normal: return .blue
        case .slow: return .orange
        }
    }

    // MARK: Breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ONDE O TEMPO FOI")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            breakdownBar
            legend
        }
    }

    private var breakdownSegments: [(label: String, seconds: Double, color: Color)] {
        var items: [(String, Double, Color)] = []
        items.append(("Whisper", metrics.transcriptionSeconds, Color(red: 0.38, green: 0.66, blue: 0.98)))
        if let p = metrics.postProcessingSeconds { items.append(("MLX", p, Color(red: 0.72, green: 0.58, blue: 1.0))) }
        if let i = metrics.insertionSeconds { items.append(("Paste", i, Color(red: 0.95, green: 0.80, blue: 0.40))) }
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
        .frame(height: 10)
    }

    private var legend: some View {
        VStack(spacing: 4) {
            ForEach(Array(breakdownSegments.enumerated()), id: \.offset) { _, segment in
                HStack(spacing: 8) {
                    Circle().fill(segment.color).frame(width: 8, height: 8)
                    Text(segment.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(DurationFormat.short(segment.seconds))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(String(format: "(%.0f%%)", segment.seconds / metrics.stopToPasteSeconds * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Disclosure

    private var disclosureButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                showingTechnicalDetails.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: showingTechnicalDetails ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text(showingTechnicalDetails ? "Ocultar detalhes técnicos" : "Detalhes técnicos")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var technicalDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            whisperSection
            streamingSection
        }
    }

    private var whisperSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("WHISPER")
            if let rtf = metrics.whisperRTF {
                row("Real-time factor", String(format: "%.2f×", rtf))
            }
            if let ft = metrics.firstTokenLatency {
                row("1º token", DurationFormat.short(ft))
            }
            if let load = metrics.whisperModelLoadSeconds, load > 0 {
                row("Model load", DurationFormat.short(load))
            }
        }
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("STREAMING & COMMITS")
            row("Status",
                value: metrics.streamingUsed ? "🔗 ativo" : "⚠︎ fallback",
                valueColor: metrics.streamingUsed ? .green : .yellow)
            if let reason = metrics.fallbackReason {
                row("Motivo", value: reason, valueColor: .yellow)
            }
            if metrics.streamingCommitCount > 0 {
                row("Commits", "\(metrics.streamingCommitCount) de \(metrics.incrementalAttemptCount) tentativas")
                if let avg = metrics.streamingAvgCommitSeconds {
                    row("Média por commit", DurationFormat.short(avg))
                }
            }
            if let cov = metrics.streamingCoverageRatio {
                row("Cobertura",
                    value: String(format: "%.0f%%", cov * 100),
                    valueColor: coverageColor(cov))
            }
            if metrics.incrementalErrorCount > 0 {
                row("Erros", value: "\(metrics.incrementalErrorCount)", valueColor: .red)
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }

    private func row(_ label: String, value: String, valueColor: Color) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func coverageColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.4: return .red
        case ..<0.75: return .orange
        default: return .green
        }
    }
}

// MARK: - Settings sheet

private struct SettingsSheetView: View {
    @Bindable var store: SettingsStore
    @Binding var isPresented: Bool
    @State private var selected: SettingsSection = .general

    var body: some View {
        VStack(spacing: 0) {
            header

            tabs
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSectionsRouter(store: store, selectedID: selected.rawValue)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: 580)
        .background(MimirTheme.surface)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ajustes")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(MimirTheme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(MimirTheme.secondaryInk)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(MimirTheme.softFill))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                tabButton(for: section)
            }
            Spacer(minLength: 0)
        }
    }

    private func tabButton(for section: SettingsSection) -> some View {
        let isSelected = selected == section
        return Button {
            selected = section
        } label: {
            Text(section.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : MimirTheme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Group {
                        if isSelected {
                            Capsule().fill(MimirTheme.brandGradient)
                        } else {
                            Capsule().fill(MimirTheme.softFill)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        switch selected {
        case .general: return "Atalho global, modo de ativação e idioma."
        case .audio: return "Entrada de microfone usada pelo Mimir."
        case .pipeline: return "Transcrição, pós-processamento e inserção."
        case .permissions: return "Permissões necessárias para o atalho global funcionar."
        case .about: return "Sobre o Mimir."
        }
    }
}

struct SettingsSectionsRouter: View {
    @Bindable var store: SettingsStore
    let selectedID: String

    var body: some View {
        let overlay = SettingsOverlay(
            store: store,
            selectedItemID: .constant(selectedID),
            isPresented: .constant(true)
        )
        switch selectedID {
        case "audio":
            overlay.audioSection
        case "pipeline":
            overlay.pipelineSection
        case "permissions":
            overlay.permissionsSection
        case "about":
            overlay.aboutSection
        default:
            overlay.generalSection
        }
    }
}

// MARK: - Helpers

func humanizedDate(_ date: Date) -> String {
    let now = Date()
    let diff = now.timeIntervalSince(date)
    let calendar = Calendar.current

    if diff < 60 { return "agora" }
    if diff < 3600 { return "há \(Int(diff / 60)) min" }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "pt_BR")

    if calendar.isDateInToday(date) {
        formatter.dateFormat = "'hoje,' HH:mm"
        return formatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
        formatter.dateFormat = "'ontem,' HH:mm"
        return formatter.string(from: date)
    }
    if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day, days < 7 {
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date).lowercased()
    }
    formatter.dateFormat = "d/M HH:mm"
    return formatter.string(from: date)
}
