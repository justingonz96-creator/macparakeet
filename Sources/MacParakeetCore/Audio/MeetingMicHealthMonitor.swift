import Foundation

public struct MeetingMicHealthMonitor: Sendable {
    public struct Config: Sendable, Equatable {
        public var systemActiveConfirmationSeconds: TimeInterval
        public var micGapSeconds: TimeInterval
        public var systemGapSeconds: TimeInterval
        public var nonSilentLevelThreshold: Float

        public init(
            systemActiveConfirmationSeconds: TimeInterval = 3.0,
            micGapSeconds: TimeInterval = 1.0,
            systemGapSeconds: TimeInterval = 2.0,
            nonSilentLevelThreshold: Float = 0.02
        ) {
            self.systemActiveConfirmationSeconds = systemActiveConfirmationSeconds
            self.micGapSeconds = micGapSeconds
            self.systemGapSeconds = systemGapSeconds
            self.nonSilentLevelThreshold = nonSilentLevelThreshold
        }

        public static let `default` = Config()
    }

    public struct AudioSignal: Sendable, Equatable {
        public var isNonSilent: Bool

        public init(isNonSilent: Bool) {
            self.isNonSilent = isNonSilent
        }
    }

    public enum StallSignature: String, Sendable, Equatable {
        case micMissing = "mic_missing"
        case micSilent = "mic_silent"
        case micGap = "mic_gap"
    }

    public enum HealthEvent: Sendable, Equatable {
        case stallSuspected(signature: StallSignature, elapsedMs: Int)
        case recovered
    }

    private let config: Config
    private var systemActiveStartedAt: Date?
    private var lastMicBufferAt: Date?
    private var lastSystemBufferAt: Date?
    private var silentMicStartedAt: Date?
    private var lastMicWasNonSilent = false
    private var activeStallSignature: StallSignature?

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func reset() {
        systemActiveStartedAt = nil
        lastMicBufferAt = nil
        lastSystemBufferAt = nil
        silentMicStartedAt = nil
        lastMicWasNonSilent = false
        activeStallSignature = nil
    }

    public mutating func ingest(
        micSignal: AudioSignal? = nil,
        systemSignal: AudioSignal? = nil,
        now: Date
    ) -> [HealthEvent] {
        var events: [HealthEvent] = []

        expireSystemActivityIfStale(now: now)

        if let systemSignal {
            lastSystemBufferAt = now
            if systemSignal.isNonSilent {
                if systemActiveStartedAt == nil {
                    systemActiveStartedAt = now
                }
            } else {
                systemActiveStartedAt = nil
            }
        }

        if let micSignal {
            lastMicBufferAt = now
            lastMicWasNonSilent = micSignal.isNonSilent

            if micSignal.isNonSilent {
                silentMicStartedAt = nil
                if activeStallSignature != nil {
                    activeStallSignature = nil
                    events.append(.recovered)
                }
            } else if silentMicStartedAt == nil {
                silentMicStartedAt = now
            }
        }

        guard activeStallSignature == nil,
              let systemActiveStartedAt,
              now.timeIntervalSince(systemActiveStartedAt) >= config.systemActiveConfirmationSeconds,
              let signature = currentSignature(now: now)
        else {
            return events
        }

        activeStallSignature = signature
        events.append(.stallSuspected(signature: signature, elapsedMs: elapsedMs(for: signature, now: now)))
        return events
    }

    private func currentSignature(now: Date) -> StallSignature? {
        guard let lastMicBufferAt else {
            return .micMissing
        }

        if now.timeIntervalSince(lastMicBufferAt) >= config.micGapSeconds {
            return .micGap
        }

        if !lastMicWasNonSilent {
            return .micSilent
        }

        return nil
    }

    private mutating func expireSystemActivityIfStale(now: Date) {
        guard let lastSystemBufferAt,
              now.timeIntervalSince(lastSystemBufferAt) >= config.systemGapSeconds
        else {
            return
        }
        systemActiveStartedAt = nil
    }

    private func elapsedMs(for signature: StallSignature, now: Date) -> Int {
        let start: Date
        switch signature {
        case .micMissing:
            start = systemActiveStartedAt ?? now
        case .micSilent:
            let silenceStartedAt = silentMicStartedAt ?? lastMicBufferAt ?? systemActiveStartedAt ?? now
            start = boundedBySystemActivity(silenceStartedAt)
        case .micGap:
            let gapStartedAt = lastMicBufferAt ?? systemActiveStartedAt ?? now
            start = boundedBySystemActivity(gapStartedAt)
        }
        return max(0, Int((now.timeIntervalSince(start) * 1_000).rounded()))
    }

    private func boundedBySystemActivity(_ date: Date) -> Date {
        guard let systemActiveStartedAt, date < systemActiveStartedAt else {
            return date
        }
        return systemActiveStartedAt
    }
}
