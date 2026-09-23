import Foundation

public enum CompactUsage {
    public static func weeklyWarning(for snapshot: UsageSnapshot?, now: Date) -> LimitWindow? {
        // Weekly-only accounts already show this limit as their primary reading.
        guard let snapshot, snapshot.fiveHour != nil,
              let weekly = snapshot.sevenDay,
              weekly.usedPercent.isFinite,
              weekly.usedPercent > 80 || (WeeklyPace.calculate(window: weekly, now: now).map { $0.status != .onTrack } ?? false),
              UsageFreshness.canDisplay(window: weekly, updatedAt: snapshot.updatedAt, now: now, provider: snapshot.provider)
        else { return nil }
        return weekly
    }
}
