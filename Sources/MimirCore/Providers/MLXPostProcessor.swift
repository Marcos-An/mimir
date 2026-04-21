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
        try await polish(transcript, onChunk: { _ in })
    }

    public func polish(
        _ transcript: String,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return transcript }

        let container = try await ensureLoaded()
        let session = ChatSession(
            container,
            instructions: Self.systemPrompt(for: style),
            generateParameters: Self.makeGenerateParameters(inputCharCount: normalizedTranscript.count)
        )

        var accumulated = ""
        var tokensSinceLastEmit = 0
        let emitEveryNTokens = 6
        let stream = session.streamResponse(to: Self.userPrompt(for: normalizedTranscript, style: style))
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
        if Self.looksLikeForeignScript(cleaned) && !Self.looksLikeForeignScript(normalizedTranscript) {
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

    static func userPrompt(for transcript: String, style: PostProcessingStyle) -> String {
        let taskLine: String = switch style {
        case .disabled:
            "If there is nothing to adjust, return the transcription exactly as you received it."
        case .cleanup:
            "Do only a conservative review of the transcription below, following the system rules."
        case .structured:
            "Format the dictation transcription below following the system rules."
        }

        return """
        \(taskLine)
        Reply only with the final text.

        Transcription:
        \(transcript)
        """
    }

    static func systemPrompt(for style: PostProcessingStyle) -> String {
        switch style {
        case .disabled, .cleanup:
            return cleanupPrompt
        case .structured:
            return structuredPrompt
        }
    }

    private static let cleanupPrompt = """
    Dictation transcription reviewer. Output: only the final text, no quotes or comments.
    Language: same as input, same variant, same alphabet. Do not translate.
    Fidelity: preserve words, facts, names, numbers, URLs, code. Do not invent, do not complete, do not summarize, do not reorganize.
    Fix only: spelling, diacritics, capitalization, punctuation. Remove only hesitations ("uh", "um") and obvious accidental repetitions.
    """

    private static let structuredPrompt = """
    Dictation transcription formatter. Improve readability without changing content. Output: only the final text, no quotes or comments.
    Language: same as input, same variant, same alphabet. Do not translate.
    Fidelity: preserve words, facts, names, numbers, URLs, code. Do not invent, do not complete thoughts, do not summarize, do not rephrase.
    Do: spelling, diacritics, capitalization, punctuation, sentence/paragraph breaks when obvious. Bulleted lists only when the dictation clearly enumerates. Flowing text otherwise.
    Don't: headings, sections, summaries, conclusions. Do not reorganize into topics. When in doubt, minimum intervention.
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
