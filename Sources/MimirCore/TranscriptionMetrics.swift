import Foundation

public struct TranscriptionMetrics: Codable, Equatable, Sendable {
    public var audioLoading: TimeInterval
    public var fullPipeline: TimeInterval
    public var realTimeFactor: Double
    public var firstTokenLatency: TimeInterval?
    public var inputAudioSeconds: TimeInterval?
    public var modelLoading: TimeInterval?
    public var decodingWindowing: TimeInterval?
    public var totalDecodingWindows: Double?
    public var totalDecodingFallbacks: Double?

    public init(
        audioLoading: TimeInterval,
        fullPipeline: TimeInterval,
        realTimeFactor: Double,
        firstTokenLatency: TimeInterval? = nil,
        inputAudioSeconds: TimeInterval? = nil,
        modelLoading: TimeInterval? = nil,
        decodingWindowing: TimeInterval? = nil,
        totalDecodingWindows: Double? = nil,
        totalDecodingFallbacks: Double? = nil
    ) {
        self.audioLoading = audioLoading
        self.fullPipeline = fullPipeline
        self.realTimeFactor = realTimeFactor
        self.firstTokenLatency = firstTokenLatency
        self.inputAudioSeconds = inputAudioSeconds
        self.modelLoading = modelLoading
        self.decodingWindowing = decodingWindowing
        self.totalDecodingWindows = totalDecodingWindows
        self.totalDecodingFallbacks = totalDecodingFallbacks
    }
}

/// Métricas centradas no usuário: wall clock de cada etapa do stop→paste.
/// Soma de `transcription + postProcessing + insertion` é o tempo de bloqueio
/// percebido depois de soltar o gatilho.
public struct SessionMetrics: Codable, Equatable, Sendable {
    /// Duração do áudio gravado (wall clock entre start e stop).
    public var audioSeconds: TimeInterval?
    /// Tempo gasto com Whisper depois do stop. Se streaming estava ativo, é só o tail.
    public var transcriptionSeconds: TimeInterval
    /// Wall clock do `polish` do pós-processador MLX (nil quando desligado).
    public var postProcessingSeconds: TimeInterval?
    /// Wall clock da inserção (paste) final.
    public var insertionSeconds: TimeInterval?
    /// `true` quando o caminho de streaming commitou algo antes do stop.
    /// `false` indica fallback de transcrição do arquivo inteiro no release.
    public var streamingUsed: Bool
    /// Segundos de áudio pré-comitados pelo streaming antes do stop.
    public var streamingCommittedAudioSeconds: TimeInterval?
    /// Segundos de áudio transcritos na última chamada (tail no stop, ou áudio inteiro no fallback).
    public var tailAudioSeconds: TimeInterval?
    /// Quantos commits o assembler fez durante a gravação.
    public var streamingCommitCount: Int
    /// Soma de tempo gasto em todos os commits incrementais (wall clock).
    public var streamingCommitCumulativeSeconds: TimeInterval?
    /// Tempo de carregamento do modelo Whisper reportado pelo provider.
    public var whisperModelLoadSeconds: TimeInterval?
    /// Latência do primeiro token reportada pelo Whisper (informativo).
    public var firstTokenLatency: TimeInterval?
    /// Real-time factor interno do Whisper, útil pra diagnóstico de modelo.
    public var whisperRTF: Double?
    /// Motivo do fallback quando `streamingUsed == false`. Valores comuns:
    /// `"no-commit"` (nenhum commit aconteceu), `"tail-failure"` (tail lançou erro),
    /// `"no-format"` (formato não resolvido).
    public var fallbackReason: String?
    /// Diagnóstico: tentativas de commit incremental durante a gravação.
    public var incrementalAttemptCount: Int
    /// Diagnóstico: commits que Whisper devolveu texto vazio.
    public var incrementalEmptyResultCount: Int
    /// Diagnóstico: commits que lançaram erro.
    public var incrementalErrorCount: Int
    /// Diagnóstico: última mensagem de erro incremental, se houve.
    public var lastIncrementalError: String?

    public init(
        audioSeconds: TimeInterval? = nil,
        transcriptionSeconds: TimeInterval,
        postProcessingSeconds: TimeInterval? = nil,
        insertionSeconds: TimeInterval? = nil,
        streamingUsed: Bool,
        streamingCommittedAudioSeconds: TimeInterval? = nil,
        tailAudioSeconds: TimeInterval? = nil,
        streamingCommitCount: Int = 0,
        streamingCommitCumulativeSeconds: TimeInterval? = nil,
        whisperModelLoadSeconds: TimeInterval? = nil,
        firstTokenLatency: TimeInterval? = nil,
        whisperRTF: Double? = nil,
        fallbackReason: String? = nil,
        incrementalAttemptCount: Int = 0,
        incrementalEmptyResultCount: Int = 0,
        incrementalErrorCount: Int = 0,
        lastIncrementalError: String? = nil
    ) {
        self.audioSeconds = audioSeconds
        self.transcriptionSeconds = transcriptionSeconds
        self.postProcessingSeconds = postProcessingSeconds
        self.insertionSeconds = insertionSeconds
        self.streamingUsed = streamingUsed
        self.streamingCommittedAudioSeconds = streamingCommittedAudioSeconds
        self.tailAudioSeconds = tailAudioSeconds
        self.streamingCommitCount = streamingCommitCount
        self.streamingCommitCumulativeSeconds = streamingCommitCumulativeSeconds
        self.whisperModelLoadSeconds = whisperModelLoadSeconds
        self.firstTokenLatency = firstTokenLatency
        self.whisperRTF = whisperRTF
        self.fallbackReason = fallbackReason
        self.incrementalAttemptCount = incrementalAttemptCount
        self.incrementalEmptyResultCount = incrementalEmptyResultCount
        self.incrementalErrorCount = incrementalErrorCount
        self.lastIncrementalError = lastIncrementalError
    }

    public var streamingCoverageRatio: Double? {
        guard let audio = audioSeconds, audio > 0,
              let committed = streamingCommittedAudioSeconds else { return nil }
        return min(1.0, committed / audio)
    }

    public var streamingAvgCommitSeconds: TimeInterval? {
        guard streamingCommitCount > 0, let total = streamingCommitCumulativeSeconds else { return nil }
        return total / Double(streamingCommitCount)
    }

    public var stopToPasteSeconds: TimeInterval {
        transcriptionSeconds + (postProcessingSeconds ?? 0) + (insertionSeconds ?? 0)
    }
}

public struct SpeechTranscription: Equatable, Sendable {
    public var text: String
    public var language: String?
    public var metrics: TranscriptionMetrics?

    public init(text: String, language: String? = nil, metrics: TranscriptionMetrics? = nil) {
        self.text = text
        self.language = language
        self.metrics = metrics
    }
}

public struct LocalPipelineResult: Equatable, Sendable {
    public var transcription: SpeechTranscription
    public var outputText: String
    public var activeIntent: PolishIntent
    public var postProcessingSeconds: TimeInterval?
    public var insertionSeconds: TimeInterval?

    public init(
        transcription: SpeechTranscription,
        outputText: String,
        activeIntent: PolishIntent = .defaults,
        postProcessingSeconds: TimeInterval? = nil,
        insertionSeconds: TimeInterval? = nil
    ) {
        self.transcription = transcription
        self.outputText = outputText
        self.activeIntent = activeIntent
        self.postProcessingSeconds = postProcessingSeconds
        self.insertionSeconds = insertionSeconds
    }
}
