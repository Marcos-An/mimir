import Testing
@testable import MimirCore

@Test("Whisper prompt puts the glossary first and the previous context last")
func whisperPromptOrdersGlossaryThenContext() {
    let prompt = WhisperKitProvider.promptText(
        vocabulary: "Supabase\n  WhisperKit  \n\nNatemans",
        previousContext: "  e depois a gente sobe o deploy.  "
    )
    #expect(prompt == "Supabase, WhisperKit, Natemans. e depois a gente sobe o deploy.")
}

@Test("Whisper prompt is nil without vocabulary or context")
func whisperPromptIsNilWhenEmpty() {
    #expect(WhisperKitProvider.promptText(vocabulary: " \n ", previousContext: nil) == nil)
    #expect(WhisperKitProvider.promptText(vocabulary: "", previousContext: "   ") == nil)
}

@Test("Whisper prompt caps the glossary size")
func whisperPromptCapsGlossary() {
    let vocabulary = (1...200).map { "term\($0)" }.joined(separator: "\n")
    let prompt = WhisperKitProvider.promptText(vocabulary: vocabulary, previousContext: nil)
    #expect(prompt?.components(separatedBy: ", ").count == WhisperKitProvider.maxPromptVocabularyTerms)
}

@Test("End-of-text is only blocked while the prompt is still being fed")
func prefillFilterOnlyActsDuringPromptPrefill() {
    let prev = 50362, sot = 50258
    func prefilling(_ tokens: [Int]) -> Bool {
        WhisperKitProvider.PromptPrefillEndTokenFilter.isStillPrefilling(
            tokens, startOfPreviousToken: prev, startOfTranscriptToken: sot
        )
    }
    let initialPrompt = [prev, 30644, 11, sot, 50267, 50360, 50365]
    #expect(prefilling(initialPrompt))
    // Um token gerado: o modelo já pode encerrar.
    #expect(prefilling(initialPrompt + [6001]) == false)
    // Sem prompt o filtro não age.
    #expect(prefilling([sot, 50267, 50360, 50365]) == false)
}

@Test("Language candidates are the system languages plus English")
func languageCandidatesFollowSystemLanguages() {
    #expect(WhisperKitProvider.candidateLanguages(preferred: ["pt-BR"]) == ["pt", "en"])
    #expect(WhisperKitProvider.candidateLanguages(preferred: ["en-US", "pt-BR"]) == ["pt", "en"])
    // Nenhum idioma de sistema reconhecido: vale a allowlist inteira.
    #expect(WhisperKitProvider.candidateLanguages(preferred: ["ja-JP"]).contains("es"))
}

@Test("Language detection only picks among the candidates")
func languageDetectionIgnoresNonCandidates() {
    let probabilities: [String: Float] = ["es": -0.2, "pt": -0.9, "en": -3.0, "ja": -0.1]
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: probabilities, candidates: ["pt", "en"]) == "pt")
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: probabilities, candidates: ["de"]) == nil)
}

@Test("Language detection keeps the Mac's language unless another is clearly ahead")
func languageDetectionFavoursSystemLanguage() {
    // Close call (English barely ahead): stay in Portuguese.
    let close: [String: Float] = ["en": -0.6, "pt": -1.1]
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: close, candidates: ["pt", "en"], favoured: "pt") == "pt")
    // English far ahead (real English dictation): switch.
    let clear: [String: Float] = ["en": -0.05, "pt": -4.0]
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: clear, candidates: ["pt", "en"], favoured: "pt") == "en")
    // No favoured language: plain maximum.
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: close, candidates: ["pt", "en"]) == "en")
    // WhisperKit often reports only the winner: unsure English → Portuguese,
    // confident English → English.
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: ["en": -0.9], candidates: ["pt", "en"], favoured: "pt") == "pt")
    #expect(WhisperKitProvider.bestLanguage(logProbabilities: ["en": -0.05], candidates: ["pt", "en"], favoured: "pt") == "en")
}

@Test("Sound tags between asterisks are removed from the transcript")
func asteriskSoundTagsAreRemoved() {
    let raw = "*crash* *repeat* É, agora sim. *sos* Mas relativamente curto *sos*"
    #expect(WhisperKitProvider.cleanSpecialTokens(raw) == "É, agora sim. Mas relativamente curto")
}
