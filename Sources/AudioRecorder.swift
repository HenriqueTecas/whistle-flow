import Accelerate
import AVFoundation

enum RecorderError: LocalizedError {
    case noInput, unusableInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "No microphone available"
        case .unusableInput: return "Couldn't open the microphone"
        }
    }
}

/// Captures one microphone as 16 kHz mono float samples, the format Whistle expects.
///
/// Uses AVCaptureSession rather than AVAudioEngine: it opens a specific device cleanly even when the
/// output is a Bluetooth headset, and converts to 16 kHz mono itself.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Samples and a 0...1 loudness level, delivered on the capture queue.
    var onAudio: (([Float], Float) -> Void)?

    /// Starting and stopping a capture session blocks, so both run here, in order, off the main thread.
    private let control = DispatchQueue(label: "whistleflow.capture.control")
    private let delivery = DispatchQueue(label: "whistleflow.capture.audio", qos: .userInteractive)
    private var session: AVCaptureSession?

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: Double(WhistleEngine.sampleRate),
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Opens `device` (the system default input when nil). Errors arrive on the main thread.
    func start(device: AudioInputDevice?, onError: @escaping (Error) -> Void) {
        control.async {
            do {
                try self.open(device)
            } catch {
                DispatchQueue.main.async { onError(error) }
            }
        }
    }

    /// Stops recording; `then` runs once every captured sample has been handed to `onAudio`.
    func stop(then: @escaping () -> Void = {}) {
        control.async {
            self.session?.stopRunning()
            self.session = nil
            self.delivery.sync {}
            then()
        }
    }

    private func open(_ device: AudioInputDevice?) throws {
        session?.stopRunning()
        let captureDevice = device.flatMap { AVCaptureDevice(uniqueID: $0.uid) } ?? AVCaptureDevice.default(for: .audio)
        guard let captureDevice else { throw RecorderError.noInput }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = Self.settings
        output.setSampleBufferDelegate(self, queue: delivery)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw RecorderError.unusableInput }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        self.session = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        guard !samples.isEmpty,
              samples.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count,
                                                                          destination: $0.baseAddress!) }) == noErr
        else { return }
        let level = samples.withUnsafeBufferPointer { Self.level(of: $0.baseAddress!, count: $0.count) }
        onAudio?(samples, level)
    }

    static func level(of samples: UnsafePointer<Float>, count: Int) -> Float {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (decibels + 50) / 40))  // -50 dB is silent, -10 dB is full scale
    }
}
