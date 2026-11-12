import Foundation
import Testing
@testable import MimirCore

// Casos extraídos do histórico real de ditados (com.mimir.history.v1):
// reticências de hesitação, fechos alucinados e minúscula pós-ponto eram os
// três defeitos mais frequentes que sobreviviam ao pós-processamento.

@Test("Pause ellipses before lowercase become a plain space")
func ellipsesBeforeLowercaseBecomeSpace() {
    let input = "Para limpar a minha fala. E... eu ter esse texto."
    #expect(DictationTextCleaner.clean(input) == "Para limpar a minha fala. E eu ter esse texto.")
}

@Test("Ellipses before uppercase close the sentence")
func ellipsesBeforeUppercaseCloseSentence() {
    let input = "Não tá legal... Ele não tá bom."
    #expect(DictationTextCleaner.clean(input) == "Não tá legal. Ele não tá bom.")
}

@Test("Trailing ellipses collapse to a single period")
func trailingEllipsesCollapse() {
    #expect(DictationTextCleaner.clean("The punctuation is not very correct. Is...") == "The punctuation is not very correct. Is.")
}

@Test("Ellipses after question mark keep only the question mark")
func ellipsesAfterQuestionMark() {
    #expect(DictationTextCleaner.clean("Transcrevi primeiro, não?... Passar por um LLM.") == "Transcrevi primeiro, não? Passar por um LLM.")
}

@Test("Unicode ellipsis character is treated like three dots")
func unicodeEllipsisHandled() {
    #expect(DictationTextCleaner.clean("Vou verificar… depois te falo.") == "Vou verificar depois te falo.")
}

@Test("Hallucinated Obrigado at the end is stripped")
func trailingObrigadoStripped() {
    let input = "Você pode verificar se esse é o caso? Obrigado."
    #expect(DictationTextCleaner.clean(input) == "Você pode verificar se esse é o caso?")
}

@Test("Hallucinated Tchau at the end is stripped")
func trailingTchauStripped() {
    let input = "Alinhado ao bottom do card e não no centro ou no topo. Tchau."
    #expect(DictationTextCleaner.clean(input) == "Alinhado ao bottom do card e não no centro ou no topo.")
}

@Test("Chained farewells are stripped in one pass")
func chainedFarewellsStripped() {
    let input = "Me manda o link do PR. Obrigado. Tchau."
    #expect(DictationTextCleaner.clean(input) == "Me manda o link do PR.")
}

@Test("A dictation that is only a farewell is preserved")
func farewellOnlyDictationPreserved() {
    #expect(DictationTextCleaner.clean("Obrigado!") == "Obrigado!")
}

@Test("A long final sentence containing thanks is not stripped")
func longSentenceWithThanksPreserved() {
    let input = "Fico no aguardo. Muito obrigado pela ajuda com o deploy de ontem."
    #expect(DictationTextCleaner.clean(input) == input)
}

@Test("Lowercase after sentence end is capitalized")
func lowercaseAfterPeriodCapitalized() {
    let input = "Está custando muito. tá demorando bastante."
    #expect(DictationTextCleaner.clean(input) == "Está custando muito. Tá demorando bastante.")
}

@Test("First letter of the text is capitalized")
func firstLetterCapitalized() {
    #expect(DictationTextCleaner.clean("bom dia, tudo bem?") == "Bom dia, tudo bem?")
}

@Test("Domains and versions are not capitalized")
func domainsNotCapitalized() {
    let input = "Sobe no site.com e roda a v1.2 do script."
    #expect(DictationTextCleaner.clean(input) == "Sobe no site.com e roda a v1.2 do script.")
}

@Test("Missing terminal punctuation is added")
func terminalPunctuationAdded() {
    #expect(DictationTextCleaner.clean("Me avisa quando terminar") == "Me avisa quando terminar.")
}

@Test("Whitespace before punctuation is removed")
func whitespaceBeforePunctuationRemoved() {
    #expect(DictationTextCleaner.clean("O meu CNPJ .") == "O meu CNPJ.")
}

@Test("Clean text passes through unchanged")
func cleanTextUnchanged() {
    let input = "Revisa o PR #516, por favor. A janela de approve é de 2 horas."
    #expect(DictationTextCleaner.clean(input) == input)
}
