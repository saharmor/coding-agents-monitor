import SwiftUI
import UsageCore

struct WidgetView: View {
    @ObservedObject var store: UsageStore
    @State private var showsWeekly = false

    var body: some View {
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

            ProviderView(provider: .claude, snapshot: store.claude, showsWeekly: showsWeekly)
            ProviderView(provider: .codex, snapshot: store.codex, showsWeekly: showsWeekly)
        }
        .padding(10)
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: showsWeekly) { value in
            NotificationCenter.default.post(
                name: .usageMonitorWeeklyVisibilityChanged,
                object: nil,
                userInfo: ["showsWeekly": value]
            )
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 12)
    }
}

private struct ProviderView: View {
    var provider: UsageProvider
    var snapshot: UsageSnapshot?
    var showsWeekly: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProviderLogo(provider: provider)
                    .frame(width: 16, height: 16)
                    .opacity(snapshot == nil ? 0.55 : 1)
                    .help(provider.displayName)

                UsageMeter(label: "5h", window: snapshot?.fiveHour, emptyText: statusText)
            }

            if showsWeekly {
                HStack(spacing: 7) {
                    Color.clear
                        .frame(width: 16, height: 16)

                    UsageMeter(label: "7d", window: snapshot?.sevenDay, emptyText: statusText)
                }
            }
        }
    }

    private var statusText: String {
        guard let snapshot else {
            return "waiting"
        }
        let age = Date().timeIntervalSince(snapshot.updatedAt)
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
}

private struct ProviderLogo: View {
    var provider: UsageProvider

    var body: some View {
        switch provider {
        case .claude:
            ClaudeLogo()
        case .codex:
            CodexLogo()
        }
    }
}

private struct ClaudeLogo: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule()
                    .fill(Color(red: 0.82, green: 0.46, blue: 0.24))
                    .frame(width: 3.2, height: 11)
                    .offset(y: -3.3)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle()
                .fill(Color(red: 0.93, green: 0.72, blue: 0.55))
                .frame(width: 4, height: 4)
        }
        .accessibilityLabel("Claude")
    }
}

private struct CodexLogo: View {
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                    .stroke(Color(red: 0.12, green: 0.54, blue: 0.48), lineWidth: 1.7)
                    .frame(width: 8.4, height: 4.8)
                    .offset(x: 3.5)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle()
                .fill(Color(red: 0.16, green: 0.72, blue: 0.64))
                .frame(width: 3.4, height: 3.4)
        }
        .accessibilityLabel("Codex")
    }
}

private struct UsageMeter: View {
    var label: String
    var window: LimitWindow?
    var emptyText: String

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .frame(width: 20, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(color)
                            .frame(width: geometry.size.width * CGFloat((window?.usedPercent ?? 0) / 100))
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

    private var usedText: String {
        guard let used = window?.usedPercent else {
            return "--"
        }
        return "\(Int(round(used)))%"
    }

    private var resetText: String {
        if window == nil {
            return emptyText
        }
        guard let date = window?.resetsAt else {
            return "reset unknown"
        }
        return ResetFormatter.shared.string(from: date)
    }

    private var color: Color {
        guard let used = window?.usedPercent else {
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

    func string(from date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        let relative: String

        if seconds <= 0 {
            relative = "now"
        } else if seconds < 60 * 60 {
            let minutes = max(1, min(59, Int(ceil(seconds / 60))))
            relative = minutes == 1 ? "1 min" : "\(minutes) mins"
        } else {
            relative = "\(max(1, Int(seconds / (60 * 60))))h"
        }

        return "resets in \(relative) (\(clockString(from: date)))"
    }

    private func clockString(from date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
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
