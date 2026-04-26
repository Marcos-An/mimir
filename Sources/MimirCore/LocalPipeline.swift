import Foundation

public protocol SpeechToTextProviding: Sendable {
    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription
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
    public var postProcessor: (any TextPostProcessing)?
    public var textInserter: any TextInserting

    public init(
        speechToText: any SpeechToTextProviding,
        postProcessor: (any TextPostProcessing)?,
        textInserter: any TextInserting
    ) {
        self.speechToText = speechToText
        self.postProcessor = postProcessor
        self.textInserter = textInserter
    }

    /// Retorna uma cópia do pipeline com outro inserter. Usado pelo controller
    /// para rotear o modo Hermes sem duplicar toda a pipeline.
    public func with(textInserter: any TextInserting) -> LocalPipeline {
        LocalPipeline(
            speechToText: speechToText,
            postProcessor: postProcessor,
            textInserter: textInserter
        )
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
        let routedTranscription = SpeechTranscription(
            text: routed.text,
            language: transcription.language,
            metrics: transcription.metrics
        )
        if intent != .defaults {
            await onIntent?(intent)
        }

        let finalText: String
        var postSeconds: TimeInterval?
        if let postProcessor {
            await onPhase?(.postProcessing)
            let start = Date()
            if let onPolishChunk {
                finalText = try await postProcessor.polish(routedTranscription.text, intent: intent) { chunk in
                    await onPolishChunk(chunk)
                }
            } else {
                finalText = try await postProcessor.polish(routedTranscription.text, intent: intent)
            }
            postSeconds = Date().timeIntervalSince(start)
        } else {
            finalText = routedTranscription.text
        }
        await onPhase?(.inserting)
        let insertStart = Date()
        try await textInserter.insert(finalText)
        let insertSeconds = Date().timeIntervalSince(insertStart)
        return LocalPipelineResult(
            transcription: routedTranscription,
            outputText: finalText,
            activeIntent: intent,
            postProcessingSeconds: postSeconds,
            insertionSeconds: insertSeconds
        )
    }

    public func transcribeAudio(
        audioFileURL: URL,
        languageHint: String?,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil
    ) async throws -> SpeechTranscription {
        await onPhase?(.transcribing)
        return try await speechToText.transcribe(audioFileURL: audioFileURL, languageHint: languageHint)
    }

    public func transcribeIncrementalArtifact(
        _ artifact: IncrementalCaptureArtifact,
        languageHint: String?,
        onPhase: (@Sendable (AppPhase) async -> Void)? = nil
    ) async throws -> SpeechTranscription {
        if let fileURL = artifact.fileURL,
           FileManager.default.fileExists(atPath: fileURL.path) {
            return try await transcribeAudio(
                audioFileURL: fileURL,
                languageHint: languageHint,
                onPhase: onPhase
            )
        }

        guard let audioCapture = artifact.audioCapture else {
            throw MimirError.transcriptionFailed("Incremental capture artifact has no readable audio payload.")
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-incremental-\(UUID().uuidString).wav")
        try audioCapture.makeWAVData().write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try await transcribeAudio(
            audioFileURL: temporaryURL,
            languageHint: languageHint,
            onPhase: onPhase
        )
    }
}
