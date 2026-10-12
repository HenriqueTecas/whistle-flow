import Accelerate
import AVFoundation
import Cocoa

/// The audio and transcription state of one dictation. Confined to the engine queue.
private final class DictationSession {
    let language: String?
    let keywords: String?
    var onPreview: ((String) -> Void)?

    private var pcm: [Float] = []
    private var chunk: [Float] = []
    private var committed: [String] = []
    private var pending = ""
    private var streaming = false
    private var closed = false
    private(set) var peak: Float = 0

    init(language: String?, keywords: String?) {
        self.language = language
        self.keywords = keywords
    }

    var seconds: Double { Double(pcm.count) / Double(WhistleEngine.sampleRate) }

    /// Buffers audio and, every second of it, advances Whistle's live stream. The stream drives the
    /// preview and is the transcript for dictations longer than the 30 s one-shot limit.
    func ingest(_ samples: [Float], engine: WhistleEngine) {
        guard !closed else { return }
        var loudest: Float = 0
        vDSP_maxmgv(samples, 1, &loudest, vDSP_Length(samples.count))
        peak = max(peak, loudest)
        pcm += samples
        chunk += samples
        guard chunk.count >= WhistleEngine.sampleRate else { return }
        let step = try? engine.streamProcess(chunk, language: language, keywords: keywords)
        streaming = true
        chunk.removeAll(keepingCapacity: true)
        guard let step else { return }
        if !step.text.isEmpty { committed.append(step.text) }
        pending = step.pending ?? ""
        onPreview?(Self.join(committed + [pending]))
    }

    func finish(engine: WhistleEngine) throws -> String {
        closed = true
        if pcm.count <= WhistleEngine.maxOneShotSamples {
            // One pass over the whole clip beats the stitched stream, and takes well under 100 ms.
            if streaming { _ = try? engine.streamStop() }
            return try engine.transcribe(pcm, language: language, keywords: keywords).text
        }
        if !chunk.isEmpty, let step = try? engine.streamProcess(chunk, language: language, keywords: keywords) {
            committed.append(step.text)
        }
        committed.append(try engine.streamStop().text)
        return Self.join(committed)
    }

    /// Stitches stream segments, capitalizing a segment that starts a new sentence.
    static func join(_ segments: [String]) -> String {
        segments.filter { !$0.isEmpty }.reduce("") { text, segment in
            guard let last = text.last else { return segment }
            var segment = segment
            if ".!?".contains(last), let first = segment.first, first.isLowercase {
                segment = first.uppercased() + segment.dropFirst()
            }
            return text + " " + segment
        }
    }

    func cancel(engine: WhistleEngine) {
        closed = true
        if streaming { _ = try? engine.streamStop() }
    }
}

/// Runs dictation end to end: key press, recording, transcription, cleanup, paste.
final class DictationController {
    enum Phase: Equatable { case idle, recording(handsFree: Bool), processing }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onPhaseChange: ((Phase) -> Void)?
    private(set) var modelReady = false
    private(set) var lastTranscript: String?

    private static let minimumHold: TimeInterval = 0.3
    private static let maximumLength: TimeInterval = 15 * 60

    private let engine = WhistleEngine.shared
    private let recorder = AudioRecorder()
    private let overlay: OverlayController
    private let settings = AppSettings.shared
    private var session: DictationSession?
    private var startedAt = Date()
    private var targetApp: String?
    private var microphone: String?
    private var limitTimer: Timer?

    init(overlay: OverlayController) {
        self.overlay = overlay
        overlay.onStop = { [weak self] in self?.finish("stop button") }
        overlay.onCancel = { [weak self] in self?.cancel(silently: false, "cancel button") }
    }

    func loadModel(completion: @escaping (Error?) -> Void) {
        let engine = self.engine
        engine.queue.async {
            do {
                try engine.loadIfNeeded()
                _ = try? engine.transcribe([Float](repeating: 0, count: 8000), language: "en", keywords: nil)  // warm-up
                DispatchQueue.main.async {
                    self.modelReady = true
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Hotkey events, on the main thread. Returns true to swallow the key.
    func handle(_ event: HotkeyMonitor.Event) -> Bool {
        switch (event, phase) {
        case (.triggerDown, .idle):
            start(handsFree: false)
        case (.triggerDown, .recording(handsFree: true)):
            finish("key pressed")
        case (.triggerUp, .recording(handsFree: false)):
            // A quick tap is an accident, not a dictation.
            if Date().timeIntervalSince(startedAt) < Self.minimumHold {
                cancel(silently: true, "quick tap")
                overlay.flash("Hold \(settings.hotkey.shortTitle) while you speak", seconds: 1.4)
            } else {
                finish("key released")
            }
        case (.space, .recording(handsFree: false)):
            phase = .recording(handsFree: true)
            overlay.show(.handsFree)
            return true
        case (.escape, .recording):
            cancel(silently: false, "escape")
            return true
        case (.otherKey, .recording(handsFree: false)):
            cancel(silently: true, "shortcut")  // the key was part of a shortcut such as Fn+Delete
        default:
            break
        }
        return false
    }

    func toggleHandsFree() {
        switch phase {
        case .idle: start(handsFree: true)
        case .recording: finish("menu")
        case .processing: break
        }
    }

    func start(handsFree: Bool, fromMicrophone: Bool = true) {
        guard phase == .idle else { return }
        guard modelReady else { return overlay.flash("Loading Whistle…") }
        if fromMicrophone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                break
            case .notDetermined:
                Log.write("start blocked: microphone not asked yet")
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                return overlay.flash("Allow microphone access, then try again")
            default:
                Log.write("start blocked: microphone denied")
                return overlay.flash("Microphone access is off — see Settings")
            }
        }

        let device = fromMicrophone ? AudioDevices.resolve(settings.microphone) : nil
        microphone = fromMicrophone ? device?.name ?? "system default" : "simulated"
        let session = DictationSession(language: settings.languageCode, keywords: settings.keywords)
        if settings.livePreview {
            session.onPreview = { [weak self] text in DispatchQueue.main.async { self?.overlay.model.preview = text } }
        }
        self.session = session
        Log.write("start: \(handsFree ? "hands-free" : "push-to-talk"), mic: \(microphone ?? "-")")
        targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
        startedAt = Date()
        phase = .recording(handsFree: handsFree)
        overlay.reset(showPreview: settings.livePreview)
        overlay.show(handsFree ? .handsFree : .listening)
        if settings.sounds { Sounds.play("Tink") }
        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumLength, repeats: false) { [weak self] _ in
            self?.finish("time limit")
        }
        guard fromMicrophone else { return }

        // Start the microphone after the key event returns, so the event tap never waits on audio setup.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session else { return }
            let engine = self.engine
            self.recorder.onAudio = { [weak self] samples, level in
                engine.queue.async { session.ingest(samples, engine: engine) }
                DispatchQueue.main.async { self?.overlay.push(level: level) }
            }
            self.recorder.start(device: device) { [weak self] error in
                guard let self, self.session === session else { return }
                self.cancel(silently: true, "microphone error: \(error.localizedDescription)")
                self.overlay.flash(error.localizedDescription)
            }
        }
    }

    func finish(_ reason: String) {
        guard case .recording = phase, let session else { return }
        Log.write("finish: \(reason)")
        limitTimer?.invalidate()
        phase = .processing
        overlay.show(.processing)
        if settings.sounds { Sounds.play("Pop") }

        let cleaner = settings.cleaner
        let app = targetApp
        let microphone = self.microphone ?? "-"
        let releasedAt = Date()
        let engine = self.engine
        // Transcribe only once the recorder has handed over its last samples.
        recorder.stop { engine.queue.async {
            let seconds = session.seconds
            let peak = 20 * log10(max(session.peak, 1e-7))
            Log.write(String(format: "heard %.1f s from %@, peak %.0f dBFS", seconds, microphone, peak))
            let result = Result { try session.finish(engine: engine) }
            DispatchQueue.main.async { [weak self] in
                self?.deliver(result, cleaner: cleaner, app: app, seconds: seconds, releasedAt: releasedAt)
            }
        } }
    }

    func cancel(silently: Bool, _ reason: String) {
        guard case .recording = phase, let session else { return }
        Log.write("cancel: \(reason)")
        recorder.stop()
        limitTimer?.invalidate()
        self.session = nil
        phase = .idle
        let engine = self.engine
        engine.queue.async { session.cancel(engine: engine) }
        if silently { overlay.hide() } else { overlay.flash("Cancelled", seconds: 0.9) }
    }

    private func deliver(_ result: Result<String, Error>, cleaner: TextCleaner, app: String?, seconds: Double,
                         releasedAt: Date) {
        session = nil
        phase = .idle
        let raw: String
        switch result {
        case .success(let text): raw = text
        case .failure(let error):
            Log.write("error: \(error.localizedDescription)")
            return overlay.flash(error.localizedDescription, seconds: 3)
        }
        let text = cleaner.clean(raw)
        guard !text.isEmpty else {
            Log.write("no speech in the audio")
            return overlay.flash("No speech detected", seconds: 1.2)
        }

        lastTranscript = text
        let pasted = Paster.insert(text, smartSpacing: settings.smartSpacing)
        if pasted { overlay.hide() } else { overlay.flash("Copied — grant Accessibility to paste automatically", seconds: 2.5) }
        let latency = Date().timeIntervalSince(releasedAt) * 1000
        Log.write(String(format: "%.1f s audio, %.0f ms to %@", seconds, latency, pasted ? "paste" : "copy"))
        if settings.keepHistory {
            HistoryStore.shared.add(HistoryEntry(date: Date(), text: text, raw: raw, app: app, seconds: seconds,
                                                 latencyMs: latency))
        }
    }

    /// Plays an audio file through the whole pipeline in real time, as if spoken into the microphone.
    func simulate(file: URL) {
        guard let samples = try? AudioFile.load16kMono(file), !samples.isEmpty else {
            return overlay.flash("Can't read \(file.lastPathComponent)")
        }
        start(handsFree: false, fromMicrophone: false)
        guard let session else { return }
        let engine = self.engine
        let step = WhistleEngine.sampleRate / 20
        var offset = 0
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.session === session, case .recording = self.phase else { return timer.invalidate() }
            guard offset < samples.count else {
                timer.invalidate()
                return self.finish("end of file")
            }
            let chunk = Array(samples[offset..<min(offset + step, samples.count)])
            offset += step
            self.overlay.push(level: chunk.withUnsafeBufferPointer { AudioRecorder.level(of: $0.baseAddress!, count: $0.count) })
            engine.queue.async { session.ingest(chunk, engine: engine) }
        }
    }
}

enum Sounds {
    static func play(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = 0.25
        sound.play()
    }
}
