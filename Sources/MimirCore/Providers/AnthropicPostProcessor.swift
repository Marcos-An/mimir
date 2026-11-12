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
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        modelID: String = AnthropicPostProcessor.defaultModelID,
        style: PostProcessingStyle = .cleanDictation,
        customVocabulary: String = ""
    ) {
        self.init(modelID: modelID, style: style, customVocabulary: customVocabulary, session: nil, apiKeyProvider: { Self.resolveAPIKey() })
    }

    /// Tests inject a stubbed session and a fixed key (never the Keychain).
    init(
        modelID: String = AnthropicPostProcessor.defaultModelID,
        style: PostProcessingStyle = .cleanDictation,
        customVocabulary: String = "",
        session: URLSession?,
        apiKeyProvider: @escaping @Sendable () -> String?
    ) {
        self.modelID = modelID
        self.style = style
        self.customVocabulary = customVocabulary
        self.apiKeyProvider = apiKeyProvider
        if let session {
            self.session = session
            return
        }
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
        guard let key = apiKeyProvider() else { return nil }
        cachedAPIKey = key
        return key
    }

    /// Keychain primeiro; env var como escape hatch de desenvolvimento.
    public static func resolveAPIKey() -> String? {
        AnthropicAPIKey.resolve()
    }

    private func requestCompletion(
        for transcript: String,
        intent: PolishIntent,
        apiKey: String
    ) async throws -> String {
        // Mesma heurística de teto do MLX: ~0.35 tok/char em pt-BR, 1.5× de folga.
        let approxInputTokens = max(100, Int(Double(transcript.count) * 0.35))
        let maxTokens = min(8192, max(300, Int(Double(approxInputTokens) * 1.5)))
        do {
            // One retry after a dead pooled socket: a fresh connection usually
            // answers in ~1.5 s. If the network is really down, the caller
            // pastes the transcript as dictated.
            return try await AnthropicClient(session: session).complete(
                apiKey: apiKey,
                model: modelID,
                system: MLXPostProcessor.systemPrompt(for: intent, fallbackStyle: style, customVocabulary: customVocabulary),
                messages: [.init(role: "user", content: MLXPostProcessor.userPrompt(for: transcript, intent: intent, fallbackStyle: style))],
                maxTokens: maxTokens,
                retries: 1
            )
        } catch let failure as AnthropicClient.Failure {
            throw MimirError.postProcessingFailed("\(failure)")
        }
    }
}
