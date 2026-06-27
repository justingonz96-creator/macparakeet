import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

final class SettingsStatusRulesTests: XCTestCase {
    func testLocalModelsDoesNotShowReadyWhenInactiveWhisperIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            whisper: .notDownloaded,
            nemotron: .ready,
            activeEngine: .parakeet
        )

        XCTAssertNil(status)
    }

    func testLocalModelsShowsReadyOnlyWhenBothEnginesAreAvailable() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            whisper: .notLoaded,
            nemotron: .ready,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.ok, label: "Ready"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveEngineIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            whisper: .notDownloaded,
            nemotron: .ready,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testLocalModelsShowsPreparingWhenActiveEngineIsPreparing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .notLoaded,
            whisper: .preparing,
            nemotron: .ready,
            activeEngine: .whisper
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Preparing"))
    }

    func testLocalModelsRequiresActionWhenEitherEngineFailed() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            whisper: .failed,
            nemotron: .ready,
            activeEngine: .parakeet
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action needed"))
    }

    func testLocalModelsRecommendsDownloadWhenActiveNemotronIsMissing() {
        let status = SettingsStatusRules.localModelsCardStatus(
            parakeet: .ready,
            whisper: .ready,
            nemotron: .notDownloaded,
            activeEngine: .nemotron
        )

        XCTAssertEqual(status, SettingsCardStatus(.recommended, label: "Download recommended"))
    }

    func testMeetingRecordingRequiresScreenRecordingPermission() {
        let status = SettingsStatusRules.meetingRecordingCardStatus(
            meetingRecordingEnabled: true,
            screenRecordingGranted: false
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Permission required"))
    }

    func testPermissionsRequiresActionWhenScreenRecordingMissingForMeetings() {
        let status = SettingsStatusRules.permissionsCardStatus(
            meetingRecordingEnabled: true,
            microphoneGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false
        )

        XCTAssertEqual(status, SettingsCardStatus(.required, label: "Action required"))
    }
}
