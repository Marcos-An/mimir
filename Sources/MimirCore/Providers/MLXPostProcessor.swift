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
        return """

        User's personal vocabulary (people, projects, product names — verbatim spelling):
        \(terms.joined(separator: ", "))
        When a garbled or phonetically-transcribed word plausibly matches one of these terms, restore the term exactly as written above. Do not force a match where the speech clearly means something else.
        """
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
    Goal: make the dictation clean, punctuated, and readable without changing the user's meaning, voice, or sequence of thought.
    Language: same language, same variant, same alphabet. Do not translate.
    Preserve: intent, facts, and the original order of ideas, names, numbers, URLs, commands, code, acronyms, and technical terms.
    Technical vocabulary (preserve verbatim — keep English spelling, never localize to Portuguese):
    - Programming: Swift, SwiftUI, React, React Native, TypeScript, JavaScript, Node, Python, Xcode, Cursor.
    - Git/CI: branch, commit, diff, pull request, PR, merge, rebase, staging, deploy, rollback, Bitbucket, GitHub, Playwright, CI, CD.
    - Web/UI/CSS: frontend, front-end, backend, back-end, fullstack, component, hook, state, props, view, render, layout, padding, margin, border, button, modal, tooltip, popover, scroll, flex, grid, gap, viewport, breakpoint, responsive, dark mode, theme, token.
    - Backend/data: API, REST, GraphQL, URL, endpoint, fetch, debounce, throttle, worker, queue, job, migration, schema, query, mutation, cache, redis, postgres, sqlite, index, foreign key, lock, deadlock, serverless, lambda, bucket.
    - Stack: MCP, Obsidian, Mimir, Claude, Haiku, Sonnet, Opus, Qwen, WhisperKit, Whisper, MLX, Keychain, API key, LLM, Anthropic, OpenAI.
    When the user dictates one of these terms in English mid-sentence (Portuguese ↔ English code-switching), write it in English exactly. Do NOT replace with a Portuguese near-homophone (e.g. "padding" must NOT become "pede"; "worker" must NOT become "uorker"; "button" stays "button").
    If a technical term sounds garbled in the raw transcription but the most plausible reading is one of the terms above, restore it (e.g. "Hiroko"/"Raikou" near LLM talk are almost certainly "Haiku"/"Claude").
    Do not normalize unfamiliar technical terms into everyday words — a term you don't recognize is more likely a product, library, or project name than a misheard common word; keep it verbatim.
    Whisper hallucinates short closings ("Obrigado.", "Tchau.", "Valeu.") at pauses — artifacts of its training on video captions. Remove a standalone closing like these when it interrupts the flow mid-text or dangles after a complete request with no addressee; keep it when the speaker is genuinely signing off a message to someone.
    Improve only punctuation, diacritics, capitalization, agreement, sentence boundaries, and paragraph breaks when helpful.
    If the dictation is rambling, fragmented, or self-correcting, preserve that content and order; preserve the original order even when the result remains a bit messy. Do not infer a cleaner plan or rewrite it into a different idea.
    Remove only obvious filler hesitations, exact accidental repetitions, and pause artifacts such as repeated ellipses.
    If a pause was transcribed as something like "... E ..." and the "E" adds no meaning, remove that pause marker.
    Do not summarize, compress, invent details, complete unfinished thoughts, add context, reorganize, or change the argument.
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

    private static let promptEngineerPrompt = """
    Dictation editor. The user dictated a message they will paste into an LLM chat (Claude, GPT, Gemini, etc.). Clean it into the message they meant to write. Output: only the final text, no quotes, no meta-commentary, no explanation of changes.
    Language: same as the dictation input, same variant, same alphabet. Do not translate. If the dictation is in Portuguese, write the final text in Portuguese; if it is in English, write it in English. Whisper sometimes mistranscribes stretches of speech into the wrong language mid-dictation: when the transcription mixes languages, write the whole output in the language carrying most of the content (count the words), and translate the stray-language sentences back into it. An opening interjection or swear in another language ("What the fuck?", "shit") does NOT decide the language — keep it verbatim where it is and write the rest in the dominant language. The same goes for code-switched technical terms, which stay in English inside Portuguese text.
    Keep the user's voice: first person, addressed to the assistant, same tone. Not every dictation is a task — it may be a question, an opinion, feedback, or context. Do NOT recast it as a role description ("You are an assistant…"), a spec, a numbered task list, or headings. Use bullet points or numbering ONLY when the dictation itself clearly enumerates items.
    Preserve the user's meaning and order of ideas. Preserve entities verbatim: proper nouns, personal names, numbers, dates, URLs, filenames, code symbols, commands, technical terms, acronyms.
    This is dictation, not writing: it always needs real editing. Always remove speech disfluencies — hesitations ("é...", "tipo", "assim", "uh"), conversational tics that carry no information ("né?", "sabe?", "então" as sentence padding, "pra falar a verdade" when it is mere throat-clearing), false starts, abandoned fragments, and exact repetitions. Merge restatements of the same point into the single clearest sentence, and join choppy fragments into fluent ones. The result should read like the user wrote it deliberately, not like a transcript.
    Whisper hallucinates short closings ("Obrigado.", "Tchau.", "Valeu.", "Thanks.") at pauses — artifacts of its training on video captions, never spoken on purpose here. Delete them, whether they land mid-text or at the end.
    Whisper also mangles technical terms and proper nouns phonetically. When context makes the intended term clear, restore it (e.g. "gitpun na mei" → "git pull na main"; "essa brand" in a branch discussion → "essa branch").
    Editing is about how it reads, never about what survives: never drop a statement the user actually made, even when it is emphatic, blunt, profane, an aside, or sounds redundant next to the rest. Keep emphasis and profanity as spoken. Cut only disfluencies, tics, false starts, exact repetitions, and hallucinated closings.
    Every sentence in the output must trace to something the user said — do not add requirements, formats, examples, context, or constraints the user did not mention.
    Do not answer the prompt.
    """

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
