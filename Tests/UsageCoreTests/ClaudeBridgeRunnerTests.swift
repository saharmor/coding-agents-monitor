import Foundation
import Testing
@testable import UsageCore

@Test func claudeTimerHonorsPersistedServerCooldownWithoutTruncation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_000_000)
    #expect(ClaudeBridgeRunner.refreshDelay(root: root, now: now) == 300)
    let file = root.appendingPathComponent("claude-refresh-state.json")
    try JSONSerialization.data(withJSONObject: ["nextAllowedAt": (now.timeIntervalSince1970 + 3600) * 1000]).write(to: file)
    #expect(ClaudeBridgeRunner.refreshDelay(root: root, now: now) == 3600)
    #expect(ClaudeBridgeRunner.refreshDelay(root: root, now: now.addingTimeInterval(4000)) == 300)
    try Data("null".utf8).write(to: file)
    #expect(ClaudeBridgeRunner.refreshDelay(root: root, now: now) == 300)
}

@Test func nodeDiscoveryWorksWithFinderPathAndNvmOnly() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    for version in ["v9.0.0", "v22.19.0"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                                                withIntermediateDirectories: true)
    }
    let expected = home.appendingPathComponent(".nvm/versions/node/v22.19.0/bin/node")
    let found = NodeRuntime.findExecutable(environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], home: home,
                                          isExecutable: { $0.hasPrefix(home.appendingPathComponent(".nvm/versions/node").path) && $0.hasSuffix("/bin/node") })
    #expect(found == expected)
}

@Test func nodeDiscoveryHonorsPathAndExplicitOverride() {
    let environment = ["PATH": "/custom/bin:/usr/bin", "USAGE_MONITOR_NODE_PATH": "/selected/node"]
    #expect(NodeRuntime.findExecutable(environment: environment, isExecutable: { $0 == "/selected/node" })?.path == "/selected/node")
    #expect(NodeRuntime.findExecutable(environment: environment, isExecutable: { $0 == "/custom/bin/node" }) == nil)
    #expect(NodeRuntime.findExecutable(environment: ["PATH": "/custom/bin"], isExecutable: { $0 == "/custom/bin/node" })?.path == "/custom/bin/node")
}

@Test(arguments: [0, 2, 3, 5, 6, 7, 127])
func bridgeRunnerReportsFailuresInsteadOfSilentSuccess(_ status: Int) throws {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-test-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: script) }
    try Data("exit \(status)\n".utf8).write(to: script)
    let result = ClaudeBridgeRunner.refresh(bridgePath: script.path, node: URL(fileURLWithPath: "/bin/sh"), timeout: 2)
    if status == 0 {
        try result.get()
    } else {
        let expected: ClaudeRefreshError = [2: .signInRequired, 3: .rateLimited, 6: .cacheWriteFailed, 7: .deferred][status] ?? .unavailable
        guard case .failure(let error) = result else { Issue.record("Failed process was reported as successful"); return }
        #expect(error == expected)
    }
}

@Test func manualRefreshPassesExplicitFlagToBridge() throws {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-manual-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: script) }
    try Data("[ \"$1\" = \"--refresh-only\" ] && [ \"$2\" = \"--manual\" ]\n".utf8).write(to: script)
    try ClaudeBridgeRunner.refresh(bridgePath: script.path, node: URL(fileURLWithPath: "/bin/sh"), manual: true).get()
}

@Test func bridgeRunnerBoundsHungProcessesAndHandlesMissingNode() throws {
    let script = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-timeout-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: script) }
    try Data("exec /bin/sleep 10\n".utf8).write(to: script)
    let started = Date()
    let result = ClaudeBridgeRunner.refresh(bridgePath: script.path, node: URL(fileURLWithPath: "/bin/sh"), timeout: 0.1)
    guard case .failure(let error) = result else { Issue.record("Hung process succeeded"); return }
    #expect(error == .timedOut)
    #expect(Date().timeIntervalSince(started) < 3)
    guard case .failure(let missing) = ClaudeBridgeRunner.refresh(bridgePath: script.path, node: nil) else {
        Issue.record("Missing Node succeeded"); return
    }
    #expect(missing == .nodeUnavailable)
}
