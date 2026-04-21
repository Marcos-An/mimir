import Foundation
import Observation

@MainActor
@Observable
public final class ModelDownloadMonitor {
    public private(set) var isActive: Bool = false
    public private(set) var fractionCompleted: Double = 0
    public private(set) var label: String = ""
    public private(set) var isIndeterminate: Bool = false

    public init() {}

    public func start(label: String, indeterminate: Bool = false) {
        self.label = label
        self.fractionCompleted = 0
        self.isIndeterminate = indeterminate
        self.isActive = true
    }

    public func update(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        self.fractionCompleted = clamped
        if clamped > 0 && clamped < 1 {
            self.isIndeterminate = false
        }
    }

    public func finish() {
        self.isActive = false
        self.isIndeterminate = false
        self.fractionCompleted = 1
    }
}
