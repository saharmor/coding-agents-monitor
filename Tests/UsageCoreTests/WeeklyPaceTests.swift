import Foundation
import Testing
@testable import UsageCore

private let paceNow = Date(timeIntervalSince1970: 1_800_000_000)

private func paceWindow(used: Double, elapsedDays: Double) -> LimitWindow {
    LimitWindow(usedPercent: used, remainingPercent: 100 - used,
                resetsAt: paceNow.addingTimeInterval((7 - elapsedDays) * 86400))
}

@Test func weeklyPaceUsesElapsedTimeAndReportsPercentagePoints() throws {
    let pace = try #require(WeeklyPace.calculate(window: paceWindow(used: 27, elapsedDays: 1), now: paceNow))
    #expect(abs(pace.allowance - 100.0 / 7) < 0.000001)
    #expect(pace.status == .ahead)
    #expect(pace.suffix == " (+13)")
    let red = try #require(WeeklyPace.calculate(window: paceWindow(used: 30, elapsedDays: 1), now: paceNow))
    #expect(red.status == .over)
    #expect(red.suffix == " (+16)")
}

@Test func weeklyPaceThresholdsAreInclusiveAndUseFractionalDays() throws {
    let allowance = 100.0 / 7
    for used in [0, allowance] {
        let pace = try #require(WeeklyPace.calculate(window: paceWindow(used: used, elapsedDays: 1), now: paceNow))
        #expect(pace.status == .onTrack)
        #expect(pace.suffix == (used == 0 ? " (-14)" : " (0)"))
    }
    let boundary = try #require(WeeklyPace.calculate(window: paceWindow(used: allowance * 2, elapsedDays: 1), now: paceNow))
    #expect(boundary.status == .ahead)
    #expect(WeeklyPace.calculate(window: paceWindow(used: allowance * 2 + 0.001, elapsedDays: 1), now: paceNow)?.status == .over)
    let half = try #require(WeeklyPace.calculate(window: paceWindow(used: 7.2, elapsedDays: 0.5), now: paceNow))
    #expect(abs(half.allowance - 100.0 / 14) < 0.000001)
    #expect(half.differenceText == "+<1")
    #expect(WeeklyPace.calculate(window: paceWindow(used: 85, elapsedDays: 6), now: paceNow)?.status == .onTrack)
}

@Test func weeklyPaceShowsSignedSavingsAndZero() throws {
    for (used, elapsedDays, expected) in [(24.0, 3.5, "-26"), (25, 3.5, "-25"),
                                        (49.9, 3.5, "-<1"), (50, 3.5, "0"),
                                        (0, 6.999, "-100"), (0, 0, "0")] {
        let pace = try #require(WeeklyPace.calculate(window: paceWindow(used: used, elapsedDays: elapsedDays), now: paceNow))
        #expect(pace.status == .onTrack)
        #expect(pace.differenceText == expected)
        #expect(pace.suffix == " (\(expected))")
    }
    let green = try #require(WeeklyPace.calculate(window: paceWindow(used: 25, elapsedDays: 3.5), now: paceNow))
    #expect(green.help.contains("25.0 percentage points below weekly pace"))
}

@Test func greenWeeklyPaceDoesNotAddUnnecessaryCompactWarnings() {
    var snapshot = UsageSnapshot(provider: .claude,
                                 fiveHour: LimitWindow(usedPercent: 5, remainingPercent: 95, resetsAt: paceNow.addingTimeInterval(3600)),
                                 sevenDay: paceWindow(used: 24, elapsedDays: 3.5),
                                 context: nil, updatedAt: paceNow, source: .claudeStatusLine)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow) == nil)
    snapshot.sevenDay = paceWindow(used: 85, elapsedDays: 6)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow)?.usedPercent == 85)
    snapshot.sevenDay?.resetsAt = nil
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow)?.usedPercent == 85)
    snapshot.sevenDay?.usedPercent = 24
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow) == nil)
}

@Test func weeklyPaceRejectsMissingExpiredOrImpossibleWindows() {
    #expect(WeeklyPace.calculate(window: nil, now: paceNow) == nil)
    for used in [Double.nan, .infinity, -1, 101] {
        #expect(WeeklyPace.calculate(window: paceWindow(used: used, elapsedDays: 1), now: paceNow) == nil)
    }
    for elapsed in [-0.1, 7, 8] {
        #expect(WeeklyPace.calculate(window: paceWindow(used: 20, elapsedDays: elapsed), now: paceNow) == nil)
    }
    var window = paceWindow(used: 20, elapsedDays: 1)
    window.resetsAt = nil
    #expect(WeeklyPace.calculate(window: window, now: paceNow) == nil)
    #expect(WeeklyPace.calculate(window: paceWindow(used: 0, elapsedDays: 0), now: paceNow)?.status == .onTrack)
}

@Test func aheadOfPaceWeeklyQuotaAppearsInCompactViewBeforeEightyPercent() {
    let snapshot = UsageSnapshot(provider: .claude,
                                 fiveHour: LimitWindow(usedPercent: 5, remainingPercent: 95, resetsAt: paceNow.addingTimeInterval(3600)),
                                 sevenDay: paceWindow(used: 27, elapsedDays: 1),
                                 context: nil, updatedAt: paceNow, source: .claudeStatusLine)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow)?.usedPercent == 27)
    var weeklyOnly = snapshot
    weeklyOnly.fiveHour = nil
    #expect(CompactUsage.weeklyWarning(for: weeklyOnly, now: paceNow) == nil)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: paceNow.addingTimeInterval(1800)) == nil)
}
