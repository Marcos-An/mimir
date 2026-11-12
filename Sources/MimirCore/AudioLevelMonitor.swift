import Foundation
import Observation

/// Turns raw microphone RMS into a 0…1 level that looks right for speech.
///
/// Loudness is perceived logarithmically, so the mapping works in dBFS rather
/// than linear RMS (the old `rms * 6` left normal speech at ~20% of the bar
/// and clipped loud speech). Two trackers make it adapt to any mic and room:
/// - a noise floor that drops fast and rises only on steady, near-floor sound,
///   so room noise reads as silence;
/// - a slow average of the speaker's own level, so a quiet mic still moves
///   the bars and a loud one doesn't clip.
/// Full scale sits `headroomDB` above that average and the curve expands the
/// top, so ordinary speech lands mid-bar and only stressed syllables reach the
/// top (a peak-following scale pinned every word at the maximum).
/// Attack is fast and release slower, like a VU meter.
public struct SpeechLevelMeter: Sendable {
    private var noiseFloorDB: Float = -50
    private var speechDB: Float = -30
    private var smoothed: Float = 0

    /// Steady sound within this many dB above the floor counts as room noise.
    private static let noiseBand: Float = 10
    /// Levels this far above the floor still read as silence.
    private static let gateDB: Float = 6
    /// Smallest floor-to-speech distance, so silence is never amplified into motion.
    private static let minimumRangeDB: Float = 18
    /// Full scale, above the average speech level.
    private static let headroomDB: Float = 20
    /// >1 keeps quieter syllables low, so the bars show the rhythm of speech.
    private static let curve: Float = 1.8

    public init() {}

    /// One update per audio slice (~40 ms).
    public mutating func level(forRMS rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))

        if db < noiseFloorDB {
            noiseFloorDB += (db - noiseFloorDB) * 0.3
        } else if db < noiseFloorDB + Self.noiseBand {
            noiseFloorDB += (db - noiseFloorDB) * 0.02
        }
        noiseFloorDB = min(noiseFloorDB, -30)

        let gate = noiseFloorDB + Self.gateDB
        if db > gate + 6 {
            speechDB += (db - speechDB) * 0.04
        }
        speechDB = min(max(speechDB, noiseFloorDB + Self.minimumRangeDB), -12)

        let fullScale = speechDB + Self.headroomDB
        let normalized = max(0, min(1, (db - gate) / (fullScale - gate)))
        let shaped = pow(normalized, Self.curve)

        let rate: Float = shaped > smoothed ? 0.45 : 0.25
        smoothed += (shaped - smoothed) * rate
        return smoothed
    }
}

@MainActor
@Observable
public final class AudioLevelMonitor {
    public private(set) var levels: [Float]
    public let barCount: Int
    @ObservationIgnored private var meter = SpeechLevelMeter()

    public init(barCount: Int = 14) {
        self.barCount = barCount
        self.levels = Array(repeating: 0, count: barCount)
    }

    /// Feeds raw RMS values (one per audio slice, oldest first). The meter
    /// runs on every slice; the bars advance once per call (one audio buffer,
    /// ~85 ms), showing the loudest slice, so the wave doesn't race by.
    public func push(rms values: [Float]) {
        guard !values.isEmpty else { return }
        var loudest: Float = 0
        for rms in values {
            loudest = max(loudest, meter.level(forRMS: rms))
        }
        var next = levels
        next.removeFirst()
        next.append(loudest)
        levels = next
    }

    /// Starts a new recording from flat bars. The calibration carries over:
    /// it is usually the same mic and room, so the first word already reads
    /// right; a new mic re-calibrates within a couple of seconds.
    public func reset() {
        levels = Array(repeating: 0, count: barCount)
    }
}
