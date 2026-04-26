import Foundation

/// Envia o texto transcrito para a ilha do Hermes via callback in-process,
/// quando algum integrador externo precisar rotear ditado para o REPL embutido.
public struct HermesHandoffInserter: TextInserting {
    public typealias Handoff = @Sendable (String) async throws -> Void

    private let handoff: Handoff

    public init(handoff: @escaping Handoff) {
        self.handoff = handoff
    }

    public func insert(_ text: String) async throws {
        // Normalização: newlines viram espaço para não submeter prematuramente,
        // e o payload termina em \r (carriage return = Enter real do teclado,
        // o que REPLs com readline — como o Hermes — esperam para submit).
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        let payload = cleaned.hasSuffix("\r") ? cleaned : cleaned + "\r"
        try await handoff(payload)
    }
}
