import AVFoundation
import Cocoa
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private lazy var dictation = DictationController(overlay: overlay)
    private let hotkeys = HotkeyMonitor()
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var tapRetry: Timer?
    private var modelError: String?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
        dictation.onPhaseChange = { [weak self] _ in self?.updateStatusIcon() }

        let simulatedFile = CLI.value(after: "--simulate")
        dictation.loadModel { [weak self] error in
            self?.modelError = error?.localizedDescription
            Log.write(error.map { "model failed: \($0.localizedDescription)" } ?? "model ready")
            if let simulatedFile {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self?.dictation.simulate(file: URL(fileURLWithPath: simulatedFile))
                }
            }
        }

        hotkeys.hotkey = settings.hotkey
        hotkeys.handler = { [weak self] event in self?.dictation.handle(event) ?? false }
        settings.$hotkey.sink { [weak self] in self?.hotkeys.hotkey = $0 }.store(in: &subscriptions)
        startHotkeys()

        guard simulatedFile == nil else { return }
        if Permissions.microphone == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if !Permissions.accessibility || Permissions.microphone != .authorized
            || (settings.hotkey == .fn && !Permissions.fnKeyIsFree) {
            showSettings()
        }
    }

    /// The event tap can only be created once Accessibility is granted, so keep trying until it is.
    private func startHotkeys() {
        Log.write("accessibility: \(Permissions.accessibility ? "granted" : "not granted"), "
                  + "microphone: \(Permissions.microphoneDescription)")
        if hotkeys.start() { return Log.write("listening for \(settings.hotkey.shortTitle)") }
        Log.write("waiting for Accessibility permission")
        if CLI.value(after: "--simulate") == nil { Permissions.promptAccessibility() }
        tapRetry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, self.hotkeys.start() else { return }
            timer.invalidate()
            self.updateStatusIcon()
            Log.write("listening for \(self.settings.hotkey.shortTitle)")
            self.overlay.flash("Ready — hold \(self.settings.hotkey.shortTitle) and speak", seconds: 3)
        }
    }

    private func updateStatusIcon() {
        let symbol: String
        switch dictation.phase {
        case .idle: symbol = hotkeys.isRunning ? "waveform" : "waveform.slash"
        case .recording: symbol = "mic.fill"
        case .processing: symbol = "ellipsis"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whistle Flow")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private var statusText: String {
        if let modelError { return "Model error: \(modelError)" }
        if !dictation.modelReady { return "Loading Whistle…" }
        if !hotkeys.isRunning { return "Needs Accessibility permission" }
        if Permissions.microphone != .authorized { return "Needs microphone permission" }
        switch dictation.phase {
        case .idle: return "Ready"
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled("Whistle Flow — \(statusText)"))
        menu.addItem(disabled("Hold \(settings.hotkey.shortTitle) to dictate · add Space for hands-free"))
        menu.addItem(.separator())

        let toggleTitle = dictation.phase == .idle ? "Start Hands-Free Dictation" : "Finish Dictation"
        menu.addItem(item(toggleTitle, #selector(toggleDictation)))
        let copyLast = item("Copy Last Transcript", #selector(copyLastTranscript))
        copyLast.isEnabled = dictation.lastTranscript != nil || !HistoryStore.shared.entries.isEmpty
        menu.addItem(copyLast)

        let recent = NSMenu()
        for entry in HistoryStore.shared.entries.prefix(10) {
            let flat = entry.text.replacingOccurrences(of: "\n", with: " ")
            let title = flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
            let recentItem = item(title, #selector(copyHistoryEntry(_:)))
            recentItem.representedObject = entry.text
            recentItem.toolTip = "Click to copy"
            recent.addItem(recentItem)
        }
        if recent.items.isEmpty { recent.addItem(disabled("No dictations yet")) }
        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())

        let languages = NSMenu()
        for (code, name) in Languages.all {
            let languageItem = item(name, #selector(selectLanguage(_:)))
            languageItem.representedObject = code
            languageItem.state = settings.language == code ? .on : .off
            languages.addItem(languageItem)
        }
        let microphones = NSMenu()
        let automatic = item("Automatic (\(AudioDevices.resolve(AudioDevices.automatic)?.name ?? "default"))",
                             #selector(selectMicrophone(_:)))
        automatic.representedObject = AudioDevices.automatic
        microphones.addItem(automatic)
        microphones.addItem(.separator())
        for device in AudioDevices.inputs() {
            let deviceItem = item(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name,
                                  #selector(selectMicrophone(_:)))
            deviceItem.representedObject = device.uid
            microphones.addItem(deviceItem)
        }
        for microphoneItem in microphones.items {
            microphoneItem.state = microphoneItem.representedObject as? String == settings.microphone ? .on : .off
        }
        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = microphones
        menu.addItem(microphoneItem)

        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        menu.addItem(languageItem)
        let fillers = item("Remove Filler Words", #selector(toggleFillers))
        fillers.state = settings.removeFillers ? .on : .off
        menu.addItem(fillers)
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Quit Whistle Flow", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = action == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return menuItem
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    @objc private func toggleDictation() { dictation.toggleHandsFree() }

    @objc private func copyLastTranscript() {
        guard let text = dictation.lastTranscript ?? HistoryStore.shared.entries.first?.text else { return }
        copy(text)
    }

    @objc private func copyHistoryEntry(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { copy(text) }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { settings.language = code }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String { settings.microphone = uid }
    }

    @objc private func toggleFillers() { settings.removeFillers.toggle() }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        overlay.flash("Copied", seconds: 0.8)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Whistle Flow"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
