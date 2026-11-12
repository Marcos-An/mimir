import Foundation

/// Como a última sessão terminou. Permite à UI distinguir "colou o texto" de
/// "não havia fala" — antes os dois casos eram um `.idle` indistinguível e a
/// ilha simplesmente desaparecia.
public enum SessionCompletion: Equatable, Sendable {
    case inserted
    case noSpeech
    /// Nada reconhecido E o áudio capturado estava fraco demais para ASR
    /// confiável. A causa é o microfone, não o modelo — vale dizer isso.
    case audioTooQuiet
}

public struct DictationSnapshot: Equatable, Sendable {
    public var phase: AppPhase
    public var lastTranscript: String?
    public var lastTranscription: SpeechTranscription?
    public var lastSessionMetrics: SessionMetrics?
    /// Modo da sessão em andamento (nil quando ociosa).
    public var activeMode: DictationMode?
    /// Resultado da última sessão concluída; zerado ao começar a próxima.
    public var lastCompletion: SessionCompletion?

    public init(
        phase: AppPhase = .idle,
        lastTranscript: String? = nil,
        lastTranscription: SpeechTranscription? = nil,
        lastSessionMetrics: SessionMetrics? = nil,
        activeMode: DictationMode? = nil,
        lastCompletion: SessionCompletion? = nil
    ) {
        self.phase = phase
        self.lastTranscript = lastTranscript
        self.lastTranscription = lastTranscription
        self.lastSessionMetrics = lastSessionMetrics
        self.activeMode = activeMode
        self.lastCompletion = lastCompletion
    }
}

public enum DictationMode: String, Codable, Equatable, Sendable {
    /// Texto final limpo e colado no app ativo (padrão).
    case dictation
    /// Reescreve a fala como prompt/texto estruturado e cola no app ativo.
    case promptRewrite

    public var displayName: String {
        switch self {
        case .dictation:
            "Clean Dictation"
        case .promptRewrite:
            "Prompt / Rewrite"
        }
    }

    public var defaultPolishIntent: PolishIntent {
        switch self {
        case .dictation:
            .defaults
        case .promptRewrite:
            .promptEngineer
        }
    }

    public var accentName: String {
        switch self {
        case .dictation:
            "green"
        case .promptRewrite:
            "blue"
        }
    }
}

/// Fluxo de transcrição:
/// - **Durante a gravação**: o áudio acumulado é cortado em segmentos APENAS em
///   vales de silêncio (`SilenceSegmenter`) e cada segmento é transcrito
///   enquanto o usuário ainda fala. No release só a cauda pendente é
///   transcrita — a latência do stop fica limitada ao tamanho da cauda.
/// - **Ditados muito curtos** (nada atingiu o target de corte, hoje 10s): não
///   há segmento nenhum, e o release transcreve o arquivo completo de uma vez
///   (`fallbackReason: "no-segments"`). Era o que acontecia abaixo de 20s antes
///   de set/2026, em 100% dos ditados curtos — daí o target ter caído pra 10s.
/// - **Segmento que falha**: o áudio volta pra fila (`requeueFailedSegment`) e
///   a segmentação CONTINUA; o trecho ganha outra chance de corte e, no pior
///   caso, entra na cauda do stop. O que já foi commitado nunca é descartado.
/// - **Último recurso**: só quando o teto de re-enfileiramentos estoura (ou a
///   sessão é cancelada) o caminho segmentado é condenado e o release
///   re-transcreve o arquivo completo (`"segmented-path-recovery"`).
public actor DictationSessionController {
    private let settings: AppSettings
    private let recorder: any AudioRecording
    private let pipeline: LocalPipeline
    private let segmenterConfig: SilenceSegmenter.Config

    private var currentSnapshot = DictationSnapshot()
    private var snapshotContinuations: [UUID: AsyncStream<DictationSnapshot>.Continuation] = [:]

    private var chunkConsumerTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var postProcessorWarmTask: Task<Void, Never>?
    private var segmentInFlight = false
    /// Pico da última captura, em dBFS. Usado para explicar um resultado vazio.
    private var lastCapturePeakDBFS: Double?
    /// Pico abaixo disso significa que o momento mais alto da gravação nunca
    /// passou de ~10% do fundo de escala — baixo demais para ASR confiável.
    private static let tooQuietPeakDBFS: Double = -20
    /// Chunks ainda não commitados em nenhum segmento (a "cauda" corrente).
    /// Após cada corte os chunks do segmento saem daqui — memória limitada ao
    /// tamanho de um segmento, não à sessão inteira.
    private var pendingChunks: [AudioChunk] = []
    private var captureFormat: AudioCaptureFormat?
    private var accumulator = SegmentAccumulator()
    /// Um segmento falhou ou devolveu vazio com fala real: o texto acumulado
    /// não é mais confiável — o release transcreve o arquivo completo.
    private var segmentedPathBroken = false
    private var currentMode: DictationMode = .dictation

    // Telemetria por sessão (zerada em resetSessionState).
    private var segmentAttemptCount = 0
    private var segmentEmptyCount = 0
    private var segmentErrorCount = 0
    private var lastSegmentError: String?
    private var committedFrameCount = 0
    /// Quantas vezes um segmento que falhou voltou pra fila nesta sessão.
    private var segmentRequeueCount = 0
    /// Teto de re-enfileiramentos. Uma janela que falha sempre não pode queimar
    /// CPU pela gravação inteira — esgotado o teto, a sessão volta ao
    /// comportamento antigo (arquivo completo no stop).
    private static let maxSegmentRequeues = 2
    private var totalFrameCount = 0
    private var segmentCumulativeSeconds: TimeInterval = 0

    public init(
        settings: AppSettings,
        recorder: any AudioRecording,
        pipeline: LocalPipeline,
        segmenterConfig: SilenceSegmenter.Config = .default
    ) {
        self.settings = settings
        self.recorder = recorder
        self.pipeline = pipeline
        self.segmenterConfig = segmenterConfig
    }

    public var snapshot: DictationSnapshot {
        currentSnapshot
    }

    /// Stream de snapshots emitido a cada mudança de estado — a UI consome por
    /// push em vez de polling.
    public func snapshotUpdates() -> AsyncStream<DictationSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            snapshotContinuations[id] = continuation
            continuation.yield(currentSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotContinuation(id) }
            }
        }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
    }

    private func updateSnapshot(_ transform: (inout DictationSnapshot) -> Void) {
        transform(&currentSnapshot)
        for continuation in snapshotContinuations.values {
            continuation.yield(currentSnapshot)
        }
    }

    /// Preload de launch: só a transcrição. O pós-processador (o mais pesado em
    /// memória) é aquecido quando a gravação começa — mantê-lo residente desde o
    /// login prende ~1,7 GB mesmo em dias que o usuário não dita nada.
    public func preload() async {
        await pipeline.preloadTranscription()
    }

    public func prepareModels() async {
        await pipeline.preload()
    }

    private func warmPostProcessorIfNeeded() {
        // Re-aquece a CADA gravação: para o provider cloud isso revive a
        // conexão TLS (pool ocioso por horas custava ~13s no polish); para o
        // MLX é no-op depois do primeiro load (a task de load é cacheada).
        guard postProcessorWarmTask == nil else { return }
        let pipeline = self.pipeline
        // Fire-and-forget: não pode atrasar o início da gravação.
        postProcessorWarmTask = Task.detached(priority: .userInitiated) { [weak self] in
            await pipeline.preloadPostProcessing()
            await self?.clearPostProcessorWarmTask()
        }
    }

    private func clearPostProcessorWarmTask() {
        postProcessorWarmTask = nil
    }

    /// Encerra qualquer sessão em andamento e libera o microfone. Chamado
    /// quando o controller é substituído (rebuild de settings) — sem isso o
    /// engine antigo ficaria capturando pra sempre.
    public func teardown() async {
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        segmentTask?.cancel()
        segmentTask = nil
        postProcessorWarmTask?.cancel()
        postProcessorWarmTask = nil
        if let finished = try? await recorder.finishCapture() {
            try? FileManager.default.removeItem(at: finished.fileURL)
        }
        resetSessionState()
        updateSnapshot { snapshot in
            snapshot = DictationSnapshot()
        }
        for continuation in snapshotContinuations.values {
            continuation.finish()
        }
        snapshotContinuations.removeAll()
    }

    public func handleActivationPressed() async throws {
        try await handleActivationPressed(mode: .dictation)
    }

    public func handleActivationPressed(mode: DictationMode) async throws {
        do {
            let captureSession = try await recorder.beginCapture()
            captureFormat = captureSession.format
            resetSessionState()
            currentMode = mode
            // O polish só roda depois da fala; aquecer agora esconde o load (e a
            // resolução da API key do provider cloud) atrás do tempo de gravação.
            warmPostProcessorIfNeeded()
            updateSnapshot { snapshot in
                snapshot.phase = .recording
                snapshot.lastTranscript = nil
                snapshot.lastTranscription = nil
                snapshot.lastSessionMetrics = nil
                snapshot.activeMode = mode
                snapshot.lastCompletion = nil
            }
            // Deixa o provider re-avaliar idioma do zero nesta sessão.
            if let resettable = pipeline.speechToText as? SessionResettableSpeechProvider {
                await resettable.resetSessionLanguage()
            }
            chunkConsumerTask?.cancel()
            chunkConsumerTask = Task { [weak self] in
                for await chunk in captureSession.chunks {
                    await self?.ingest(chunk)
                }
            }
        } catch {
            updateSnapshot { snapshot in
                snapshot.phase = .error(message: error.localizedDescription)
                snapshot.activeMode = nil
            }
            throw error
        }
    }

    public func handleActivationCancelled() async throws {
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        segmentTask?.cancel()
        segmentTask = nil
        do {
            let finished = try await recorder.finishCapture()
            // Sessão cancelada: ninguém vai transcrever o áudio, deletar imediato.
            try? FileManager.default.removeItem(at: finished.fileURL)
        } catch {
            // swallow: cancel should always leave us idle
        }
        resetSessionState()
        updateSnapshot { snapshot in
            snapshot.phase = .idle
            snapshot.lastTranscript = nil
            snapshot.lastTranscription = nil
            snapshot.activeMode = nil
        }
    }

    public func handleActivationReleased() async throws {
        let pipelineToUse = pipeline
        do {
            let finished = try await recorder.finishCapture()
            // O WAV é a fonte do fallback de recuperação — deletar só no fim,
            // defer cobre sucesso e qualquer throw daqui pra frente.
            defer { try? FileManager.default.removeItem(at: finished.fileURL) }
            lastCapturePeakDBFS = finished.audioPeakDBFS
            updateSnapshot { $0.phase = .transcribing }

            // O finishCapture encerra o stream; o consumer drena os chunks
            // restantes e termina. Depois disso `pendingChunks` está completo.
            await chunkConsumerTask?.value
            chunkConsumerTask = nil
            // Segmento em voo termina de transcrever (é áudio que já não
            // precisará ser re-transcrito na cauda).
            if let segmentTask {
                await segmentTask.value
            }
            segmentTask = nil

            let transcriptionStart = Date()
            let sampleRate = captureFormat?.sampleRate ?? 16_000
            let totalAudioSeconds = Double(totalFrameCount) / sampleRate

            var streamingUsed = false
            var fallbackReason: String?
            var tailAudioSeconds = totalAudioSeconds
            let finalTranscription: SpeechTranscription

            if settings.transcriptionStrategy == .chunked, !accumulator.isEmpty, !segmentedPathBroken {
                do {
                    let tailFrames = pendingChunks.reduce(0) { $0 + $1.frameCount }
                    tailAudioSeconds = Double(tailFrames) / sampleRate
                    var tailTranscription: SpeechTranscription?
                    if tailFrames > 0, let format = captureFormat {
                        let capture = IncrementalAudioCapture(audioFormat: format, chunks: pendingChunks)
                            .paddedWithTrailingSilence(seconds: 0.3)
                        do {
                            tailTranscription = try await pipelineToUse.transcribeAudioCapture(
                                capture,
                                languageHint: settings.preferredLanguage,
                                previousContext: accumulator.contextTail(),
                                onPhase: { [weak self] phase in
                                    await self?.setPhase(phase)
                                }
                            )
                        } catch MimirError.emptyTranscript {
                            // Cauda sem fala (usuário soltou depois de uma pausa) — ok.
                            tailTranscription = nil
                        }
                    }
                    let tailText = tailTranscription?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let joined = tailText.isEmpty ? accumulator.text : accumulator.text + " " + tailText
                    let strippedJoined = WhisperKitProvider.stripTailFarewells(joined)
                    finalTranscription = SpeechTranscription(
                        text: strippedJoined,
                        language: tailTranscription?.language ?? accumulator.language,
                        metrics: tailTranscription?.metrics ?? accumulator.lastMetrics
                    )
                    streamingUsed = true
                } catch {
                    // Única recuperação do caminho segmentado: arquivo completo.
                    fallbackReason = "segmented-path-recovery"
                    tailAudioSeconds = totalAudioSeconds
                    finalTranscription = try await pipelineToUse.transcribeAudio(
                        audioFileURL: finished.fileURL,
                        languageHint: settings.preferredLanguage,
                        onPhase: { [weak self] phase in
                            await self?.setPhase(phase)
                        }
                    )
                }
            } else {
                // `segmentRequeueCount > 0` entra aqui porque um segmento pode
                // ter falhado, voltado pra fila e a sessão ter terminado antes
                // de qualquer commit: o caminho segmentado não foi "condenado",
                // mas a causa do arquivo completo foi falha de segmento, não
                // ditado curto. Rotular de "no-segments" mentiria na telemetria.
                fallbackReason = (segmentedPathBroken || segmentRequeueCount > 0)
                    ? "segmented-path-recovery"
                    : "no-segments"
                finalTranscription = try await pipelineToUse.transcribeAudio(
                    audioFileURL: finished.fileURL,
                    languageHint: settings.preferredLanguage,
                    onPhase: { [weak self] phase in
                        await self?.setPhase(phase)
                    }
                )
            }

            if settings.keepsRecentRecordings {
                RecordingArchive.keep(audioAt: finished.fileURL, rawText: finalTranscription.text)
            }

            // Guard de artefato: Whisper devolve símbolos de som ("♫", "[Music]")
            // quando classifica o áudio como não-fala — tipicamente gravação
            // baixa demais. Colar isso é pior que não colar nada, então tratamos
            // como "nenhuma fala detectada".
            guard !WhisperKitProvider.isNonSpeechArtifact(finalTranscription.text) else {
                throw MimirError.emptyTranscript
            }

            // Pós-processamento único com o texto completo: o provider cloud é
            // rápido o bastante (~1–2s) para dispensar o antigo polish por
            // segmento, e corrigir com o contexto inteiro rende texto melhor
            // que costurar segmentos polidos isoladamente.
            // Sem `onPolishChunk`: o produto não mostra preview incremental do
            // texto, então gerar callbacks por chunk seria trabalho jogado fora.
            let result = try await pipelineToUse.process(
                transcription: finalTranscription,
                defaultIntent: currentMode.defaultPolishIntent,
                onPhase: { [weak self] phase in
                    await self?.setPhase(phase)
                }
            )

            // transcriptionSeconds = wall clock do stop até a transcrição ficar pronta
            // (exclui tempo de post-processing/insertion, que são medidos separadamente
            // pelo LocalPipeline).
            let totalSinceStop = Date().timeIntervalSince(transcriptionStart)
            let postSec = result.postProcessingSeconds ?? 0
            let insertSec = result.insertionSeconds ?? 0
            let transcriptionSeconds = max(0, totalSinceStop - postSec - insertSec)

            let sessionMetrics = SessionMetrics(
                audioSeconds: nil, // preenchido pelo MimirAppModel com o tempo de gravação real.
                transcriptionSeconds: transcriptionSeconds,
                postProcessingSeconds: result.postProcessingSeconds,
                insertionSeconds: result.insertionSeconds,
                streamingUsed: streamingUsed,
                streamingCommittedAudioSeconds: streamingUsed ? Double(committedFrameCount) / sampleRate : nil,
                tailAudioSeconds: tailAudioSeconds,
                streamingCommitCount: accumulator.segmentCount,
                streamingCommitCumulativeSeconds: accumulator.segmentCount > 0 ? segmentCumulativeSeconds : nil,
                whisperModelLoadSeconds: result.transcription.metrics?.modelLoading,
                firstTokenLatency: result.transcription.metrics?.firstTokenLatency,
                whisperRTF: result.transcription.metrics?.realTimeFactor,
                fallbackReason: fallbackReason,
                incrementalAttemptCount: segmentAttemptCount,
                incrementalEmptyResultCount: segmentEmptyCount,
                incrementalErrorCount: segmentErrorCount,
                lastIncrementalError: lastSegmentError,
                postProcessingInputCharacterCount: result.postProcessingInputCharacterCount,
                postProcessingOutputCharacterCount: result.postProcessingOutputCharacterCount,
                postProcessingSystemBefore: result.postProcessingSystemBefore,
                postProcessingSystemAfter: result.postProcessingSystemAfter,
                detectedLanguage: finalTranscription.language,
                languageHint: result.transcription.metrics?.languageHint ?? settings.preferredLanguage,
                transcriptionModelName: result.transcription.metrics?.modelName,
                promptTokensInjected: result.transcription.metrics?.promptTokensUsed,
                promptFallbackUsed: result.transcription.metrics?.promptFallbackUsed,
                audioMeanDBFS: finished.audioMeanDBFS,
                audioPeakDBFS: finished.audioPeakDBFS,
                postProcessingEditRatio: result.postProcessingEditRatio
            )

            updateSnapshot { snapshot in
                snapshot.phase = .idle
                snapshot.lastTranscript = result.outputText
                snapshot.lastTranscription = result.transcription
                snapshot.lastSessionMetrics = sessionMetrics
                snapshot.activeMode = nil
                snapshot.lastCompletion = .inserted
            }
            resetSessionState()
        } catch MimirError.emptyTranscript {
            // Distingue "não falei nada" de "o mic captou fraco demais": só o
            // segundo caso é acionável pelo usuário.
            let tooQuiet = (lastCapturePeakDBFS ?? 0) < Self.tooQuietPeakDBFS
            resetSessionState()
            updateSnapshot { snapshot in
                snapshot.phase = .idle
                snapshot.lastTranscript = nil
                snapshot.lastTranscription = nil
                snapshot.lastSessionMetrics = nil
                snapshot.activeMode = nil
                snapshot.lastCompletion = tooQuiet ? .audioTooQuiet : .noSpeech
            }
        } catch {
            resetSessionState()
            updateSnapshot { snapshot in
                snapshot.activeMode = nil
                snapshot.phase = .error(message: error.localizedDescription)
            }
        }
    }

    /// A UI já mostrou a falha ao usuário: volta pra idle para o ícone do menu
    /// bar e a ilha não ficarem presos em estado de erro.
    public func acknowledgeError() async {
        guard case .error = currentSnapshot.phase else { return }
        updateSnapshot { $0.phase = .idle }
    }

    private func setPhase(_ phase: AppPhase) {
        updateSnapshot { $0.phase = phase }
    }

    private func resetSessionState() {
        pendingChunks.removeAll(keepingCapacity: false)
        accumulator.reset()
        segmentedPathBroken = false
        segmentInFlight = false
        segmentAttemptCount = 0
        segmentEmptyCount = 0
        segmentErrorCount = 0
        lastSegmentError = nil
        committedFrameCount = 0
        segmentRequeueCount = 0
        totalFrameCount = 0
        segmentCumulativeSeconds = 0
    }

    private func ingest(_ chunk: AudioChunk) {
        pendingChunks.append(chunk)
        totalFrameCount += chunk.frameCount
        guard currentSnapshot.phase == .recording else { return }
        maybeCutSegment()
    }

    private func maybeCutSegment() {
        guard settings.transcriptionStrategy == .chunked else { return }
        guard !segmentInFlight, !segmentedPathBroken else { return }
        guard let format = captureFormat else { return }
        guard let cutIndex = SilenceSegmenter.cutIndex(
            chunks: pendingChunks,
            sampleRate: format.sampleRate,
            config: segmenterConfig,
            hasPriorSegment: !accumulator.isEmpty
        ) else { return }

        let segmentChunks = Array(pendingChunks[0...cutIndex])
        pendingChunks.removeFirst(cutIndex + 1)
        segmentInFlight = true
        segmentTask = Task { [weak self] in
            await self?.transcribeSegment(chunks: segmentChunks, format: format)
        }
    }

    private func transcribeSegment(chunks: [AudioChunk], format: AudioCaptureFormat) async {
        defer { segmentInFlight = false }
        segmentAttemptCount += 1
        let start = Date()
        let capture = IncrementalAudioCapture(audioFormat: format, chunks: chunks)
            .paddedWithTrailingSilence(seconds: 0.3)
        do {
            var transcription = try await transcribeSegmentOnce(capture)
            if transcription == nil {
                segmentEmptyCount += 1
                let meanRMS = chunks.reduce(Float(0)) { $0 + $1.rms } / Float(max(chunks.count, 1))
                // Silêncio de verdade: nenhuma palavra existia ali, só pula.
                guard meanRMS >= segmenterConfig.silenceRMSFloor else { return }
                // Fala real com resultado vazio: recovery cirúrgico — uma
                // segunda tentativa do MESMO segmento antes de condenar a
                // sessão inteira à re-transcrição do arquivo completo.
                transcription = try await transcribeSegmentOnce(capture)
                guard transcription != nil else {
                    requeueFailedSegment(chunks)
                    return
                }
            }
            guard let transcription else { return }
            accumulator.append(transcription)
            committedFrameCount += chunks.reduce(0) { $0 + $1.frameCount }
            segmentCumulativeSeconds += Date().timeIntervalSince(start)
        } catch is CancellationError {
            segmentedPathBroken = true
        } catch {
            segmentErrorCount += 1
            lastSegmentError = error.localizedDescription
            requeueFailedSegment(chunks)
        }
    }

    /// Devolve o áudio de um segmento que falhou pro início da fila pendente em
    /// vez de condenar a sessão inteira.
    ///
    /// Antes, um único segmento ruim NO MEIO da fala setava
    /// `segmentedPathBroken`, e o `guard` do `maybeCutSegment` desligava a
    /// segmentação pelo resto da gravação: todo o áudio seguinte ficava sem
    /// transcrever e o stop re-lia o arquivo completo, jogando fora os
    /// segmentos já commitados (medido: 7 sessões em 200, mediana de 17,96s de
    /// stop→paste, uma delas com 10 commits descartados).
    ///
    /// Re-enfileirar preserva a ordem (só um segmento voa por vez, garantido
    /// por `segmentInFlight`, então `pendingChunks` só contém áudio POSTERIOR
    /// ao trecho que falhou) e dá ao trecho uma chance real, não só um retry:
    /// com mais áudio na fila, `SilenceSegmenter` pode achar um vale de
    /// silêncio melhor e cortar em outro ponto. No pior caso o trecho
    /// simplesmente entra na cauda transcrita no stop.
    private func requeueFailedSegment(_ chunks: [AudioChunk]) {
        guard segmentRequeueCount < Self.maxSegmentRequeues else {
            segmentedPathBroken = true
            return
        }
        segmentRequeueCount += 1
        pendingChunks.insert(contentsOf: chunks, at: 0)
    }

    /// Uma passada de transcrição do segmento. `nil` = sem texto (Whisper vazio
    /// ou classificado como não-fala) — a decisão de retry/pulo é do chamador.
    private func transcribeSegmentOnce(_ capture: IncrementalAudioCapture) async throws -> SpeechTranscription? {
        do {
            let transcription = try await pipeline.transcribeAudioCapture(
                capture,
                languageHint: settings.preferredLanguage,
                previousContext: accumulator.contextTail()
            )
            let text = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : transcription
        } catch MimirError.emptyTranscript {
            return nil
        }
    }
}
