import AVFoundation
import Cocoa

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var microphoneDescription: String {
        switch microphone {
        case .authorized: return "granted"
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// "Press 🌐 key to" in Keyboard settings: 0 Do Nothing, 1 Change Input Source, 2 Emoji, 3 Dictation.
    /// Unset means the system default, which is not Do Nothing.
    static var fnKeyIsFree: Bool {
        (CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int) == 0
    }

    static func openPrivacyPane(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
}

/// Polls permission state while the settings window is open; none of it posts change notifications.
final class PermissionsModel: ObservableObject {
    @Published var microphone = Permissions.microphone
    @Published var accessibility = Permissions.accessibility
    @Published var fnKeyIsFree = Permissions.fnKeyIsFree
    private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        microphone = Permissions.microphone
        accessibility = Permissions.accessibility
        fnKeyIsFree = Permissions.fnKeyIsFree
    }
}
