import Foundation
#if os(macOS)
import Darwin
import MachO
#endif

public struct SystemResourceSnapshot: Codable, Equatable, Sendable {
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var systemUptimeSeconds: TimeInterval
    public var thermalState: String
    public var loadAverage1m: Double?
    public var loadAverage5m: Double?
    public var loadAverage15m: Double?
    public var memoryFreeBytes: UInt64?
    public var memoryActiveBytes: UInt64?
    public var memoryInactiveBytes: UInt64?
    public var memoryWiredBytes: UInt64?
    public var memoryCompressedBytes: UInt64?

    public init(
        processorCount: Int,
        physicalMemoryBytes: UInt64,
        systemUptimeSeconds: TimeInterval,
        thermalState: String,
        loadAverage1m: Double? = nil,
        loadAverage5m: Double? = nil,
        loadAverage15m: Double? = nil,
        memoryFreeBytes: UInt64? = nil,
        memoryActiveBytes: UInt64? = nil,
        memoryInactiveBytes: UInt64? = nil,
        memoryWiredBytes: UInt64? = nil,
        memoryCompressedBytes: UInt64? = nil
    ) {
        self.processorCount = processorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemUptimeSeconds = systemUptimeSeconds
        self.thermalState = thermalState
        self.loadAverage1m = loadAverage1m
        self.loadAverage5m = loadAverage5m
        self.loadAverage15m = loadAverage15m
        self.memoryFreeBytes = memoryFreeBytes
        self.memoryActiveBytes = memoryActiveBytes
        self.memoryInactiveBytes = memoryInactiveBytes
        self.memoryWiredBytes = memoryWiredBytes
        self.memoryCompressedBytes = memoryCompressedBytes
    }

    public static func capture() -> SystemResourceSnapshot {
        let processInfo = ProcessInfo.processInfo
        let loads = currentLoadAverage()
        let memory = currentMemoryStats()
        return SystemResourceSnapshot(
            processorCount: processInfo.processorCount,
            physicalMemoryBytes: processInfo.physicalMemory,
            systemUptimeSeconds: processInfo.systemUptime,
            thermalState: String(describing: processInfo.thermalState),
            loadAverage1m: loads[safe: 0],
            loadAverage5m: loads[safe: 1],
            loadAverage15m: loads[safe: 2],
            memoryFreeBytes: memory.freeBytes,
            memoryActiveBytes: memory.activeBytes,
            memoryInactiveBytes: memory.inactiveBytes,
            memoryWiredBytes: memory.wiredBytes,
            memoryCompressedBytes: memory.compressedBytes
        )
    }

    private static func currentLoadAverage() -> [Double] {
        #if os(macOS)
        var values = [Double](repeating: 0, count: 3)
        let count = getloadavg(&values, Int32(values.count))
        guard count > 0 else { return [] }
        return Array(values.prefix(Int(count)))
        #else
        return []
        #endif
    }

    private static func currentMemoryStats() -> (
        freeBytes: UInt64?,
        activeBytes: UInt64?,
        inactiveBytes: UInt64?,
        wiredBytes: UInt64?,
        compressedBytes: UInt64?
    ) {
        #if os(macOS)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (nil, nil, nil, nil, nil)
        }
        let pageSize = UInt64(getpagesize())
        return (
            freeBytes: UInt64(stats.free_count) * pageSize,
            activeBytes: UInt64(stats.active_count) * pageSize,
            inactiveBytes: UInt64(stats.inactive_count) * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize
        )
        #else
        return (nil, nil, nil, nil, nil)
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
