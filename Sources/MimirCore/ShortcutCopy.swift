import Foundation

public func keyBindingDisplayString(_ binding: KeyBinding) -> String {
    binding.keyCaps.joined()
}

public func recorderSubtitle(binding: KeyBinding?) -> String {
    guard let binding else {
        return "No shortcut set — click to record."
    }
    return "Current: \(keyBindingDisplayString(binding)) · click to change."
}

public func activationSubtitle(mode: ActivationMode, binding: KeyBinding) -> String {
    let shortcut = keyBindingDisplayString(binding)
    switch mode {
    case .holdToTalk:
        return "Hold \(shortcut) while you speak; release to insert the transcription."
    case .tapToToggle:
        return "Tap \(shortcut) to start; tap again to stop and insert."
    }
}
