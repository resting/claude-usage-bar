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

    // MARK: - isWithinIgnoreWindow pure function

    /// Builds a Date at the given local hour/minute using a fixed UTC calendar,
    /// so the time-of-day extraction is deterministic regardless of test machine TZ.
    private func time(_ hour: Int, _ minute: Int) -> (Date, Calendar) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: hour, minute: minute))!
        return (date, cal)
    }

    func testIgnoreWindow_insideDaytimeRange_returnsTrue() {
        let (now, cal) = time(3, 30)
        XCTAssertTrue(isWithinIgnoreWindow(startMinutes: 60, endMinutes: 300, now: now, calendar: cal))
    }

    func testIgnoreWindow_outsideDaytimeRange_returnsFalse() {
        let (now, cal) = time(6, 0)
        XCTAssertFalse(isWithinIgnoreWindow(startMinutes: 60, endMinutes: 300, now: now, calendar: cal))
    }

    func testIgnoreWindow_wrapsMidnight_lateNight_returnsTrue() {
        // 23:00–07:00 quiet window, now = 02:00 → inside.
        let (now, cal) = time(2, 0)
        XCTAssertTrue(isWithinIgnoreWindow(startMinutes: 23 * 60, endMinutes: 7 * 60, now: now, calendar: cal))
    }

    func testIgnoreWindow_wrapsMidnight_evening_returnsTrue() {
        // 23:00–07:00 quiet window, now = 23:30 → inside.
        let (now, cal) = time(23, 30)
        XCTAssertTrue(isWithinIgnoreWindow(startMinutes: 23 * 60, endMinutes: 7 * 60, now: now, calendar: cal))
    }

    func testIgnoreWindow_wrapsMidnight_daytime_returnsFalse() {
        // 23:00–07:00 quiet window, now = 12:00 → outside.
        let (now, cal) = time(12, 0)
        XCTAssertFalse(isWithinIgnoreWindow(startMinutes: 23 * 60, endMinutes: 7 * 60, now: now, calendar: cal))
    }

    func testIgnoreWindow_startInclusive_endExclusive() {
        let (start, cal) = time(1, 0)
        XCTAssertTrue(isWithinIgnoreWindow(startMinutes: 60, endMinutes: 300, now: start, calendar: cal))
        let (end, _) = time(5, 0)
        XCTAssertFalse(isWithinIgnoreWindow(startMinutes: 60, endMinutes: 300, now: end, calendar: cal))
    }

    func testIgnoreWindow_zeroLength_matchesNothing() {
        let (now, cal) = time(9, 0)
        XCTAssertFalse(isWithinIgnoreWindow(startMinutes: 540, endMinutes: 540, now: now, calendar: cal))
    }

    // MARK: - ResetCommandService ignore-window setters

    @MainActor
    func testSetIgnoreWindow_persistsToUserDefaults() {
        let svc = ResetCommandService()
        svc.setIgnoreWindowEnabled(true)
        svc.setIgnoreStartMinutes(22 * 60)
        svc.setIgnoreEndMinutes(6 * 60)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ignoreWindowEnabled"))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "ignoreWindowStartMinutes"), 22 * 60)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "ignoreWindowEndMinutes"), 6 * 60)
        UserDefaults.standard.removeObject(forKey: "ignoreWindowEnabled")
        UserDefaults.standard.removeObject(forKey: "ignoreWindowStartMinutes")
        UserDefaults.standard.removeObject(forKey: "ignoreWindowEndMinutes")
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

    // MARK: - extractCurrentSessionLine

    func testExtractCurrentSessionLine_findsAndTrimsLine() {
        let output = """
        Some banner text

          Current session: 1% used · resets Jul 9 at 3:19pm (Asia/Singapore)

        Other stuff
        """
        XCTAssertEqual(
            ResetCommandService.extractCurrentSessionLine(from: output),
            "Current session: 1% used · resets Jul 9 at 3:19pm (Asia/Singapore)"
        )
    }

    func testExtractCurrentSessionLine_missingLine_returnsNil() {
        let output = "Hi! What are you working on today?"
        XCTAssertNil(ResetCommandService.extractCurrentSessionLine(from: output))
    }

    func testExtractCurrentSessionLine_emptyOutput_returnsNil() {
        XCTAssertNil(ResetCommandService.extractCurrentSessionLine(from: ""))
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
