import Foundation

public struct WeeklyPace: Equatable, Sendable {
    public enum Status: Int, Sendable {
        case onTrack, ahead, over
    }

    public static let duration: TimeInterval = 7 * 24 * 60 * 60
    public static let dailyAllowance = 100.0 / 7
    public let allowance: Double
    public let difference: Double
    public let status: Status

    public static func calculate(window: LimitWindow?, now: Date) -> WeeklyPace? {
        guard let window, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
              let reset = window.resetsAt else { return nil }
        let remaining = reset.timeIntervalSince(now)
        guard remaining.isFinite, remaining > 0, remaining <= duration else { return nil }
        // Quota weeks are anchored to the provider's reset, not calendar weekdays.
        let allowance = (duration - remaining) / duration * 100
        let difference = window.usedPercent - allowance
        let status: Status = difference <= 0.000001 ? .onTrack :
            difference <= dailyAllowance + 0.000001 ? .ahead : .over
        return WeeklyPace(allowance: allowance, difference: difference, status: status)
    }

    public var differenceText: String {
        let magnitude = abs(difference)
        guard magnitude > 0.000001 else { return "0" }
        let sign = difference < 0 ? "-" : "+"
        return sign + (magnitude < 0.5 ? "<1" : "\(Int(magnitude.rounded()))")
    }

    public var suffix: String { " (\(differenceText))" }

    public var help: String {
        let summary = abs(difference) <= 0.000001 ? "Exactly on weekly pace." :
            "\(String(format: "%.1f", abs(difference))) percentage points \(difference < 0 ? "below" : "ahead of") weekly pace."
        return "\(summary) Allowance by now: \(String(format: "%.1f", allowance))%. Orange: up to one day's allowance ahead (14.3 points); red: more than one day ahead."
    }
}
