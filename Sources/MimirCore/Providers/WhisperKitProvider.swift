import AVFoundation
import CoreML
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

    public init(
        modelName: String,
        strategy: TranscriptionStrategy,
        language: String?,
        detectLanguage: Bool,
        concurrentWorkerCount: Int,
        chunkingMode: WhisperKitChunkingMode,
        prefersWordTimestamps: Bool
    ) {
        self.modelName = modelName
        self.strategy = strategy
        self.language = language
        self.detectLanguage = detectLanguage
        self.concurrentWorkerCount = concurrentWorkerCount
        self.chunkingMode = chunkingMode
        self.prefersWordTimestamps = prefersWordTimestamps
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
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            firstTokenLogProbThreshold: -1.5,
            noSpeechThreshold: 0.6,
            concurrentWorkerCount: concurrentWorkerCount,
            chunkingStrategy: chunkingStrategy
        )
    }
}

public actor WhisperKitProvider: SessionResettableSpeechProvider, WarmableSpeechToTextProviding {
    private var pipeline: WhisperKit?
    private let configuration: WhisperKitProviderConfiguration
    /// Idioma detectado com sucesso na primeira chamada da sessão. Reusado
    /// pelas chamadas seguintes para evitar flickering de detecção em chunks
    /// parciais (que alucinam pt → ja → pt).
    private var cachedSessionLanguage: String?

    /// Idiomas aceitáveis para auto-detect. Se o Whisper detectar um idioma
    /// fora dessa lista, rejeitamos e mantemos o estado para tentar de novo.
    /// Evita o caso "áudio parcial detectado como japonês".
    private static let allowlistedDetectableLanguages: Set<String> = [
        "pt", "en", "es", "fr", "de", "it", "nl", "sv", "no", "da", "fi",
        "ru", "pl", "cs", "uk", "tr", "ro", "el", "ca"
    ]

    /// Last-resort language when detection fails and the user set none: the
    /// Mac's own language if Whisper handles it well, otherwise English.
    nonisolated static var fallbackLanguage: String {
        if let code = Locale.preferredLanguages.first.flatMap(primarySubtag(from:)),
           allowlistedDetectableLanguages.contains(code) {
            return code
        }
        return "en"
    }

    /// Vocabulário pessoal (um termo por linha) injetado como prompt do decoder.
    private let vocabulary: String
    /// Falso desliga o condicionamento por prompt (vocabulário + contexto).
    private let usesPrompt: Bool
    /// Reports the first-run model download to the UI. Nil in tools and tests.
    private let downloadMonitor: ModelDownloadMonitor?

    public init(
        modelName: String,
        strategy: TranscriptionStrategy = .chunked,
        vocabulary: String = "",
        usesPrompt: Bool = true,
        downloadMonitor: ModelDownloadMonitor? = nil
    ) {
        self.configuration = Self.configuration(
            modelName: modelName,
            strategy: strategy,
            languageHint: nil
        )
        self.vocabulary = vocabulary
        self.usesPrompt = usesPrompt
        self.downloadMonitor = downloadMonitor
    }

    public init(
        model: WhisperKitModel = .base,
        strategy: TranscriptionStrategy = .chunked,
        vocabulary: String = "",
        downloadMonitor: ModelDownloadMonitor? = nil
    ) {
        self.init(modelName: model.modelName, strategy: strategy, vocabulary: vocabulary, downloadMonitor: downloadMonitor)
    }

    /// Limpa o idioma em cache. Chamar no início de cada sessão de ditado para
    /// deixar o detector re-avaliar o idioma do novo áudio.
    public func resetSessionLanguage() {
        cachedSessionLanguage = nil
    }

    public func preload() async {
        _ = try? await ensurePipeline()
    }

    /// Segundos gastos carregando o modelo na ÚLTIMA chamada a `ensurePipeline`.
    /// Zero quando o pipeline já estava quente.
    ///
    /// Existe porque `TranscriptionTimings.modelLoading` do WhisperKit é um
    /// acumulador da biblioteca, não uma medida por chamada: a telemetria
    /// registrava 2,49s / 1,41s constantes em sessão após sessão, número que o
    /// dashboard apresentava como "carga do modelo deste ditado".
    private var lastPipelineLoadSeconds: TimeInterval = 0

    /// Fonte de áudio da transcrição: arquivo em disco ou samples em memória.
    /// O caminho em memória evita o round-trip WAV-em-disco por segmento.
    private enum TranscriptionInput {
        case file(URL)
        case samples([Float])
    }

    public func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        try await performTranscription(input: .file(audioFileURL), languageHint: languageHint, previousContext: nil)
    }

    public func transcribe(
        audio: IncrementalAudioCapture,
        languageHint: String?,
        previousContext: String?
    ) async throws -> SpeechTranscription {
        try await performTranscription(
            input: .samples(Self.floatSamples(from: audio)),
            languageHint: languageHint,
            previousContext: previousContext
        )
    }

    private func performTranscription(
        input: TranscriptionInput,
        languageHint: String?,
        previousContext: String?
    ) async throws -> SpeechTranscription {
        let pipeline = try await ensurePipeline()
        let samples = Self.samples(for: input)

        // Prioridade: hint explícito do usuário > cache da sessão > detecção
        // restrita aos idiomas do usuário.
        let effectiveHint: String?
        if let languageHint {
            effectiveHint = languageHint
        } else if let cached = cachedSessionLanguage {
            effectiveHint = cached
        } else if let samples, let detected = await detectSessionLanguage(samples, on: pipeline) {
            cachedSessionLanguage = detected
            effectiveHint = detected
        } else {
            effectiveHint = nil
        }

        let baseConfiguration = Self.configuration(
            modelName: configuration.modelName,
            strategy: configuration.strategy,
            languageHint: effectiveHint
        )

        // Prompt do decoder = vocabulário pessoal + cauda do texto já transcrito.
        // É o único ponto onde o Whisper aprende a grafia de um termo ANTES de
        // errar; o pós-processador só conserta depois. Se a chamada com prompt
        // vier vazia, refazemos sem prompt e marcamos `promptFallbackUsed`.
        var decodeOptions = baseConfiguration.decodeOptions
        let promptTokens = usesPrompt
            ? Self.promptTokens(
                for: Self.promptText(vocabulary: vocabulary, previousContext: previousContext),
                tokenizer: pipeline.tokenizer
            )
            : []
        var promptFallbackUsed = false
        var results: [TranscriptionResult]
        if promptTokens.isEmpty {
            results = try await run(input, samples: samples, on: pipeline, decodeOptions: decodeOptions)
        } else {
            decodeOptions.promptTokens = promptTokens
            // Com prompt o WhisperKit desliga o prefill cache e mede o
            // "primeiro token" no índice 0, que é o próprio prompt — o corte por
            // `firstTokenLogProbThreshold` avaliaria a previsão errada.
            decodeOptions.firstTokenLogProbThreshold = nil
            results = try await run(input, samples: samples, on: pipeline, decodeOptions: decodeOptions)
            if Self.cleanSpecialTokens(Self.joinedText(of: results)).isEmpty {
                promptFallbackUsed = true
                decodeOptions = baseConfiguration.decodeOptions
                results = try await run(input, samples: samples, on: pipeline, decodeOptions: decodeOptions)
            }
        }

        // Agregamos pelos segmentos em vez do TranscriptionResult.text: em
        // variantes turbo/quantizadas o campo `text` às vezes vem vazio mesmo
        // quando os segments têm conteúdo.
        let raw = Self.joinedText(of: results)
        let text = Self.cleanSpecialTokens(raw)

        let diag = "[Mimir.Whisper] model=\(baseConfiguration.modelName) lang=\(effectiveHint ?? "auto") results=\(results.count) segments=\(results.flatMap(\.segments).count) chars=\(raw.count) prompt_tokens=\(promptTokens.count) prompt_fallback=\(promptFallbackUsed)\n"
        FileHandle.standardError.write(diag.data(using: .utf8) ?? Data())

        guard !text.isEmpty else {
            let rawSummary = raw.prefix(200)
            let diag = "[Mimir.Whisper] empty transcript treated as no-speech (results=\(results.count), raw=\(rawSummary))\n"
            FileHandle.standardError.write(diag.data(using: .utf8) ?? Data())
            throw MimirError.emptyTranscript
        }

        let timings = Self.mergeTimings(from: results)
        var metrics = timings.map(Self.metrics(from:))
        if metrics == nil {
            metrics = TranscriptionMetrics(audioLoading: 0, fullPipeline: 0, realTimeFactor: 0)
        }
        metrics?.modelName = baseConfiguration.modelName
        metrics?.languageHint = effectiveHint
        // Medida nossa, não o acumulador da biblioteca: 0 = pipeline já quente.
        metrics?.modelLoading = lastPipelineLoadSeconds
        metrics?.promptTokensUsed = promptTokens.count
        metrics?.promptFallbackUsed = promptFallbackUsed

        return SpeechTranscription(
            text: text,
            language: results.last?.language ?? cachedSessionLanguage,
            metrics: metrics
        )
    }

    private func run(
        _ input: TranscriptionInput,
        samples: [Float]?,
        on pipeline: WhisperKit,
        decodeOptions: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        if let samples {
            return try await pipeline.transcribe(audioArray: samples, decodeOptions: decodeOptions)
        }
        // WAV ilegível pelo nosso loader: cai no caminho por path, sem ganho.
        guard case .file(let url) = input else { return [] }
        return try await pipeline.transcribe(audioPath: url.path, decodeOptions: decodeOptions)
    }

    /// Samples Float já com o nível normalizado. O caminho de arquivo (batch,
    /// recovery, ditado curto) também passa pelo ganho — é justamente o
    /// fallback quem recebe o áudio mais difícil.
    private nonisolated static func samples(for input: TranscriptionInput) -> [Float]? {
        switch input {
        case .file(let url):
            try? floatSamples(fromWAVAt: url)
        case .samples(let samples):
            samples
        }
    }

    /// Agregamos pelos segmentos em vez do `TranscriptionResult.text`: em
    /// variantes comprimidas o campo `text` às vezes vem vazio mesmo quando os
    /// segments têm conteúdo.
    private nonisolated static func joinedText(of results: [TranscriptionResult]) -> String {
        let segmentText = results.flatMap(\.segments).map(\.text).joined(separator: " ")
        return segmentText.isEmpty ? results.map(\.text).joined(separator: " ") : segmentText
    }

    // MARK: - Idioma

    /// Detecta o idioma do primeiro áudio da sessão, escolhendo só entre os
    /// idiomas do usuário. O decoder livre troca pt por es/gl em áudio curto e,
    /// antes disto, os modelos large caíam em "pt" fixo — ditado em inglês saía
    /// deformado. Falha de detecção devolve nil e a configuração decide.
    private func detectSessionLanguage(_ samples: [Float], on pipeline: WhisperKit) async -> String? {
        guard let detection = try? await pipeline.detectLangauge(audioArray: samples) else { return nil }
        return Self.bestLanguage(
            logProbabilities: detection.langProbs,
            candidates: Self.candidateLanguages(preferred: Locale.preferredLanguages),
            favoured: Locale.preferredLanguages.first.flatMap(Self.primarySubtag(from:))?.lowercased()
        )
    }

    /// Detection runs on the first seconds of audio, where a breath or room
    /// noise leaves it unsure; Portuguese dictation was decoded as English,
    /// which invented "*sos*"-style tags and took 8x longer. So another
    /// language only beats the Mac's own when it is clearly ahead:
    /// - when both scores are known, five times as likely (ln 5);
    /// - WhisperKit usually reports only the winner's log-probability, so
    ///   then the winner must be at least 80% sure.
    static let favouredLanguageMargin: Float = 1.6
    static let minimumSwitchLogProbability: Float = log(0.8)

    /// Idiomas do sistema (subtag primária) + inglês, restritos à allowlist.
    /// Sem nenhum idioma de sistema reconhecido, vale a allowlist inteira.
    nonisolated static func candidateLanguages(preferred: [String]) -> Set<String> {
        let system = Set(preferred.compactMap(primarySubtag(from:)).map { $0.lowercased() })
            .intersection(allowlistedDetectableLanguages)
        return system.isEmpty ? allowlistedDetectableLanguages : system.union(["en"])
    }

    nonisolated static func bestLanguage(
        logProbabilities: [String: Float],
        candidates: Set<String>,
        favoured: String? = nil
    ) -> String? {
        let best = logProbabilities
            .filter { candidates.contains($0.key) }
            .max { $0.value < $1.value }
        guard let best else { return nil }
        guard let favoured, favoured != best.key, candidates.contains(favoured) else {
            return best.key
        }
        if let favouredScore = logProbabilities[favoured] {
            return best.value - favouredScore < favouredLanguageMargin ? favoured : best.key
        }
        return best.value >= minimumSwitchLogProbability ? best.key : favoured
    }

    // MARK: - Prompt

    /// Contorna um defeito do WhisperKit (0.18): enquanto o laço de decodificação
    /// ainda está ALIMENTANDO os tokens do prompt, ele amostra a previsão do
    /// modelo e, se ela for `<|endoftext|>`, encerra o segmento — a transcrição
    /// volta vazia sem o áudio ter sido decodificado. Era essa a causa dos
    /// vazios com prompt (ago/2026), atribuídos na época à quantização.
    /// Este filtro proíbe `<|endoftext|>` enquanto nenhum token novo foi gerado.
    /// Sem prompt (`tokens` não começa em `<|startofprev|>`) é um no-op.
    final class PromptPrefillEndTokenFilter: LogitsFiltering {
        private let startOfPreviousToken: Int
        private let startOfTranscriptToken: Int
        private let endTokenIndex: [[NSNumber]]

        init(specialTokens: SpecialTokens) {
            startOfPreviousToken = specialTokens.startOfPreviousToken
            startOfTranscriptToken = specialTokens.startOfTranscriptToken
            endTokenIndex = [[0, 0, specialTokens.endToken as NSNumber]]
        }

        func filterLogits(_ logits: MLMultiArray, withTokens tokens: [Int]) -> MLMultiArray {
            guard Self.isStillPrefilling(
                tokens,
                startOfPreviousToken: startOfPreviousToken,
                startOfTranscriptToken: startOfTranscriptToken
            ) else { return logits }
            logits.fill(indexes: endTokenIndex, with: -FloatType.infinity)
            return logits
        }

        /// O prompt inicial é `<|startofprev|> … <|startoftranscript|> idioma
        /// tarefa timestamp`; enquanto `tokens` não passou disso, nada foi gerado.
        static func isStillPrefilling(
            _ tokens: [Int],
            startOfPreviousToken: Int,
            startOfTranscriptToken: Int
        ) -> Bool {
            guard tokens.first == startOfPreviousToken,
                  let transcriptStart = tokens.firstIndex(of: startOfTranscriptToken) else { return false }
            return tokens.count <= transcriptStart + 4
        }
    }

    static let maxPromptVocabularyTerms = 60

    /// Texto de condicionamento: glossário primeiro, contexto por último (o
    /// WhisperKit corta o prompt pelo fim, então o contexto recente sobrevive).
    nonisolated static func promptText(vocabulary: String, previousContext: String?) -> String? {
        let terms = vocabulary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(maxPromptVocabularyTerms)
        var parts = [String]()
        if !terms.isEmpty {
            parts.append(terms.joined(separator: ", ") + ".")
        }
        if let context = previousContext?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            parts.append(context)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private nonisolated static func promptTokens(for text: String?, tokenizer: (any WhisperTokenizer)?) -> [Int] {
        guard let text, let tokenizer else { return [] }
        return tokenizer.encode(text: " " + text)
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// Carrega um WAV de captura (16 kHz mono) como samples Float normalizados
    /// em nível. Falha silenciosa → o chamador cai no caminho por path, sem ganho.
    nonisolated static func floatSamples(fromWAVAt url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            throw MimirError.transcriptionFailed("empty or unreadable capture file")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw MimirError.transcriptionFailed("capture file has no float channel data")
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return AudioGain.normalized(samples)
    }

    /// Converte PCM Int16 little-endian (formato canônico da captura) para os
    /// samples Float que o WhisperKit consome direto, já com o nível
    /// normalizado — gravação baixa faz o modelo devolver "♫" em vez de texto.
    nonisolated static func floatSamples(from capture: IncrementalAudioCapture) -> [Float] {
        let totalFrames = capture.chunks.reduce(0) { $0 + $1.frameCount }
        var samples = [Float]()
        samples.reserveCapacity(totalFrames)
        for chunk in capture.chunks {
            chunk.data.withUnsafeBytes { raw in
                for value in raw.bindMemory(to: Int16.self) {
                    samples.append(Float(Int16(littleEndian: value)) / Float(Int16.max))
                }
            }
        }
        return AudioGain.normalized(samples)
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
            // Large/medium: "pt" é só o último recurso, para quando a detecção
            // explícita de `detectSessionLanguage` falha e não há hint.
            // Word timestamps continuam desativados no turbo (decoder raso
            // interage mal). VAD e worker count subiram pra 8 pra aproveitar
            // paralelismo real; se surgirem outputs vazios, reavaliar.
            let effectiveLanguage = isLargeModel ? (language ?? fallbackLanguage) : language
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

    static func cleanedTranscriptForTesting(_ input: String) -> String {
        cleanSpecialTokens(input)
    }

    /// Símbolos de som que o Whisper emite quando classifica o áudio como
    /// não-fala. Aparecem soltos (sem colchetes), então escapam do filtro de
    /// `[...]`.
    private static let musicSymbols: Set<Character> = ["♫", "♪", "🎵", "🎶", "♩", "♬"]

    /// `true` quando a transcrição não contém nenhum caractere de conteúdo real —
    /// só símbolos de som, pontuação ou espaço. Nesses casos tratamos como
    /// "nenhuma fala" em vez de colar lixo no app do usuário.
    public static func isNonSpeechArtifact(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return true }
        return !stripped.contains { character in
            guard !musicSymbols.contains(character) else { return false }
            return character.isLetter || character.isNumber
        }
    }

    static func cleanSpecialTokens(_ input: String) -> String {
        var text = input
        // Whisper alucina descrições de som entre colchetes ("[Music]", "[Som de porta]",
        // "[Applause]" etc.) — artefato do treino em legendas de vídeo. Em ditado
        // por voz você nunca estaria falando literalmente colchetes, então remove
        // qualquer `[...]` curto.
        text = text.replacingOccurrences(of: #"\s*\[[^\]]{1,80}\]\s*"#, with: " ", options: .regularExpression)
        // Same artifact between asterisks ("*sos*", "*crash*", "*risos*"): seen
        // when the language is misdetected. Nobody dictates asterisks.
        text = text.replacingOccurrences(of: #"\s*\*[^*\n]{1,30}\*\s*"#, with: " ", options: .regularExpression)
        // Símbolos de som soltos: só removemos quando são a transcrição INTEIRA.
        // Se houver fala real junto, o usuário pode ter dito "coloca um ♫ aqui".
        if isNonSpeechArtifact(text) {
            text = ""
        }
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

    /// Apenas assinaturas INEQUÍVOCAS do treino em vídeos de YouTube. Despedidas
    /// genéricas ("obrigado", "valeu", "tchau", "amém", "até a próxima") ficam de
    /// fora de propósito: usuários reais terminam mensagens ditadas com elas, e
    /// removê-las é comer palavras legítimas.
    private static let farewellPhrases: Set<String> = [
        // pt
        "obrigado por assistir", "obrigada por assistir",
        "até o próximo vídeo",
        "legendado por", "legendas pela equipe",
        "inscrevase no canal", "não esqueça de se inscrever",
        // en
        "thanks for watching", "thank you for watching",
        "see you next time", "see you in the next video",
        "dont forget to subscribe", "like and subscribe"
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

    /// `load: true` é obrigatório. O WhisperKit só carrega os modelos no init
    /// quando `load` é explícito ou quando um `modelFolder` é passado
    /// (`config.load ?? (config.modelFolder != nil)`); sem isso o `tokenizer`
    /// fica nil até a primeira transcrição — e como é o tokenizer que converte o
    /// vocabulário técnico e o contexto anterior em `promptTokens`, o
    /// condicionamento do decoder nunca era aplicado. Também torna o `preload()`
    /// real em vez de um no-op.
    ///
    /// `prewarm: true` força a especialização do Core ML para o Neural Engine na
    /// carga. Sem ela, o decoder roda em fallback GPU/CPU até o sistema decidir
    /// especializar — na prática RTF ~0.7× em vez de ~0.1–0.2×. A especialização
    /// é cara UMA vez por (modelo, versão de OS) e fica em cache do sistema.
    static func makeConfiguration(modelName: String) -> WhisperKitConfig {
        WhisperKitConfig(model: modelName, prewarm: true, load: true)
    }

    /// One Whisper in memory per app. Settings changes rebuild the session and
    /// create a new provider; they reuse this instead of reloading the model.
    /// Also joins the launch preload, first-run setup and an early dictation
    /// into a single load.
    private static let sharedLoader = SharedModelLoader<WhisperKit>()

    private func ensurePipeline() async throws -> WhisperKit {
        if let pipeline {
            lastPipelineLoadSeconds = 0
            return pipeline
        }
        let start = Date()
        let modelName = configuration.modelName
        let monitor = downloadMonitor
        let pipeline = try await Self.sharedLoader.value(for: modelName) {
            .init(value: try await Self.loadPipeline(modelName: modelName, monitor: monitor))
        }
        lastPipelineLoadSeconds = Date().timeIntervalSince(start)
        self.pipeline = pipeline
        return pipeline
    }

    // MARK: - Model files

    /// Where models are stored. Application Support, not WhisperKit's default
    /// ~/Documents/huggingface: Documents triggers a privacy prompt and may be
    /// synced (and evicted) by iCloud.
    nonisolated static var modelsBase: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Mimir/huggingface", isDirectory: true)
    }

    /// Where builds before 1.0 stored models. Only looked at for people who
    /// already used Mimir (they have history), so new installs never touch
    /// Documents and never see the prompt.
    nonisolated static var legacyModelsBase: URL? {
        guard UserDefaults.standard.object(forKey: "com.mimir.history.v1") != nil else { return nil }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("huggingface", isDirectory: true)
    }

    nonisolated static func variantFolder(base: URL, modelName: String) -> URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(modelName)", isDirectory: true)
    }

    /// The three Core ML models WhisperKit needs are all on disk.
    nonisolated static func hasCompleteModel(at folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("\(name).mlmodelc/coremldata.bin").path
            )
        }
    }

    private nonisolated static func loadPipeline(
        modelName: String,
        monitor: ModelDownloadMonitor?
    ) async throws -> WhisperKit {
        if let monitor {
            await monitor.begin(.speech, owner: modelName)
        }
        do {
            let pipeline = try await resolveAndLoad(modelName: modelName, monitor: monitor)
            if let specialTokens = pipeline.tokenizer?.specialTokens {
                pipeline.textDecoder.logitsFilters = [PromptPrefillEndTokenFilter(specialTokens: specialTokens)]
            }
            if let monitor {
                await monitor.finish(.speech, owner: modelName, succeeded: true)
            }
            return pipeline
        } catch {
            if let monitor {
                await monitor.finish(.speech, owner: modelName, succeeded: false)
            }
            throw MimirError.transcriptionFailed("WhisperKit load failed: \(error.localizedDescription)")
        }
    }

    /// Loads straight from disk when the model is there (works offline, no
    /// network round trip at launch); downloads otherwise, or when the files on
    /// disk turn out to be unusable.
    private nonisolated static func resolveAndLoad(
        modelName: String,
        monitor: ModelDownloadMonitor?
    ) async throws -> WhisperKit {
        let candidates = [modelsBase, legacyModelsBase].compactMap { $0 }
        if let base = candidates.first(where: { hasCompleteModel(at: variantFolder(base: $0, modelName: modelName)) }) {
            if let monitor {
                await monitor.downloadFinished(.speech, owner: modelName)
            }
            do {
                return try await load(modelFolder: variantFolder(base: base, modelName: modelName), base: base)
            } catch {
                // Damaged or partial files: fetch again below.
                if let monitor {
                    await monitor.begin(.speech, owner: modelName)
                }
            }
        }

        let base = modelsBase
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Only show a download if fetching takes noticeable time.
        let delayedReveal: Task<Void, Never>? = monitor.map { m in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                m.showDownload(.speech, owner: modelName)
            }
        }
        defer { delayedReveal?.cancel() }
        let folder = try await WhisperKit.download(
            variant: modelName,
            downloadBase: base,
            progressCallback: { progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in monitor?.update(.speech, owner: modelName, fraction: fraction) }
            }
        )
        if let monitor {
            await monitor.downloadFinished(.speech, owner: modelName)
        }
        return try await load(modelFolder: folder, base: base)
    }

    private nonisolated static func load(modelFolder: URL, base: URL) async throws -> WhisperKit {
        let config = makeConfiguration(modelName: modelFolder.lastPathComponent)
        config.modelFolder = modelFolder.path
        // The tokenizer is fetched once next to the model, then read from disk.
        config.tokenizerFolder = base
        config.download = false
        return try await WhisperKit(config)
    }

    private nonisolated static func primarySubtag(from bcp47: String) -> String? {
        bcp47.split(separator: "-").first.map(String.init)
    }
}
