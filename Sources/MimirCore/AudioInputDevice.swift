import CoreAudio
import Foundation

public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let deviceID: AudioDeviceID

    public var id: String { uid }

    public init(uid: String, name: String, deviceID: AudioDeviceID) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
    }

    public static func allInputs() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        ) == noErr else {
            return []
        }

        return ids.compactMap(device(for:))
    }

    public static func device(forUID uid: String) -> AudioInputDevice? {
        allInputs().first(where: { $0.uid == uid })
    }

    public static func systemDefaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return device(for: deviceID)
    }

    private static func device(for id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInputChannels(id) else { return nil }
        guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? "Desconhecido"
        return AudioInputDevice(uid: uid, name: name, deviceID: id)
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else {
            return false
        }

        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        return abl.contains(where: { $0.mNumberChannels > 0 })
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { pointer -> OSStatus in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw)
            }
        }
        guard status == noErr, let ref else { return nil }
        return ref as String
    }
}
