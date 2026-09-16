import Foundation
import Darwin

public enum NodeRuntime {
    public static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let manager = FileManager.default
        if let override = environment["USAGE_MONITOR_NODE_PATH"] {
            return isExecutable(override) ? URL(fileURLWithPath: override) : nil
        }
        var paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/node" }
        paths += [home.appendingPathComponent(".local/bin/node").path,
                  "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? manager.contentsOfDirectory(atPath: nvm.path)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent("\($0)/bin/node").path }
        return paths.first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }
}

public enum ClaudeRefreshError: Error, LocalizedError, Equatable, Sendable {
    case nodeUnavailable, launchFailed, timedOut, signInRequired, rateLimited, unavailable, cacheWriteFailed, deferred

    public var errorDescription: String? {
        switch self {
        case .nodeUnavailable: return "Node unavailable - check installation"
        case .launchFailed: return "Claude bridge failed to start"
        case .timedOut: return "refresh timed out - retrying"
        case .signInRequired: return "sign in to Claude Code"
        case .rateLimited: return "rate limited - cooling down"
        case .unavailable: return "Claude unavailable - retrying"
        case .cacheWriteFailed: return "cannot save Claude usage"
        case .deferred: return "refresh already running or checked within the last minute"
        }
    }
}

public enum ClaudeBridgeRunner {
    public static func refreshDelay(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usage-monitor"),
                                    now: Date = Date(), minimum: TimeInterval = 300) -> TimeInterval {
        struct Schedule: Decodable { let nextAllowedAt: Double }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("claude-refresh-state.json")),
              let state = try? JSONDecoder().decode(Schedule.self, from: data),
              state.nextAllowedAt.isFinite else { return minimum }
        return max(minimum, state.nextAllowedAt / 1000 - now.timeIntervalSince1970)
    }

    // Run only on a utility queue. No response bodies are captured or logged.
    public static func refresh(bridgePath: String, node: URL? = NodeRuntime.findExecutable(),
                               timeout: TimeInterval = 30, manual: Bool = false) -> Result<Void, ClaudeRefreshError> {
        guard let node else { return .failure(.nodeUnavailable) }
        let process = Process()
        process.executableURL = node
        process.arguments = [bridgePath, "--refresh-only"] + (manual ? ["--manual"] : [])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed)
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            return .failure(.timedOut)
        }
        guard process.terminationReason == .exit else { return .failure(.unavailable) }
        switch process.terminationStatus {
        case 0: return .success(())
        case 2: return .failure(.signInRequired)
        case 3: return .failure(.rateLimited)
        case 6: return .failure(.cacheWriteFailed)
        case 7: return .failure(.deferred)
        default: return .failure(.unavailable)
        }
    }
}
