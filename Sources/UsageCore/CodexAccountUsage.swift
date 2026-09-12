import Foundation

public enum CodexAccountParser {
    public static func parseResult(_ data: Data, fetchedAt: Date = Date()) -> UsageSnapshot? {
        guard let root = UsageJSON.object(from: data) else { return nil }
        let bucket: [String: Any]?
        if let buckets = root.dictionary("rateLimitsByLimitId") {
            bucket = buckets.dictionary("codex")
        } else {
            let legacy = root.dictionary("rateLimits")
            let id = legacy?.string("limitId")
            bucket = id == nil || id == "codex" ? legacy : nil
        }
        guard let bucket else { return nil }
        let windows = [bucket.dictionary("primary"), bucket.dictionary("secondary")].compactMap { $0 }
        func window(minutes: Double) -> LimitWindow? {
            guard let raw = windows.first(where: { $0.double("windowDurationMins") == minutes }),
                  let used = raw.double("usedPercent"), used.isFinite else { return nil }
            return UsageJSON.limitWindow(usedPercent: used, resetsAt: raw.double("resetsAt"))
        }
        let fiveHour = window(minutes: 300)
        let sevenDay = window(minutes: 10_080)
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSnapshot(provider: .codex, fiveHour: fiveHour, sevenDay: sevenDay,
                             context: nil, updatedAt: fetchedAt, source: .codexAccount)
    }
}

public enum UsageFreshness {
    public static let maximumAge: TimeInterval = 120

    public static func needsUpdate(window: LimitWindow?, updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return true }
        if now.timeIntervalSince(updatedAt) >= maximumAge { return true }
        guard let reset = window?.resetsAt else { return false }
        return reset <= now
    }

    public static func nextRefresh(after snapshot: UsageSnapshot, now: Date) -> TimeInterval {
        let nextReset = [snapshot.fiveHour?.resetsAt, snapshot.sevenDay?.resetsAt]
            .compactMap { $0 }.filter { $0 > now }.min()
        return min(60, max(5, (nextReset?.timeIntervalSince(now) ?? 60) + 1))
    }
}
