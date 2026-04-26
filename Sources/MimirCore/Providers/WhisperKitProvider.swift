import Foundation
@preconcurrency import WhisperKit

public enum WhisperKitChunkingMode: String, Equatable, Sendable {
    case none
    case vad
}

public struct WhisperKitProviderConfiguration: Equatable, Sendable {
    public let modelName: String
    public let strategy: TranscriptionStrategy
    public let language: String?
    public let detectLanguage: Bool
    public let concurrentWorkerCount: Int
    public let chunkingMode: WhisperKitChunkingMode
    public let prefersWordTimestamps: Bool
    public let promptTokens: [Int]?

    public init(
        modelName: String,
        strategy: TranscriptionStrategy,
        language: String?,
        detectLanguage: Bool,
        concurrentWorkerCount: Int,
        chunkingMode: WhisperKitChunkingMode,
        prefersWordTimestamps: Bool,
        promptTokens: [Int]? = nil
    ) {
        self.modelName = modelName
        self.strategy = strategy
        self.language = language
        self.detectLanguage = detectLanguage
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkingMode = chunkingMode
        self.prefersWordTimestamps = prefersWordTimestamps
        self.promptTokens = promptTokens
    }

    public func withPromptTokens(_ tokens: [Int]) -> WhisperKitProviderConfiguration {
        WhisperKitProviderConfiguration(
            modelName: modelName,
            strategy: strategy,
            language: language,
            detectLanguage: detectLanguage,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingMode: chunkingMode,
            prefersWordTimestamps: prefersWordTimestamps,
            promptTokens: tokens
        )
    }

    var decodeOptions: DecodingOptions {
        let chunkingStrategy: ChunkingStrategy = switch chunkingMode {
        case .none:
            .none
        case .vad:
            .vad
        }

        return DecodingOptions(
            language: language,
            usePrefillPrompt: true,
            usePrefillCache: true,
            detectLanguage: detectLanguage,
            skipSpecialTokens: true,
            wordTimestamps: prefersWordTimestamps,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: chunkingStrategy
        )
    }
}

public actor WhisperKitProvider: SessionResettableSpeechProvider {
    private var pipeline: WhisperKit?
    private let configuration: WhisperKitProviderConfiguration
    /// Idioma detectado com sucesso na primeira chamada da sessão. Reusado
    /// pelas chamadas seguintes para evitar flickering de detecção em chunks
    /// parciais (que alucinam pt → ja → pt).
    private var cachedSessionLanguage: String?

    /// Transcrições recentes bem-sucedidas. Usadas como contexto prévio pro
    /// decoder (promptTokens) — Whisper aprende o vocabulário do próprio
    /// usuário ao longo do uso. Quanto mais você usa, mais ele reconhece seus
    /// termos (nomes de projeto, frameworks, etc.) sem precisar configurar.
    private var recentTranscriptions: [String] = []
    private static let maxRecentInMemory = 8
    /// Budget de tokens pra promptTokens. Whisper suporta ~224 tokens de
    /// contexto total — deixamos margem pra não atrapalhar a transcrição.
    private static let maxPromptTokenBudget = 180

    /// Idiomas aceitáveis para auto-detect. Se o Whisper detectar um idioma
    /// fora dessa lista, rejeitamos e mantemos o estado para tentar de novo.
    /// Evita o caso "áudio parcial detectado como japonês".
    private static let allowlistedDetectableLanguages: Set<String> = [
        "pt", "en", "es", "fr", "de", "it", "nl", "sv", "no", "da", "fi",
        "ru", "pl", "cs", "uk", "tr", "ro", "el", "ca"
    ]

    public init(modelName: String, strategy: TranscriptionStrategy = .chunked) {
        self.configuration = Self.configuration(
            modelName: modelName,
            strategy: strategy,
            languageHint: nil
        )
    }

    public init(model: WhisperKitModel = .base, strategy: TranscriptionStrategy = .chunked) {
        self.configuration = Self.configuration(
            model: model,
            strategy: strategy,
            languageHint: nil
        )
    }

    /// Limpa o idioma em cache. Chamar no início de cada sessão de ditado para
    /// deixar o detector re-avaliar o idioma do novo áudio.
    public func resetSessionLanguage() {
        cachedSessionLanguage = nil
    }

    /// Vocabulário técnico injetado como "contexto prévio" pro Whisper. Ajuda
    /// ele a reconhecer termos que aparecem no fluxo de trabalho do usuário
    /// em vez de transcrever foneticamente (ex: "curl" → "crow", "Bitbucket" → "beat bucket").
    /// Mantido curto pra não estourar o context window do decoder.
    private static let technicalVocabularyHint = "Desenvolvimento com Swift, React, TypeScript, Node. Ferramentas: Bitbucket, GitHub, curl, git, diff, commit, pull request. Stack: MCP, Obsidian, skill, Hermes, Mimir, Claude, Whisper, LLM."

    public func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        let pipeline = try await ensurePipeline()

        // Prioridade: hint explícito do usuário > cache da sessão > auto-detect.
        let effectiveHint: String?
        if let languageHint {
            effectiveHint = languageHint
        } else if let cached = cachedSessionLanguage {
            effectiveHint = cached
        } else {
            effectiveHint = nil
        }

        var configuration = Self.configuration(
            modelName: configuration.modelName,
            strategy: configuration.strategy,
            languageHint: effectiveHint
        )

        // Constrói o prompt dinâmico: vocabulário técnico base + transcrições
        // recentes do usuário. Whisper usa isso como "contexto prévio" e enviesa
        // o decoder a favor do vocabulário que o usuário já usou.
        // Importante: em variantes large/turbo/quantizadas o promptTokens pode
        // fazer o decoder devolver tokens vazios. Só injetamos nos modelos
        // small e menores.
        let isLargeModel = configuration.modelName.contains("large") || configuration.modelName.contains("medium")
        if !isLargeModel, let tokenizer = pipeline.tokenizer {
            let promptText = buildPromptContext()
            let allTokens = tokenizer.encode(text: promptText)
            let truncated = Array(allTokens.suffix(Self.maxPromptTokenBudget))
            if !truncated.isEmpty {
                configuration = configuration.withPromptTokens(truncated)
            }
        }

        let results = try await pipeline.transcribe(
            audioPath: audioFileURL.path,
            decodeOptions: configuration.decodeOptions
        )

        // Agregamos pelos segmentos em vez do TranscriptionResult.text: em
        // variantes turbo/quantizadas o campo `text` às vezes vem vazio mesmo
        // quando os segments têm conteúdo.
        let resultText = results.map(\.text).joined(separator: " ")
        let segmentText = results
            .flatMap(\.segments)
            .map(\.text)
            .joined(separator: " ")
        let raw = segmentText.isEmpty ? resultText : segmentText

        let diag = "[Mimir.Whisper] model=\(configuration.modelName) results=\(results.count) segments=\(results.flatMap(\.segments).count) result_chars=\(resultText.count) segment_chars=\(segmentText.count)\n"
        FileHandle.standardError.write(diag.data(using: .utf8) ?? Data())

        let text = Self.cleanSpecialTokens(raw)

        guard !text.isEmpty else {
            let rawSummary = raw.prefix(200)
            let diag = "[Mimir.Whisper] empty transcript treated as no-speech (results=\(results.count), raw=\(rawSummary))\n"
            FileHandle.standardError.write(diag.data(using: .utf8) ?? Data())
            throw MimirError.emptyTranscript
        }

        // Se acabamos de detectar um idioma (não havia hint), guardar no cache
        // da sessão — desde que seja um dos idiomas permitidos (evita locking
        // numa falsa detecção de CJK).
        if effectiveHint == nil, let detected = results.last?.language,
           Self.allowlistedDetectableLanguages.contains(detected) {
            cachedSessionLanguage = detected
        }

        // Só alimentamos o buffer de vocabulário com transcrições que o próprio
        // Whisper considerou confiáveis — evita que chutes/alucinações poluam
        // o contexto das próximas chamadas.
        if Self.looksTrustworthy(results: results) {
            rememberTranscription(text)
        }

        let timings = Self.mergeTimings(from: results)
        return SpeechTranscription(
            text: text,
            language: results.last?.language ?? cachedSessionLanguage,
            metrics: timings.map(Self.metrics(from:))
        )
    }

    /// Monta o texto de prompt que será tokenizado e injetado no decoder.
    /// Ordem: vocabulário técnico base + transcrições recentes (em ordem cronológica).
    private func buildPromptContext() -> String {
        guard !recentTranscriptions.isEmpty else {
            return Self.technicalVocabularyHint
        }
        let recent = recentTranscriptions.joined(separator: " ")
        return "\(Self.technicalVocabularyHint) \(recent)"
    }

    /// Heurística pra decidir se uma transcrição é confiável o bastante pra
    /// entrar no buffer de vocabulário. Se qualquer segmento tiver
    /// sinais típicos de alucinação, descartamos.
    private static func looksTrustworthy(results: [TranscriptionResult]) -> Bool {
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            // Modelos chutando: logprob muito baixo.
            if segment.avgLogprob < -0.9 { return false }
            // Loops de repetição: compression ratio alto.
            if segment.compressionRatio > 2.4 { return false }
            // "Não é fala": Whisper detectou que o áudio nem é speech.
            if segment.noSpeechProb > 0.6 { return false }
        }
        return true
    }

    private func rememberTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Evita bloat: só guardamos transcrições de tamanho razoável, não fragmentos.
        guard trimmed.count >= 8 else { return }
        recentTranscriptions.append(trimmed)
        if recentTranscriptions.count > Self.maxRecentInMemory {
            recentTranscriptions.removeFirst(recentTranscriptions.count - Self.maxRecentInMemory)
        }
    }

    public nonisolated static func configuration(
        model: WhisperKitModel,
        strategy: TranscriptionStrategy,
        languageHint: String?
    ) -> WhisperKitProviderConfiguration {
        configuration(modelName: model.modelName, strategy: strategy, languageHint: languageHint)
    }

    public nonisolated static func configuration(
        modelName: String,
        strategy: TranscriptionStrategy,
        languageHint: String?
    ) -> WhisperKitProviderConfiguration {
        let language = languageHint.flatMap(primarySubtag(from:))
        let detectLanguage = language == nil
        let isLargeModel = modelName.contains("large") || modelName.contains("medium")

        switch strategy {
        case .chunked:
            // Large/medium: forçamos pt como fallback porque a auto-detecção
            // também parece falhar no quantizado quando não há hint explícito.
            // Word timestamps continuam desativados no turbo (decoder raso
            // interage mal). VAD e worker count subiram pra 8 pra aproveitar
            // paralelismo real; se surgirem outputs vazios, reavaliar.
            let effectiveLanguage = isLargeModel ? (language ?? "pt") : language
            let effectiveDetect = isLargeModel ? false : detectLanguage
            return WhisperKitProviderConfiguration(
                modelName: modelName,
                strategy: strategy,
                language: effectiveLanguage,
                detectLanguage: effectiveDetect,
                concurrentWorkerCount: 8,
                chunkingMode: .vad,
                prefersWordTimestamps: isLargeModel ? false : true
            )
        case .batch:
            return WhisperKitProviderConfiguration(
                modelName: modelName,
                strategy: strategy,
                language: language,
                detectLanguage: detectLanguage,
                concurrentWorkerCount: isLargeModel ? 4 : 8,
                chunkingMode: .none,
                prefersWordTimestamps: false
            )
        }
    }

    private static func mergeTimings(from results: [TranscriptionResult]) -> TranscriptionTimings? {
        guard var merged = results.first?.timings else { return nil }
        for timing in results.dropFirst().compactMap(\.timings) {
            merged.audioLoading += timing.audioLoading
            merged.audioProcessing += timing.audioProcessing
            merged.logmels += timing.logmels
            merged.encoding += timing.encoding
            merged.prefill += timing.prefill
            merged.decodingInit += timing.decodingInit
            merged.decodingLoop += timing.decodingLoop
            merged.decodingPredictions += timing.decodingPredictions
            merged.decodingFiltering += timing.decodingFiltering
            merged.decodingSampling += timing.decodingSampling
            merged.decodingFallback += timing.decodingFallback
            merged.decodingWindowing += timing.decodingWindowing
            merged.decodingKvCaching += timing.decodingKvCaching
            merged.decodingWordTimestamps += timing.decodingWordTimestamps
            merged.decodingNonPrediction += timing.decodingNonPrediction
            merged.totalAudioProcessingRuns += timing.totalAudioProcessingRuns
            merged.totalLogmelRuns += timing.totalLogmelRuns
            merged.totalEncodingRuns += timing.totalEncodingRuns
            merged.totalDecodingLoops += timing.totalDecodingLoops
            merged.totalKVUpdateRuns += timing.totalKVUpdateRuns
            merged.totalTimestampAlignmentRuns += timing.totalTimestampAlignmentRuns
            merged.totalDecodingFallbacks += timing.totalDecodingFallbacks
            merged.totalDecodingWindows += timing.totalDecodingWindows
            merged.fullPipeline += timing.fullPipeline
            merged.inputAudioSeconds += timing.inputAudioSeconds
            merged.modelLoading += timing.modelLoading
            merged.prewarmLoadTime += timing.prewarmLoadTime
            merged.encoderLoadTime += timing.encoderLoadTime
            merged.decoderLoadTime += timing.decoderLoadTime
            merged.encoderSpecializationTime += timing.encoderSpecializationTime
            merged.decoderSpecializationTime += timing.decoderSpecializationTime
            merged.tokenizerLoadTime += timing.tokenizerLoadTime
            merged.pipelineStart = min(merged.pipelineStart, timing.pipelineStart)
            merged.firstTokenTime = min(merged.firstTokenTime, timing.firstTokenTime)
        }
        return merged
    }

    private static func metrics(from timings: TranscriptionTimings) -> TranscriptionMetrics {
        let firstTokenLatency: TimeInterval? = if timings.firstTokenTime.isFinite, timings.pipelineStart.isFinite {
            max(0, timings.firstTokenTime - timings.pipelineStart)
        } else {
            nil
        }

        return TranscriptionMetrics(
            audioLoading: timings.audioLoading,
            fullPipeline: timings.fullPipeline,
            realTimeFactor: timings.realTimeFactor,
            firstTokenLatency: firstTokenLatency,
            inputAudioSeconds: timings.inputAudioSeconds,
            modelLoading: timings.modelLoading,
            decodingWindowing: timings.decodingWindowing,
            totalDecodingWindows: timings.totalDecodingWindows,
            totalDecodingFallbacks: timings.totalDecodingFallbacks
        )
    }

    private static func cleanSpecialTokens(_ input: String) -> String {
        var text = input
        // Whisper alucina descrições de som entre colchetes ("[Music]", "[Som de porta]",
        // "[Applause]" etc.) — artefato do treino em legendas de vídeo. Em ditado
        // por voz você nunca estaria falando literalmente colchetes, então remove
        // qualquer `[...]` curto.
        text = text.replacingOccurrences(of: #"\s*\[[^\]]{1,80}\]\s*"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<\|[^|>]+\|>"#, with: "", options: .regularExpression)
        text = stripCJKHallucinations(text)
        text = stripTailFarewells(text)
        text = text.replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper foi treinado em muitos vídeos do YouTube, que tipicamente terminam
    /// com "thanks for watching" / "obrigado pela atenção" / etc. Em ditado com
    /// silêncio final ou fala cortada o modelo "completa" com essas frases —
    /// não é fala real do usuário. Se a última sentença bater uma lista curta
    /// de farewells conhecidos E for curta (até 5 palavras), removemos.
    static func stripTailFarewells(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }

        // Remove terminator/whitespace trailing para achar o corpo da última sentença.
        var stripEndIdx = trimmed.endIndex
        while stripEndIdx > trimmed.startIndex {
            let prev = trimmed.index(before: stripEndIdx)
            let ch = trimmed[prev]
            if ch.isWhitespace || ".!?".contains(ch) {
                stripEndIdx = prev
            } else {
                break
            }
        }
        let stripped = String(trimmed[..<stripEndIdx])
        guard !stripped.isEmpty else { return input }

        // Última sentença = depois do último terminator dentro do texto "podado".
        let lastTerminatorIdx = stripped.lastIndex(where: { ".!?".contains($0) })
        let tailStart: String.Index = lastTerminatorIdx.map { stripped.index(after: $0) } ?? stripped.startIndex

        let tail = String(stripped[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = tail
            .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return input }
        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard wordCount > 0, wordCount <= 5 else { return input }
        guard farewellPhrases.contains(normalized) else { return input }

        // Se o texto inteiro era só o farewell, preserva — o usuário pode ter
        // realmente dito "obrigado" como mensagem curta pra alguém.
        let prefix = String(stripped[..<tailStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return input }
        return prefix
    }

    private static let farewellPhrases: Set<String> = [
        // pt
        "obrigado", "obrigada",
        "muito obrigado", "muito obrigada",
        "obrigado pela atenção", "obrigada pela atenção",
        "obrigado por assistir", "obrigada por assistir",
        "tchau", "valeu",
        "até a próxima", "até logo", "até mais",
        "legendado por", "legendas pela equipe",
        // en
        "thanks", "thank you",
        "thanks for watching", "thank you for watching",
        "see you next time", "see you", "see ya",
        "bye", "goodbye", "later"
    ]

    /// Whisper alucina frases em japonês/chinês/coreano no fim de áudios com
    /// silêncio ou fala parcial (artefato do treinamento em vídeos do YouTube).
    /// Se a transcrição tem caracteres latinos (conteúdo real) E caracteres CJK,
    /// os CJK são quase certamente alucinação — removemos.
    private static func stripCJKHallucinations(_ text: String) -> String {
        let cjkRanges: [ClosedRange<UInt32>] = [
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul
            0x3000...0x303F   // CJK Symbols and Punctuation
        ]

        let isCJK: (Unicode.Scalar) -> Bool = { scalar in
            cjkRanges.contains { $0.contains(scalar.value) }
        }

        let hasCJK = text.unicodeScalars.contains(where: isCJK)
        guard hasCJK else { return text }

        // Se tem pelo menos um caractere ASCII letra, assume-se que o conteúdo real
        // é latino e o CJK é alucinação.
        let hasLatinLetter = text.unicodeScalars.contains { scalar in
            (0x41...0x5A).contains(scalar.value) ||
            (0x61...0x7A).contains(scalar.value) ||
            (0xC0...0xFF).contains(scalar.value)
        }
        guard hasLatinLetter else { return text }

        let cleanedScalars = text.unicodeScalars.filter { !isCJK($0) }
        return String(String.UnicodeScalarView(cleanedScalars))
    }

    private func ensurePipeline() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        do {
            let config = WhisperKitConfig(model: configuration.modelName)
            let pipeline = try await WhisperKit(config)
            self.pipeline = pipeline
            return pipeline
        } catch {
            throw MimirError.transcriptionFailed("WhisperKit load failed: \(error.localizedDescription)")
        }
    }

    private nonisolated static func primarySubtag(from bcp47: String) -> String? {
        bcp47.split(separator: "-").first.map(String.init)
    }
}
