import XCTest
import FluidAudio
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

    // MARK: - Configuration

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

    // MARK: - Manager preparation

    private func makeService(
        factory: RecordingManagerFactory,
        explicitConstraint: SpeakerDiarizationConstraint? = nil,
        directory: URL = FileManager.default.temporaryDirectory
    ) -> DiarizationService {
        DiarizationService(
            makeManager: { constraint in factory.make(for: constraint) },
            modelsDirectory: directory,
            explicitConstraint: explicitConstraint
        )
    }

    func testDiarizePreparesModelsUsingCustomDirectoryBeforeColdStartInference() async throws {
        let customDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let factory = RecordingManagerFactory(result: DiarizationResult(segments: [
            TimedSpeakerSegment(
                speakerId: "speaker_0",
                embedding: [],
                startTimeSeconds: 0,
                endTimeSeconds: 1.2,
                qualityScore: 0.9
            ),
        ]))
        let service = makeService(factory: factory, directory: customDirectory)
        let audioURL = URL(fileURLWithPath: "/tmp/test.wav")

        let result = try await service.diarize(audioURL: audioURL)
        let manager = try XCTUnwrap(factory.managers.first)
        let preparedDirectories = await manager.preparedDirectories
        let processedAudioURLs = await manager.processedAudioURLs
        let ready = await service.isReady()

        XCTAssertEqual(factory.constraints, [nil])
        XCTAssertEqual(preparedDirectories, [customDirectory])
        XCTAssertEqual(processedAudioURLs, [audioURL])
        XCTAssertEqual(result.speakerCount, 1)
        XCTAssertEqual(result.speakers.map { $0.id }, ["S1"])
        XCTAssertEqual(result.segments.map { $0.speakerId }, ["S1"])
        XCTAssertTrue(ready)
    }

    func testEachDistinctConstraintGetsItsOwnPreparedManagerOnce() async throws {
        let factory = RecordingManagerFactory(result: DiarizationResult(segments: []))
        let service = makeService(factory: factory)

        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"))
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"), speakerConstraint: .range(min: 1, max: 3))
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/c.wav"), speakerConstraint: .range(min: 1, max: 3))
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/d.wav"))

        XCTAssertEqual(factory.constraints, [nil, .range(min: 1, max: 3)])
        let processedPerManager = await factory.managers.asyncMap { await $0.processedAudioURLs.count }
        XCTAssertEqual(processedPerManager, [2, 2])
    }

    func testExplicitConstraintWinsOverPerCallHint() async throws {
        let factory = RecordingManagerFactory(result: DiarizationResult(segments: []))
        let service = makeService(factory: factory, explicitConstraint: .exact(3))

        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"), speakerConstraint: .range(min: 1, max: 2))
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"))

        // The explicit constraint lives in the factory's config; the hint is
        // dropped rather than producing a second manager.
        XCTAssertEqual(factory.constraints, [nil])
        let explicit = await service.explicitSpeakerConstraint()
        XCTAssertEqual(explicit, .exact(3))
    }

    func testOverlappingColdDiarizeCallsShareOnePreparation() async throws {
        let factory = RecordingManagerFactory(result: DiarizationResult(segments: []))
        let entered = AsyncPermit(value: 0)
        let release = AsyncPermit(value: 0)
        factory.prepareSignals = (entered, release)
        let service = makeService(factory: factory)

        let first = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav")) }
        try await entered.wait()
        let second = Task { try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav")) }
        // Give the second caller the chance to (wrongly) start its own preparation.
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(factory.managers.count, 1, "the second cold caller must await the first load, not start its own")

        release.signal()
        _ = try await first.value
        _ = try await second.value

        let manager = try XCTUnwrap(factory.managers.first)
        let prepared = await manager.preparedDirectories.count
        let processed = await manager.processedAudioURLs.count
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(processed, 2)
    }

    func testFailedPreparationIsRetriedByTheNextCall() async throws {
        let factory = RecordingManagerFactory(result: DiarizationResult(segments: []))
        factory.prepareErrors = [OfflineDiarizationError.modelNotLoaded("first"), CancellationError()]
        let service = makeService(factory: factory)

        for _ in 0..<2 {
            do {
                _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/a.wav"))
                XCTFail("expected the preparation to fail")
            } catch {}
            let ready = await service.isReady()
            XCTAssertFalse(ready)
        }

        // FluidAudio's own recovery ran inside prepareModels; a failed task,
        // including one that failed with CancellationError, is not reused.
        _ = try await service.diarize(audioURL: URL(fileURLWithPath: "/tmp/b.wav"))

        XCTAssertEqual(factory.managers.count, 3)
        let ready = await service.isReady()
        XCTAssertTrue(ready)
    }
}

/// Builds one recording fake manager per requested constraint.
private final class RecordingManagerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let result: DiarizationResult
    private(set) var constraints: [SpeakerDiarizationConstraint?] = []
    private(set) var managers: [RecordingOfflineDiarizerManager] = []
    var prepareErrors: [Error] = []
    var prepareSignals: (entered: AsyncPermit, release: AsyncPermit)?

    init(result: DiarizationResult) {
        self.result = result
    }

    func make(for constraint: SpeakerDiarizationConstraint?) -> any OfflineDiarizerManaging {
        lock.lock()
        defer { lock.unlock() }
        constraints.append(constraint)
        let error: Error? = prepareErrors.isEmpty ? nil : prepareErrors.removeFirst()
        let manager = RecordingOfflineDiarizerManager(result: result, prepareError: error, signals: prepareSignals)
        managers.append(manager)
        return manager
    }
}

private actor RecordingOfflineDiarizerManager: OfflineDiarizerManaging {
    let result: DiarizationResult
    private let prepareError: Error?
    private let signals: (entered: AsyncPermit, release: AsyncPermit)?
    var preparedDirectories: [URL] = []
    var processedAudioURLs: [URL] = []

    init(result: DiarizationResult, prepareError: Error?, signals: (entered: AsyncPermit, release: AsyncPermit)?) {
        self.result = result
        self.prepareError = prepareError
        self.signals = signals
    }

    func prepareModels(at directory: URL) async throws {
        preparedDirectories.append(directory)
        if let prepareError { throw prepareError }
        if let signals {
            signals.entered.signal()
            try await signals.release.wait()
        }
    }

    func process(audioURL: URL) async throws -> DiarizationResult {
        processedAudioURLs.append(audioURL)
        return result
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var values: [T] = []
        for element in self { values.append(await transform(element)) }
        return values
    }
}
