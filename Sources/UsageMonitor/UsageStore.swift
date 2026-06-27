import Foundation
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published var codex: UsageSnapshot?
    @Published var claude: UsageSnapshot?
    @Published var setupMessage = "Setting up Claude bridge..."

    private var codexCollector: CodexUsageCollector?
    private var claudeCollector: ClaudeUsageCollector?
    private let claudeUsageRefresher = ClaudeUsageRefresher()

    func start() {
        installClaudeBridge()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexRoot = home.appendingPathComponent(".codex/sessions")
        let claudeStatus = home.appendingPathComponent(".usage-monitor/claude-status.json")

        codexCollector = CodexUsageCollector(root: codexRoot) { [weak self] snapshot in
            self?.codex = snapshot
        }
        claudeCollector = ClaudeUsageCollector(file: claudeStatus) { [weak self] snapshot in
            self?.claude = snapshot
        }

        codexCollector?.start()
        claudeCollector?.start()
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
