import Foundation

public func keyBindingDisplayString(_ binding: KeyBinding) -> String {
    binding.keyCaps.joined()
}

public func recorderSubtitle(binding: KeyBinding?) -> String {
    guard let binding else {
        return "Nenhum atalho definido — clique para gravar."
    }
    return "Atual: \(keyBindingDisplayString(binding)) · clique para alterar."
}

public func activationSubtitle(mode: ActivationMode, binding: KeyBinding) -> String {
    let shortcut = keyBindingDisplayString(binding)
    switch mode {
    case .holdToTalk:
        return "Mantenha \(shortcut) pressionado enquanto fala; ao soltar, a transcrição é inserida."
    case .tapToToggle:
        return "Toque \(shortcut) para iniciar; toque novamente para parar e inserir."
    }
}
