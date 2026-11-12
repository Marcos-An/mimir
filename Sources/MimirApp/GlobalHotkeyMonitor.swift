import AppKit
import MimirCore
import Observation

extension Notification.Name {
    static let keyBindingRecordingStarted = Notification.Name("mimir.keyBinding.recordingStarted")
    static let keyBindingRecordingStopped = Notification.Name("mimir.keyBinding.recordingStopped")
}

@MainActor
final class GlobalHotkeyMonitor {
    struct TriggerSpec: Equatable {
        var binding: KeyBinding
        var mode: DictationMode
    }

    private var triggers: [TriggerSpec]
    private var mode: ActivationMode
    private let model: MimirAppModel
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var globalKeyUpMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var activeTrigger: TriggerSpec?
    private var isPaused = false

    /// Se um trigger "prefixo" (modifier-only) dispara enquanto existe outro trigger
    /// mais específico que o contém como prefixo, esperamos esse intervalo
    /// antes de iniciar a gravação. Se o trigger específico chegar dentro da janela,
    /// roteamos para ele. Se não chegar, fire o prefixo normalmente.
    private static let prefixGraceNanoseconds: UInt64 = 150_000_000
    private var pendingPrefixTrigger: TriggerSpec?
    private var pendingStartTask: Task<Void, Never>?

    /// Durante a gravação, um tap de ⌥ sozinho (down→up sem outra tecla no
    /// meio) para a gravação e envia — espelho do Esc, que cancela. Armado no
    /// ⌥-down com sessão ativa; qualquer outra tecla ou modificador no meio
    /// (⌥Space, ⌥T…) desarma, porque aí o ⌥ era parte de um combo.
    private var pendingSendOnOptionRelease = false

    /// Consumes Esc while recording so it doesn't also hit the front app.
    private var escapeInterceptor: EscapeKeyInterceptor?

    init(
        dictationTrigger: KeyBinding,
        promptRewriteTrigger: KeyBinding,
        mode: ActivationMode,
        model: MimirAppModel
    ) {
        self.triggers = [
            TriggerSpec(binding: dictationTrigger, mode: .dictation),
            TriggerSpec(binding: promptRewriteTrigger, mode: .promptRewrite)
        ]
        self.mode = mode
        self.model = model
        start()
        observeRecording()
    }

    private func observeRecording() {
        NotificationCenter.default.addObserver(forName: .keyBindingRecordingStarted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        NotificationCenter.default.addObserver(forName: .keyBindingRecordingStopped, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
    }

    private func pause() {
        guard !isPaused else { return }
        cancelPendingPrefix()
        pendingSendOnOptionRelease = false
        if activeTrigger != nil && mode == .holdToTalk {
            Task { try? await model.stopDictation() }
        }
        activeTrigger = nil
        isPaused = true
        syncEscapeInterceptor()
    }

    private func resume() {
        isPaused = false
        syncEscapeInterceptor()
    }

    private func observePhase() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncEscapeInterceptor()
                self?.observePhase()
            }
        }
    }

    private func syncEscapeInterceptor() {
        escapeInterceptor?.setEnabled(model.phase == .recording && !isPaused)
    }

    func updateDictationTrigger(_ newTrigger: KeyBinding) {
        updateActivationTrigger(newTrigger, atMode: .dictation)
    }

    func updatePromptRewriteTrigger(_ newTrigger: KeyBinding) {
        updateActivationTrigger(newTrigger, atMode: .promptRewrite)
    }

    private func updateActivationTrigger(_ newTrigger: KeyBinding, atMode dictationMode: DictationMode) {
        guard let idx = triggers.firstIndex(where: { $0.mode == dictationMode }) else { return }
        guard triggers[idx].binding != newTrigger else { return }
        cancelPendingPrefix()
        if activeTrigger?.mode == dictationMode && mode == .holdToTalk {
            Task { try? await model.stopDictation() }
        }
        activeTrigger = nil
        triggers[idx].binding = newTrigger
    }

    func updateMode(_ newMode: ActivationMode) {
        guard newMode != mode else { return }
        cancelPendingPrefix()
        if activeTrigger != nil && mode == .holdToTalk {
            Task { try? await model.stopDictation() }
        }
        activeTrigger = nil
        mode = newMode
    }

    private func start() {
        DispatchQueue.main.async { [weak self] in
            self?.installMonitors()
        }
    }

    private func installMonitors() {
        _ = PermissionCoordinator.isInputMonitoringGranted
        _ = PermissionCoordinator.isAccessibilityGranted

        escapeInterceptor = EscapeKeyInterceptor { [weak self] in
            guard let self, !self.isPaused, self.model.phase == .recording else { return }
            Task { try? await self.model.cancelDictation() }
        }
        observePhase()
        syncEscapeInterceptor()

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in await self?.handleFlags(event: event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in await self?.handleFlags(event: event) }
            return event
        }
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleEscape(event: event)
                await self?.handleKey(event: event, isDown: true)
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor [weak self] in
                await self?.handleEscape(event: event)
                await self?.handleKey(event: event, isDown: true)
            }
            return event
        }
        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            Task { @MainActor [weak self] in await self?.handleKey(event: event, isDown: false) }
        }
        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            Task { @MainActor [weak self] in await self?.handleKey(event: event, isDown: false) }
            return event
        }
    }

    private func handleEscape(event: NSEvent) async {
        if isPaused { return }
        guard event.keyCode == 53 else { return }
        guard model.phase == .recording else { return }
        // The event tap already cancelled on this keypress. Don't skip just
        // because the tap is enabled: when the main thread is busy, macOS
        // disables the tap for a moment and that Esc reaches only this monitor.
        if let interceptor = escapeInterceptor,
           abs(interceptor.lastHandledTimestamp - event.timestamp) < 0.05 {
            return
        }
        try? await model.cancelDictation()
    }

    private func handleFlags(event: NSEvent) async {
        if isPaused { return }

        await handleOptionSendGesture(event: event)

        for spec in triggers {
            let binding = spec.binding
            if binding.isModifierOnly {
                let pressed = isFlagsPressed(event: event, keyCode: binding.keyCode)
                await applyTriggerState(spec, pressed: pressed)
                if pressed { return }
            } else if binding.isModifierCombo {
                let pressed = binding.matchesModifierFlags(rawFlags: event.modifierFlags.rawValue)
                await applyTriggerState(spec, pressed: pressed)
                if pressed { return }
            }
        }
    }

    /// Tap de ⌥ sozinho durante a gravação → para e envia. Armado quando o
    /// evento de flags é exatamente ⌥ com sessão gravando; disparado quando os
    /// modificadores zeram sem nenhuma tecla no meio. `handleKey` desarma em
    /// qualquer keyDown (⌥ era prefixo de combo, não o gesto de envio).
    private func handleOptionSendGesture(event: NSEvent) async {
        let independent = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if independent == .option {
            // A modifier-only ⌥ trigger already stops on its own tap; arming the
            // gesture too would send a second stop for the same keypress.
            let isTriggerKey = triggers.contains {
                $0.binding.isModifierOnly && $0.binding.keyCode == event.keyCode
            }
            pendingSendOnOptionRelease = !isTriggerKey && model.phase == .recording
        } else if independent.isEmpty {
            guard pendingSendOnOptionRelease else { return }
            pendingSendOnOptionRelease = false
            guard model.phase == .recording else { return }
            try? await model.stopDictation()
        } else {
            pendingSendOnOptionRelease = false
        }
    }

    private func handleKey(event: NSEvent, isDown: Bool) async {
        if isPaused { return }
        if isDown { pendingSendOnOptionRelease = false }

        for spec in triggers {
            let binding = spec.binding
            guard !binding.isModifierOnly, !binding.isModifierCombo else { continue }
            guard event.keyCode == binding.keyCode else { continue }

            let eventFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let expected = binding.modifiers & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
            let modsMatch = (eventFlags == expected)

            if modsMatch {
                await applyTriggerState(spec, pressed: isDown)
                return
            } else if !isDown && activeTrigger == spec {
                await applyTriggerState(spec, pressed: false)
                return
            }
        }
    }

    private func applyTriggerState(_ spec: TriggerSpec, pressed: Bool) async {
        if pressed {
            // Trigger específico (com tecla principal) cancela qualquer delay
            // pendente do prefixo — roteamos para o específico.
            if !spec.binding.isModifierOnly && !spec.binding.isModifierCombo {
                cancelPendingPrefix()
            }

            if let active = activeTrigger {
                guard active == spec else { return }
                return
            }

            // Se este trigger é prefixo de outro configurado, espera uma janela
            // curta pra ver se o trigger específico chega.
            if isPrefixOfAnotherTrigger(spec.binding) {
                schedulePrefixFire(spec)
                return
            }

            activeTrigger = spec
            await fireStart(mode: spec.mode)
        } else {
            // Release:
            // - tap-to-toggle + pending: o usuário soltou sem completar combo.
            //   Confirmou a intenção do modifier sozinho — flush e toggla.
            // - hold-to-talk + pending: o timer pode já ter disparado fireStart;
            //   se chegou aqui antes do timer, foi tap rápido — start+stop curto.
            if pendingPrefixTrigger == spec {
                cancelPendingPrefix()
                activeTrigger = spec
                await fireStart(mode: spec.mode)
            }
            guard activeTrigger == spec else { return }
            activeTrigger = nil
            await fireStop()
        }
    }

    private func schedulePrefixFire(_ spec: TriggerSpec) {
        cancelPendingPrefix()
        pendingPrefixTrigger = spec
        // Tap-to-toggle: sem timer. O fire só acontece no release se nenhum
        // combo foi completado nesse meio-tempo — isso dá ao usuário tempo
        // ilimitado pra completar ⌥+T, ⌥+Space etc., mas mantém o modifier
        // sozinho funcional como atalho de dictation.
        // Hold-to-talk: timer curto pra abrir margem ao combo antes de iniciar
        // a gravação. Sem o timer, "press to talk" não funcionaria.
        guard mode == .holdToTalk else { return }
        pendingStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: GlobalHotkeyMonitor.prefixGraceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.pendingPrefixTrigger == spec else { return }
            self.pendingPrefixTrigger = nil
            self.pendingStartTask = nil
            self.activeTrigger = spec
            await self.fireStart(mode: spec.mode)
        }
    }

    private func cancelPendingPrefix() {
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingPrefixTrigger = nil
    }

    /// Um binding é "prefixo" de outro quando ele é só um modificador e algum
    /// trigger configurado usa esse modificador combinado com outra tecla.
    /// Exemplo: Right ⌥ é prefixo de ⌥+Space.
    private func isPrefixOfAnotherTrigger(_ binding: KeyBinding) -> Bool {
        let otherBindings = triggers.map(\.binding)
        if binding.isModifierOnly {
            let bit = Self.deviceIndependentModifierBit(forKeyCode: binding.keyCode)
            guard bit != 0 else { return false }
            return otherBindings.contains { other in
                guard other != binding else { return false }
                guard !other.isModifierOnly, !other.isModifierCombo else { return false }
                return (other.modifiers & bit) != 0
            }
        }
        if binding.isModifierCombo {
            let selfMods = binding.modifiers & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
            return otherBindings.contains { other in
                guard other != binding else { return false }
                guard !other.isModifierOnly, !other.isModifierCombo else { return false }
                let otherMods = other.modifiers & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue
                return (otherMods & selfMods) == selfMods
            }
        }
        return false
    }

    /// Mapeia keyCode de tecla modificadora para o bit equivalente em
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`.
    private static func deviceIndependentModifierBit(forKeyCode code: UInt16) -> UInt {
        switch code {
        case 55, 54: return 1 << 20   // command
        case 56, 60: return 1 << 17   // shift
        case 58, 61: return 1 << 19   // option
        case 59, 62: return 1 << 18   // control
        case 63: return 1 << 23       // function
        default: return 0
        }
    }

    private func fireStart(mode dictationMode: DictationMode) async {
        switch mode {
        case .holdToTalk:
            try? await model.startDictation(mode: dictationMode)
        case .tapToToggle:
            if model.phase == .recording {
                try? await model.stopDictation()
            } else {
                try? await model.startDictation(mode: dictationMode)
            }
        }
    }

    private func fireStop() async {
        switch mode {
        case .holdToTalk:
            try? await model.stopDictation()
        case .tapToToggle:
            return
        }
    }

    private func isFlagsPressed(event: NSEvent, keyCode: UInt16) -> Bool {
        let raw = event.modifierFlags.rawValue
        switch keyCode {
        case 55: return raw & 0x00000008 != 0   // NX_DEVICELCMDKEYMASK
        case 54: return raw & 0x00000010 != 0   // NX_DEVICERCMDKEYMASK
        case 58: return raw & 0x00000020 != 0   // NX_DEVICELALTKEYMASK
        case 61: return raw & 0x00000040 != 0   // NX_DEVICERALTKEYMASK
        case 56: return raw & 0x00000002 != 0   // NX_DEVICELSHIFTKEYMASK
        case 60: return raw & 0x00000004 != 0   // NX_DEVICERSHIFTKEYMASK
        case 59: return raw & 0x00000001 != 0   // NX_DEVICELCTLKEYMASK
        case 62: return raw & 0x00002000 != 0   // NX_DEVICERCTLKEYMASK
        case 63: return event.modifierFlags.contains(.function)
        default: return false
        }
    }
}
