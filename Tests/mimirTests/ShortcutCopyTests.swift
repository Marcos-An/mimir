import Foundation
import Testing
@testable import MimirCore

@Test("keyBindingDisplayString formats modifier + key combo")
func keyBindingDisplayStringFormatsCombo() {
    let binding = KeyBinding(keyCode: 2, modifiers: (1 << 17) | (1 << 19), label: "D")
    #expect(keyBindingDisplayString(binding) == "⌥⇧D")
}

@Test("keyBindingDisplayString returns label for modifier-only bindings")
func keyBindingDisplayStringModifierOnly() {
    let binding = KeyBinding.defaultRightCommand
    #expect(keyBindingDisplayString(binding) == "Right ⌘")
}

@Test("activationSubtitle describes hold-to-talk with binding")
func activationSubtitleHoldToTalk() {
    let binding = KeyBinding(keyCode: 2, modifiers: (1 << 17) | (1 << 19), label: "D")
    #expect(
        activationSubtitle(mode: .holdToTalk, binding: binding)
            == "Hold ⌥⇧D while you speak; release to insert the transcription."
    )
}

@Test("activationSubtitle describes tap-to-toggle with binding")
func activationSubtitleTapToToggle() {
    let binding = KeyBinding(keyCode: 2, modifiers: (1 << 17) | (1 << 19), label: "D")
    #expect(
        activationSubtitle(mode: .tapToToggle, binding: binding)
            == "Tap ⌥⇧D to start; tap again to stop and insert."
    )
}

@Test("recorderSubtitle handles missing binding")
func recorderSubtitleNoBinding() {
    #expect(recorderSubtitle(binding: nil) == "No shortcut set — click to record.")
}

@Test("recorderSubtitle includes current binding when present")
func recorderSubtitleWithBinding() {
    let binding = KeyBinding(keyCode: 2, modifiers: (1 << 17) | (1 << 19), label: "D")
    #expect(recorderSubtitle(binding: binding) == "Current: ⌥⇧D · click to change.")
}
