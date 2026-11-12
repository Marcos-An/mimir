import Foundation
import Testing
@testable import MimirCore

/// Stubs every request of a URLSession built with `StubURLProtocol.session()`.
/// Requests are recorded; each answer comes from `responder` in order.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, String)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func session(replies: [Reply]) -> URLSession {
        lock.withLock {
            self.replies = replies
            recorded = []
            bodies = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }
    static var requestBodies: [Data] { lock.withLock { bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        } else if let httpBody = request.httpBody {
            body = httpBody
        }
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(request)
            Self.bodies.append(body)
            return Self.replies.isEmpty ? .http(500, "{}") : Self.replies.removeFirst()
        }
        switch reply {
        case .http(let status, let text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

let anthropicTextReply = #"{"content":[{"type":"text","text":"Texto limpo."}],"stop_reason":"end_turn"}"#

@Suite(.serialized)
struct AnthropicRequestTests {
    @Test("Dictation cleanup sends the same Messages API request as before")
    func polishRequestShape() async throws {
        let session = StubURLProtocol.session(replies: [.http(200, anthropicTextReply)])
        let processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        let result = try await processor.polish("texto ditado", intent: .defaults)
        #expect(result == "Texto limpo.")

        let request = try #require(StubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try #require(JSONSerialization.jsonObject(with: StubURLProtocol.requestBodies[0]) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(body["temperature"] == nil)
        #expect(body["max_tokens"] as? Int == 300)
        #expect((body["system"] as? String)?.isEmpty == false)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] == "user")
        #expect(messages[0]["content"]?.contains("texto ditado") == true)
    }

    @Test("Dictation cleanup retries once on a dead connection")
    func polishRetriesOnceOnTimeout() async throws {
        let session = StubURLProtocol.session(replies: [.failure(.timedOut), .http(200, anthropicTextReply)])
        let processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        #expect(try await processor.polish("texto ditado", intent: .defaults) == "Texto limpo.")
        #expect(StubURLProtocol.requests.count == 2)
    }

    @Test("Refusals and HTTP errors fall back to the dictated text")
    func polishFallsBackOnErrors() async throws {
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        var session = StubURLProtocol.session(replies: [.http(200, refusal)])
        var processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        #expect(try await processor.polish("texto ditado", intent: .defaults) == "texto ditado")

        session = StubURLProtocol.session(replies: [.http(401, "{}")])
        processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        #expect(try await processor.polish("texto ditado", intent: .defaults) == "texto ditado")
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("Out of credits is reported and cleared by the next call that works")
    func outOfCreditsIsReported() async throws {
        let lowBalance = #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API."}}"#
        var session = StubURLProtocol.session(replies: [.http(400, lowBalance)])
        var processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        #expect(try await processor.polish("texto ditado", intent: .defaults) == "texto ditado")
        #expect(AnthropicAccountStatus.shared.isOutOfCredits)

        session = StubURLProtocol.session(replies: [.http(200, anthropicTextReply)])
        processor = AnthropicPostProcessor(session: session, apiKeyProvider: { "test-key" })
        #expect(try await processor.polish("texto ditado", intent: .defaults) == "Texto limpo.")
        #expect(!AnthropicAccountStatus.shared.isOutOfCredits)
    }

    @Test("Billing errors are told apart from other client errors")
    func billingErrorDetection() {
        func body(_ type: String, _ message: String) -> Data {
            Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)
        }
        #expect(AnthropicClient.isOutOfCredits(status: 402, body: Data()))
        #expect(AnthropicClient.isOutOfCredits(status: 400, body: body("billing_error", "x")))
        #expect(AnthropicClient.isOutOfCredits(status: 400, body: body("invalid_request_error", "Your credit balance is too low")))
        #expect(!AnthropicClient.isOutOfCredits(status: 400, body: body("invalid_request_error", "max_tokens is too large")))
        #expect(!AnthropicClient.isOutOfCredits(status: 500, body: body("api_error", "credit balance")))
    }
}
