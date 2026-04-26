import Foundation
import Testing
@testable import MimirCore

@Test("Router leaves unprefixed text untouched")
func routerPassesThroughWhenNoTrigger() {
    let routed = CommandPrefixRouter.route("olha, preciso resolver isso agora")
    #expect(routed.intent == .defaults)
    #expect(routed.text == "olha, preciso resolver isso agora")
}

@Test("Router detects prompt trigger and strips it")
func routerDetectsPromptTrigger() {
    let routed = CommandPrefixRouter.route("prompt me ajuda a revisar esse PR")
    #expect(routed.intent == .promptEngineer)
    #expect(routed.text == "me ajuda a revisar esse PR")
}

@Test("Router detects prompt with comma separator that Whisper produces")
func routerHandlesPunctuationAfterTrigger() {
    let routed = CommandPrefixRouter.route("Prompt, olha só o que eu preciso")
    #expect(routed.intent == .promptEngineer)
    #expect(routed.text == "olha só o que eu preciso")
}

@Test("Router detects translate trigger in Portuguese")
func routerDetectsTraduzirTrigger() {
    let routed = CommandPrefixRouter.route("traduzir: vou precisar disso para hoje")
    #expect(routed.intent == .translateToEnglish)
    #expect(routed.text == "vou precisar disso para hoje")
}

@Test("Router detects translate trigger in English")
func routerDetectsTranslateTrigger() {
    let routed = CommandPrefixRouter.route("Translate. I need this done today.")
    #expect(routed.intent == .translateToEnglish)
    #expect(routed.text == "I need this done today.")
}

@Test("Router only fires on first word")
func routerIgnoresTriggerNotAtStart() {
    let routed = CommandPrefixRouter.route("eu preciso de um prompt melhor pro Claude")
    #expect(routed.intent == .defaults)
    #expect(routed.text == "eu preciso de um prompt melhor pro Claude")
}

@Test("Router returns defaults when trigger has no content after it")
func routerIgnoresTriggerAlone() {
    let routed = CommandPrefixRouter.route("prompt")
    #expect(routed.intent == .defaults)
    #expect(routed.text == "prompt")
}

@Test("Router preserves original on empty input")
func routerHandlesEmptyInput() {
    let routed = CommandPrefixRouter.route("   ")
    #expect(routed.intent == .defaults)
    #expect(routed.text == "   ")
}
