import XCTest
@testable import MacParakeet

@MainActor
final class SparkleUpdateGuardTests: XCTestCase {
    // MARK: - isDevBuildVersion

    func testIsDevBuildVersionTrueForNil() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion(nil))
    }

    func testIsDevBuildVersionTrueForEmpty() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion(""))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("   "))
    }

    func testIsDevBuildVersionTrueForZeroSentinel() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("0.0.0"))
    }

    func testIsDevBuildVersionTrueForDevSentinel() {
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("dev"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("DEV"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("Dev"))
    }

    func testIsDevBuildVersionTrueForPdxSubstring() {
        // OSS-cohort sentinel per memory note (project_telemetry_time_anchor).
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("0.6.0-pdx"))
        XCTAssertTrue(SparkleUpdateGuard.isDevBuildVersion("pdx"))
    }

    func testIsDevBuildVersionFalseForSemverRelease() {
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("0.5.7"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("1.0.0"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("0.6.0"))
        XCTAssertFalse(SparkleUpdateGuard.isDevBuildVersion("10.20.30"))
    }

    // MARK: - blockReason

    func testBlockReasonBlocksDevBuildBeforeMeetingState() {
        XCTAssertEqual(
            SparkleUpdateGuard.blockReason(appVersion: "0.0.0", isMeetingRecordingActive: true),
            .devBuild(version: "0.0.0")
        )
    }

    func testBlockReasonBlocksReleaseBuildDuringMeeting() {
        XCTAssertEqual(
            SparkleUpdateGuard.blockReason(appVersion: "0.6.0", isMeetingRecordingActive: true),
            .meetingRecordingActive
        )
    }

    func testBlockReasonAllowsReleaseBuildWhenIdle() {
        XCTAssertNil(
            SparkleUpdateGuard.blockReason(appVersion: "0.6.0", isMeetingRecordingActive: false)
        )
    }

    // MARK: - Upstream feed (Echo audit 2026-09-09)

    func testBlockReasonBlocksUpstreamMacParakeetFeed() {
        XCTAssertEqual(
            SparkleUpdateGuard.blockReason(
                appVersion: "0.6.7-dev",
                isMeetingRecordingActive: false,
                feedURL: "https://macparakeet.com/appcast.xml"
            ),
            .upstreamFeed
        )
    }

    func testBlockReasonAllowsAnEchoOwnedFeed() {
        XCTAssertNil(
            SparkleUpdateGuard.blockReason(
                appVersion: "0.6.7",
                isMeetingRecordingActive: false,
                feedURL: "https://echo.example.com/appcast.xml"
            )
        )
    }

    /// The shipped Info.plist must not run background update checks.
    func testBuildScriptDisablesAutomaticUpdateChecks() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/dist/build_app_bundle.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("<key>SUEnableAutomaticChecks</key>\n  <false/>"))
    }
}
