import Foundation

/// Minimal Messages API client shared by dictation cleanup and the writing
/// check. Raw HTTP on purpose: Swift has no official Anthropic SDK.
public struct AnthropicClient: Sendable {
    public struct Message: Sendable {
        public let role: String
        public let content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case http(status: Int, snippet: String)
        case refusal
        case badPayload
        case emptyText
        case transport(URLError.Code)
        /// The account has no credit left (billing). Every call fails until
        /// credits are added in the Anthropic console.
        case outOfCredits
    }

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private let session: URLSession

    public init(session: URLSession) {
        self.session = session
    }

    /// One completion. `retries` re-sends only after a dead connection
    /// (timeout, lost connection, cannot connect) — never after an HTTP error,
    /// which the server may already have billed.
    public func complete(
        apiKey: String,
        model: String,
        system: String,
        messages: [Message],
        maxTokens: Int,
        retries: Int
    ) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] }
        ]
        if model.hasPrefix("claude-haiku-4") {
            // Fidelity task: the default temperature made the model "improve"
            // text with things the user never said.
            body["temperature"] = 0
        } else {
            // Haiku 5.5 rejects non-default sampling values and thinks by
            // default; these tasks need no reasoning, and thinking only adds
            // latency before the first word.
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attemptsLeft = retries
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                do {
                    let text = try Self.text(from: data, response: response)
                    AnthropicAccountStatus.shared.setOutOfCredits(false)
                    return text
                } catch Failure.outOfCredits {
                    AnthropicAccountStatus.shared.setOutOfCredits(true)
                    throw Failure.outOfCredits
                }
            } catch let error as URLError
                where attemptsLeft > 0
                    && (error.code == .timedOut
                        || error.code == .networkConnectionLost
                        || error.code == .cannotConnectToHost) {
                attemptsLeft -= 1
            } catch let error as URLError {
                throw Failure.transport(error.code)
            }
        }
    }

    static func text(from data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw Failure.badPayload }
        guard http.statusCode == 200 else {
            if isOutOfCredits(status: http.statusCode, body: data) { throw Failure.outOfCredits }
            throw Failure.http(status: http.statusCode, snippet: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { throw Failure.badPayload }
        // A declined request comes back as HTTP 200.
        if (json["stop_reason"] as? String) == "refusal" { throw Failure.refusal }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw Failure.emptyText }
        return text
    }
}

extension AnthropicClient {
    /// Billing errors: HTTP 402, an error of type `billing_error`, or the
    /// "credit balance is too low" 400 the API sends when credits run out.
    static func isOutOfCredits(status: Int, body: Data) -> Bool {
        if status == 402 { return true }
        guard status == 400 || status == 403,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return false }
        if (error["type"] as? String) == "billing_error" { return true }
        let message = ((error["message"] as? String) ?? "").lowercased()
        return message.contains("credit balance")
    }
}

/// Whether the last Claude call failed for lack of credits. Shared by the
/// dictation cleanup and the writing check, so the app can tell the user
/// (both fail quietly otherwise: dictation pastes the raw text).
public final class AnthropicAccountStatus: @unchecked Sendable {
    public static let shared = AnthropicAccountStatus()
    public static let didChange = Notification.Name("AnthropicAccountStatusDidChange")

    private let lock = NSLock()
    private var outOfCredits = false

    public init() {}

    public var isOutOfCredits: Bool { lock.withLock { outOfCredits } }

    public func setOutOfCredits(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            guard outOfCredits != value else { return false }
            outOfCredits = value
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

/// The Anthropic key, read once and kept in memory. Reading the Keychain can
/// show a permission dialog and stall the caller, so typing ticks must never
/// touch it; Settings calls `reload()` after saving or deleting the key.
public final class AnthropicKeyStore: @unchecked Sendable {
    public static let shared = AnthropicKeyStore()

    private let lock = NSLock()
    private var cached: String??
    private let read: @Sendable () -> String?

    public init(read: @escaping @Sendable () -> String? = { AnthropicPostProcessor.resolveAPIKey() }) {
        self.read = read
    }

    /// Cached value; nil until `load()` ran once. Never blocks on the Keychain.
    public var cachedKey: String? { lock.withLock { cached ?? nil } }

    public var isLoaded: Bool { lock.withLock { cached != nil } }

    /// Reads the Keychain if needed. Call off the main thread.
    @discardableResult
    public func load() -> String? {
        if let cached = lock.withLock({ cached }) { return cached }
        let value = read()
        lock.withLock { cached = .some(value) }
        return value
    }

    public func invalidate() {
        lock.withLock { cached = nil }
    }

    /// Re-reads the key after Settings saved or removed it. The old value
    /// stays readable until the new one replaces it. Call off the main thread.
    @discardableResult
    public func reload() -> String? {
        let value = read()
        lock.withLock { cached = .some(value) }
        return value
    }
}
