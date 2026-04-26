import Foundation

public struct DictationSnapshot: Equatable, Sendable {
    public var phase: AppPhase
    public var lastTranscript: String?
    public var lastTranscription: SpeechTranscription?
    public var lastSessionMetrics: SessionMetrics?
    /// Texto parcial que o MLX está gerando — atualizado em streaming.
    /// `nil` quando não está em pós-processamento ou quando o provider não
    /// suporta streaming.
    public var partialPolishText: String?
    /// Modo da sessão em andamento (nil quando ociosa).
    public var activeMode: DictationMode?

    public init(
        phase: AppPhase = .idle,
        lastTranscript: String? = nil,
        lastTranscription: SpeechTranscription? = nil,
        lastSessionMetrics: SessionMetrics? = nil,
        partialPolishText: String? = nil,
        activeMode: DictationMode? = nil
    ) {
        self.phase = phase
        self.lastTranscript = lastTranscript
        self.lastTranscription = lastTranscription
        self.lastSessionMetrics = lastSessionMetrics
        self.partialPolishText = partialPolishText
        self.activeMode = activeMode
    }
}

public enum DictationMode: String, Codable, Equatable, Sendable {
    /// Texto final limpo e colado no app ativo (padrão).
    case dictation
    /// Reescreve a fala como prompt/texto estruturado e cola no app ativo.
    case promptRewrite
    /// Envia o texto final para a ilha do Hermes em vez de colar no app ativo.
    case hermes

    public var displayName: String {
        switch self {
        case .dictation:
            "Clean Dictation"
        case .promptRewrite:
            "Prompt / Rewrite"
        case .hermes:
            "Hermes handoff"
        }
    }

    public var defaultPolishIntent: PolishIntent {
        switch self {
        case .dictation:
            .defaults
        case .promptRewrite:
            .promptEngineer
        case .hermes:
            .defaults
        }
    }

    public var accentName: String {
        switch self {
        case .dictation:
            "green"
        case .promptRewrite:
            "blue"
        case .hermes:
            "purple"
        }
    }
}

public actor DictationSessionController {
    private let settings: AppSettings
    private let recorder: any AudioRecording
    private let pipeline: LocalPipeline
    private let hermesInserter: (any TextInserting)?
    private let incrementalPollingIntervalNanoseconds: UInt64
    /// Número de chunks mantidos como "margem de segurança" no fim do áudio
    /// incremental. Não transcrevemos estes chunks no incremental pra não commitar
    /// palavras possivelmente cortadas. Em release, são transcritos como tail.
    private let safetyChunksAtTail: Int
    /// Janela mínima de áudio (em segundos) por commit incremental.
    /// Deltas abaixo desse limiar são acumulados até atingirem o mínimo.
    private let minimumDeltaSeconds: Double
    private var currentSnapshot = DictationSnapshot()
    private var incrementalTask: Task<Void, Never>?
    private var assembler = IncrementalTranscriptAssembler()
    private var accumulatedChunks: [AudioChunk] = []
    private var accumulatedFormat: AudioCaptureFormat?
    private var currentMode: DictationMode = .dictation
    private var incrementalStopRequested = false
    private var incrementalTranscriptionInFlight = false
    // Telemetria por sessão (zerada em resetIncrementalState).
    private var commitCount: Int = 0
    private var commitCumulativeSeconds: TimeInterval = 0
    private var committedFrameCount: Int = 0
    // Diagnóstico: quantos ciclos tentaram transcrever delta no incremental.
    private var incrementalAttemptCount: Int = 0
    private var incrementalEmptyResultCount: Int = 0
    private var incrementalErrorCount: Int = 0
    private var lastIncrementalError: String?

    public init(
        settings: AppSettings,
        recorder: any AudioRecording,
        pipeline: LocalPipeline,
        hermesInserter: (any TextInserting)? = nil,
        incrementalPollingIntervalNanoseconds: UInt64 = 700_000_000,
        safetyChunksAtTail: Int = 8,
        minimumDeltaSeconds: Double = 5.0
    ) {
        self.settings = settings
        self.recorder = recorder
        self.pipeline = pipeline
        self.hermesInserter = hermesInserter
        self.incrementalPollingIntervalNanoseconds = incrementalPollingIntervalNanoseconds
        self.safetyChunksAtTail = safetyChunksAtTail
        self.minimumDeltaSeconds = minimumDeltaSeconds
    }

    public var snapshot: DictationSnapshot {
        currentSnapshot
    }

    public func handleActivationPressed() async throws {
        try await handleActivationPressed(mode: .dictation)
    }

    public func handleActivationPressed(mode: DictationMode) async throws {
        do {
            try await recorder.beginCapture()
            currentSnapshot.phase = .recording
            currentSnapshot.lastTranscript = nil
            currentSnapshot.lastTranscription = nil
            currentSnapshot.lastSessionMetrics = nil
            currentSnapshot.partialPolishText = nil
            currentSnapshot.activeMode = mode
            currentMode = mode
            resetIncrementalState()
            // Deixa o provider re-avaliar idioma do zero nesta sessão.
            if let resettable = pipeline.speechToText as? SessionResettableSpeechProvider {
                await resettable.resetSessionLanguage()
            }
            incrementalTask?.cancel()
            incrementalTask = shouldUseHiddenIncrementalTranscription ? makeIncrementalTask() : nil
        } catch {
            currentSnapshot.phase = .error(message: error.localizedDescription)
            currentSnapshot.activeMode = nil
            throw error
        }
    }

    public func handleActivationCancelled() async throws {
        incrementalTask?.cancel()
        incrementalTask = nil
        resetIncrementalState()
        do {
            _ = try await recorder.finishCapture()
        } catch {
            // swallow: cancel should always leave us idle
        }
        currentSnapshot.phase = .idle
        currentSnapshot.lastTranscript = nil
        currentSnapshot.lastTranscription = nil
        currentSnapshot.activeMode = nil
    }

    public func handleActivationReleased() async throws {
        await stopIncrementalTaskForRelease()
        let pipelineToUse = pipelineForCurrentMode()
        do {
            let finished = try await recorder.finishCapture()
            currentSnapshot.phase = .transcribing

            let transcriptionStart = Date()

            // Se o loop incremental commitou algo durante a gravação, reaproveita
            // esse texto e transcreve apenas a cauda não-commitada. Com deltas
            // grandes (~5s+) cada commit tem contexto suficiente pra ficar
            // lexicamente estável — compromisso viável entre velocidade e
            // fidelidade do full-file.
            let sampleRate = accumulatedFormat?.sampleRate ?? 16_000
            let allChunks = accumulatedChunks + finished.trailingChunks
            let totalFrames = allChunks.reduce(0) { $0 + $1.frameCount }
            let totalAudioSeconds = Double(totalFrames) / sampleRate

            let finalTranscription: SpeechTranscription
            var tailAudioSeconds: TimeInterval
            let streamingUsed: Bool
            var fallbackReason: String?

            if let committed = assembler.committedTranscription,
               let committedEnd = assembler.committedSpan?.endSequence,
               let format = accumulatedFormat,
               !committed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tailChunks = allChunks.filter { $0.id.sequence > committedEnd }
                let tailFrames = tailChunks.reduce(0) { $0 + $1.frameCount }
                tailAudioSeconds = Double(tailFrames) / sampleRate
                streamingUsed = true

                if tailChunks.isEmpty {
                    finalTranscription = committed
                } else {
                    let tailStart = tailChunks.first!.id.sequence
                    let tailEnd = tailChunks.last!.id.sequence
                    let tailCapture = IncrementalAudioCapture(audioFormat: format, chunks: tailChunks)
                        .paddedWithTrailingSilence(seconds: 0.3)
                    let artifact = IncrementalCaptureArtifact(
                        audioCapture: tailCapture,
                        span: ChunkSpan(startSequence: tailStart, endSequence: tailEnd)
                    )
                    do {
                        let tailTranscription = try await pipelineToUse.transcribeIncrementalArtifact(
                            artifact,
                            languageHint: settings.preferredLanguage,
                            onPhase: { [weak self] phase in
                                await self?.setPhase(phase)
                            }
                        )
                        let committedText = committed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let tailText = tailTranscription.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let combined = tailText.isEmpty ? committedText : committedText + " " + tailText
                        finalTranscription = SpeechTranscription(
                            text: combined,
                            language: tailTranscription.language ?? committed.language,
                            metrics: tailTranscription.metrics
                        )
                    } catch {
                        fallbackReason = "tail-failure"
                        finalTranscription = try await pipelineToUse.transcribeAudio(
                            audioFileURL: finished.fileURL,
                            languageHint: settings.preferredLanguage,
                            onPhase: { [weak self] phase in
                                await self?.setPhase(phase)
                            }
                        )
                        tailAudioSeconds = totalAudioSeconds
                    }
                }
            } else {
                streamingUsed = false
                fallbackReason = "no-commit"
                tailAudioSeconds = totalAudioSeconds
                finalTranscription = try await pipelineToUse.transcribeAudio(
                    audioFileURL: finished.fileURL,
                    languageHint: settings.preferredLanguage,
                    onPhase: { [weak self] phase in
                        await self?.setPhase(phase)
                    }
                )
            }

            let result = try await pipelineToUse.process(
                transcription: finalTranscription,
                defaultIntent: currentMode.defaultPolishIntent,
                onPhase: { [weak self] phase in
                    await self?.setPhase(phase)
                },
                onPolishChunk: { [weak self] chunk in
                    await self?.updatePartialPolish(chunk)
                }
            )

            // transcriptionSeconds = wall clock do stop até a transcrição ficar pronta
            // (exclui tempo de post-processing/insertion, que são medidos separadamente
            // pelo LocalPipeline).
            let totalSinceStop = Date().timeIntervalSince(transcriptionStart)
            let postSec = result.postProcessingSeconds ?? 0
            let insertSec = result.insertionSeconds ?? 0
            let transcriptionSeconds = max(0, totalSinceStop - postSec - insertSec)

            let committedSeconds: TimeInterval? = streamingUsed
                ? Double(committedFrameCount) / sampleRate
                : nil
            let tailSeconds: TimeInterval = tailAudioSeconds

            let sessionMetrics = SessionMetrics(
                audioSeconds: nil, // preenchido pelo MimirAppModel com o tempo de gravação real.
                transcriptionSeconds: transcriptionSeconds,
                postProcessingSeconds: result.postProcessingSeconds,
                insertionSeconds: result.insertionSeconds,
                streamingUsed: streamingUsed,
                streamingCommittedAudioSeconds: committedSeconds,
                tailAudioSeconds: tailSeconds,
                streamingCommitCount: commitCount,
                streamingCommitCumulativeSeconds: commitCount > 0 ? commitCumulativeSeconds : nil,
                whisperModelLoadSeconds: result.transcription.metrics?.modelLoading,
                firstTokenLatency: result.transcription.metrics?.firstTokenLatency,
                whisperRTF: result.transcription.metrics?.realTimeFactor,
                fallbackReason: fallbackReason,
                incrementalAttemptCount: incrementalAttemptCount,
                incrementalEmptyResultCount: incrementalEmptyResultCount,
                incrementalErrorCount: incrementalErrorCount,
                lastIncrementalError: lastIncrementalError
            )

            currentSnapshot.phase = .idle
            currentSnapshot.lastTranscript = result.outputText
            currentSnapshot.lastTranscription = result.transcription
            currentSnapshot.lastSessionMetrics = sessionMetrics
            currentSnapshot.partialPolishText = nil
            currentSnapshot.activeMode = nil
            resetIncrementalState()
        } catch MimirError.emptyTranscript {
            resetIncrementalState()
            currentSnapshot.phase = .idle
            currentSnapshot.lastTranscript = nil
            currentSnapshot.lastTranscription = nil
            currentSnapshot.lastSessionMetrics = nil
            currentSnapshot.partialPolishText = nil
            currentSnapshot.activeMode = nil
        } catch {
            resetIncrementalState()
            currentSnapshot.activeMode = nil
            currentSnapshot.phase = .error(message: error.localizedDescription)
        }
    }

    /// Seleciona o pipeline efetivo para o modo da sessão atual.
    /// Prompt/Rewrite mantém o paste normal; Hermes handoff troca o destino.
    private func pipelineForCurrentMode() -> LocalPipeline {
        guard currentMode == .hermes, let hermesInserter else {
            return pipeline
        }
        return pipeline.with(textInserter: hermesInserter)
    }

    private func updatePartialPolish(_ text: String) {
        currentSnapshot.partialPolishText = text
    }

    private func setPhase(_ phase: AppPhase) {
        currentSnapshot.phase = phase
    }

    private var shouldUseHiddenIncrementalTranscription: Bool {
        // Reativado mesmo o output vindo do arquivo completo: o loop incremental
        // mantém o Whisper aquecido durante a gravação, evitando que o release
        // pague cold-decode em áudio > 30s (modelo Large sem chunking tem
        // performance-cliff severo quando recebe áudio frio e longo).
        settings.transcriptionStrategy == .chunked
    }

    private func resetIncrementalState() {
        assembler.reset()
        accumulatedChunks.removeAll(keepingCapacity: false)
        accumulatedFormat = nil
        incrementalStopRequested = false
        incrementalTranscriptionInFlight = false
        commitCount = 0
        commitCumulativeSeconds = 0
        committedFrameCount = 0
        incrementalAttemptCount = 0
        incrementalEmptyResultCount = 0
        incrementalErrorCount = 0
        lastIncrementalError = nil
    }

    private func makeIncrementalTask() -> Task<Void, Never> {
        let interval = incrementalPollingIntervalNanoseconds
        return Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { break }
                    if shouldStopIncrementalLoop() { break }
                    await self.captureIncrementalTranscription()
                    if shouldStopIncrementalLoop() { break }
                } catch is CancellationError {
                    break
                } catch {
                    continue
                }
            }
        }
    }

    private func shouldStopIncrementalLoop() -> Bool {
        incrementalStopRequested
    }

    private func stopIncrementalTaskForRelease() async {
        guard let task = incrementalTask else { return }
        incrementalStopRequested = true
        if incrementalTranscriptionInFlight {
            await task.value
        } else {
            task.cancel()
        }
        incrementalTask = nil
    }

    private func captureIncrementalTranscription() async {
        guard currentSnapshot.phase == .recording else { return }

        let batch: IncrementalChunkBatch?
        do {
            batch = try await recorder.nextIncrementalChunkBatch()
        } catch {
            return
        }

        guard let batch else { return }

        accumulatedFormat = batch.audioFormat
        accumulatedChunks.append(contentsOf: batch.chunks)

        // Delta commit: pega só os chunks novos desde o último commit, aplicando
        // `safetyChunksAtTail` como margem pra não cortar palavra no fim do
        // áudio disponível agora. Cada chamada transcreve só áudio novo (custo O(1)
        // por commit em vez de O(n) do prefixo crescente).
        let committedEnd = assembler.committedSpan?.endSequence
        let newChunks: [AudioChunk]
        if let end = committedEnd {
            newChunks = accumulatedChunks.filter { $0.id.sequence > end }
        } else {
            newChunks = accumulatedChunks
        }
        let safeNewCount = newChunks.count - safetyChunksAtTail
        guard safeNewCount > 0 else { return }
        let safeDeltaChunks = Array(newChunks.prefix(safeNewCount))

        // Minimum de áudio por delta: Whisper com janelas muito curtas (<1.5s)
        // frequentemente devolve texto vazio ou mal segmentado. Acumular mais
        // dá contexto suficiente pra transcrição ser estável sem perder
        // o ganho de custo O(1) do delta.
        let sampleRate = batch.audioFormat.sampleRate
        let totalDeltaFrames = safeDeltaChunks.reduce(0) { $0 + $1.frameCount }
        let deltaSeconds = sampleRate > 0 ? Double(totalDeltaFrames) / sampleRate : 0
        guard deltaSeconds >= minimumDeltaSeconds else { return }

        guard let deltaStart = safeDeltaChunks.first?.id.sequence,
              let deltaEnd = safeDeltaChunks.last?.id.sequence else { return }
        let deltaSpan = ChunkSpan(startSequence: deltaStart, endSequence: deltaEnd)

        let capture = IncrementalAudioCapture(
            audioFormat: batch.audioFormat,
            chunks: safeDeltaChunks
        ).paddedWithTrailingSilence(seconds: 0.3)
        let artifact = IncrementalCaptureArtifact(audioCapture: capture, span: deltaSpan)

        incrementalAttemptCount += 1
        let commitStart = Date()
        incrementalTranscriptionInFlight = true
        defer { incrementalTranscriptionInFlight = false }
        do {
            let transcription = try await pipeline.transcribeIncrementalArtifact(
                artifact,
                languageHint: settings.preferredLanguage
            )
            guard currentSnapshot.phase == .recording else { return }
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                incrementalEmptyResultCount += 1
                return
            }
            commitCount += 1
            commitCumulativeSeconds += Date().timeIntervalSince(commitStart)
            // committedFrameCount = soma acumulada dos frames já commitados (todos
            // os chunks cujo sequence ≤ deltaEnd).
            committedFrameCount = accumulatedChunks
                .filter { $0.id.sequence <= deltaEnd }
                .reduce(0) { $0 + $1.frameCount }
            assembler.appendDelta(
                span: deltaSpan,
                transcription: SpeechTranscription(
                    text: text,
                    language: transcription.language,
                    metrics: transcription.metrics
                )
            )
        } catch MimirError.emptyTranscript {
            incrementalEmptyResultCount += 1
        } catch {
            incrementalErrorCount += 1
            lastIncrementalError = error.localizedDescription
        }
    }
}
