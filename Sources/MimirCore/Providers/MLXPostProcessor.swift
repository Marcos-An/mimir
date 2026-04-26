import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

public actor MLXPostProcessor: TextPostProcessing {
    public static let defaultModelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private let modelID: String
    private let style: PostProcessingStyle
    private let downloadMonitor: ModelDownloadMonitor?
    private var container: ModelContainer?

    public init(
        modelID: String = MLXPostProcessor.defaultModelID,
        style: PostProcessingStyle = .structured,
        downloadMonitor: ModelDownloadMonitor? = nil
    ) {
        self.modelID = modelID
        self.style = style
        self.downloadMonitor = downloadMonitor
    }

    public func preload() async {
        _ = try? await ensureLoaded()
    }

    public func polish(_ transcript: String) async throws -> String {
        try await polish(transcript, intent: .defaults, onChunk: { _ in })
    }

    public func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        try await polish(transcript, intent: intent, onChunk: { _ in })
    }

    public func polish(
        _ transcript: String,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        try await polish(transcript, intent: .defaults, onChunk: onChunk)
    }

    public func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return transcript }

        let effectiveStyle = self.style
        let container = try await ensureLoaded()
        let session = ChatSession(
            container,
            instructions: Self.systemPrompt(for: intent, fallbackStyle: effectiveStyle),
            generateParameters: Self.makeGenerateParameters(inputCharCount: normalizedTranscript.count)
        )

        var accumulated = ""
        var tokensSinceLastEmit = 0
        let emitEveryNTokens = 6
        let stream = session.streamResponse(to: Self.userPrompt(for: normalizedTranscript, intent: intent, fallbackStyle: effectiveStyle))
        for try await chunk in stream {
            accumulated += chunk
            tokensSinceLastEmit += 1
            // Throttle de callbacks: actor-hop por token gera overhead
            // notável (contenção + serialização). Emitir a cada 6 tokens
            // mantém o preview fluido (~30 fps pra decode @ 50 tok/s)
            // sem estrangular o decode.
            guard tokensSinceLastEmit >= emitEveryNTokens else { continue }
            tokensSinceLastEmit = 0
            let preview = Self.previewSanitize(accumulated)
            if !preview.isEmpty {
                await onChunk(preview)
            }
        }
        // Flush final — garante que a UI veja o texto completo.
        let finalPreview = Self.previewSanitize(accumulated)
        if !finalPreview.isEmpty {
            await onChunk(finalPreview)
        }

        let cleaned = Self.cleanOutput(accumulated)
        if cleaned.isEmpty { return transcript }
        // Only translation is allowed to change language; prompt/rewrite should
        // keep the user's dictation language while shaping it into a better prompt.
        let allowsLanguageChange = (intent == .translateToEnglish)
        if !allowsLanguageChange,
           Self.looksLikeForeignScript(cleaned),
           !Self.looksLikeForeignScript(normalizedTranscript) {
            return transcript
        }
        return cleaned
    }

    /// Limpeza barata para preview: remove prefixos comuns de abertura
    /// (aspas, crase de bloco de código). Não tenta desfazer finais, pra
    /// não piscar o texto enquanto o modelo ainda está gerando.
    static func previewSanitize(_ text: String) -> String {
        var s = text
        while s.hasPrefix("\"") || s.hasPrefix(" ") || s.hasPrefix("`") {
            s.removeFirst()
        }
        return s
    }

    /// Parâmetros de geração afinados para post-processamento determinístico:
    /// - temperature=0 → greedy decode, reproduzível e marginalmente mais rápido.
    /// - maxTokens ~ 1.5× tokens da entrada → impede saída runaway sem cortar o texto.
    /// - Heurística de tokens: ~0.35 tokens/char em pt-BR (empírico p/ Qwen tokenizer).
    private static func makeGenerateParameters(inputCharCount: Int) -> GenerateParameters {
        let approxInputTokens = max(100, Int(Double(inputCharCount) * 0.35))
        let cap = max(200, Int(Double(approxInputTokens) * 1.5))
        var params = GenerateParameters()
        params.temperature = 0
        params.maxTokens = cap
        return params
    }

    private static func looksLikeForeignScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs, Hiragana, Katakana, Hangul, Cyrillic, Arabic
            if (0x4E00...0x9FFF).contains(v) ||
               (0x3040...0x309F).contains(v) ||
               (0x30A0...0x30FF).contains(v) ||
               (0xAC00...0xD7AF).contains(v) ||
               (0x0400...0x04FF).contains(v) ||
               (0x0600...0x06FF).contains(v) {
                return true
            }
        }
        return false
    }

    static func cleanOutput(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("```") {
            cleaned = cleaned.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.hasPrefix("\"") && cleaned.hasSuffix("\"") && cleaned.count >= 2 {
            cleaned.removeFirst()
            cleaned.removeLast()
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func userPrompt(for transcript: String, intent: PolishIntent, fallbackStyle: PostProcessingStyle) -> String {
        let taskLine: String
        switch intent {
        case .translateToEnglish:
            taskLine = "Translate the dictation below into clear, natural English following the system rules."
        case .promptEngineer:
            taskLine = "Rewrite the dictation below as a structured prompt for an LLM, following the system rules."
        case .defaults:
            switch fallbackStyle {
            case .disabled:
                taskLine = "If there is nothing to adjust, return the transcription exactly as you received it."
            case .cleanup:
                taskLine = "Do only a conservative review of the transcription below, following the system rules."
            case .cleanDictation:
                taskLine = "Clean up the dictation below into natural readable text, following the system rules."
            case .structured:
                taskLine = "Format the dictation transcription below following the system rules."
            }
        }

        return """
        \(taskLine)
        Reply only with the final text.

        Transcription:
        \(transcript)
        """
    }

    static func systemPrompt(for intent: PolishIntent, fallbackStyle: PostProcessingStyle) -> String {
        switch intent {
        case .translateToEnglish:
            return translatePrompt
        case .promptEngineer:
            return promptEngineerPrompt
        case .defaults:
            switch fallbackStyle {
            case .disabled, .cleanup:
                return cleanupPrompt
            case .cleanDictation:
                return cleanDictationPrompt
            case .structured:
                return structuredPrompt
            }
        }
    }

    /// Backwards-compatible helper used by tests. Prefer the `intent:` variant.
    static func systemPrompt(for style: PostProcessingStyle) -> String {
        systemPrompt(for: .defaults, fallbackStyle: style)
    }

    private static let cleanupPrompt = """
    Dictation transcription reviewer. Output: only the final text, no quotes or comments.
    Language: same as input, same variant, same alphabet. Do not translate.
    Fidelity: preserve words, facts, names, numbers, URLs, code. Do not invent, do not complete, do not summarize, do not reorganize.
    Fix only: spelling, diacritics, capitalization, punctuation. Remove only hesitations ("uh", "um") and obvious accidental repetitions.
    """

    private static let cleanDictationPrompt = """
    Dictation transcript editor. Output: only the final text, no quotes or comments.
    Goal: make the dictation clean, natural, and easy to read without changing the user's meaning or voice.
    Language: same language, same variant, same alphabet. Do not translate.
    Preserve: intent, facts, order of ideas, names, numbers, URLs, commands, code, acronyms, and technical terms.
    You may improve punctuation, diacritics, capitalization, agreement, sentence boundaries, and paragraph breaks when helpful.
    You may lightly reorganize a confusing sentence only when the intended meaning is clear.
    Remove hesitations, false starts, accidental repetitions, and pause artifacts such as repeated ellipses.
    If a pause was transcribed as something like "... E ..." and the "E" adds no meaning, remove that pause marker.
    Do not summarize, invent details, complete unfinished thoughts, add context, or change the argument.
    Do not turn prose into headings, sections, or bullet lists unless the dictation clearly enumerates items.
    If a change could alter the meaning, preserve the original wording.
    """

    private static let structuredPrompt = """
    Dictation transcription formatter. Improve readability without changing content. Output: only the final text, no quotes or comments.
    Language: same as input, same variant, same alphabet. Do not translate.
    Fidelity: preserve words, facts, names, numbers, URLs, code. Do not invent, do not complete thoughts, do not summarize, do not rephrase.
    Do: spelling, diacritics, capitalization, punctuation, sentence/paragraph breaks when obvious. Bulleted lists only when the dictation clearly enumerates. Flowing text otherwise.
    Don't: headings, sections, summaries, conclusions. Do not reorganize into topics. When in doubt, minimum intervention.
    """

    private static let translatePrompt = """
    Professional translator. Convert the dictation into clear, well-written, natural English. Output: only the final English text, no quotes, no comments, no explanations.
    This is not a literal word-by-word translation. Read the meaning of the input and express it the way a fluent native English speaker would write it — polished prose, well-punctuated, idiomatic.
    If the input is already in English, just correct spelling, grammar, and punctuation.
    Preserve entities verbatim: proper nouns, personal names, numbers, dates, times, URLs, emails, identifiers, code symbols, acronyms. Do not localize them.
    Do not invent, complete, summarize, or add content the speaker did not say. Do not add commentary.
    """

    private static let promptEngineerPrompt = """
    Prompt engineer. The user just dictated a rambling description of what they want an LLM to do. Rewrite it as a clear, structured prompt ready to send to an LLM (Claude, GPT, Gemini, etc.). Output: only the final prompt, no quotes, no meta-commentary, no explanation of changes.
    Language: same as the dictation input, same variant, same alphabet. Do not translate. If the dictation is in Portuguese, write the final prompt in Portuguese; if it is in English, write it in English.
    Structure (use when it fits; do not force headings for short prompts):
      1. Brief context — what the user is working on or the situation.
      2. The specific task or question — phrased directly and unambiguously.
      3. Constraints, format, or output expectations when mentioned.
    Preserve entities verbatim: proper nouns, personal names, numbers, dates, URLs, filenames, code symbols, technical terms, acronyms.
    Do not answer the prompt. Do not invent facts, examples, requirements, or constraints the user did not mention. Tighten verbosity; remove filler words, hesitations, and self-corrections.
    """

    private func ensureLoaded() async throws -> ModelContainer {
        if let container { return container }

        let monitor = downloadMonitor

        let delayedStart: Task<Void, Never>? = monitor.map { m in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else { return }
                m.start(label: "Downloading model", indeterminate: true)
            }
        }

        let observer = ProgressObserver(monitor: monitor)

        let configuration = ModelConfiguration(id: modelID)
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    observer.attach(progress)
                }
            )
            delayedStart?.cancel()
            observer.stop()
            if let monitor {
                await monitor.finish()
            }
            self.container = container
            return container
        } catch {
            delayedStart?.cancel()
            observer.stop()
            if let monitor {
                await monitor.finish()
            }
            throw error
        }
    }
}

private final class ProgressObserver: @unchecked Sendable {
    private weak var monitor: ModelDownloadMonitor?
    private var observation: NSKeyValueObservation?
    private let lock = NSLock()

    init(monitor: ModelDownloadMonitor?) {
        self.monitor = monitor
    }

    func attach(_ progress: Progress) {
        lock.lock(); defer { lock.unlock() }
        observation?.invalidate()
        let monitor = monitor
        let initial = progress.fractionCompleted
        Task { @MainActor in monitor?.update(fraction: initial) }
        observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in monitor?.update(fraction: fraction) }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        observation?.invalidate()
        observation = nil
    }
}
