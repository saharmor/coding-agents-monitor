import Foundation
import Darwin

public enum CodexAccountError: Error, LocalizedError, Sendable {
    case unavailable, requestFailed, invalidResponse, timedOut, cancelled, busy

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex CLI unavailable"
        case .requestFailed: return "Could not refresh Codex; check connection and Codex login"
        case .invalidResponse: return "Codex did not report account limits"
        case .timedOut: return "Codex refresh timed out"
        case .cancelled: return "Codex refresh cancelled"
        case .busy: return "Codex refresh already running"
        }
    }
}

// A short-lived, quota-only RPC connection. No threads, turns, or token reads.
public final class CodexAccountReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "usage-monitor.codex-account", qos: .utility)
    private let executable: URL?
    private let arguments: [String]
    private let timeout: TimeInterval
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var timer: DispatchSourceTimer?
    private var buffer = Data()
    private var receivedBytes = 0
    private var requestID = UUID()
    private var initialized = false
    private var completion: (@Sendable (Result<UsageSnapshot, CodexAccountError>) -> Void)?

    public init(executable: URL? = CodexAccountReader.findExecutable(),
                arguments: [String] = ["app-server"], timeout: TimeInterval = 15) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    public func read(completion: @escaping @Sendable (Result<UsageSnapshot, CodexAccountError>) -> Void) {
        queue.async { [weak self] in self?.start(completion: completion) }
    }

    public func cancel() {
        queue.async { [weak self] in self?.finish(.failure(.cancelled)) }
    }

    private func start(completion: @escaping @Sendable (Result<UsageSnapshot, CodexAccountError>) -> Void) {
        guard self.completion == nil else { completion(.failure(.busy)); return }
        guard let executable else { completion(.failure(.unavailable)); return }
        self.completion = completion
        requestID = UUID()
        let id = requestID
        initialized = false
        buffer.removeAll(keepingCapacity: false)
        receivedBytes = 0
        let task = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        input = stdin
        output = stdout
        process = task
        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        // nvm's Codex launcher needs Node even when launched by Finder/login.
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin")
        task.environment = environment
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.requestID == id, self.completion != nil else { return }
                self.consume(chunk)
            }
        }
        // EOF is handled on stdout so a final response is drained before failure.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.requestID == id else { return }
            self.finish(.failure(.timedOut))
        }
        self.timer = timer
        timer.resume()
        do {
            try task.run()
            try send(["id": 0, "method": "initialize", "params": [
                "clientInfo": ["name": "coding_agents_monitor", "title": "Coding Agents Monitor", "version": "1.0"]
            ]])
        } catch {
            finish(.failure(.requestFailed))
        }
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        try input?.fileHandleForWriting.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { finish(.failure(.requestFailed)); return }
        receivedBytes += data.count
        guard receivedBytes <= 1_048_576 else { finish(.failure(.invalidResponse)); return }
        buffer.append(data)
        while completion != nil, let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = UsageJSON.object(from: line) else { continue }
            // Match replies, never cached rate-limit notifications from initialization.
            guard let id = message.int("id"), id == 0 || id == 1 else { continue }
            if message["error"] != nil { finish(.failure(.requestFailed)); return }
            do {
                if id == 0 && !initialized && message["result"] != nil {
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 1, "method": "account/rateLimits/read"])
                } else if id == 1 && initialized {
                    guard let result = message.dictionary("result"),
                          let snapshot = CodexAccountParser.parseResult(try JSONSerialization.data(withJSONObject: result))
                    else { finish(.failure(.invalidResponse)); return }
                    finish(.success(snapshot))
                }
            } catch {
                finish(.failure(.requestFailed))
            }
        }
    }

    private func finish(_ result: Result<UsageSnapshot, CodexAccountError>) {
        guard let callback = completion else { return }
        completion = nil
        timer?.cancel()
        timer = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        try? output?.fileHandleForReading.close()
        input = nil
        output = nil
        buffer.removeAll(keepingCapacity: false)
        if let task = process { Self.stop(task) }
        process = nil
        callback(result)
    }

    private static func stop(_ task: Process) {
        guard task.isRunning else { return }
        task.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }

    deinit {
        timer?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let process { Self.stop(process) }
    }

    public static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        if let override = env["USAGE_MONITOR_CODEX_PATH"] {
            return FileManager.default.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        var paths = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        paths += [home.appendingPathComponent(".local/bin/codex").path,
                  "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []
        paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent("\($0)/bin/codex").path }
        paths += ["/Applications/Codex.app/Contents/Resources/codex",
                  home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }
}
