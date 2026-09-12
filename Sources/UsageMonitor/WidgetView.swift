import AppKit
import Combine
import SwiftUI
import UsageCore

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("usageWidgetCollapsed") private var isCollapsed = false
    @State private var showsWeekly = false
    @State private var now = Date()

    private let clockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if isCollapsed {
                collapsedBody
            } else {
                expandedBody
            }
        }
        .padding(isCollapsed ? 7 : 10)
        .frame(width: isCollapsed ? 208 : 220)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: isCollapsed) { value in
            store.refreshCodex()
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
            HStack(spacing: 8) {
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

            ProviderView(provider: .claude, snapshot: store.claude, showsWeekly: showsWeekly, now: now)
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
        .help("Expand usage. Claude parentheses show Fable weekly usage.")
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
                    label: primaryLabel,
                    window: primaryWindow,
                    snapshotUpdatedAt: snapshot?.updatedAt,
                    emptyText: statusText(for: primaryWindow),
                    now: now
                )
            }

            if showsWeekly && !usesWeeklyFallback {
                HStack(spacing: 7) {
                    Color.clear
                        .frame(width: 16, height: 16)

                    UsageMeter(
                        label: "7d",
                        window: snapshot?.sevenDay,
                        snapshotUpdatedAt: snapshot?.updatedAt,
                        emptyText: statusText(for: snapshot?.sevenDay),
                        now: now
                    )
                }
            }

            if showsWeekly && provider == .claude {
                HStack(spacing: 7) {
                    Color.clear.frame(width: 16, height: 16)
                    UsageMeter(
                        label: "Fable",
                        window: snapshot?.fableWeekly,
                        snapshotUpdatedAt: snapshot?.fableWeeklyUpdatedAt,
                        emptyText: "not reported",
                        now: now
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

                if provider == .claude, snapshot?.fableWeekly != nil {
                    Text(fableText)
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(fableColor)
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
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("\(provider.displayName) \(usesWeeklyFallback ? "7-day" : "5-hour") usage.\(provider == .claude ? " Parentheses: Fable weekly usage." : "") Last checked: \(snapshot?.updatedAt.formatted(date: .omitted, time: .standard) ?? "waiting")")
    }

    private var usedText: String {
        guard let used = displayedUsedPercent else {
            return "--"
        }
        return "\(Int(round(used)))%"
    }

    private var displayedFablePercent: Double? {
        guard let window = snapshot?.fableWeekly,
              !UsageFreshness.needsUpdate(window: window,
                                          updatedAt: snapshot?.fableWeeklyUpdatedAt, now: now)
        else { return nil }
        return window.usedPercent
    }

    private var fableText: String {
        displayedFablePercent.map { "(\(Int(round($0)))%)" } ?? "(--)"
    }

    private var fableColor: Color {
        guard let used = displayedFablePercent else { return .secondary }
        if used >= 90 { return .red }
        return used >= 70 ? .orange : .secondary
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
        UsageFreshness.needsUpdate(window: window, updatedAt: snapshot?.updatedAt, now: now)
    }

    private var primaryWindow: LimitWindow? {
        snapshot?.fiveHour ?? snapshot?.sevenDay
    }

    private var usesWeeklyFallback: Bool {
        snapshot?.fiveHour == nil && snapshot?.sevenDay != nil
    }

    private var textColor: Color {
        guard let used = displayedUsedPercent else {
            return .secondary
        }
        return used >= 70 ? statusColor : .primary
    }

    private var statusColor: Color {
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

private struct UsageMeter: View {
    var label: String
    var window: LimitWindow?
    var snapshotUpdatedAt: Date?
    var emptyText: String
    var now: Date

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
                Text(usedText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text(resetText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var displayedUsedPercent: Double? {
        guard let used = window?.usedPercent else {
            return nil
        }
        return needsFreshSample ? nil : used
    }

    private var needsFreshSample: Bool {
        UsageFreshness.needsUpdate(window: window, updatedAt: snapshotUpdatedAt, now: now)
    }

    private var usedText: String {
        guard let used = displayedUsedPercent else {
            return "--"
        }
        return "\(Int(round(used)))%"
    }

    private var resetText: String {
        if window == nil {
            return emptyText
        }
        if needsFreshSample {
            return "stale - refreshing"
        }
        guard let date = window?.resetsAt else {
            if let used = displayedUsedPercent, used <= 0.5 {
                return "ready"
            }
            return "waiting for reset time"
        }
        return ResetFormatter.shared.string(from: date, now: now)
    }

    private var color: Color {
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
