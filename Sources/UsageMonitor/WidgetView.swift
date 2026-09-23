import AppKit
import Combine
import SwiftUI
import UsageCore

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("usageWidgetCollapsed") private var isCollapsed = false
    @State private var showsWeekly = false
    @State private var showsRefreshResult = false
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var collapsedWidth: CGFloat {
        let warnings = [store.claude, store.codex].compactMap {
            CompactUsage.weeklyWarning(for: $0, now: now)
        }.count
        let paceLabels = [store.claude, store.codex].compactMap { $0 }.reduce(0) { count, snapshot in
            let primary = snapshot.fiveHour == nil ? snapshot.sevenDay : nil
            let primaryHasPace = UsageFreshness.canDisplay(window: primary, updatedAt: snapshot.updatedAt, now: now, provider: snapshot.provider) &&
                WeeklyPace.calculate(window: primary, now: now) != nil
            let fableHasPace = snapshot.provider == .claude && UsageFreshness.canDisplay(window: snapshot.fableWeekly, updatedAt: snapshot.fableWeeklyUpdatedAt, now: now, provider: snapshot.provider) &&
                WeeklyPace.calculate(window: snapshot.fableWeekly, now: now) != nil
            return count + (primaryHasPace ? 1 : 0) + (fableHasPace ? 1 : 0)
        }
        return 220 + CGFloat(warnings) * 80 + CGFloat(paceLabels) * 36
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(isCollapsed ? 7 : 10)
        .frame(width: isCollapsed ? collapsedWidth : 220)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: collapsedWidth) { width in
            NotificationCenter.default.post(
                name: .usageMonitorCollapsedWidthChanged,
                object: nil,
                userInfo: ["width": width]
            )
        }
        .onChange(of: isCollapsed) { value in
            store.refreshCodex()
            store.refreshClaude()
            NotificationCenter.default.post(
                name: .usageMonitorCollapsedChanged,
                object: nil,
                userInfo: ["isCollapsed": value]
            )
        }
        .onChange(of: showsWeekly) { value in
            NotificationCenter.default.post(
                name: .usageMonitorWeeklyVisibilityChanged,
                object: nil,
                userInfo: ["showsWeekly": value]
            )
        }
        .onReceive(clockTimer) { value in
            now = value
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Usage")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))

                if store.setupMessage.contains("failed") {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(store.setupMessage)
                }

                Spacer()

                Button {
                    showsRefreshResult = false
                    store.refreshNow()
                } label: {
                    Group {
                        if store.manualRefreshInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(store.manualRefreshInFlight)
                .accessibilityLabel("Refresh usage")
                .help("Refresh usage now. Claude server cooldowns still apply; checks are at least one minute apart.")
                .popover(isPresented: $showsRefreshResult) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.manualRefreshMessage ?? "Refreshing...")
                        Text(store.codexRefreshError.map { "Codex: \($0)" } ??
                             (store.codexRefreshInFlight ? "Codex refreshing..." :
                              "Codex last checked: \(store.codex?.updatedAt.formatted(date: .omitted, time: .standard) ?? "waiting")"))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(12)
                    .frame(width: 240, alignment: .leading)
                }
                .onChange(of: store.manualRefreshMessage) { message in
                    showsRefreshResult = message != nil
                }

                Button {
                    NotificationCenter.default.post(name: .usageMonitorSnoozeRequested, object: nil)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Hide for one hour")
                .help("Hide widget for 1 hour")

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isCollapsed = true
                    }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Minimize")
                .help("Minimize widget")

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsWeekly.toggle()
                    }
                } label: {
                    Image(systemName: showsWeekly ? "calendar.badge.minus" : "calendar")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showsWeekly ? .primary : .secondary)
                .help(showsWeekly ? "Hide weekly usage" : "Show weekly usage")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ProviderView(provider: .claude, snapshot: store.claude, showsWeekly: showsWeekly, now: now,
                         refreshError: store.claudeRefreshError)
            ProviderView(provider: .codex, snapshot: store.codex, showsWeekly: showsWeekly, now: now,
                         refreshError: store.codexRefreshError)
        }
    }

    private var collapsedBody: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                isCollapsed = false
            }
        } label: {
            HStack(spacing: 3) {
                CollapsedProviderView(provider: .claude, snapshot: store.claude, now: now)

                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 1, height: 14)

                CollapsedProviderView(provider: .codex, snapshot: store.codex, now: now)

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .buttonStyle(.plain)
        .help("Expand usage. ~ means cached, not live. Parentheses: Fable weekly. Weekly colors compare usage with elapsed time; signed values are percentage points above (+) or below (-) pace.")
    }
}

private struct ProviderView: View {
    var provider: UsageProvider
    var snapshot: UsageSnapshot?
    var showsWeekly: Bool
    var now: Date
    var refreshError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProviderLogo(provider: provider)
                    .frame(width: 16, height: 16)
                    .opacity(snapshot == nil ? 0.55 : 1)
                    .help(refreshError ?? "\(provider.displayName). Last checked: \(snapshot?.updatedAt.formatted(date: .omitted, time: .standard) ?? "waiting")")

                UsageMeter(
                    provider: provider,
                    label: primaryLabel,
                    isWeekly: usesWeeklyFallback,
                    window: primaryWindow,
                    snapshotUpdatedAt: snapshot?.updatedAt,
                    emptyText: statusText(for: primaryWindow),
                    now: now,
                    refreshError: refreshError
                )
            }

            if showsWeekly && !usesWeeklyFallback {
                HStack(spacing: 7) {
                    Color.clear
                        .frame(width: 16, height: 16)

                    UsageMeter(
                        provider: provider,
                        label: "7d",
                        isWeekly: true,
                        window: snapshot?.sevenDay,
                        snapshotUpdatedAt: snapshot?.updatedAt,
                        emptyText: statusText(for: snapshot?.sevenDay),
                        now: now,
                        refreshError: refreshError
                    )
                }
            }

            if showsWeekly && provider == .claude {
                HStack(spacing: 7) {
                    Color.clear.frame(width: 16, height: 16)
                    UsageMeter(
                        provider: provider,
                        label: "Fable",
                        isWeekly: true,
                        window: snapshot?.fableWeekly,
                        snapshotUpdatedAt: snapshot?.fableWeeklyUpdatedAt,
                        emptyText: "not reported",
                        now: now,
                        refreshError: refreshError
                    )
                    .help("Fable weekly usage")
                }
            }
        }
    }

    private var primaryWindow: LimitWindow? {
        snapshot?.fiveHour ?? snapshot?.sevenDay
    }

    private var primaryLabel: String {
        usesWeeklyFallback ? "7d" : "5h"
    }

    private var usesWeeklyFallback: Bool {
        snapshot?.fiveHour == nil && snapshot?.sevenDay != nil
    }

    private func statusText(for window: LimitWindow?) -> String {
        guard let snapshot else {
            return refreshError == nil ? "refreshing..." : "refresh unavailable"
        }
        guard window != nil else {
            return "not reported"
        }
        let age = now.timeIntervalSince(snapshot.updatedAt)
        if age > 600 {
            return "stale \(Int(age / 60))m"
        }
        if age < 60 {
            return "live"
        }
        return "\(Int(age / 60))m ago"
    }
}

private extension UsageProvider {
    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        }
    }

    var logoResourceName: String {
        switch self {
        case .claude:
            return "claude-logo"
        case .codex:
            return "codex-logo"
        }
    }

    @MainActor var logoImage: NSImage? {
        switch self {
        case .claude:
            return ProviderLogoCache.claude
        case .codex:
            return ProviderLogoCache.codex
        }
    }
}

@MainActor
private enum ProviderLogoCache {
    static let claude = loadImage(named: UsageProvider.claude.logoResourceName)
    static let codex = loadImage(named: UsageProvider.codex.logoResourceName)

    private static func loadImage(named name: String) -> NSImage? {
        if let namedImage = NSImage(named: name) {
            return namedImage
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private struct ProviderLogo: View {
    var provider: UsageProvider

    var body: some View {
        if let image = provider.logoImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityLabel(Text(provider.displayName))
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(provider.displayName))
        }
    }
}

private struct CollapsedProviderView: View {
    var provider: UsageProvider
    var snapshot: UsageSnapshot?
    var now: Date

    var body: some View {
        HStack(spacing: 3) {
            ProviderLogo(provider: provider)
                .frame(width: 13, height: 13)
                .opacity(snapshot == nil ? 0.55 : 1)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.85), lineWidth: 0.7)
                        )
                        .offset(x: 1.5, y: 1)
                }

            HStack(spacing: 0) {
                Text(usedText)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(textColor)
                    .help(primaryPace?.help ?? "Five-hour usage")

                if provider == .claude, snapshot?.fableWeekly != nil {
                    Text(fableText)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(fableColor)
                        .help(fablePace?.help ?? "Fable weekly pace unavailable")
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

            if let resetText {
                Text(resetText)
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 20, alignment: .leading)
            }

            if let weeklyWarning {
                Text("\(cachedPrefix(window: weeklyWarning, updatedAt: snapshot?.updatedAt))7d \(Int(round(weeklyWarning.usedPercent)))%\(WeeklyPace.calculate(window: weeklyWarning, now: now)?.suffix ?? "")")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(WeeklyPace.calculate(window: weeklyWarning, now: now)?.color ?? .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 76, alignment: .leading)
                    .help(WeeklyPace.calculate(window: weeklyWarning, now: now)?.help ?? "Weekly pace unavailable without a valid reset time.")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("\(provider.displayName) \(usesWeeklyFallback ? "7-day" : "5-hour") usage.\(provider == .claude ? " Parentheses: Fable weekly usage." : "") Last checked: \(snapshot?.updatedAt.formatted(date: .omitted, time: .standard) ?? "waiting")")
    }

    private var usedText: String {
        guard let used = displayedUsedPercent else {
            return "--"
        }
        return "\(cachedPrefix(window: primaryWindow, updatedAt: snapshot?.updatedAt))\(Int(round(used)))%\(primaryPace?.suffix ?? "")"
    }

    private var primaryPace: WeeklyPace? {
        guard usesWeeklyFallback, displayedUsedPercent != nil else { return nil }
        return WeeklyPace.calculate(window: primaryWindow, now: now)
    }

    private var fablePace: WeeklyPace? {
        guard displayedFablePercent != nil else { return nil }
        return WeeklyPace.calculate(window: snapshot?.fableWeekly, now: now)
    }

    private func cachedPrefix(window: LimitWindow?, updatedAt: Date?) -> String {
        UsageFreshness.needsUpdate(window: window, updatedAt: updatedAt, now: now) ? "~" : ""
    }

    private var weeklyWarning: LimitWindow? {
        CompactUsage.weeklyWarning(for: snapshot, now: now)
    }

    private var displayedFablePercent: Double? {
        guard let window = snapshot?.fableWeekly,
              UsageFreshness.canDisplay(window: window,
                                         updatedAt: snapshot?.fableWeeklyUpdatedAt, now: now, provider: provider)
        else { return nil }
        return window.usedPercent
    }

    private var fableText: String {
        displayedFablePercent.map { "(\(cachedPrefix(window: snapshot?.fableWeekly, updatedAt: snapshot?.fableWeeklyUpdatedAt))\(Int(round($0)))%\(fablePace.map { " \($0.differenceText)" } ?? ""))" } ?? "(--)"
    }

    private var fableColor: Color {
        fablePace?.color ?? .secondary
    }

    private var displayedUsedPercent: Double? {
        guard
            let window = primaryWindow,
            !needsFreshSample(window: window)
        else {
            return nil
        }
        return window.usedPercent
    }

    private var resetText: String? {
        guard
            displayedUsedPercent != nil,
            let resetsAt = primaryWindow?.resetsAt
        else {
            return nil
        }

        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else {
            return nil
        }
        if seconds < 60 * 60 {
            let minutes = max(1, min(59, Int(ceil(seconds / 60))))
            return "\(minutes)m"
        }
        return "\(max(1, Int(ceil(seconds / (60 * 60)))))h"
    }

    private func needsFreshSample(window: LimitWindow) -> Bool {
        !UsageFreshness.canDisplay(window: window, updatedAt: snapshot?.updatedAt, now: now, provider: provider)
    }

    private var primaryWindow: LimitWindow? {
        snapshot?.fiveHour ?? snapshot?.sevenDay
    }

    private var usesWeeklyFallback: Bool {
        snapshot?.fiveHour == nil && snapshot?.sevenDay != nil
    }

    private var textColor: Color {
        if usesWeeklyFallback { return primaryPace?.color ?? .secondary }
        guard let used = displayedUsedPercent else {
            return .secondary
        }
        return used >= 90 ? .red : used >= 70 ? .orange : .primary
    }

    private var statusColor: Color {
        var levels = [primaryPace, fablePace, WeeklyPace.calculate(window: weeklyWarning, now: now)]
            .compactMap { $0?.status.rawValue }
        if !usesWeeklyFallback, let used = displayedUsedPercent {
            levels.append(used >= 90 ? 2 : used >= 70 ? 1 : 0)
        }
        guard let level = levels.max() else { return .gray }
        return level == 2 ? .red : level == 1 ? .orange : .green
    }
}

private struct UsageMeter: View {
    var provider: UsageProvider
    var label: String
    var isWeekly: Bool
    var window: LimitWindow?
    var snapshotUpdatedAt: Date?
    var emptyText: String
    var now: Date
    var refreshError: String? = nil

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .frame(width: label == "Fable" ? 32 : 20, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat((displayedUsedPercent ?? 0) / 100))
                    }
                }
                .frame(height: 6)
                HStack(spacing: 3) {
                    Text(usedText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    if let difference = pace?.differenceText {
                        Text("(\(difference))")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                    }
                }
                    .foregroundStyle(isWeekly ? (pace?.color ?? .secondary) : .primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: isWeekly ? 80 : 40, alignment: .trailing)
                    .help(pace?.help ?? (isWeekly ? "Weekly pace unavailable without a valid reset time." : "Five-hour usage"))
            }
            HStack {
                Text(resetText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(resetHelp)
                Spacer()
            }
        }
    }

    private var displayedUsedPercent: Double? {
        guard let used = window?.usedPercent else {
            return nil
        }
        return UsageFreshness.canDisplay(window: window, updatedAt: snapshotUpdatedAt, now: now, provider: provider) ? used : nil
    }

    private var pace: WeeklyPace? {
        guard isWeekly, displayedUsedPercent != nil else { return nil }
        return WeeklyPace.calculate(window: window, now: now)
    }

    private var needsFreshSample: Bool {
        UsageFreshness.needsUpdate(window: window, updatedAt: snapshotUpdatedAt, now: now)
    }

    private var usedText: String {
        guard let used = displayedUsedPercent else {
            return "--"
        }
        return "\(needsFreshSample ? "~" : "")\(Int(round(used)))%"
    }

    private var resetText: String {
        if let date = window?.resetsAt, date > now {
            return ResetFormatter.shared.string(from: date, now: now)
        }
        if window == nil {
            return refreshError ?? emptyText
        }
        if needsFreshSample && displayedUsedPercent == nil {
            return refreshError ?? "stale - refreshing"
        }
        guard let date = window?.resetsAt else {
            if let used = displayedUsedPercent, used <= 0.5 {
                return "ready"
            }
            return "waiting for reset time"
        }
        return ResetFormatter.shared.string(from: date, now: now)
    }

    private var resetHelp: String {
        var details: [String] = []
        if let snapshotUpdatedAt {
            let minutes = max(0, Int(now.timeIntervalSince(snapshotUpdatedAt) / 60))
            let age = minutes == 0 ? "just now" : "\(minutes)m ago"
            details.append("Last checked \(age) (\(snapshotUpdatedAt.formatted(date: .omitted, time: .standard))).")
            if needsFreshSample { details.append("Cached reading; waiting for fresh usage.") }
        } else {
            details.append("No usage reading received yet.")
        }
        if let refreshError { details.append(refreshError) }
        return details.joined(separator: " ")
    }

    private var color: Color {
        if isWeekly { return pace?.color ?? .gray }
        guard let used = displayedUsedPercent else {
            return .gray
        }
        if used >= 90 {
            return .red
        }
        if used >= 70 {
            return .orange
        }
        return .green
    }
}

private extension WeeklyPace {
    var color: Color {
        switch status {
        case .onTrack: return .green
        case .ahead: return .orange
        case .over: return .red
        }
    }
}

@MainActor
private final class ResetFormatter {
    static let shared = ResetFormatter()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.dateFormat = "h:mma"
        return formatter
    }()

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mma"
        return formatter
    }()

    func string(from date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let relative: String

        if seconds <= 0 {
            return "waiting for update"
        } else if seconds < 60 * 60 {
            let minutes = max(1, min(59, Int(ceil(seconds / 60))))
            relative = minutes == 1 ? "1 min" : "\(minutes) mins"
        } else {
            relative = "\(max(1, Int(ceil(seconds / (60 * 60)))))h"
        }

        return "resets in \(relative) (\(clockString(from: date, now: now)))"
    }

    private func clockString(from date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return normalizedClock(timeFormatter.string(from: date))
        }
        return normalizedClock(dateFormatter.string(from: date))
    }

    private func normalizedClock(_ value: String) -> String {
        value
            .replacingOccurrences(of: "AM", with: "am")
            .replacingOccurrences(of: "PM", with: "pm")
    }
}
