import Cocoa

/// Command-line modes, for checking the engine and the cleaner without the UI:
///   WhistleFlow --transcribe clip.wav [--language en]
///   WhistleFlow --clean "Um, so, uh, new paragraph"
enum CLI {
    static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func run() -> Int32? {
        if CommandLine.arguments.contains("--list-mics") {
            let systemDefault = AudioDevices.defaultInput?.uid
            for device in AudioDevices.inputs() {
                print("\(device.name)\(device.isBluetooth ? " [Bluetooth]" : "")\(device.isBuiltIn ? " [built-in]" : "")"
                      + "\(device.uid == systemDefault ? " [system default]" : "")  uid=\(device.uid)")
            }
            print("automatic → \(AudioDevices.resolve(AudioDevices.automatic)?.name ?? "none")")
            return 0
        }
        if CommandLine.arguments.contains("--mic-check") {
            return micCheck(setting: value(after: "--mic-check") ?? AudioDevices.automatic)
        }
        if let text = value(after: "--clean") {
            print(TextCleaner().clean(text))
            return 0
        }
        guard let path = value(after: "--transcribe") else { return nil }
        let language = value(after: "--language")
        let engine = WhistleEngine.shared
        return engine.queue.sync {
            do {
                var started = Date()
                try engine.loadIfNeeded()
                print(String(format: "load        %6.0f ms", Date().timeIntervalSince(started) * 1000))
                let pcm = try AudioFile.load16kMono(URL(fileURLWithPath: path))
                let seconds = Double(pcm.count) / Double(WhistleEngine.sampleRate)

                started = Date()
                let oneShot = try engine.transcribe(Array(pcm.prefix(WhistleEngine.maxOneShotSamples)),
                                                    language: language, keywords: nil)
                print(String(format: "one-shot    %6.0f ms  (%.1f s audio, %@)", Date().timeIntervalSince(started) * 1000,
                             seconds, oneShot.language ?? "-"))
                print("  raw:   " + oneShot.text)
                print("  clean: " + TextCleaner().clean(oneShot.text))

                started = Date()
                var parts: [String] = []
                var offset = 0
                while offset < pcm.count {
                    let chunk = Array(pcm[offset..<min(offset + WhistleEngine.sampleRate, pcm.count)])
                    parts.append(try engine.streamProcess(chunk, language: language, keywords: nil).text)
                    offset += chunk.count
                }
                parts.append(try engine.streamStop().text)
                print(String(format: "stream      %6.0f ms  (%d passes)", Date().timeIntervalSince(started) * 1000, parts.count))
                print("  raw:   " + parts.filter { !$0.isEmpty }.joined(separator: " "))
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        }
    }
}

extension CLI {
    /// Records a few seconds, prints the loudness and what Whistle heard. Nothing is saved.
    static func micCheck(setting: String) -> Int32 {
        let device = AudioDevices.resolve(setting.hasPrefix("--") ? AudioDevices.automatic : setting)
        print("microphone: \(device?.name ?? "system default")")
        let recorder = AudioRecorder()
        let lock = NSLock()
        var count = 0
        var peak: Float = 0
        var firstSound: Int?
        let started = Date()
        var firstBuffer: TimeInterval?
        var pcm: [Float] = []
        recorder.onAudio = { samples, _ in
            lock.lock()
            defer { lock.unlock() }
            if firstBuffer == nil { firstBuffer = Date().timeIntervalSince(started) }
            let loudest = samples.map(abs).max() ?? 0
            if firstSound == nil, loudest > 0.003 { firstSound = count }
            peak = max(peak, loudest)
            count += samples.count
            pcm += samples
        }
        var failure: Error?
        recorder.start(device: device) { failure = $0 }
        Thread.sleep(forTimeInterval: Double(value(after: "--seconds") ?? "") ?? 2)
        let stopped = DispatchSemaphore(value: 0)
        recorder.stop { stopped.signal() }
        stopped.wait()
        if let failure {
            print("error: \(failure.localizedDescription)")
            return 1
        }
        lock.lock()
        print(firstBuffer.map { String(format: "first audio after %.0f ms", $0 * 1000) } ?? "no audio delivered")
        defer { lock.unlock() }
        let rate = Double(WhistleEngine.sampleRate)
        print(String(format: "captured %.2f s, peak %.0f dBFS, first sound after %@", Double(count) / rate,
                     20 * log10(max(peak, 1e-7)), firstSound.map { String(format: "%.2f s", Double($0) / rate) } ?? "never"))
        let engine = WhistleEngine.shared
        let heard = engine.queue.sync {
            try? engine.transcribe(Array(pcm.prefix(WhistleEngine.maxOneShotSamples)), language: nil, keywords: nil).text
        }
        print("heard: \(heard.map { $0.isEmpty ? "(no speech)" : $0 } ?? "(transcription failed)")")
        return 0
    }
}

if let code = CLI.run() { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
