import Foundation

struct Transcript: Decodable {
    let text: String
    let language: String?
    let ttft_ms: Double?
    let decode_tps: Double?
}

struct StreamStep: Decodable {
    let text: String
    let pending: String?
    let language: String?
    let received: Double?
    let pass_ms: Double?
}

enum EngineError: LocalizedError {
    case modelMissing
    case native(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "Whistle model (whistle.cact) not found"
        case .native(let message): return message
        }
    }
}

/// Wraps the Cactus Needle C engine running the Whistle speech model.
/// The engine holds one process-global model and is not thread-safe, so every call must run on `queue`.
final class WhistleEngine {
    static let shared = WhistleEngine()
    static let sampleRate = 16_000
    /// needle_transcribe accepts at most 30 s; longer dictations go through the streaming API.
    static let maxOneShotSamples = 30 * sampleRate

    let queue = DispatchQueue(label: "whistleflow.engine", qos: .userInitiated)
    private var out = [CChar](repeating: 0, count: 1 << 18)
    private(set) var isLoaded = false

    static func modelURL() -> URL? {
        let candidates: [URL?] = [
            ProcessInfo.processInfo.environment["WHISTLE_MODEL"].map { URL(fileURLWithPath: $0) },
            Bundle.main.url(forResource: "whistle", withExtension: "cact"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/cactus-needle/whistle/2.0.0/whistle.cact"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func loadIfNeeded() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        if isLoaded { return }
        guard let url = Self.modelURL() else { throw EngineError.modelMissing }
        let data = try Data(contentsOf: url)
        let rc = data.withUnsafeBytes { raw in
            needle_load(raw.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count))
        }
        if rc < 0 { throw EngineError.native(lastError()) }
        isLoaded = true
    }

    func transcribe(_ pcm: [Float], language: String?, keywords: String?) throws -> Transcript {
        try loadIfNeeded()
        if pcm.isEmpty { return Transcript(text: "", language: nil, ttft_ms: nil, decode_tps: nil) }
        let capacity = Int32(out.count)
        let rc = pcm.withUnsafeBufferPointer { samples in
            withOptionalCString(language) { lang in
                withOptionalCString(keywords) { kw in
                    needle_transcribe(samples.baseAddress, Int32(samples.count), lang, kw, 0, &out, capacity)
                }
            }
        }
        return try decode(rc)
    }

    /// Appends audio (about a second at a time) to the live stream and returns the words it committed.
    func streamProcess(_ pcm: [Float], language: String?, keywords: String?) throws -> StreamStep {
        try loadIfNeeded()
        let capacity = Int32(out.count)
        let rc = pcm.withUnsafeBufferPointer { samples in
            withOptionalCString(language) { lang in
                withOptionalCString(keywords) { kw in
                    needle_stream_transcribe_process(samples.baseAddress, Int32(samples.count), lang, kw, &out, capacity)
                }
            }
        }
        return try decode(rc)
    }

    /// Ends the stream: the unconfirmed tail becomes committed text, and the next process call starts fresh.
    func streamStop() throws -> StreamStep {
        try loadIfNeeded()
        let rc = needle_stream_transcribe_stop(&out, Int32(out.count))
        return try decode(rc)
    }

    private func decode<T: Decodable>(_ rc: Int32) throws -> T {
        if rc < 0 { throw EngineError.native(lastError()) }
        let json = out.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func lastError() -> String {
        needle_last_error().map { String(cString: $0) } ?? "unknown engine error"
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string, !string.isEmpty else { return body(nil) }
    return string.withCString(body)
}
