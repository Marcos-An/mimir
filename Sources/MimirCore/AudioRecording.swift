import AVFoundation
import CoreAudio
import Foundation

public protocol AudioRecording: Sendable {
    func beginCapture() async throws
    func nextIncrementalChunkBatch() async throws -> IncrementalChunkBatch?
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

public struct ChunkSpan: Hashable, Sendable {
    public let startSequence: Int
    public let endSequence: Int

    public init(startSequence: Int, endSequence: Int) {
        precondition(endSequence >= startSequence, "ChunkSpan must be non-empty")
        self.startSequence = startSequence
        self.endSequence = endSequence
    }

    public var count: Int { endSequence - startSequence + 1 }

    public func covers(_ other: ChunkSpan) -> Bool {
        startSequence <= other.startSequence && endSequence >= other.endSequence
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

    public init(id: ChunkID, data: Data, frameCount: Int) {
        self.id = id
        self.data = data
        self.frameCount = frameCount
    }
}

public struct IncrementalChunkBatch: Equatable, Sendable {
    public let chunks: [AudioChunk]
    public let span: ChunkSpan
    public let audioFormat: AudioCaptureFormat

    public init(chunks: [AudioChunk], span: ChunkSpan, audioFormat: AudioCaptureFormat) {
        self.chunks = chunks
        self.span = span
        self.audioFormat = audioFormat
    }
}

public struct FinishedCapture: Equatable, Sendable {
    public let fileURL: URL
    public let span: ChunkSpan?
    /// Chunks que existiam no recorder mas ainda não tinham sido entregues via
    /// `nextIncrementalChunkBatch` quando o release aconteceu. Permite ao
    /// controller completar a trilha de áudio pra transcrição delta no release.
    public let trailingChunks: [AudioChunk]

    public init(fileURL: URL, span: ChunkSpan?, trailingChunks: [AudioChunk] = []) {
        self.fileURL = fileURL
        self.span = span
        self.trailingChunks = trailingChunks
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
    /// ele alucina continuações. Essencial para transcrição incremental onde
    /// o áudio termina no meio da fala do usuário.
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

public struct IncrementalCaptureArtifact: Equatable, Sendable {
    public var fileURL: URL?
    public var audioCapture: IncrementalAudioCapture?
    public var span: ChunkSpan

    public init(fileURL: URL, span: ChunkSpan) {
        self.fileURL = fileURL
        self.audioCapture = nil
        self.span = span
    }

    public init(audioCapture: IncrementalAudioCapture, span: ChunkSpan) {
        self.fileURL = nil
        self.audioCapture = audioCapture
        self.span = span
    }

    public var hasInMemoryAudio: Bool {
        audioCapture != nil
    }
}

public actor MacAudioRecorder: AudioRecording {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var currentFileURL: URL?
    private var inputDeviceUID: String?
    private let levelMonitor: AudioLevelMonitor?
    private let minimumIncrementalBatchBytes: Int
    private var allChunks: [AudioChunk] = []
    private var nextSequence: Int = 0
    private var lastEmittedEndSequence: Int? = nil
    private var captureFormat: AudioCaptureFormat?

    public init(
        inputDeviceUID: String? = nil,
        levelMonitor: AudioLevelMonitor? = nil,
        minimumIncrementalBatchBytes: Int = 32 * 1024
    ) {
        self.inputDeviceUID = inputDeviceUID
        self.levelMonitor = levelMonitor
        self.minimumIncrementalBatchBytes = minimumIncrementalBatchBytes
    }

    public func setInputDeviceUID(_ uid: String?) {
        inputDeviceUID = uid
    }

    public func beginCapture() async throws {
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

        let writeSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: nativeFormat.sampleRate,
            AVNumberOfChannelsKey: nativeFormat.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: fileURL, settings: writeSettings)
        } catch {
            let nsError = error as NSError
            print("[Mimir] AVAudioFile create failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            throw MimirError.transcriptionFailed("Failed to create audio file: \(nsError.localizedDescription)")
        }

        let monitor = levelMonitor
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            try? file.write(from: buffer)
            let frameCount = Int(buffer.frameLength)
            if let pcmData = MacAudioRecorder.interleavedPCMData(from: buffer), frameCount > 0 {
                Task {
                    await self?.appendIncrementalChunk(data: pcmData, frameCount: frameCount)
                }
            }
            if let monitor {
                let level = MacAudioRecorder.computeLevel(buffer: buffer)
                Task { @MainActor in monitor.push(level) }
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            let nsError = error as NSError
            print("[Mimir] AVAudioEngine start failed: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            throw MimirError.transcriptionFailed("Failed to start audio: \(nsError.localizedDescription)")
        }

        self.engine = engine
        self.file = file
        self.currentFileURL = fileURL
        self.allChunks = []
        self.nextSequence = 0
        self.lastEmittedEndSequence = nil
        self.captureFormat = AudioCaptureFormat(
            sampleRate: nativeFormat.sampleRate,
            channelCount: Int(nativeFormat.channelCount),
            bitsPerSample: 16
        )
    }

    public func finishCapture() async throws -> FinishedCapture {
        guard let engine, let currentFileURL else {
            throw MimirError.noRecordingInProgress
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let span: ChunkSpan?
        if nextSequence > 0 {
            span = ChunkSpan(startSequence: 0, endSequence: nextSequence - 1)
        } else {
            span = nil
        }

        // Drena chunks ainda não entregues por nextIncrementalChunkBatch (abaixo
        // do threshold de bytes). Permite ao controller fazer finalização delta
        // sem perder áudio.
        let pendingStart = lastEmittedEndSequence.map { $0 + 1 } ?? 0
        let trailing: [AudioChunk]
        if pendingStart < nextSequence {
            trailing = Array(allChunks[pendingStart..<nextSequence])
        } else {
            trailing = []
        }

        self.engine = nil
        self.file = nil
        self.currentFileURL = nil
        self.allChunks = []
        self.nextSequence = 0
        self.lastEmittedEndSequence = nil
        self.captureFormat = nil
        return FinishedCapture(fileURL: currentFileURL, span: span, trailingChunks: trailing)
    }

    public func nextIncrementalChunkBatch() async throws -> IncrementalChunkBatch? {
        guard let format = captureFormat else { return nil }
        let pendingStart = lastEmittedEndSequence.map { $0 + 1 } ?? 0
        guard pendingStart < nextSequence else { return nil }

        let newChunks = Array(allChunks[pendingStart..<nextSequence])
        let pendingBytes = newChunks.reduce(into: 0) { $0 += $1.data.count }
        guard pendingBytes >= minimumIncrementalBatchBytes else { return nil }

        let span = ChunkSpan(startSequence: 0, endSequence: nextSequence - 1)
        lastEmittedEndSequence = nextSequence - 1
        return IncrementalChunkBatch(chunks: newChunks, span: span, audioFormat: format)
    }

    private func appendIncrementalChunk(data: Data, frameCount: Int) {
        let chunk = AudioChunk(
            id: ChunkID(sequence: nextSequence),
            data: data,
            frameCount: frameCount
        )
        allChunks.append(chunk)
        nextSequence += 1
    }

    private static func computeLevel(buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sumSquares: Float = 0
        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            for i in 0..<frameCount {
                let sample = samples[i]
                sumSquares += sample * sample
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            return min(1, rms * 6)
        }
        if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            for i in 0..<frameCount {
                let normalized = Float(samples[i]) / Float(Int16.max)
                sumSquares += normalized * normalized
            }
            let rms = sqrtf(sumSquares / Float(frameCount))
            return min(1, rms * 6)
        }
        return 0
    }

    nonisolated private static func interleavedPCMData(from buffer: AVAudioPCMBuffer) -> Data? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

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

    public func beginCapture() async throws {
        throw MimirError.notImplemented("Wire AVAudioEngine recording here")
    }

    public func nextIncrementalChunkBatch() async throws -> IncrementalChunkBatch? {
        nil
    }

    public func finishCapture() async throws -> FinishedCapture {
        throw MimirError.notImplemented("Wire AVAudioEngine recording here")
    }
}

private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}
