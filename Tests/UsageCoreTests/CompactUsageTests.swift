import Foundation
import Testing
@testable import UsageCore

private let sampleTime = Date(timeIntervalSince1970: 1_789_240_000)

private func sample(_ provider: UsageProvider, weeklyUsed: Double) -> UsageSnapshot {
    UsageSnapshot(
        provider: provider,
        fiveHour: LimitWindow(usedPercent: 5, remainingPercent: 95,
                              resetsAt: sampleTime.addingTimeInterval(3600)),
        sevenDay: LimitWindow(usedPercent: weeklyUsed, remainingPercent: 100 - weeklyUsed,
                              resetsAt: sampleTime.addingTimeInterval(86400)),
        context: nil, updatedAt: sampleTime,
        source: provider == .claude ? .claudeStatusLine : .codexAccount
    )
}

@Test(arguments: [UsageProvider.claude, .codex])
func weeklyWarningsUseStrictThresholdForBothProviders(_ provider: UsageProvider) {
    for used in [0.0, 79.9, 80.0] {
        #expect(CompactUsage.weeklyWarning(for: sample(provider, weeklyUsed: used), now: sampleTime) == nil)
    }
    for used in [80.1, 81, 90, 98, 100] {
        #expect(CompactUsage.weeklyWarning(for: sample(provider, weeklyUsed: used), now: sampleTime)?.usedPercent == used)
    }
}

@Test func weeklyWarningDoesNotDuplicateFallbackOrUseFable() {
    var snapshot = sample(.claude, weeklyUsed: 98)
    snapshot.fiveHour = nil
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime) == nil)
    snapshot = sample(.claude, weeklyUsed: 20)
    snapshot.fableWeekly = LimitWindow(usedPercent: 99, remainingPercent: 1, resetsAt: nil)
    snapshot.fableWeeklyUpdatedAt = sampleTime
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime) == nil)
    snapshot.sevenDay = nil
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime) == nil)
    #expect(CompactUsage.weeklyWarning(for: nil, now: sampleTime) == nil)
}

@Test func weeklyWarningExpiresAndDisappearsAfterReset() {
    var snapshot = sample(.codex, weeklyUsed: 98)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime.addingTimeInterval(119)) != nil)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime.addingTimeInterval(120)) == nil)
    snapshot.sevenDay?.resetsAt = sampleTime
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime) == nil)
    snapshot = sample(.codex, weeklyUsed: 0)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime) == nil)
}

@Test func claudeCachedReadingsAreBoundedAndNeverSurviveReset() {
    let snapshot = sample(.claude, weeklyUsed: 98)
    let later = sampleTime.addingTimeInterval(900)
    #expect(UsageFreshness.needsUpdate(window: snapshot.fiveHour, updatedAt: sampleTime, now: later))
    #expect(UsageFreshness.canDisplay(window: snapshot.fiveHour, updatedAt: sampleTime, now: later, provider: .claude))
    #expect(!UsageFreshness.canDisplay(window: snapshot.fiveHour, updatedAt: sampleTime, now: later, provider: .codex))
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: later) != nil)
    #expect(CompactUsage.weeklyWarning(for: snapshot, now: sampleTime.addingTimeInterval(1800)) == nil)
    var window = snapshot.fiveHour
    window?.resetsAt = later
    #expect(!UsageFreshness.canDisplay(window: window, updatedAt: sampleTime, now: later, provider: .claude))
    #expect(!UsageFreshness.canDisplay(window: snapshot.fiveHour, updatedAt: later, now: sampleTime, provider: .claude))
    #expect(UsageFreshness.canDisplay(window: snapshot.fiveHour, updatedAt: sampleTime.addingTimeInterval(30), now: sampleTime, provider: .claude))
    #expect(!UsageFreshness.canDisplay(window: snapshot.fableWeekly, updatedAt: nil, now: later, provider: .claude))
}
