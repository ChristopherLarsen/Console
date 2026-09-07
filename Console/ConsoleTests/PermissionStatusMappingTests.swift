import XCTest
import Speech
@testable import Console

/// H21-F01 / H20-F02 — the speech recognition permission status must surface
/// denied and restricted instead of collapsing them into "Not Granted".
final class PermissionStatusMappingTests: XCTestCase {

    func testSpeechAuthorizationStatusesMapIndividually() {
        XCTAssertEqual(
            PermissionStatusPoller.mapSpeechAuthorizationStatus(.authorized),
            .granted
        )
        XCTAssertEqual(
            PermissionStatusPoller.mapSpeechAuthorizationStatus(.denied),
            .denied
        )
        XCTAssertEqual(
            PermissionStatusPoller.mapSpeechAuthorizationStatus(.restricted),
            .restricted
        )
        XCTAssertEqual(
            PermissionStatusPoller.mapSpeechAuthorizationStatus(.notDetermined),
            .notGranted
        )
    }

    func testDeniedIsNotCollapsedIntoNotGranted() {
        let status = PermissionStatusPoller.mapSpeechAuthorizationStatus(.denied)
        XCTAssertNotEqual(status, .notGranted)
        XCTAssertEqual(status.displayLabel, "Denied")
    }

    func testRestrictedIsNotCollapsedIntoNotGranted() {
        let status = PermissionStatusPoller.mapSpeechAuthorizationStatus(.restricted)
        XCTAssertNotEqual(status, .notGranted)
        XCTAssertEqual(status.displayLabel, "Restricted")
        XCTAssertFalse(status.isUserChangeable)
    }
}
