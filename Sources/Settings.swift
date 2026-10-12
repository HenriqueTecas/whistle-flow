import Foundation

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        case .rightControl: return "Right ⌃ Control"
        }
    }

    var shortTitle: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        case .rightControl: return "right ⌃"
        }
    }
}

enum Languages {
    static let all: [(code: String, name: String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("de", "German"), ("fr", "French"),
        ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"),
    ]
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hotkey: HotkeyChoice { didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// An input device UID, or AudioDevices.automatic.
    @Published var microphone: String { didSet { defaults.set(microphone, forKey: "microphone") } }
    @Published var removeFillers: Bool { didSet { defaults.set(removeFillers, forKey: "removeFillers") } }
    @Published var voiceCommands: Bool { didSet { defaults.set(voiceCommands, forKey: "voiceCommands") } }
    @Published var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var livePreview: Bool { didSet { defaults.set(livePreview, forKey: "livePreview") } }
    @Published var keepHistory: Bool { didSet { defaults.set(keepHistory, forKey: "keepHistory") } }
    @Published var dictionary: [String] { didSet { defaults.set(dictionary, forKey: "dictionary") } }
    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: "snippets") }
    }

    private init() {
        defaults.register(defaults: [
            "hotkey": HotkeyChoice.fn.rawValue, "language": "en", "microphone": AudioDevices.automatic,
            "removeFillers": true, "voiceCommands": true,
            "smartSpacing": true, "sounds": true, "livePreview": true, "keepHistory": true,
        ])
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        language = defaults.string(forKey: "language") ?? "en"
        microphone = defaults.string(forKey: "microphone") ?? AudioDevices.automatic
        removeFillers = defaults.bool(forKey: "removeFillers")
        voiceCommands = defaults.bool(forKey: "voiceCommands")
        smartSpacing = defaults.bool(forKey: "smartSpacing")
        sounds = defaults.bool(forKey: "sounds")
        livePreview = defaults.bool(forKey: "livePreview")
        keepHistory = defaults.bool(forKey: "keepHistory")
        dictionary = defaults.stringArray(forKey: "dictionary") ?? []
        snippets = defaults.data(forKey: "snippets").flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }

    /// nil lets Whistle detect the language.
    var languageCode: String? { language == "auto" ? nil : language }

    /// Dictionary words as Whistle keyword biasing: newline-separated phrases.
    var keywords: String? {
        let words = dictionary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return words.isEmpty ? nil : words.joined(separator: "\n")
    }

    var cleaner: TextCleaner {
        TextCleaner(removeFillers: removeFillers, voiceCommands: voiceCommands, snippets: snippets)
    }
}
