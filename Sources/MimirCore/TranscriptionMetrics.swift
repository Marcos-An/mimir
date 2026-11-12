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
    /// Nome do modelo (Whisper) ou identificador do provider efetivamente usado.
    public var modelName: String?
    /// Hint de idioma passado para o decoder. nil = auto-detect.
    public var languageHint: String?
    /// Quantos tokens de prompt foram injetados nesta chamada.
    public var promptTokensUsed: Int?
    /// Verdadeiro quando a primeira chamada com prompt veio vazia e refizemos sem prompt.
    public var promptFallbackUsed: Bool?

    public init(
        audioLoading: TimeInterval,
        fullPipeline: TimeInterval,
        realTimeFactor: Double,
        firstTokenLatency: TimeInterval? = nil,
        inputAudioSeconds: TimeInterval? = nil,
        modelLoading: TimeInterval? = nil,
        decodingWindowing: TimeInterval? = nil,
        totalDecodingWindows: Double? = nil,
        totalDecodingFallbacks: Double? = nil,
        modelName: String? = nil,
        languageHint: String? = nil,
        promptTokensUsed: Int? = nil,
        promptFallbackUsed: Bool? = nil
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
        self.modelName = modelName
        self.languageHint = languageHint
        self.promptTokensUsed = promptTokensUsed
        self.promptFallbackUsed = promptFallbackUsed
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
    /// Diagnóstico de pós-processamento: tamanho do texto enviado ao MLX/local processor.
    public var postProcessingInputCharacterCount: Int?
    /// Diagnóstico de pós-processamento: tamanho do texto produzido pelo MLX/local processor.
    public var postProcessingOutputCharacterCount: Int?
    /// Snapshot de sistema capturado imediatamente antes do pós-processamento.
    public var postProcessingSystemBefore: SystemResourceSnapshot?
    /// Snapshot de sistema capturado imediatamente depois do pós-processamento.
    public var postProcessingSystemAfter: SystemResourceSnapshot?
    /// Diagnóstico de qualidade: idioma efetivamente usado pelo Whisper (detectado ou hint).
    /// Cruzar com `languageHint` permite ver quando confiamos no auto-detect e o que ele entregou.
    public var detectedLanguage: String?
    /// Hint de idioma passado para o provider nesta sessão (nil = auto-detect).
    public var languageHint: String?
    /// Nome do modelo Whisper efetivamente usado (ou identificador do provider para Apple Speech etc).
    public var transcriptionModelName: String?
    /// Quantos tokens de prompt técnico/contexto foram injetados no decoder (0 quando nenhum).
    public var promptTokensInjected: Int?
    /// Verdadeiro quando a primeira chamada com prompt devolveu vazio e refizemos sem prompt.
    /// Sinal de que o prompt está sabotando o decoder neste modelo/áudio.
    public var promptFallbackUsed: Bool?
    /// Nível médio do áudio em dBFS (0 = full scale, valores negativos = mais baixo).
    /// Tipicamente -18 a -20 é alvo prático para fala; muito abaixo de -30 já degrada o ASR.
    public var audioMeanDBFS: Double?
    /// Pico de nível em dBFS. Próximo de 0 = quase clipping.
    public var audioPeakDBFS: Double?
    /// Razão simples [0, 1] de quanto o pós-processador modificou o texto.
    /// 0 = idêntico, 1 = totalmente reescrito. Útil pra flagrar MLX traduzindo/normalizando demais.
    public var postProcessingEditRatio: Double?

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
        lastIncrementalError: String? = nil,
        postProcessingInputCharacterCount: Int? = nil,
        postProcessingOutputCharacterCount: Int? = nil,
        postProcessingSystemBefore: SystemResourceSnapshot? = nil,
        postProcessingSystemAfter: SystemResourceSnapshot? = nil,
        detectedLanguage: String? = nil,
        languageHint: String? = nil,
        transcriptionModelName: String? = nil,
        promptTokensInjected: Int? = nil,
        promptFallbackUsed: Bool? = nil,
        audioMeanDBFS: Double? = nil,
        audioPeakDBFS: Double? = nil,
        postProcessingEditRatio: Double? = nil
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
        self.postProcessingInputCharacterCount = postProcessingInputCharacterCount
        self.postProcessingOutputCharacterCount = postProcessingOutputCharacterCount
        self.postProcessingSystemBefore = postProcessingSystemBefore
        self.postProcessingSystemAfter = postProcessingSystemAfter
        self.detectedLanguage = detectedLanguage
        self.languageHint = languageHint
        self.transcriptionModelName = transcriptionModelName
        self.promptTokensInjected = promptTokensInjected
        self.promptFallbackUsed = promptFallbackUsed
        self.audioMeanDBFS = audioMeanDBFS
        self.audioPeakDBFS = audioPeakDBFS
        self.postProcessingEditRatio = postProcessingEditRatio
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
    public var postProcessingInputCharacterCount: Int?
    public var postProcessingOutputCharacterCount: Int?
    public var postProcessingSystemBefore: SystemResourceSnapshot?
    public var postProcessingSystemAfter: SystemResourceSnapshot?
    /// Distância de edição normalizada [0, 1] entre o texto roteado e o texto final.
    /// 0 = pós-processador não mexeu, 1 = reescreveu tudo. Valores altos com intent
    /// `defaults` são sinal de que o MLX está extrapolando o briefing.
    public var postProcessingEditRatio: Double?

    public init(
        transcription: SpeechTranscription,
        outputText: String,
        activeIntent: PolishIntent = .defaults,
        postProcessingSeconds: TimeInterval? = nil,
        insertionSeconds: TimeInterval? = nil,
        postProcessingInputCharacterCount: Int? = nil,
        postProcessingOutputCharacterCount: Int? = nil,
        postProcessingSystemBefore: SystemResourceSnapshot? = nil,
        postProcessingSystemAfter: SystemResourceSnapshot? = nil,
        postProcessingEditRatio: Double? = nil
    ) {
        self.transcription = transcription
        self.outputText = outputText
        self.activeIntent = activeIntent
        self.postProcessingSeconds = postProcessingSeconds
        self.insertionSeconds = insertionSeconds
        self.postProcessingInputCharacterCount = postProcessingInputCharacterCount
        self.postProcessingOutputCharacterCount = postProcessingOutputCharacterCount
        self.postProcessingSystemBefore = postProcessingSystemBefore
        self.postProcessingSystemAfter = postProcessingSystemAfter
        self.postProcessingEditRatio = postProcessingEditRatio
    }
}
