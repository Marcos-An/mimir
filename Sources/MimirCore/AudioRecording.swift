@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// Sessão de captura ativa: formato + stream de chunks empurrados na ordem
/// exata em que o áudio chegou (AsyncStream preserva ordem de yield — sem os
/// Tasks avulsos que podiam reordenar chunks sob carga).
public struct AudioCaptureSession: Sendable {
    public let format: AudioCaptureFormat
    public let chunks: AsyncStream<AudioChunk>

    public init(format: AudioCaptureFormat, chunks: AsyncStream<AudioChunk>) {
        self.format = format
        self.chunks = chunks
    }
}

public protocol AudioRecording: Sendable {
    /// Inicia a captura e devolve o stream de chunks. O stream termina quando
    /// `finishCapture` é chamado — o consumidor drena o restante e encerra.
    func beginCapture() async throws -> AudioCaptureSession
    func finishCapture() async throws -> FinishedCapture
}

public struct ChunkID: Hashable, Sendable, Comparable {
    public let sequence: Int

    public init(sequence: Int) {
        self.sequence = sequence
    }

    public static func < (lhs: ChunkID, rhs: ChunkID) -> Bool {
        lhs.sequence < rhs.sequence
    }
}

public struct AudioCaptureFormat: Equatable, Hashable, Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let bitsPerSample: Int

    public init(sampleRate: Double, channelCount: Int, bitsPerSample: Int = 16) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitsPerSample = bitsPerSample
    }
}

public struct AudioChunk: Equatable, Sendable {
    public let id: ChunkID
    public let data: Data
    public let frameCount: Int
    /// RMS do chunk (samples normalizados [-1, 1]). Alimenta o SilenceSegmenter
    /// para escolher fronteiras de corte em silêncio real.
    public let rms: Float

    public init(id: ChunkID, data: Data, frameCount: Int, rms: Float = 0) {
        self.id = id
        self.data = data
        self.frameCount = frameCount
        self.rms = rms
    }
}

public struct FinishedCapture: Equatable, Sendable {
    public let fileURL: URL
    /// Nível médio do áudio em dBFS, agregado em toda a sessão.
    /// nil quando o recorder não conseguiu medir (silêncio total ou bug).
    public let audioMeanDBFS: Double?
    /// Pico absoluto em dBFS. Próximo de 0 = clipping.
    public let audioPeakDBFS: Double?

    public init(
        fileURL: URL,
        audioMeanDBFS: Double? = nil,
        audioPeakDBFS: Double? = nil
    ) {
        self.fileURL = fileURL
        self.audioMeanDBFS = audioMeanDBFS
        self.audioPeakDBFS = audioPeakDBFS
    }
}

public struct IncrementalAudioCapture: Equatable, Sendable {
    public var audioFormat: AudioCaptureFormat
    public var chunks: [AudioChunk]

    public init(audioFormat: AudioCaptureFormat, chunks: [AudioChunk]) {
        self.audioFormat = audioFormat
        self.chunks = chunks
    }

    public var sampleRate: Double { audioFormat.sampleRate }
    public var channelCount: Int { audioFormat.channelCount }
    public var bitsPerSample: Int { audioFormat.bitsPerSample }

    public var pcmByteCount: Int {
        chunks.reduce(into: 0) { $0 += $1.data.count }
    }

    public var renderedFileByteCount: Int {
        44 + pcmByteCount
    }

    /// Retorna uma cópia do áudio com um chunk de silêncio no fim. Whisper
    /// precisa de silêncio trailing para entender "fim da fala" — sem isso,
    /// ele alucina continuações. Essencial para segmentos cujo áudio termina
    /// perto da fala do usuário.
    public func paddedWithTrailingSilence(seconds: Double) -> IncrementalAudioCapture {
        let frameCount = Int((audioFormat.sampleRate * seconds).rounded())
        guard frameCount > 0 else { return self }
        let byteCount = frameCount * audioFormat.channelCount * audioFormat.bitsPerSample / 8
        let silenceData = Data(count: byteCount)
        let nextSequence = (chunks.last?.id.sequence ?? -1) + 1
        let silenceChunk = AudioChunk(
            id: ChunkID(sequence: nextSequence),
            data: silenceData,
            frameCount: frameCount
        )
        return IncrementalAudioCapture(
            audioFormat: audioFormat,
            chunks: chunks + [silenceChunk]
        )
    }

    public func makeWAVData() -> Data {
        let pcmByteCount = pcmByteCount
        let roundedSampleRate = Int(audioFormat.sampleRate.rounded())
        let byteRate = roundedSampleRate * audioFormat.channelCount * audioFormat.bitsPerSample / 8
        let blockAlign = audioFormat.channelCount * audioFormat.bitsPerSample / 8

        var data = Data()
        data.reserveCapacity(renderedFileByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(36 + pcmByteCount)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(16)))
        data.append(contentsOf: littleEndianBytes(UInt16(1)))
        data.append(contentsOf: littleEndianBytes(UInt16(audioFormat.channelCount)))
        data.append(contentsOf: littleEndianBytes(UInt32(roundedSampleRate)))
        data.append(contentsOf: littleEndianBytes(UInt32(byteRate)))
        data.append(contentsOf: littleEndianBytes(UInt16(blockAlign)))
        data.append(contentsOf: littleEndianBytes(UInt16(audioFormat.bitsPerSample)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndianBytes(UInt32(pcmByteCount)))
        for chunk in chunks {
            data.append(chunk.data)
        }
        return data
    }
}

public actor MacAudioRecorder: AudioRecording {
    /// Taxa canônica do Whisper. Gravamos diretamente nesse formato em vez de
    /// salvar o nativo do mic (48 kHz estéreo) — Whisper resamplearia internamente
    /// e descartaria o conteúdo acima de 8 kHz mesmo, então economizamos ~6× em
    /// disco e I/O por sessão.
    private static let targetSampleRate: Double = 16_000

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var currentFileURL: URL?
    private var inputDeviceUID: String?
    private let levelMonitor: AudioLevelMonitor?
    private var chunkContinuation: AsyncStream<AudioChunk>.Continuation?
    private var tapState: TapState?

    public init(
        inputDeviceUID: String? = nil,
        levelMonitor: AudioLevelMonitor? = nil
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.levelMonitor = levelMonitor
    }

    public func setInputDeviceUID(_ uid: String?) {
        inputDeviceUID = uid
    }

    public func beginCapture() async throws -> AudioCaptureSession {
        // Dupla ativação (race de hotkey): nunca sobrescrever um engine vivo —
        // o tap antigo continuaria alimentando o mesmo estado com o mic aberto.
        guard engine == nil else {
            throw MimirError.transcriptionFailed("A capture is already in progress.")
        }

        try await PermissionCoordinator.ensureMicrophoneAccess()

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-\(UUID().uuidString).wav")

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = inputDeviceUID, let device = AudioInputDevice.device(forUID: uid) {
            try setInputDevice(device.deviceID, onInput: input)
        } else if let systemDefault = AudioInputDevice.systemDefaultInput() {
            try setInputDevice(systemDefault.deviceID, onInput: input)
        }

        let nativeFormat = input.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw MimirError.transcriptionFailed("Invalid input device (rate=\(nativeFormat.sampleRate), ch=\(nativeFormat.channelCount)).")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw MimirError.transcriptionFailed("Could not build 16kHz mono target format.")
        }

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw MimirError.transcriptionFailed("Could not create audio converter (\(nativeFormat.sampleRate)Hz/\(nativeFormat.channelCount)ch → 16kHz/mono).")
        }

        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file: AVAudioFile
        do {
            // commonFormat e interleaved precisam casar com o `outBuffer` que
            // alimentamos via `file.write(from:)`. Sem isso, o `AVAudioFile`
            // assume processingFormat = Float32 não-interleaved (default) e o
            // AudioConverter interno bate assertion no primeiro write
            // (EXC_BREAKPOINT em ExtAudioFile::WriteInputProc).
            file = try AVAudioFile(
                forWriting: fileURL,
                settings: writeSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            let nsError = error as NSError
            print("[Mimir] AVAudioFile create failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            throw MimirError.transcriptionFailed("Failed to create audio file: \(nsError.localizedDescription)")
        }

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let tapState = TapState()
        let monitor = levelMonitor
        if let monitor {
            Task { @MainActor in monitor.reset() }
        }
        let sampleRateRatio = Self.targetSampleRate / nativeFormat.sampleRate

        // Tudo que o tap produz é calculado no próprio thread do tap (serial)
        // e publicado via yield — nenhum Task avulso, nenhuma reordenação.
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            // Razão das taxas + margem cobre o filtro FIR do resampler;
            // o converter mantém estado entre chamadas, então frames "presos"
            // no filtro aparecem no próximo buffer.
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * sampleRateRatio)) + 256
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            let flag = ConverterInputFlag()
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, statusPtr in
                if flag.consumed {
                    statusPtr.pointee = .noDataNow
                    return nil
                }
                flag.consumed = true
                statusPtr.pointee = .haveData
                return buffer
            }
            guard status != .error, outBuffer.frameLength > 0 else { return }

            try? file.write(from: outBuffer)

            let frameCount = Int(outBuffer.frameLength)
            guard let stats = MacAudioRecorder.levelStats(buffer: outBuffer),
                  let pcmData = MacAudioRecorder.interleavedPCMData(from: outBuffer),
                  frameCount > 0 else { return }

            let rms = Float(sqrt(stats.sumSquares / Double(max(stats.frameCount, 1))))
            let sequence = tapState.consumeNextSequence(
                sumSquares: stats.sumSquares,
                frameCount: stats.frameCount,
                peak: stats.peak
            )
            continuation.yield(AudioChunk(
                id: ChunkID(sequence: sequence),
                data: pcmData,
                frameCount: frameCount,
                rms: rms
            ))

            if let monitor {
                // Two ~40 ms slices per ~85 ms buffer instead of one value, so the
                // wave follows syllables. Mapping to 0…1 is the meter's job.
                let slices = MacAudioRecorder.sliceRMS(buffer: outBuffer, sliceFrames: max(320, (frameCount + 1) / 2))
                Task { @MainActor in monitor.push(rms: slices) }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            let nsError = error as NSError
            print("[Mimir] AVAudioEngine start failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            throw MimirError.transcriptionFailed("Failed to start audio: \(nsError.localizedDescription)")
        }

        self.engine = engine
        self.file = file
        self.currentFileURL = fileURL
        self.chunkContinuation = continuation
        self.tapState = tapState

        return AudioCaptureSession(
            format: AudioCaptureFormat(
                sampleRate: Self.targetSampleRate,
                channelCount: 1,
                bitsPerSample: 16
            ),
            chunks: stream
        )
    }

    /// Limpa WAVs órfãos deixados em `temporaryDirectory` por sessões anteriores
    /// que não passaram pelo cleanup do controller (crash, force-quit, sessão
    /// ativa quando o app fechou). `minimumAge` evita pisar em uma sessão em
    /// andamento no mesmo TMPDIR.
    public static func purgeOrphanedTemporaryRecordings(olderThan minimumAge: TimeInterval = 3600) {
        let tmp = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-minimumAge)
        for url in contents {
            let name = url.lastPathComponent
            guard name.hasPrefix("mimir-"), name.hasSuffix(".wav") else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let mtime, mtime < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func finishCapture() async throws -> FinishedCapture {
        guard let engine, let currentFileURL else {
            throw MimirError.noRecordingInProgress
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunkContinuation?.finish()

        let levels = tapState?.sessionLevels()
        let meanDBFS: Double?
        if let levels, levels.frameCount > 0 {
            let meanSquare = levels.sumSquares / Double(levels.frameCount)
            let rms = sqrt(max(meanSquare, .leastNormalMagnitude))
            meanDBFS = 20 * log10(rms)
        } else {
            meanDBFS = nil
        }
        let peakDBFS: Double?
        if let levels, levels.peak > 0 {
            peakDBFS = 20 * Double(log10(levels.peak))
        } else {
            peakDBFS = nil
        }

        self.engine = nil
        self.file = nil
        self.currentFileURL = nil
        self.chunkContinuation = nil
        self.tapState = nil
        return FinishedCapture(
            fileURL: currentFileURL,
            audioMeanDBFS: meanDBFS,
            audioPeakDBFS: peakDBFS
        )
    }

    /// Estatísticas de nível por buffer convertido (16k mono). Soma de quadrados
    /// + frame count permitem reconstruir o RMS do chunk e da sessão; o pico
    /// fica como running max. Roda no thread do tap.
    nonisolated static func levelStats(buffer: AVAudioPCMBuffer) -> (sumSquares: Double, frameCount: Int, peak: Float)? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        var sumSq: Double = 0
        var peak: Float = 0

        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            for i in 0..<frameCount {
                let s = samples[i]
                sumSq += Double(s * s)
                let a = abs(s)
                if a > peak { peak = a }
            }
            return (sumSq, frameCount, peak)
        }
        if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            for i in 0..<frameCount {
                let n = Float(samples[i]) / Float(Int16.max)
                sumSq += Double(n * n)
                let a = abs(n)
                if a > peak { peak = a }
            }
            return (sumSq, frameCount, peak)
        }
        return nil
    }

    /// RMS of consecutive slices of the first channel. A short final slice is
    /// kept so no audio is skipped.
    nonisolated static func sliceRMS(buffer: AVAudioPCMBuffer, sliceFrames: Int) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, sliceFrames > 0 else { return [] }
        var result: [Float] = []
        var start = 0
        while start < frameCount {
            let end = min(start + sliceFrames, frameCount)
            var sum: Float = 0
            if let channel = buffer.int16ChannelData?[0] {
                for i in start..<end {
                    let n = Float(channel[i]) / Float(Int16.max)
                    sum += n * n
                }
            } else if let channel = buffer.floatChannelData?[0] {
                for i in start..<end { sum += channel[i] * channel[i] }
            }
            result.append(sqrt(sum / Float(end - start)))
            start = end
        }
        return result
    }

    nonisolated private static func interleavedPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        // Caminho rápido: o buffer alvo já é Int16 interleaved mono — uma cópia
        // única de memória em vez de append de 2 bytes por amostra.
        if channelCount == 1, let channelData = buffer.int16ChannelData {
            return Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)
        }

        var data = Data(capacity: frameCount * channelCount * MemoryLayout<Int16>.size)

        func append(_ sample: Int16) {
            var littleEndian = sample.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        if let channelData = buffer.floatChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let sample = max(-1, min(1, channelData[channel][frame]))
                    append(Int16(sample * Float(Int16.max)))
                }
            }
            return data
        }

        if let channelData = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    append(channelData[channel][frame])
                }
            }
            return data
        }

        return nil
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, onInput node: AVAudioInputNode) throws {
        guard let unit = node.audioUnit else {
            throw MimirError.transcriptionFailed("Audio unit unavailable on inputNode.")
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("[Mimir] AudioUnitSetProperty(CurrentDevice) failed with status \(status)")
            throw MimirError.transcriptionFailed("Could not select microphone (status \(status)).")
        }
    }
}

public struct NullAudioRecorder: AudioRecording {
    public init() {}

    public func beginCapture() async throws -> AudioCaptureSession {
        throw MimirError.notImplemented("Wire AVAudioEngine recording here")
    }

    public func finishCapture() async throws -> FinishedCapture {
        throw MimirError.notImplemented("Wire AVAudioEngine recording here")
    }
}

private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

/// Estado mutado exclusivamente no thread do tap (serial); o lock só protege a
/// leitura final em `finishCapture`, que acontece depois de `removeTap`.
private final class TapState: @unchecked Sendable {
    private var nextSequence = 0
    private var sumSquares: Double = 0
    private var frameCount: Int = 0
    private var peak: Float = 0
    private let lock = NSLock()

    func consumeNextSequence(sumSquares: Double, frameCount: Int, peak: Float) -> Int {
        lock.lock()
        defer { lock.unlock() }
        self.sumSquares += sumSquares
        self.frameCount += frameCount
        if peak > self.peak { self.peak = peak }
        let sequence = nextSequence
        nextSequence += 1
        return sequence
    }

    func sessionLevels() -> (sumSquares: Double, frameCount: Int, peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (sumSquares, frameCount, peak)
    }
}

/// Box mutável para flag usada dentro do inputBlock do AVAudioConverter.
/// O block é chamado síncrono no mesmo thread do tap — não há cruzamento
/// real de domínios — mas o tipo do block é @Sendable, então uma var local
/// dispara warning de strict concurrency. Esta class encapsula a flag.
private final class ConverterInputFlag: @unchecked Sendable {
    var consumed = false
}
