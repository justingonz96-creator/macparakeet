import XCTest
import FluidAudio
import os
@testable import MacParakeetCore

final class DiarizationServiceTests: XCTestCase {

    func testMockDiarizationServiceReturnsConfiguredResult() async throws {
        let mock = MockDiarizationService()
        let expected = MacParakeetDiarizationResult(
            segments: [
                SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 5000),
                SpeakerSegment(speakerId: "S2", startMs: 5000, endMs: 10000),
            ],
            speakerCount: 2,
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S2", label: "Speaker 2"),
            ]
        )
        await mock.configure(result: expected)

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 2)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertEqual(result.speakers[0].id, "S1")
        XCTAssertEqual(result.speakers[1].label, "Speaker 2")

        let wasCalled = await mock.diarizeCalled
        XCTAssertTrue(wasCalled)
    }

    func testMockDiarizationServiceThrowsConfiguredError() async {
        let mock = MockDiarizationService()
        await mock.configure(error: STTError.transcriptionFailed("mock error"))

        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        do {
            _ = try await mock.diarize(audioURL: dummyURL)
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }

    func testMockDiarizationServiceDefaultsToEmpty() async throws {
        let mock = MockDiarizationService()
        let dummyURL = URL(fileURLWithPath: "/tmp/test.wav")
        let result = try await mock.diarize(audioURL: dummyURL)
        XCTAssertEqual(result.speakerCount, 0)
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakers.isEmpty)
    }

    func testMockPrepareModels() async throws {
        let mock = MockDiarizationService()
        try await mock.prepareModels()
        let wasCalled = await mock.prepareModelsCalled
        XCTAssertTrue(wasCalled)
        let ready = await mock.isReady()
        XCTAssertTrue(ready)
        let cached = await mock.hasCachedModels()
        XCTAssertTrue(cached)
    }

    func testIsReady() async {
        let mock = MockDiarizationService()
        let ready = await mock.isReady()
        XCTAssertFalse(ready)
    }

    func testClearModelCacheRemovesCachedSpeakerModels() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoDirectory = DiarizationService.modelCacheDirectory(directory: tempDirectory)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        for modelName in DiarizationService.requiredModelNames() {
            let modelURL = repoDirectory.appendingPathComponent(modelName, isDirectory: false)
            FileManager.default.createFile(atPath: modelURL.path, contents: Data())
        }

        XCTAssertTrue(DiarizationService.isModelCached(directory: tempDirectory))

        DiarizationService.clearModelCache(directory: tempDirectory)

        XCTAssertFalse(DiarizationService.isModelCached(directory: tempDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoDirectory.path))
    }

    func testHighAccuracyConfigUsesAsyncSettings() {
        let config = DiarizationService.highAccuracyConfig
        let fast = OfflineDiarizerConfig.default

        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
        XCTAssertTrue(config.clustering.constrainedAssignment)
        // Never tuned by the app; 0.15.6 changed its semantics to a plain distance cut.
        XCTAssertEqual(config.clustering.threshold, fast.clustering.threshold)
        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
        XCTAssertNoThrow(try config.validate())
    }

    func testOfflineConfigStartsFromHighAccuracyConfig() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .exact(2))

        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
    }

    func testOfflineConfigAppliesExactSpeakerConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .exact(2))

        XCTAssertEqual(config.clustering.numSpeakers, 2)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testOfflineConfigAppliesSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: 2, max: 4))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertEqual(config.clustering.minSpeakers, 2)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    func testOfflineConfigAppliesMinimumSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: 2, max: nil))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertEqual(config.clustering.minSpeakers, 2)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testOfflineConfigAppliesMaximumSpeakerRangeConstraint() {
        let config = DiarizationService.offlineConfig(speakerConstraint: .range(min: nil, max: 4))

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    func testDiarizePreparesModelsUsingCustomDirectoryBeforeColdStartInference() async throws {
        let customDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: [
            TimedSpeakerSegment(
                speakerId: "speaker_0",
                embedding: [],
                startTimeSeconds: 0,
                endTimeSeconds: 1.2,
                qualityScore: 0.9
            ),
        ]))
        let service = DiarizationService(manager: manager, modelsDirectory: customDirectory)
        let audioURL = URL(fileURLWithPath: "/tmp/test.wav")

        let result = try await service.diarize(audioURL: audioURL)
        let preparedDirectories = await manager.preparedDirectories
        let processedAudioURLs = await manager.processedAudioURLs
        let ready = await service.isReady()

        XCTAssertEqual(preparedDirectories, [customDirectory])
        XCTAssertEqual(processedAudioURLs, [audioURL])
        XCTAssertEqual(result.speakerCount, 1)
        XCTAssertEqual(result.speakers.map { $0.id }, ["S1"])
        XCTAssertEqual(result.segments.map { $0.speakerId }, ["S1"])
        XCTAssertTrue(ready)
    }

    func testDiarizePassesPerCallSpeakerConstraintToManager() async throws {
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: []))
        let service = DiarizationService(
            manager: manager,
            modelsDirectory: FileManager.default.temporaryDirectory
        )

        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"))
        _ = try await service.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/b.wav"),
            speakerConstraint: .range(min: 2, max: 4)
        )

        let constraints = await manager.receivedConstraints
        XCTAssertEqual(constraints, [nil, .range(min: 2, max: 4)])
    }

    func testExplicitConstraintWinsOverPerCallHint() async throws {
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: []))
        let service = DiarizationService(
            manager: manager,
            modelsDirectory: FileManager.default.temporaryDirectory,
            explicitConstraint: .exact(3)
        )

        _ = try await service.diarize(
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"),
            speakerConstraint: .range(min: 1, max: 2)
        )

        // The explicit constraint already lives in the manager's base config,
        // so the per-call hint is dropped rather than layered on top.
        let constraints = await manager.receivedConstraints
        XCTAssertEqual(constraints, [nil])
    }

    // MARK: - Model preparation concurrency

    func testOverlappingColdDiarizeCallsShareOnePreparation() async throws {
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: []))
        let entered = AsyncPermit(value: 0)
        let release = AsyncPermit(value: 0)
        await manager.setPrepareSignals(entered: entered, release: release)
        let service = DiarizationService(manager: manager, modelsDirectory: FileManager.default.temporaryDirectory)

        let first = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav")) }
        try await entered.wait()
        let second = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav")) }
        // Give the second caller the chance to (wrongly) start its own preparation.
        for _ in 0..<50 { await Task.yield() }
        let inFlight = await manager.preparedDirectories.count
        XCTAssertEqual(inFlight, 1, "the second cold caller must await the first load, not start its own")

        release.signal()
        _ = try await first.value
        _ = try await second.value

        let prepared = await manager.preparedDirectories.count
        let processed = await manager.processedAudioURLs.count
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(processed, 2)
    }

    func testFailedPreparationIsRetriedByTheNextCall() async throws {
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: []))
        await manager.setPrepareErrors([OfflineDiarizationError.modelNotLoaded("first")])
        let service = DiarizationService(manager: manager, modelsDirectory: FileManager.default.temporaryDirectory)

        do {
            _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"))
            XCTFail("expected the first preparation to fail")
        } catch {}
        let readyAfterFailure = await service.isReady()
        XCTAssertFalse(readyAfterFailure)

        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"))

        let prepared = await manager.preparedDirectories.count
        let ready = await service.isReady()
        XCTAssertEqual(prepared, 2)
        XCTAssertTrue(ready)
    }

    func testCancelledCallerReturnsWhileTheLoadIsStillBlocked() async throws {
        let manager = RecordingOfflineDiarizerManager(result: DiarizationResult(segments: []))
        let entered = AsyncPermit(value: 0)
        let release = AsyncPermit(value: 0)
        await manager.setPrepareSignals(entered: entered, release: release)
        let service = DiarizationService(manager: manager, modelsDirectory: FileManager.default.temporaryDirectory)

        let cancelled = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav")) }
        try await entered.wait()
        cancelled.cancel()

        // Must complete before the loader is released.
        do {
            _ = try await cancelled.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let stillBlocked = await manager.releasedCount
        XCTAssertEqual(stillBlocked, 0, "the shared load was still blocked when the cancelled caller returned")

        release.signal()
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"))
        let prepared = await manager.preparedDirectories.count
        XCTAssertEqual(prepared, 1, "the load that was in flight is reused by the next caller")
    }

    // MARK: - Cache recovery around OfflineDiarizerModels.load

    private func makeDiarizerCache() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repo = DiarizationService.modelCacheDirectory(directory: base)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "not json".write(to: repo.appendingPathComponent("plda-parameters.json"), atomically: true, encoding: .utf8)
        return base
    }

    private func pldaFailures() -> [Error] {
        [
            OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters"),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad plda json")),
            NSError(domain: NSCocoaErrorDomain, code: NSPropertyListReadCorruptError, userInfo: nil),
        ]
    }

    func testMalformedPLDAMetadataPurgesTheDiarizerCacheOnceAndReloads() async throws {
        for failure in pldaFailures() {
            let base = try makeDiarizerCache()
            defer { try? FileManager.default.removeItem(at: base) }
            let repo = DiarizationService.modelCacheDirectory(directory: base)
            let attempts = OSAllocatedUnfairLock(initialState: 0)

            let value = try await FluidOfflineDiarizer.loadWithRecovery(directory: base, offlineMode: false) { () throws -> String in
                let attempt = attempts.withLock { $0 += 1; return $0 }
                if attempt == 1 {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path))
                    throw failure
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: repo.path), "the repo directory is purged before the retry")
                return "loaded"
            }

            XCTAssertEqual(value, "loaded")
            XCTAssertEqual(attempts.withLock { $0 }, 2, "\(failure)")
        }
    }

    func testRecoveryGivesUpAfterTheSecondFailure() async throws {
        let base = try makeDiarizerCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        do {
            _ = try await FluidOfflineDiarizer.loadWithRecovery(directory: base, offlineMode: false) { () throws -> String in
                attempts.withLock { $0 += 1 }
                throw OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters")
            }
            XCTFail("expected the second failure to propagate")
        } catch {}
        XCTAssertEqual(attempts.withLock { $0 }, 2)
    }

    func testDownloadTransientAndCancellationErrorsKeepTheCache() async throws {
        let wrappedCancellation = NSError(
            domain: "MacParakeetTests",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)]
        )
        let preserved: [Error] = [
            CancellationError(),
            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil),
            wrappedCancellation,
            URLError(.notConnectedToInternet),
            DownloadError.networkDisabled(operation: "download"),
            DownloadError.modelMissing(repo: "speaker-diarization", missing: ["Segmentation.mlmodelc"]),
            DownloadError.stalled(path: "Embedding.mlmodelc", window: 30),
            // ModelHub already retried these and chose to preserve the cache.
            DownloadError.invalidArtifact(path: "Embedding.mlmodelc", reason: "truncated"),
            DownloadError.rateLimited(statusCode: 429, message: "slow down"),
            OfflineDiarizationError.modelNotLoaded("Segmentation.mlmodelc"),
        ]
        for error in preserved {
            let base = try makeDiarizerCache()
            defer { try? FileManager.default.removeItem(at: base) }
            let repo = DiarizationService.modelCacheDirectory(directory: base)
            let attempts = OSAllocatedUnfairLock(initialState: 0)

            do {
                _ = try await FluidOfflineDiarizer.loadWithRecovery(directory: base, offlineMode: false) { () throws -> String in
                    attempts.withLock { $0 += 1 }
                    throw error
                }
                XCTFail("expected \(error) to propagate")
            } catch {}
            XCTAssertEqual(attempts.withLock { $0 }, 1, "\(error) must not trigger a retry")
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path), "\(error) must not purge the cache")
        }
    }

    func testOfflineModeNeverPurgesEvenForPLDAFailures() async throws {
        for failure in pldaFailures() {
            let base = try makeDiarizerCache()
            defer { try? FileManager.default.removeItem(at: base) }
            let repo = DiarizationService.modelCacheDirectory(directory: base)
            let attempts = OSAllocatedUnfairLock(initialState: 0)

            do {
                _ = try await FluidOfflineDiarizer.loadWithRecovery(directory: base, offlineMode: true) { () throws -> String in
                    attempts.withLock { $0 += 1 }
                    throw failure
                }
                XCTFail("expected \(failure) to propagate")
            } catch {}
            XCTAssertEqual(attempts.withLock { $0 }, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path), "offline mode must keep the cache")
            XCTAssertFalse(FluidOfflineDiarizer.shouldPurgeCache(after: failure, offlineMode: true))
        }
    }

    func testCancellationDetectionFollowsTheUnderlyingErrorChain() {
        let nested = NSError(domain: "Outer", code: 5, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "Middle", code: 6, userInfo: [
                NSUnderlyingErrorKey: CancellationError(),
            ]),
        ])
        XCTAssertTrue(FluidOfflineDiarizer.isCancellation(nested))
        XCTAssertFalse(FluidOfflineDiarizer.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(FluidOfflineDiarizer.isPLDAMetadataFailure(OfflineDiarizationError.processingFailed("segmentation output empty")))
    }
}

private actor RecordingOfflineDiarizerManager: OfflineDiarizerManaging {
    let result: DiarizationResult
    var preparedDirectories: [URL] = []
    var processedAudioURLs: [URL] = []
    var receivedConstraints: [SpeakerDiarizationConstraint?] = []
    private var enteredSignal: AsyncPermit?
    private var releaseBlocker: AsyncPermit?
    private var prepareErrors: [Error] = []
    /// Number of times a blocked preparation was released.
    var releasedCount = 0

    init(result: DiarizationResult) {
        self.result = result
    }

    /// `entered` is signalled when preparation starts; preparation then waits
    /// on `release` so the test controls exactly when the load finishes.
    func setPrepareSignals(entered: AsyncPermit, release: AsyncPermit) {
        enteredSignal = entered
        releaseBlocker = release
    }

    func setPrepareErrors(_ errors: [Error]) {
        prepareErrors = errors
    }

    func prepareModels(at directory: URL) async throws {
        preparedDirectories.append(directory)
        if !prepareErrors.isEmpty {
            throw prepareErrors.removeFirst()
        }
        enteredSignal?.signal()
        if let releaseBlocker {
            try await releaseBlocker.wait()
            releasedCount += 1
        }
    }

    func process(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> DiarizationResult {
        processedAudioURLs.append(audioURL)
        receivedConstraints.append(speakerConstraint)
        return result
    }
}
