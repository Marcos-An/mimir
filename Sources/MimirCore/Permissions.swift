import AVFoundation
import ApplicationServices
import Foundation
import IOKit.hid
import Speech

public enum PermissionCoordinator {
    @discardableResult
    public static func ensureInputMonitoring() -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
            return true
        }
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static var isInputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    public static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
            }
            if granted { return }
            throw MimirError.microphonePermissionDenied
        default:
            throw MimirError.microphonePermissionDenied
        }
    }

    public static func ensureSpeechAccess() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            if status == .authorized { return }
            throw MimirError.speechPermissionDenied
        default:
            throw MimirError.speechPermissionDenied
        }
    }

    @discardableResult
    public static func ensureAccessibilityAccess(prompt: Bool) throws -> Bool {
        let options = ["AXTrustedCheckOptionPrompt" as String: prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted { return true }
        throw MimirError.accessibilityPermissionDenied
    }
}
