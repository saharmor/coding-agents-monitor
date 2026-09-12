import Foundation
import Testing
@testable import UsageCore

@Test func accountParserUsesMainBucketAndActualDuration() throws {
    let fetchedAt = Date(timeIntervalSince1970: 1_789_234_000)
    let json = """
    {"rateLimits":{"primary":{"usedPercent":68,"windowDurationMins":10080}},
     "rateLimitsByLimitId":{
       "codex_bengalfox":{"primary":{"usedPercent":99,"windowDurationMins":300}},
       "codex":{"primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1789839438},"secondary":null}}}
    """
    let snapshot = try #require(CodexAccountParser.parseResult(Data(json.utf8), fetchedAt: fetchedAt))
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.sevenDay?.usedPercent == 2)
    #expect(snapshot.sevenDay?.resetsAt == Date(timeIntervalSince1970: 1_789_839_438))
    #expect(snapshot.updatedAt == fetchedAt)
    #expect(snapshot.source == .codexAccount)
}

@Test func accountParserDoesNotSubstituteAnotherBucketOrInventZero() {
    let fixtures = [
        "{}",
        "{\"rateLimitsByLimitId\":{\"codex_bengalfox\":{\"primary\":{\"usedPercent\":0,\"windowDurationMins\":300}}}}",
        "{\"rateLimits\":{\"primary\":{\"windowDurationMins\":300}}}",
        "{\"rateLimits\":{\"primary\":{\"usedPercent\":7,\"windowDurationMins\":15}}}"
    ]
    for json in fixtures { #expect(CodexAccountParser.parseResult(Data(json.utf8)) == nil) }
}

@Test func accountParserSupportsLegacyAndReorderedWindows() throws {
    let json = """
    {"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":10080},
                   "secondary":{"usedPercent":0,"windowDurationMins":300}}}
    """
    let snapshot = try #require(CodexAccountParser.parseResult(Data(json.utf8)))
    #expect(snapshot.fiveHour?.usedPercent == 0)
    #expect(snapshot.sevenDay?.usedPercent == 20)
}

@Test func staleDataExpiresEvenWhenOldResetIsInFuture() {
    let now = Date()
    let old = LimitWindow(usedPercent: 68, remainingPercent: 32, resetsAt: now.addingTimeInterval(53 * 3600))
    #expect(UsageFreshness.needsUpdate(window: old, updatedAt: now.addingTimeInterval(-86_400), now: now))
    #expect(UsageFreshness.needsUpdate(window: old, updatedAt: now.addingTimeInterval(-120), now: now))
    #expect(!UsageFreshness.needsUpdate(window: old, updatedAt: now.addingTimeInterval(-60), now: now))
    var reset = old
    reset.resetsAt = now
    #expect(UsageFreshness.needsUpdate(window: reset, updatedAt: now, now: now))
}

@Test func refreshIsScheduledAtKnownReset() {
    let now = Date()
    let snapshot = UsageSnapshot(provider: .codex,
        fiveHour: LimitWindow(usedPercent: 50, remainingPercent: 50, resetsAt: now.addingTimeInterval(20)),
        sevenDay: nil, context: nil, updatedAt: now, source: .codexAccount)
    #expect(UsageFreshness.nextRefresh(after: snapshot, now: now) == 21)
    #expect(UsageFreshness.nextRefresh(after: snapshot, now: now.addingTimeInterval(-120)) == 60)
}

private func fixtureReader(_ mode: String, timeout: TimeInterval = 2) -> CodexAccountReader {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/account-server.sh")
    return CodexAccountReader(executable: URL(fileURLWithPath: "/bin/sh"),
                              arguments: [script.path, mode], timeout: timeout)
}

@Test func accountReaderHandlesPartialRepliesAndIgnoresCachedNotifications() async throws {
    let reader = fixtureReader("success")
    for _ in 0..<2 {
        let result = await withCheckedContinuation { continuation in
            reader.read { continuation.resume(returning: $0) }
        }
        let snapshot = try result.get()
        #expect(snapshot.sevenDay?.usedPercent == 2)
        #expect(snapshot.fiveHour == nil)
        #expect(Date().timeIntervalSince(snapshot.updatedAt) < 2)
    }
}

@Test(arguments: ["error", "invalid", "exit", "timeout"])
func accountReaderCompletesOnFailures(_ mode: String) async {
    let reader = fixtureReader(mode, timeout: 0.5)
    let start = Date()
    let result = await withCheckedContinuation { continuation in
        reader.read { continuation.resume(returning: $0) }
    }
    if case .success = result { Issue.record("Expected failure for \(mode)") }
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func accountReaderCancellationCompletes() async {
    let reader = fixtureReader("timeout")
    let result = await withCheckedContinuation { continuation in
        reader.read { continuation.resume(returning: $0) }
        reader.cancel()
    }
    if case .failure(.cancelled) = result { } else { Issue.record("Expected cancellation") }
}
