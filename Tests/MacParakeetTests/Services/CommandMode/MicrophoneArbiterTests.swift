import XCTest
@testable import MacParakeetCore

@MainActor
final class MicrophoneArbiterTests: XCTestCase {
    func testSecondAcquireIsRejectedUntilRelease() {
        let arbiter = MicrophoneArbiter()
        XCTAssertTrue(arbiter.tryAcquire(.commandMode))
        XCTAssertFalse(arbiter.tryAcquire(.dictation))
        XCTAssertEqual(arbiter.currentOwner, .commandMode)
        arbiter.release(.dictation) // wrong owner — no-op
        XCTAssertEqual(arbiter.currentOwner, .commandMode)
        arbiter.release(.commandMode)
        XCTAssertNil(arbiter.currentOwner)
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
    }

    func testReacquireBySameOwnerSucceeds() {
        let arbiter = MicrophoneArbiter()
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
        XCTAssertTrue(arbiter.tryAcquire(.dictation))
    }
}
