import Foundation

public enum MeetingActivityDetector {
    public struct Config: Sendable, Equatable {
        public var mode: MeetingActivityDetectionMode
        public var candidateDwellSeconds: TimeInterval
        public var declineCooldownSeconds: TimeInterval

        public init(
            mode: MeetingActivityDetectionMode = .off,
            candidateDwellSeconds: TimeInterval = 3.0,
            declineCooldownSeconds: TimeInterval = 30 * 60
        ) {
            self.mode = mode
            self.candidateDwellSeconds = candidateDwellSeconds
            self.declineCooldownSeconds = declineCooldownSeconds
        }

        public static let `default` = Config()
    }

    public enum DetectionEvent: Sendable, Equatable {
        case promptToRecord(MeetingIdentity)
        case autoStartDue(MeetingIdentity)
        case signalCleared
    }

    public struct Candidate: Sendable, Equatable {
        public let identity: MeetingIdentity
        public let since: Date

        public init(identity: MeetingIdentity, since: Date) {
            self.identity = identity
            self.since = since
        }
    }

    public static func evaluate(
        signal: ActivitySignalSnapshot,
        now: Date,
        config: Config,
        activeRecording: Bool,
        candidate: Candidate?,
        suppressedIdentities: [MeetingIdentity: Date]
    ) -> [DetectionEvent] {
        guard !activeRecording, config.mode != .off else {
            return candidate == nil ? [] : [.signalCleared]
        }

        guard let identity = candidateIdentity(for: signal) else {
            return candidate == nil ? [] : [.signalCleared]
        }

        if let candidate, candidate.identity != identity {
            return [.signalCleared]
        }

        if let suppressedUntil = suppressedIdentities[identity], suppressedUntil > now {
            return candidate == nil ? [] : [.signalCleared]
        }

        let stableSince = candidate?.since ?? now
        guard now.timeIntervalSince(stableSince) >= config.candidateDwellSeconds else {
            return []
        }

        switch config.mode {
        case .off:
            return []
        case .prompt:
            return [.promptToRecord(identity)]
        case .autoStart:
            return [.autoStartDue(identity)]
        }
    }

    public static func candidateIdentity(for signal: ActivitySignalSnapshot) -> MeetingIdentity? {
        guard !signal.audio.inputHolders.isEmpty else { return nil }

        if let app = recognizedMeetingApp(for: signal) {
            return MeetingIdentity(source: .app, app: app)
        }

        if signal.cameraRunning {
            return MeetingIdentity(source: .camera, app: nil)
        }

        return nil
    }

    private static func recognizedMeetingApp(for signal: ActivitySignalSnapshot) -> MeetingApp? {
        let inputHolders = signal.audio.inputHolders
        let outputPIDs = Set(signal.audio.outputHolders.map(\.pid))

        let dedicated = inputHolders.compactMap { process -> MeetingApp? in
            guard let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .dedicated
            else {
                return nil
            }
            return descriptor.app
        }
        if let app = preferredApp(from: dedicated) {
            return app
        }

        let chat = inputHolders.compactMap { process -> MeetingApp? in
            guard outputPIDs.contains(process.pid),
                  let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .chat
            else {
                return nil
            }
            return descriptor.app
        }
        if let app = preferredApp(from: chat) {
            return app
        }

        let browser = inputHolders.compactMap { process -> MeetingApp? in
            guard let bundleID = process.bundleID,
                  let descriptor = MeetingAppRegistry.descriptor(forBundleID: bundleID),
                  descriptor.trustTier == .browser
            else {
                return nil
            }
            let isFrontmost = signal.frontmostBundleID == bundleID
            let urlMatchesAudioBrowser = signal.recognizedMeetingURLBundleIDs.contains(bundleID)
            return (isFrontmost || urlMatchesAudioBrowser) ? descriptor.app : nil
        }
        return browser.first
    }

    private static func preferredApp(from apps: [MeetingApp]) -> MeetingApp? {
        MeetingApp.allCases.first { preferred in
            apps.contains(preferred)
        }
    }
}
