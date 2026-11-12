import Foundation
import os.log

/// Pós-processador via API da Anthropic (Claude Haiku). Substitui o MLX local
/// no papel de "polish": mesma interface, mesmos prompts, ~1–2s por ditado em
/// vez de 6–28s, sem ocupar RAM/GPU da máquina.
///
/// Privacidade: o ÁUDIO nunca sai da máquina (Whisper continua local); apenas
/// o texto transcrito é enviado.
///
/// Falha de rede/chave/timeout NUNCA quebra o ditado: devolve o transcript
/// original e o pipeline segue com a limpeza determinística.
public actor AnthropicPostProcessor: WarmableTextPostProcessing {
    public static let defaultModelID = "claude-haiku-5-5"
    /// Conta no Keychain (service `KeychainStore.service`) onde a API key vive.
    public static let apiKeyAccount = "anthropic-api-key"

    private let modelID: String
    private let style: PostProcessingStyle
    private let customVocabulary: String
    private let session: URLSession
    private let logger = Logger(subsystem: "dev.mimir.app", category: "AnthropicPostProcessor")
    /// Chave cacheada por processo: o Keychain pode exibir diálogo de permissão,
    /// e ler a cada polish bloquearia a cadeia de segmentos atrás de UI modal
    /// (medido: post de 1–2s virava 8–13s). Lemos uma vez — idealmente no
    /// `preload()`, que roda no início da gravação, escondendo qualquer prompt
    /// atrás do tempo de fala.
    private var cachedAPIKey: String?

    public init(
        modelID: String = AnthropicPostProcessor.defaultModelID,
        style: PostProcessingStyle = .cleanDictation,
        customVocabulary: String = ""
    ) {
        self.modelID = modelID
        self.style = style
        self.customVocabulary = customVocabulary
        let configuration = URLSessionConfiguration.ephemeral
        // Ditado é interativo: melhor desistir cedo (e retentar numa conexão
        // nova, ver requestCompletion) do que segurar o paste atrás de um
        // socket morto — pool ocioso por horas foi medido custando 13s.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 25
        self.session = URLSession(configuration: configuration)
    }

    /// Chamado quando a gravação começa. Sem modelo local para aquecer, mas:
    /// 1. resolve a API key (Keychain + eventual prompt) durante a fala;
    /// 2. revive a conexão TLS/HTTP2 com a API — depois de horas ocioso o pool
    ///    guarda uma conexão morta, e o primeiro POST nela fica preso em
    ///    retransmissão TCP (medido: 13s num polish que normalmente leva 2s).
    ///    Um HEAD barato força a reabertura enquanto o usuário ainda fala.
    public func preload() async {
        _ = resolveAndCacheAPIKey()
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    public func polish(_ transcript: String) async throws -> String {
        try await polish(transcript, intent: .defaults, onChunk: { _ in })
    }

    public func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        try await polish(transcript, intent: intent, onChunk: { _ in })
    }

    public func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return transcript }

        guard let apiKey = resolveAndCacheAPIKey() else {
            logger.warning("Sem API key (Keychain \(Self.apiKeyAccount, privacy: .public) ou ANTHROPIC_API_KEY); devolvendo transcript cru.")
            return transcript
        }

        let response: String
        do {
            response = try await requestCompletion(for: normalized, intent: intent, apiKey: apiKey)
        } catch {
            logger.error("Falha na chamada à API: \(error.localizedDescription, privacy: .public); devolvendo transcript cru.")
            return transcript
        }

        let cleaned = MLXPostProcessor.cleanOutput(response)
        guard !cleaned.isEmpty else { return transcript }

        // Só tradução pode trocar de idioma/alfabeto — mesmo guard do MLX.
        let allowsLanguageChange: Bool
        if case .translateTo = intent { allowsLanguageChange = true } else { allowsLanguageChange = false }
        if !allowsLanguageChange,
           MLXPostProcessor.looksLikeForeignScript(cleaned),
           !MLXPostProcessor.looksLikeForeignScript(normalized) {
            return transcript
        }

        await onChunk(cleaned)
        return cleaned
    }

    private func resolveAndCacheAPIKey() -> String? {
        if let cachedAPIKey { return cachedAPIKey }
        guard let key = Self.resolveAPIKey() else { return nil }
        cachedAPIKey = key
        return key
    }

    /// Keychain primeiro; env var como escape hatch de desenvolvimento.
    static func resolveAPIKey() -> String? {
        if let key = KeychainStore.read(account: apiKeyAccount) { return key }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func requestCompletion(
        for transcript: String,
        intent: PolishIntent,
        apiKey: String
    ) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Mesma heurística de teto do MLX: ~0.35 tok/char em pt-BR, 1.5× de folga.
        let approxInputTokens = max(100, Int(Double(transcript.count) * 0.35))
        let maxTokens = min(8192, max(300, Int(Double(approxInputTokens) * 1.5)))

        var body: [String: Any] = [
            "model": modelID,
            "max_tokens": maxTokens,
            "system": MLXPostProcessor.systemPrompt(for: intent, fallbackStyle: style, customVocabulary: customVocabulary),
            "messages": [
                [
                    "role": "user",
                    "content": MLXPostProcessor.userPrompt(for: transcript, intent: intent, fallbackStyle: style)
                ]
            ]
        ]
        if modelID.hasPrefix("claude-haiku-4") {
            // Edição de ditado é tarefa de fidelidade, não de criatividade:
            // temperature 1 (default) fazia o modelo "melhorar" o texto com
            // estrutura e requisitos que o usuário não ditou.
            body["temperature"] = 0
        } else {
            // Haiku 5.5 rejects non-default sampling values and thinks by
            // default; cleanup needs no reasoning, and thinking only adds
            // latency before the first word.
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let error as URLError
            where error.code == .timedOut
                || error.code == .networkConnectionLost
                || error.code == .cannotConnectToHost {
            // Socket morto do pool: a segunda tentativa abre conexão nova e
            // tipicamente resolve em ~1,5s. Uma única retentativa — se a rede
            // está fora de verdade, o chamador cai no texto cru.
            logger.warning("Retentando após \(error.code.rawValue, privacy: .public) (conexão possivelmente morta no pool).")
            (data, urlResponse) = try await session.data(for: request)
        }
        guard let http = urlResponse as? HTTPURLResponse else {
            throw MimirError.postProcessingFailed("resposta não-HTTP")
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw MimirError.postProcessingFailed("HTTP \(http.statusCode): \(snippet)")
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]]
        else {
            throw MimirError.postProcessingFailed("payload inesperado")
        }
        // A declined request comes back as HTTP 200; the caller then pastes
        // the transcript as dictated.
        if (json["stop_reason"] as? String) == "refusal" {
            throw MimirError.postProcessingFailed("refusal")
        }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else {
            throw MimirError.postProcessingFailed("resposta sem blocos de texto")
        }
        return text
    }
}
