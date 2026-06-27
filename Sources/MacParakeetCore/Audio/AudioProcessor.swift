import Foundation

/// Unified audio processor that handles both microphone capture and file conversion.
public actor AudioProcessor: AudioProcessorProtocol {
    private let recorder: AudioRecorder
    private let converter: AudioFileConverter

    public init(
        sharedMicStream: SharedMicrophoneStream,
        enableVad: @escaping @Sendable () -> Bool = { false },
        vadEngine: DictationVadEngine? = nil
    ) {
        self.recorder = AudioRecorder(
            sharedStream: sharedMicStream,
            enableVad: enableVad,
            vadEngine: vadEngine
        )
        self.converter = AudioFileConverter()
    }

    /// File-only init (CLI, tests). No VAD ever loads.
    public init() {
        let stream = SharedMicrophoneStream(
            platform: AVAudioEngineMicrophonePlatform()
        )
        self.recorder = AudioRecorder(sharedStream: stream)
        self.converter = AudioFileConverter()
    }

    public var audioLevel: Float {
        get async { await recorder.audioLevel }
    }

    public var vadState: VadSnapshot {
        get async { await recorder.vadState }
    }

    public var isRecording: Bool {
        get async { await recorder.isRecording }
    }

    public var recordingDeviceInfo: RecordingDeviceInfo? {
        get async { await recorder.deviceInfo }
    }

    public func convert(fileURL: URL) async throws -> URL {
        try await converter.convert(fileURL: fileURL)
    }

    public func startCapture() async throws {
        try await recorder.start()
    }

    public func stopCapture() async throws -> URL {
        try await recorder.stop()
    }
}
