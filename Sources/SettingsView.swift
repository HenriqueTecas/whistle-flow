import AVFoundation
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @StateObject private var permissions = PermissionsModel()

    var body: some View {
        TabView {
            GeneralTab(permissions: permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryTab()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            SnippetsTab()
                .tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 600, height: 520)
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }
}

private struct GeneralTab: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = HistoryStore.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var microphones: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "To hear you while the dictation key is held.",
                              granted: permissions.microphone == .authorized) {
                    if permissions.microphone == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        Permissions.openPrivacyPane("Privacy_Microphone")
                    }
                }
                PermissionRow(title: "Accessibility", detail: "To notice the dictation key and paste into other apps.",
                              granted: permissions.accessibility) {
                    Permissions.promptAccessibility()
                    Permissions.openPrivacyPane("Privacy_Accessibility")
                }
                if settings.hotkey == .fn && !permissions.fnKeyIsFree {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set “Press 🌐 key to” to “Do Nothing”")
                            Text("Otherwise the Fn key also opens the emoji picker or switches input source.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Keyboard Settings…") { Permissions.openKeyboardSettings() }
                    }
                }
            }

            Section("Dictation") {
                Picker("Dictation key", selection: $settings.hotkey) {
                    ForEach(HotkeyChoice.allCases) { Text($0.title).tag($0) }
                }
                Text("Hold to talk, release to paste. Tap Space while holding to go hands-free, then press the key again to finish. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Microphone", selection: $settings.microphone) {
                    Text("Automatic — built-in mic over Bluetooth").tag(AudioDevices.automatic)
                    ForEach(microphones, id: \.uid) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name).tag(device.uid)
                    }
                }
                .onAppear { microphones = AudioDevices.inputs() }
                if let chosen = AudioDevices.resolve(settings.microphone), chosen.isBluetooth {
                    Text("Bluetooth headsets take a second or two to turn their mic on each time you dictate, so the start of what you say gets lost, and your audio drops to call quality while recording.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
            }

            Section("Formatting") {
                Toggle("Remove filler words (um, uh, erm)", isOn: $settings.removeFillers)
                Toggle("Voice commands: “new line”, “new paragraph”", isOn: $settings.voiceCommands)
                Toggle("Add a space when continuing existing text", isOn: $settings.smartSpacing)
            }

            Section("App") {
                Toggle("Show live transcript while speaking", isOn: $settings.livePreview)
                Toggle("Play sounds", isOn: $settings.sounds)
                Toggle("Keep dictation history", isOn: $settings.keepHistory)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Model", value: "Whistle by Cactus · 16.9 MB · runs on this Mac")
                LabeledContent("Dictated", value: "\(history.totalWords.formatted()) words in \(history.entries.count.formatted()) dictations")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}

private struct DictionaryTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Names, jargon and acronyms Whistle should listen for. They're passed to the model as keyword biasing, so it favors these spellings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Add a word or phrase", text: $newWord).onSubmit(add)
                Button("Add", action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(settings.dictionary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button { settings.dictionary.removeAll { $0 == word } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if settings.dictionary.isEmpty {
                    Text("No words yet").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !settings.dictionary.contains(word) else { return }
        settings.dictionary.append(word)
        newWord = ""
    }
}

private struct SnippetsTab: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Say the trigger phrase and the expansion is typed instead, like “my calendar link” → a full URL.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Trigger phrase", text: $trigger).frame(width: 170)
                TextField("Expands to", text: $expansion).onSubmit(add)
                Button("Add", action: add)
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
            }
            List {
                ForEach(settings.snippets) { snippet in
                    HStack(alignment: .firstTextBaseline) {
                        Text(snippet.trigger).bold().frame(width: 160, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(snippet.expansion).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button { settings.snippets.removeAll { $0.id == snippet.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if settings.snippets.isEmpty {
                    Text("No snippets yet").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
    }

    private func add() {
        let phrase = trigger.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty, !expansion.isEmpty else { return }
        settings.snippets.append(Snippet(trigger: phrase, expansion: expansion))
        trigger = ""
        expansion = ""
    }
}

private struct HistoryTab: View {
    @ObservedObject private var history = HistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(history.entries.count) dictations, kept only on this Mac.").foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { history.clear() }.disabled(history.entries.isEmpty)
            }
            List(history.entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text).lineLimit(4).textSelection(.enabled)
                        Text(caption(for: entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    Button { history.remove(entry.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete")
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if history.entries.isEmpty {
                    Text("Nothing dictated yet").foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
    }

    private func caption(for entry: HistoryEntry) -> String {
        var parts = [entry.date.formatted(date: .abbreviated, time: .shortened)]
        if let app = entry.app { parts.append(app) }
        parts.append(String(format: "%.1f s", entry.seconds))
        parts.append(String(format: "%.0f ms", entry.latencyMs))
        return parts.joined(separator: " · ")
    }
}
