import AppKit
import Combine
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var setupMessage = "Setting up Claude bridge..."
    @Published var codexRefreshError: String?

    private let codexReader = CodexAccountReader()
    private var codexTimer: Timer?
    private var codexRefreshInFlight = false
    private var lastCodexAttempt = Date.distantPast
    private var codexFailures = 0
    private var isSleeping = false
    private var observers = Set<AnyCancellable>()
    private var claudeCollector: ClaudeUsageCollector?
    private let claudeUsageRefresher = ClaudeUsageRefresher()

    func start() {
        installClaudeBridge()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeStatus = home.appendingPathComponent(".usage-monitor/claude-status.json")

        claudeCollector = ClaudeUsageCollector(file: claudeStatus) { [weak self] snapshot in
            self?.claude = snapshot
        }

        startCodexMonitoring()
        claudeCollector?.start()
    }

    private func startCodexMonitoring() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isSleeping = false
                    self?.refreshCodex()
                }
            }.store(in: &observers)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isSleeping = true
                    self?.codexTimer?.invalidate()
                    self?.codexReader.cancel()
                }
            }.store(in: &observers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshCodex() }
            }.store(in: &observers)
        refreshCodex()
    }

    func refreshCodex() {
        guard !isSleeping, !codexRefreshInFlight else { return }
        let sinceLastAttempt = Date().timeIntervalSince(lastCodexAttempt)
        guard sinceLastAttempt >= 10 else {
            scheduleCodexRefresh(after: 10 - sinceLastAttempt)
            return
        }
        codexTimer?.invalidate()
        lastCodexAttempt = Date()
        codexRefreshInFlight = true
        codexReader.read { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.codexRefreshInFlight = false
                let delay: TimeInterval
                switch result {
                case .success(let snapshot):
                    // Account replies supersede saved session events after a reset.
                    self.codex = snapshot
                    self.codexRefreshError = nil
                    self.codexFailures = 0
                    delay = UsageFreshness.nextRefresh(after: snapshot, now: Date())
                case .failure(let error):
                    self.codexRefreshError = error.localizedDescription
                    self.codexFailures = min(4, self.codexFailures + 1)
                    delay = min(300, 30 * pow(2, Double(self.codexFailures)))
                }
                guard !self.isSleeping else { return }
                self.scheduleCodexRefresh(after: max(10, delay))
            }
        }
    }

    private func scheduleCodexRefresh(after delay: TimeInterval) {
        codexTimer?.invalidate()
        let timer = Timer(timeInterval: max(1, delay), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshCodex() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        codexTimer = timer
    }

    func stop() {
        isSleeping = true
        codexTimer?.invalidate()
        codexReader.cancel()
        observers.removeAll()
    }

    func installBridgeOnlyAndExit() {
        do {
            let result = try makeInstaller().install()
            Self.refreshClaudeUsage(bridgePath: result.bridgePath)
            print("Claude bridge installed at \(result.bridgePath)")
            if let backupPath = result.backupPath {
                print("Settings backup: \(backupPath)")
            }
            Foundation.exit(0)
        } catch {
            fputs("Failed to install Claude bridge: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private func installClaudeBridge() {
        let installer: ClaudeBridgeInstaller
        do {
            installer = try makeInstaller()
        } catch {
            setupMessage = "Claude bridge setup failed"
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try installer.install()
                Self.refreshClaudeUsage(bridgePath: result.bridgePath)
                let message = result.changedSettings ? "Claude bridge installed" : "Claude bridge already installed"
                Task { @MainActor [weak self] in
                    self?.claudeUsageRefresher.start(bridgePath: result.bridgePath)
                    self?.setupMessage = message
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.setupMessage = "Claude bridge setup failed"
                }
            }
        }
    }

    nonisolated private static func refreshClaudeUsage(bridgePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", bridgePath, "--refresh-only"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The collector will continue to show the last cached Claude value, if any.
        }
    }

    private func makeInstaller() throws -> ClaudeBridgeInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bridgeSource = try bridgeSourcePath()
        return ClaudeBridgeInstaller(
            settingsPath: home.appendingPathComponent(".claude/settings.json"),
            bridgeSourcePath: bridgeSource,
            installRoot: home.appendingPathComponent(".usage-monitor")
        )
    }

    private func bridgeSourcePath() throws -> URL {
        let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("claude-statusline-bridge.mjs"),
            executableDir.appendingPathComponent("../Resources/claude-statusline-bridge.mjs").standardizedFileURL,
            executableDir.appendingPathComponent("claude-statusline-bridge.mjs")
        ].compactMap { $0 }

        if let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return candidate
        }
        throw ClaudeBridgeInstallError.missingBridgeSource("claude-statusline-bridge.mjs")
    }
}

private final class ClaudeUsageRefresher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "usage-monitor.claude-oauth-refresh", qos: .utility)
    private var timer: DispatchSourceTimer?

    deinit {
        timer?.cancel()
    }

    func start(bridgePath: String) {
        queue.async {
            self.timer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
            timer.setEventHandler {
                Self.refreshClaudeUsage(bridgePath: bridgePath)
            }
            self.timer = timer
            timer.resume()
        }
    }

    private static func refreshClaudeUsage(bridgePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", bridgePath, "--refresh-only"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The collector will continue to show the last cached Claude value, if any.
        }
    }
}
