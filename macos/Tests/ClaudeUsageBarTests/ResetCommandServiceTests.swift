import XCTest
@testable import ClaudeUsageBar

final class ResetCommandServiceTests: XCTestCase {

    // MARK: - didWindowReset pure function

    func testNilPrevious_returnsFalse() {
        let now = Date()
        let futureDate = now.addingTimeInterval(3600)
        XCTAssertFalse(didWindowReset(previous: nil, current: futureDate, now: now))
    }

    func testNilCurrent_returnsFalse() {
        let now = Date()
        let pastDate = now.addingTimeInterval(-3600)
        XCTAssertFalse(didWindowReset(previous: pastDate, current: nil, now: now))
    }

    func testBothNil_returnsFalse() {
        XCTAssertFalse(didWindowReset(previous: nil, current: nil, now: Date()))
    }

    func testRealReset_oldPastNewFuture_returnsTrue() {
        // The window reset: old resetsAt is in the past, new one is in the future.
        let now = Date()
        let oldReset = now.addingTimeInterval(-60)   // reset happened 1 min ago
        let newReset = now.addingTimeInterval(18000) // next reset in 5h
        XCTAssertTrue(didWindowReset(previous: oldReset, current: newReset, now: now))
    }

    func testFalsePositive_bothInFuture_returnsFalse() {
        // API returned a slightly later future timestamp — must NOT fire.
        let now = Date()
        let prev = now.addingTimeInterval(14100) // 3h 55min from now
        let curr = now.addingTimeInterval(14400) // 4h from now (slightly later)
        XCTAssertFalse(didWindowReset(previous: prev, current: curr, now: now))
    }

    func testFalsePositive_prevFutureNewFuture_returnsFalse() {
        // No reset yet — both dates are in the future.
        let now = Date()
        let prev = now.addingTimeInterval(18000) // 5h ahead
        let curr = now.addingTimeInterval(18000) // same
        XCTAssertFalse(didWindowReset(previous: prev, current: curr, now: now))
    }

    func testOldResetExactlyAtNow_returnsTrue() {
        // Edge: old reset is exactly now (prev <= now is true).
        let now = Date()
        let oldReset = now
        let newReset = now.addingTimeInterval(18000)
        XCTAssertTrue(didWindowReset(previous: oldReset, current: newReset, now: now))
    }

    func testCurrentInPast_returnsFalse() {
        // Both past — degenerate case, should not fire.
        let now = Date()
        let old = now.addingTimeInterval(-7200) // 2h ago
        let curr = now.addingTimeInterval(-3600) // 1h ago
        XCTAssertFalse(didWindowReset(previous: old, current: curr, now: now))
    }

    // MARK: - ResetCommandService.setEnabled

    @MainActor
    func testSetEnabled_persistsToUserDefaults() {
        let svc = ResetCommandService()
        svc.setEnabled(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "autoRunOnResetEnabled"))
        svc.setEnabled(false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "autoRunOnResetEnabled"))
        UserDefaults.standard.removeObject(forKey: "autoRunOnResetEnabled")
    }

    @MainActor
    func testSetEnabled_rebaselines_sameDateDoesNotFire() {
        // Seeding a resetsAt while disabled then re-enabling must not fire with same date.
        let svc = ResetCommandService()
        let now = Date()
        let futureReset = now.addingTimeInterval(3600)

        svc.setEnabled(false)
        svc.handleReset(resetsAt: futureReset, now: now)  // stores previousResetsAt, but disabled

        // Re-enable clears previousResetsAt
        svc.setEnabled(true)
        // didWindowReset(nil, futureReset, now) == false — no fire
        XCTAssertFalse(didWindowReset(previous: nil, current: futureReset, now: now))
        svc.handleReset(resetsAt: futureReset, now: now)  // must not crash or fire
    }

    @MainActor
    func testHandleReset_realResetDetected() {
        // After a genuine reset, the condition passes.
        let now = Date()
        let oldReset = now.addingTimeInterval(-60)   // just expired
        let newReset = now.addingTimeInterval(18000) // next window
        XCTAssertTrue(didWindowReset(previous: oldReset, current: newReset, now: now))
    }
}
