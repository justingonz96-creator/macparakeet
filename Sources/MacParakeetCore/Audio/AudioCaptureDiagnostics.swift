import CoreAudio
import Foundation
import os

public enum AudioCaptureDiagnostics {
    private static let lock = OSAllocatedUnfairLock(initialState: ())
    private static let appendQueue = DispatchQueue(
        label: "com.macparakeet.audio-capture-diagnostics.append",
        qos: .utility
    )
    private static let logPathOverrideEnvironmentKey = "MACPARAKEET_AUDIO_DIAGNOSTICS_LOG_PATH"
    /// On-disk cap for `dictation-audio.log`. When the cap is reached, retain
    /// the newest complete lines instead of deleting all diagnostic history.
    /// Five MB keeps tens of days for normal use; retaining half leaves room
    /// for the next burst without rotating on every append.
    private static let maxLogBytes: UInt64 = 5_000_000
    private static let retainedLogBytes = Int(maxLogBytes / 2)
    private static let maxMessageCharacters = 16_384

    public static var diagnosticLogFileURL: URL {
        diagnosticLogURL()
    }

    public static var diagnosticLogMaxBytes: UInt64 {
        maxLogBytes
    }

    /// Device identity is private: diagnostics are designed to be shared, so
    /// labels intentionally omit CoreAudio IDs, UIDs, and microphone names.
    static func deviceLabel(_ deviceID: AudioDeviceID?) -> String {
        deviceID == nil ? "none" : "present"
    }

    static func deviceTransportLabel(_ deviceID: AudioDeviceID?) -> String {
        guard let deviceID else { return "none" }
        let transport = AudioDeviceManager.transportType(deviceID)
        if transport == kAudioDeviceTransportTypeAggregate,
            let subTransport = AudioDeviceManager.subDeviceTransport(deviceID)
        {
            return "aggregate-\(safeTransportLabel(subTransport))"
        }
        return safeTransportLabel(transport)
    }

    static func defaultInputDeviceLabel() -> String {
        deviceLabel(AudioDeviceManager.defaultInputDevice())
    }

    static func defaultInputDeviceTransportLabel() -> String {
        deviceTransportLabel(AudioDeviceManager.defaultInputDevice())
    }

    static func defaultInputDeviceSummary() -> String {
        let deviceID = AudioDeviceManager.defaultInputDevice()
        return "default_input=\(deviceLabel(deviceID)) default_input_transport=\(deviceTransportLabel(deviceID))"
    }

    static func errorType(_ error: Error) -> String {
        TelemetryErrorClassifier.classify(error)
    }

    static func errorFields(_ error: Error) -> String {
        let detail = sanitizedLogValue(error.localizedDescription)
        guard !detail.isEmpty else {
            return "error_type=\(errorType(error))"
        }
        return "error_type=\(errorType(error)) error_detail=\"\(detail)\""
    }

    static func sanitizedMessage(_ message: String) -> String {
        TelemetryErrorClassifier.sanitize(message)
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func sanitizedLogValue(_ message: String) -> String {
        String(
            sanitizedMessage(message)
                .replacingOccurrences(of: "\"", with: "'")
                .prefix(512)
        )
    }

    public static func append(_ message: @autoclosure () -> String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sanitized = String(sanitizedMessage(message()).prefix(maxMessageCharacters))
        let line = "\(formatter.string(from: Date())) \(sanitized)\n"

        guard let data = line.data(using: .utf8) else { return }

        lock.withLock {
            let fm = FileManager.default
            let logURL = diagnosticLogURL()

            do {
                try fm.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if let attributes = try? fm.attributesOfItem(atPath: logURL.path),
                    let size = attributes[.size] as? UInt64,
                    size + UInt64(data.count) > maxLogBytes
                {
                    let existingData = try Data(contentsOf: logURL)
                    var rotatedData = retainedLogSuffix(
                        existingData,
                        maxBytes: retainedLogBytes
                    )
                    rotatedData.append(data)
                    try rotatedData.write(to: logURL, options: .atomic)
                    return
                }

                if fm.fileExists(atPath: logURL.path),
                    let handle = try? FileHandle(forWritingTo: logURL)
                {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            } catch {
                // Diagnostics must never affect audio capture.
            }
        }
    }

    public static func appendAsync(_ message: String) {
        appendQueue.async {
            append(message)
        }
    }

    /// Keeps only complete newest log lines. Starting after the first newline
    /// also discards any UTF-8 code point split by the byte boundary.
    static func retainedLogSuffix(_ data: Data, maxBytes: Int) -> Data {
        guard maxBytes > 0, data.count > maxBytes else {
            return maxBytes > 0 ? data : Data()
        }

        let suffix = data.suffix(maxBytes)
        guard let firstNewline = suffix.firstIndex(of: 0x0A) else {
            return Data()
        }
        let firstCompleteLine = suffix.index(after: firstNewline)
        return Data(suffix[firstCompleteLine...])
    }

    static func diagnosticLogURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let overridePath = environment[logPathOverrideEnvironmentKey],
            !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: overridePath)
        }

        if isRunningUnderXCTest(environment: environment) {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("MacParakeetTests", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("dictation-audio-\(ProcessInfo.processInfo.processIdentifier).log")
        }

        return URL(fileURLWithPath: AppPaths.logsDir, isDirectory: true)
            .appendingPathComponent("dictation-audio.log")
    }

    private static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        return Bundle.allBundles.contains { bundle in
            bundle.bundlePath.hasSuffix(".xctest")
        }
    }

    private static func safeTransportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "bluetooth-le"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return "unknown"
        }
    }
}
