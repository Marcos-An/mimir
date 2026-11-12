import Foundation

public protocol SpeechToTextProviding: Sendable {
    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription
    /// Transcrição in-memory de um segmento. `previousContext` é o fim do texto
    /// já transcrito da mesma sessão — providers que suportam condicionamento
    /// (Whisper promptTokens) usam isso pra manter pontuação/concordância
    /// coerentes entre segmentos.
    func transcribe(
        audio: IncrementalAudioCapture,
        languageHint: String?,
        previousContext: String?
    ) async throws -> SpeechTranscription
}

public extension SpeechToTextProviding {
    /// Default para providers file-based (ex.: Apple Speech): materializa um WAV
    /// temporário e ignora o contexto.
    func transcribe(
        audio: IncrementalAudioCapture,
        languageHint: String?,
        previousContext: String?
    ) async throws -> SpeechTranscription {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-segment-\(UUID().uuidString).wav")
        try audio.makeWAVData().write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try await transcribe(audioFileURL: temporaryURL, languageHint: languageHint)
    }
}

public protocol WarmableSpeechToTextProviding: SpeechToTextProviding {
    func preload() async
}

/// Providers que mantêm estado entre chamadas (ex.: idioma detectado em cache)
/// podem implementar este protocolo para que o controller limpe o estado no
/// início de cada sessão de ditado.
public protocol SessionResettableSpeechProvider: SpeechToTextProviding {
    func resetSessionLanguage() async
}

public protocol TextPostProcessing: Sendable {
    func polish(_ transcript: String) async throws -> String
    func polish(_ transcript: String, intent: PolishIntent) async throws -> String
    func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String
}

public protocol WarmableTextPostProcessing: TextPostProcessing {
    func preload() async
}

public extension TextPostProcessing {
    /// Versão com callback incremental opcional. O provider pode invocar
    /// `onChunk(accumulatedText)` a cada pedaço gerado pra UI de preview.
    /// Default: chama `polish` não-streaming e emite o texto final de uma vez.
    func polish(
        _ transcript: String,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let result = try await polish(transcript)
        await onChunk(result)
        return result
    }

    /// Intent-aware variant. Providers that understand `PolishIntent` (like the
    /// MLX post-processor) should override. The default ignores the intent and
    /// falls back to the provider's configured behavior.
    func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        try await polish(transcript)
    }

    func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let result = try await polish(transcript, intent: intent)
        await onChunk(result)
        return result
    }
}

public protocol TextInserting: Sendable {
    func insert(_ text: String) async throws
}

public struct LocalPipeline: Sendable {
    public var speechToText: any SpeechToTextProviding
    /// Cleans plain dictation (and translations). Nil: rules only, no AI.
    public var postProcessor: (any TextPostProcessing)?
    /// Rewrites speech into a prompt. Chosen separately from dictation, so
    /// dictation can stay on the Mac while prompts use a cloud model, or the
    /// other way round. Nil: the prompt is pasted as cleaned dictation.
    public var promptPostProcessor: (any TextPostProcessing)?
    public var textInserter: any TextInserting

    /// One processor for every mode.
    public init(
        speechToText: any SpeechToTextProviding,
        postProcessor: (any TextPostProcessing)?,
        textInserter: any TextInserting
    ) {
        self.init(
            speechToText: speechToText,
            postProcessor: postProcessor,
            promptPostProcessor: postProcessor,
            textInserter: textInserter
        )
    }

    public init(
        speechToText: any SpeechToTextProviding,
        postProcessor: (any TextPostProcessing)?,
        promptPostProcessor: (any TextPostProcessing)?,
        textInserter: any TextInserting
    ) {
        self.speechToText = speechToText
        self.postProcessor = postProcessor
        self.promptPostProcessor = promptPostProcessor
        self.textInserter = textInserter
    }

    /// The processor for an intent: prompts use the prompt processor;
    /// dictation uses the dictation one; translation needs a model, so it takes
    /// whichever exists, dictation first.
    func processor(for intent: PolishIntent) -> (any TextPostProcessing)? {
        switch intent {
        case .promptEngineer: promptPostProcessor
        case .defaults: postProcessor
        case .translateTo: postProcessor ?? promptPostProcessor
        }
    }

    public func preload() async {
        async let speechWarmup: Void = preloadTranscription()
        async let postWarmup: Void = preloadPostProcessing()
        _ = await (speechWarmup, postWarmup)
    }

    /// Aquece só o reconhecimento de fala. É o que precisa estar pronto no
    /// instante em que o usuário aperta o atalho.
    public func preloadTranscription() async {
        await (speechToText as? any WarmableSpeechToTextProviding)?.preload()
    }

    /// Aquece só o pós-processamento. É o componente mais pesado em memória e
    /// só é usado depois de a fala terminar, então carregá-lo no início da
    /// gravação esconde o custo atrás do tempo de fala.
    public func preloadPostProcessing() async {
        let dictationProcessor = postProcessor as? any WarmableTextPostProcessing
        var promptProcessor = promptPostProcessor as? any WarmableTextPostProcessing
        // One processor serving both modes is warmed once.
        if let a = dictationProcessor as AnyObject?, let b = promptProcessor as AnyObject?, a === b {
            promptProcessor = nil
        }
        async let dictation: Void? = dictationProcessor?.preload()
        async let prompt: Void? = promptProcessor?.preload()
        _ = await (dictation, prompt)
    }

    public func process(
        audioFileURL: URL,
        languageHint: String?,
        defaultIntent: PolishIntent = .defaults,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil,
        onIntent: (@Sendable (PolishIntent) async -> Void)? = nil,
        onPolishChunk: (@Sendable (String) async -> Void)? = nil
    ) async throws -> LocalPipelineResult {
        let transcript = try await transcribeAudio(
            audioFileURL: audioFileURL,
            languageHint: languageHint,
            onPhase: onPhase
        )
        return try await process(
            transcription: transcript,
            defaultIntent: defaultIntent,
            onPhase: onPhase,
            onIntent: onIntent,
            onPolishChunk: onPolishChunk
        )
    }

    public func process(
        transcription: SpeechTranscription,
        defaultIntent: PolishIntent = .defaults,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil,
        onIntent: (@Sendable (PolishIntent) async -> Void)? = nil,
        onPolishChunk: (@Sendable (String) async -> Void)? = nil
    ) async throws -> LocalPipelineResult {
        // Route command prefixes ("prompt ...", "traduzir ...") to the
        // matching intent and strip the trigger word from the payload.
        let routed = CommandPrefixRouter.route(transcription.text)
        let intent = routed.intent == .defaults ? defaultIntent : routed.intent
        let speech = intent == .defaults || intent == .promptEngineer
            ? DictationTextCleaner.stripMidTextFarewells(routed.text)
            : routed.text
        let routedTranscription = SpeechTranscription(
            text: speech,
            language: transcription.language,
            metrics: transcription.metrics
        )
        if intent != .defaults {
            await onIntent?(intent)
        }

        var finalText: String
        var postSeconds: TimeInterval?
        var postInputCharacterCount: Int?
        var postOutputCharacterCount: Int?
        var systemBeforePostProcessing: SystemResourceSnapshot?
        var systemAfterPostProcessing: SystemResourceSnapshot?
        var postEditRatio: Double?
        let postProcessor = processor(for: intent)
        if let postProcessor {
            await onPhase?(.postProcessing)
            postInputCharacterCount = routedTranscription.text.count
            systemBeforePostProcessing = SystemResourceSnapshot.capture()
            let start = Date()
            let proposedText: String
            if let onPolishChunk {
                proposedText = try await postProcessor.polish(routedTranscription.text, intent: intent) { chunk in
                    await onPolishChunk(chunk)
                }
            } else {
                proposedText = try await postProcessor.polish(routedTranscription.text, intent: intent)
            }
            finalText = Self.acceptedPostProcessedText(
                proposedText,
                originalText: routedTranscription.text,
                intent: intent
            )
            postSeconds = Date().timeIntervalSince(start)
            systemAfterPostProcessing = SystemResourceSnapshot.capture()
            postOutputCharacterCount = finalText.count
        } else {
            finalText = routedTranscription.text
        }
        // Limpeza determinística no ditado padrão e no modo prompt: os dois
        // devolvem a fala do usuário no idioma original, então "Obrigado."
        // alucinado, reticências de pausa e capitalização valem igual. Só a
        // tradução fica de fora — lá o texto final é outro idioma, e um fecho
        // pode ser tradução legítima do que foi dito.
        if intent == .defaults || intent == .promptEngineer {
            finalText = DictationTextCleaner.clean(finalText)
            if postProcessor != nil {
                postOutputCharacterCount = finalText.count
            }
        }
        await onPhase?(.inserting)
        let insertStart = Date()
        try await textInserter.insert(finalText)
        let insertSeconds = Date().timeIntervalSince(insertStart)
        if postProcessor != nil {
            // Telemetria (Levenshtein até 4096², dezenas de ms): calculada DEPOIS
            // do paste — o usuário não espera métrica.
            postEditRatio = Self.editRatio(from: routedTranscription.text, to: finalText)
        }
        return LocalPipelineResult(
            transcription: routedTranscription,
            outputText: finalText,
            activeIntent: intent,
            postProcessingSeconds: postSeconds,
            insertionSeconds: insertSeconds,
            postProcessingInputCharacterCount: postInputCharacterCount,
            postProcessingOutputCharacterCount: postOutputCharacterCount,
            postProcessingSystemBefore: systemBeforePostProcessing,
            postProcessingSystemAfter: systemAfterPostProcessing,
            postProcessingEditRatio: postEditRatio
        )
    }

    /// Distância de Levenshtein normalizada pelo comprimento da string maior.
    /// Calculada em chars com algoritmo de duas linhas (memória O(min(n, m))).
    /// Para strings muito longas (>4 KB) retornamos nil para evitar custo
    /// O(n²) num caminho síncrono — telemetria não vale travar a UI.
    static func editRatio(from a: String, to b: String) -> Double? {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        guard n > 0 || m > 0 else { return 0 }
        guard max(n, m) <= 4096 else { return nil }
        if n == 0 { return 1 }
        if m == 0 { return 1 }

        // Garantir que a linha curta vire o loop interno (menos memória).
        let (short, long) = n <= m ? (aChars, bChars) : (bChars, aChars)
        let shortLen = short.count
        let longLen = long.count

        var previous = Array(0...shortLen)
        var current = Array(repeating: 0, count: shortLen + 1)

        for i in 1...longLen {
            current[0] = i
            for j in 1...shortLen {
                let cost = long[i - 1] == short[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        let distance = previous[shortLen]
        return Double(distance) / Double(max(n, m))
    }

    private static func acceptedPostProcessedText(
        _ proposedText: String,
        originalText: String,
        intent: PolishIntent
    ) -> String {
        let proposed = proposedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return originalText }
        // A note about the text instead of the text ("(Removed as a standalone
        // closing artifact…)") was once pasted into the user's app.
        guard !isModelCommentary(proposed, original: original) else { return originalText }
        guard intent == .defaults else { return proposedText }
        guard original.count >= 120 else { return proposedText }
        let minimumAllowedCount = Int((Double(original.count) * 0.90).rounded(.down))
        if proposed.count < minimumAllowedCount {
            return originalText
        }
        return proposedText
    }

    /// The model answered about the text rather than with it: the whole reply
    /// is parenthesised or bracketed while the dictation wasn't, or it talks
    /// about the transcript itself.
    static func isModelCommentary(_ proposed: String, original: String) -> Bool {
        let wrapped = (proposed.hasPrefix("(") && proposed.hasSuffix(")"))
            || (proposed.hasPrefix("[") && proposed.hasSuffix("]"))
        if wrapped && !(original.hasPrefix("(") || original.hasPrefix("[")) { return true }
        let lowered = proposed.lowercased()
        let markers = ["artifact", "no content", "nothing to clean", "transcript is empty",
                       "removed as", "no addressee", "the transcript", "the dictation"]
        return markers.contains { lowered.contains($0) && !original.lowercased().contains($0) }
    }

    public func transcribeAudio(
        audioFileURL: URL,
        languageHint: String?,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil
    ) async throws -> SpeechTranscription {
        await onPhase?(.transcribing)
        return try await speechToText.transcribe(audioFileURL: audioFileURL, languageHint: languageHint)
    }

    public func transcribeAudioCapture(
        _ capture: IncrementalAudioCapture,
        languageHint: String?,
        previousContext: String?,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil
    ) async throws -> SpeechTranscription {
        await onPhase?(.transcribing)
        return try await speechToText.transcribe(
            audio: capture,
            languageHint: languageHint,
            previousContext: previousContext
        )
    }
}
