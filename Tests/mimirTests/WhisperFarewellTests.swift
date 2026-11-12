import Foundation
import Testing
@testable import MimirCore

// O filtro de farewell existe para remover artefatos do treino do Whisper em
// vídeos de YouTube ("thanks for watching", "legendas pela equipe"). Ele NÃO
// pode remover despedidas que um usuário real dita no fim de uma mensagem —
// "obrigado", "valeu", "tchau", "amém" são conteúdo legítimo em pt-BR.

@Test("Preserves dictated 'obrigado' at the end of a real message")
func preservesDictatedObrigado() {
    let input = "Vou ao mercado depois da reunião. Obrigado."
    #expect(WhisperKitProvider.stripTailFarewells(input) == input)
}

@Test("Preserves dictated casual and religious closings")
func preservesDictatedCasualClosings() {
    let cases = [
        "Consegui ajustar o layout. Muito obrigado.",
        "Vamos recalcular os dias pendentes. Amém.",
        "Ajusta o endpoint de staging. Até a próxima.",
        "Confere o fetch da próxima página. Falou.",
        "Essa foi a reunião de hoje. Obrigado pela atenção.",
        "We should review the branch diff. Thanks.",
        "I'll send the PR today. Bye."
    ]
    for input in cases {
        #expect(WhisperKitProvider.stripTailFarewells(input) == input)
    }
}

@Test("Strips hallucinated 'thanks for watching'")
func stripsThanksForWatching() {
    let input = "Ok so this is the plan for tomorrow. Thanks for watching."
    #expect(WhisperKitProvider.stripTailFarewells(input) == "Ok so this is the plan for tomorrow.")
}

@Test("Strips unmistakable YouTube-artifact closings in Portuguese")
func stripsYouTubeArtifactClosingsInPortuguese() {
    #expect(
        WhisperKitProvider.stripTailFarewells("Refatora o worker da fila. Obrigado por assistir.")
            == "Refatora o worker da fila."
    )
    #expect(
        WhisperKitProvider.stripTailFarewells("Sobe a migration antes do deploy. Até o próximo vídeo.")
            == "Sobe a migration antes do deploy."
    )
    #expect(
        WhisperKitProvider.stripTailFarewells("Revisa o diff comigo. Legendas pela equipe.")
            == "Revisa o diff comigo."
    )
}

@Test("Preserves standalone farewell (could be a real short message)")
func preservesStandaloneFarewell() {
    #expect(WhisperKitProvider.stripTailFarewells("Obrigado por assistir.") == "Obrigado por assistir.")
    #expect(WhisperKitProvider.stripTailFarewells("thanks for watching") == "thanks for watching")
}

@Test("Does not strip when tail sentence is long — not a hallucination signature")
func keepsLongTailSentence() {
    let input = "Vou almoçar. Obrigado por assistir a demo que gravei ontem com o time inteiro."
    #expect(WhisperKitProvider.stripTailFarewells(input) == input)
}

@Test("Handles text without terminal punctuation")
func handlesNoTerminatorEdgeCase() {
    #expect(WhisperKitProvider.stripTailFarewells("obrigado por assistir") == "obrigado por assistir")
    #expect(WhisperKitProvider.stripTailFarewells("amém") == "amém")
}
