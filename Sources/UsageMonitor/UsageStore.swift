import AppKit
import Combine
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var setupMessage = "Setting up Claude bridge..."
    @Published var codexRefreshError: String?
    @Published var claudeRefreshError: String?
    @Published private(set) var manualRefreshInFlight = false
    @Published private(set) var manualRefreshMessage: String?

    private let codexReader = CodexAccountReader()
    private var codexTimer: Timer?
    @Published private(set) var codexRefreshInFlight = false
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
                    self?.refreshClaude()
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
                Task { @MainActor in
                    self?.refreshCodex()
                    self?.refreshClaude()
                }
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
        claudeUsageRefresher.stop()
        observers.removeAll()
    }

    func installBridgeOnlyAndExit() {
        do {
            let result = try makeInstaller().install()
            if case .failure(let error) = ClaudeBridgeRunner.refresh(bridgePath: result.bridgePath) {
                print("Claude usage refresh: \(error.localizedDescription)")
            }
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
                let message = result.changedSettings ? "Claude bridge installed" : "Claude bridge already installed"
                Task { @MainActor [weak self] in
                    self?.claudeUsageRefresher.start(bridgePath: result.bridgePath) { [weak self] result in
                        Task { @MainActor in
                            switch result {
                            case .success: self?.claudeRefreshError = nil
                            case .failure(.deferred): break
                            case .failure(let error): self?.claudeRefreshError = error.localizedDescription
                            }
                        }
                    }
                    self?.setupMessage = message
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.setupMessage = "Claude bridge setup failed"
                }
            }
        }
    }

    func refreshClaude() {
        claudeUsageRefresher.refresh()
    }

    func refreshNow() {
        guard !manualRefreshInFlight else { return }
        manualRefreshInFlight = true
        manualRefreshMessage = nil
        refreshCodex()
        claudeUsageRefresher.refreshManually { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.manualRefreshInFlight = false
                switch result {
                case .success:
                    self.manualRefreshMessage = "Claude refreshed."
                case .failure(.rateLimited):
                    let retry = Date().addingTimeInterval(ClaudeBridgeRunner.refreshDelay(minimum: 0))
                    self.manualRefreshMessage = "Claude is rate limited. Next retry: \(retry.formatted(date: .omitted, time: .shortened))."
                case .failure(let error):
                    self.manualRefreshMessage = "Claude: \(error.localizedDescription)."
                }
            }
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
    private var bridgePath: String?
    private var onResult: (@Sendable (Result<Void, ClaudeRefreshError>) -> Void)?
    private var nextAttempt = Date.distantPast

    deinit {
        timer?.cancel()
    }

    func start(bridgePath: String, onResult: @escaping @Sendable (Result<Void, ClaudeRefreshError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.bridgePath = bridgePath
            self.onResult = onResult
            self.refreshIfDue()
        }
    }

    func refresh() {
        queue.async { [weak self] in self?.refreshIfDue() }
    }

    func refreshManually(completion: @escaping @Sendable (Result<Void, ClaudeRefreshError>) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(.failure(.launchFailed)); return }
            completion(self.refreshIfDue(manual: true))
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.bridgePath = nil
            self?.onResult = nil
        }
    }

    @discardableResult
    private func refreshIfDue(manual: Bool = false) -> Result<Void, ClaudeRefreshError> {
        guard let bridgePath else { return .failure(.launchFailed) }
        let remaining = nextAttempt.timeIntervalSinceNow
        guard manual || remaining <= 0 else {
            schedule(after: remaining)
            return .success(())
        }
        timer?.cancel()
        let result = ClaudeBridgeRunner.refresh(bridgePath: bridgePath, manual: manual)
        // The bridge owns backoff. A blocked manual click must not extend it again.
        let scheduledDelay = ClaudeBridgeRunner.refreshDelay()
        nextAttempt = Date().addingTimeInterval(scheduledDelay)
        onResult?(result)
        schedule(after: scheduledDelay)
        return result
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(1, delay), leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.refreshIfDue() }
        self.timer = timer
        timer.resume()
    }
}
