import Foundation
import Testing
@testable import MimirCore

@Test("Strips hallucinated 'obrigado' appended after real content")
func stripsAppendedObrigado() {
    let input = "Vou ao mercado depois da reunião. Obrigado."
    #expect(WhisperKitProvider.stripTailFarewells(input) == "Vou ao mercado depois da reunião.")
}

@Test("Strips hallucinated 'thanks for watching'")
func stripsThanksForWatching() {
    let input = "Ok so this is the plan for tomorrow. Thanks for watching."
    #expect(WhisperKitProvider.stripTailFarewells(input) == "Ok so this is the plan for tomorrow.")
}

@Test("Preserves standalone farewell (could be a real short message)")
func preservesStandaloneFarewell() {
    #expect(WhisperKitProvider.stripTailFarewells("Obrigado.") == "Obrigado.")
    #expect(WhisperKitProvider.stripTailFarewells("thanks") == "thanks")
}

@Test("Does not strip when tail sentence is long — not a hallucination signature")
func keepsLongTailSentence() {
    let input = "Vou almoçar. Obrigado por me avisar do horário."
    #expect(WhisperKitProvider.stripTailFarewells(input) == input)
}

@Test("Strips Portuguese full farewell phrase")
func stripsFullFarewellPhrase() {
    let input = "Essa foi a reunião de hoje. Obrigado pela atenção."
    #expect(WhisperKitProvider.stripTailFarewells(input) == "Essa foi a reunião de hoje.")
}

@Test("Handles text without terminal punctuation")
func handlesNoTerminatorEdgeCase() {
    // No sentence terminator — entire input becomes the tail. Since stripping
    // would leave nothing, input is preserved.
    #expect(WhisperKitProvider.stripTailFarewells("obrigado") == "obrigado")
}
