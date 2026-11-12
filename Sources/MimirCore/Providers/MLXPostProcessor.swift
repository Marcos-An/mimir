import Foundation
import HuggingFace
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

public actor MLXPostProcessor: WarmableTextPostProcessing {
    public static let defaultModelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private let modelID: String
    private let style: PostProcessingStyle
    private let customVocabulary: String
    private let downloadMonitor: ModelDownloadMonitor?

    public init(
        modelID: String = MLXPostProcessor.defaultModelID,
        style: PostProcessingStyle = .structured,
        customVocabulary: String = "",
        downloadMonitor: ModelDownloadMonitor? = nil
    ) {
        self.modelID = modelID
        self.style = style
        self.customVocabulary = customVocabulary
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
            instructions: Self.systemPrompt(for: intent, fallbackStyle: effectiveStyle, customVocabulary: customVocabulary),
            generateParameters: Self.makeGenerateParameters(inputCharCount: normalizedTranscript.count)
        )

        // Geração não-streamed: o produto não mostra preview incremental, então
        // o detokenizer por token + hops de AsyncStream eram custo sem consumidor.
        let response = try await session.respond(
            to: Self.userPrompt(for: normalizedTranscript, intent: intent, fallbackStyle: effectiveStyle)
        )

        let cleaned = Self.cleanOutput(response)
        if cleaned.isEmpty { return transcript }
        // Only translation is allowed to change language; prompt/rewrite should
        // keep the user's dictation language while shaping it into a better prompt.
        let allowsLanguageChange: Bool
        if case .translateTo = intent { allowsLanguageChange = true } else { allowsLanguageChange = false }
        if !allowsLanguageChange,
           Self.looksLikeForeignScript(cleaned),
           !Self.looksLikeForeignScript(normalizedTranscript) {
            return transcript
        }
        let result = cleaned
        await onChunk(result)
        return result
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

    static func looksLikeForeignScript(_ text: String) -> Bool {
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
        case .translateTo(let languageCode):
            let displayName = Self.languageDisplayName(for: languageCode)
            taskLine = "Translate the dictation below into clear, natural \(displayName) following the system rules."
        case .promptEngineer:
            taskLine = "Clean up the dictation below into the message the user meant to send, following the system rules."
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
        systemPrompt(for: intent, fallbackStyle: fallbackStyle, customVocabulary: "")
    }

    static func systemPrompt(
        for intent: PolishIntent,
        fallbackStyle: PostProcessingStyle,
        customVocabulary: String
    ) -> String {
        let base: String
        switch intent {
        case .translateTo(let languageCode):
            base = translatePrompt(for: languageCode)
        case .promptEngineer:
            base = promptEngineerPrompt
        case .defaults:
            switch fallbackStyle {
            case .disabled, .cleanup:
                base = cleanupPrompt
            case .cleanDictation:
                base = cleanDictationPrompt
            case .structured:
                base = structuredPrompt
            }
        }
        return base + personalVocabularySection(customVocabulary)
    }

    /// Seção extra com o vocabulário pessoal do usuário (nomes, projetos,
    /// jargão). O Whisper transcreve nomes próprios foneticamente
    /// ("Nathemans" → Natemans); esta lista dá ao pós-processador a base
    /// para restaurar. Vazia = nenhuma seção.
    static func personalVocabularySection(_ customVocabulary: String) -> String {
        let terms = customVocabulary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return SharedPrompts.cleanupVocabularySection
            .replacingOccurrences(of: "{{terms}}", with: terms.joined(separator: ", "))
    }

    /// Backwards-compatible helper used by tests. Prefer the `intent:` variant.
    static func systemPrompt(for style: PostProcessingStyle) -> String {
        systemPrompt(for: .defaults, fallbackStyle: style)
    }

    private static let cleanupPrompt = SharedPrompts.cleanupLight

    private static let cleanDictationPrompt = SharedPrompts.cleanupCleanDictation

    private static let structuredPrompt = SharedPrompts.cleanupStructured

    /// Prompt de tradução parametrizado pelo idioma alvo (BCP-47). Quando o
    /// código não estiver na tabela curada, caímos no `Locale` nativo do macOS
    /// pra resolver "pt-BR" → "Brazilian Portuguese", "ja" → "Japanese" etc.
    public static func translatePrompt(for languageCode: String) -> String {
        let displayName = Self.languageDisplayName(for: languageCode)
        let normalizedTarget = languageCode.lowercased()
        let extraRules: String
        if normalizedTarget.hasPrefix("pt") {
            // Estilo técnico pt-BR: devs misturam inglês na fala. "merge" não vira "fusão",
            // "deploy" não vira "deployar", "PR" não vira "PR de pedido de puxão".
            extraRules = """

            Style for technical Brazilian Portuguese (pt-BR dev speech):
            - Keep these terms in English verbatim, do NOT translate or verbalize them: deploy, merge, rebase, commit, push, pull request, PR, branch, staging, production, prod, build, release, rollback, fetch, debounce, throttle, worker, queue, job, schema, migration, endpoint, cache, lock, deadlock, padding, margin, border, button, modal, popover, scroll, flex, grid, viewport, breakpoint, render, component, hook, state, props, view, layout, lambda, bucket, frontend, backend, fullstack.
            - Do NOT invent Portuguese-ish verbs like "deployar", "mergir", "buildar", "comitar", "pushar", "fazendo merge", "fusão". Use Portuguese auxiliary + English noun: "vou fazer o deploy", "depois do merge", "abrir um PR", "subir pro staging", "fazer fetch", "rodar a migration", "tem um conflito no merge".
            - Acronyms (PR, API, URL, CI, CD, REST, SQL, MR, IP, JWT) stay uppercase and untranslated.
            - Do NOT translate "merge conflicts" to "conflitos de fusão" — keep it as "conflitos de merge".
            - Sentence-final English fillers like "so", "then", "right", "anyway" should be dropped, not translated to "então", "certo", "enfim". They were verbal pauses, not content.
            - Match how a Brazilian developer actually talks to a coworker on Slack: direct, casual, mixing English nouns naturally with Portuguese verbs and connectors.
            """
        } else {
            extraRules = ""
        }
        return """
        Professional translator. Convert the input text into clear, well-written, natural \(displayName). Output: only the final translated text, no quotes, no comments, no explanations.
        This is not a literal word-by-word translation. Read the meaning of the input and express it the way a fluent native \(displayName) speaker would write it — polished prose, well-punctuated, idiomatic.
        If the input is already in \(displayName), just correct spelling, grammar, and punctuation.
        Preserve entities verbatim: proper nouns, personal names, numbers, dates, times, URLs, emails, identifiers, code symbols, acronyms. Do not localize them.
        Do not invent, complete, summarize, or add content the speaker did not say. Do not add filler connectors that were not in the original.\(extraRules)
        """
    }

    /// Tabela curada de idiomas mais usados — evita variações inconsistentes
    /// que `Locale.localizedString(forLanguageCode:)` produz dependendo do
    /// locale do sistema (ex.: pode devolver "português" quando o sistema está
    /// em pt). Pra códigos fora da tabela, caímos no `Locale` mas forçamos
    /// `en_US` pra ter rótulo estável em inglês — o LLM lida melhor com nomes
    /// em inglês de idiomas.
    public static func languageDisplayName(for code: String) -> String {
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        let curated: [String: String] = [
            "en": "English",
            "en-US": "American English",
            "en-GB": "British English",
            "pt": "Portuguese",
            "pt-BR": "Brazilian Portuguese",
            "pt-PT": "European Portuguese",
            "es": "Spanish",
            "fr": "French",
            "de": "German",
            "it": "Italian",
            "ja": "Japanese",
            "zh": "Chinese",
            "zh-Hans": "Simplified Chinese",
            "zh-Hant": "Traditional Chinese",
            "ko": "Korean",
            "ru": "Russian",
            "ar": "Arabic"
        ]
        if let curatedName = curated[normalized] {
            return curatedName
        }
        let primary = normalized.split(separator: "-").first.map(String.init) ?? normalized
        let englishLocale = Locale(identifier: "en_US")
        if let name = englishLocale.localizedString(forLanguageCode: primary), !name.isEmpty {
            return name
        }
        return normalized
    }

    private static let promptEngineerPrompt = SharedPrompts.cleanupPromptEngineer

    /// One Qwen in memory per app, shared by every session rebuild.
    private static let sharedLoader = SharedModelLoader<ModelContainer>()

    private func ensureLoaded() async throws -> ModelContainer {
        let monitor = downloadMonitor
        let modelID = modelID
        return try await Self.sharedLoader.value(for: modelID) {
            if let monitor {
                await monitor.begin(.polish, owner: modelID)
            }
            let delayedReveal: Task<Void, Never>? = monitor.map { m in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    m.showDownload(.polish, owner: modelID)
                }
            }
            let observer = ModelProgressObserver(monitor: monitor, kind: .polish, owner: modelID)
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
                delayedReveal?.cancel()
                observer.stop()
                if let monitor {
                    await monitor.finish(.polish, owner: modelID, succeeded: true)
                }
                return .init(value: container)
            } catch {
                delayedReveal?.cancel()
                observer.stop()
                if let monitor {
                    await monitor.finish(.polish, owner: modelID, succeeded: false)
                }
                throw error
            }
        }
    }
}
