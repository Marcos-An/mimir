import Foundation
import Observation

@MainActor
@Observable
public final class AudioLevelMonitor {
    public private(set) var levels: [Float]
    public let barCount: Int

    public init(barCount: Int = 14) {
        self.barCount = barCount
        self.levels = Array(repeating: 0, count: barCount)
    }

    public func push(_ newLevel: Float) {
        let clamped = max(0, min(1, newLevel))
        levels.removeFirst()
        levels.append(clamped)
    }

    public func reset() {
        levels = Array(repeating: 0, count: barCount)
    }
}
