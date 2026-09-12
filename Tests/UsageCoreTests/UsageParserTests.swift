import Foundation
import Testing
@testable import UsageCore

@Test func parsesFableWeeklyWithoutConfusingOtherQuotas() throws {
    let data = """
    {"five_hour":{"utilization":4},"seven_day":{"utilization":98},"limits":[
      {"kind":"weekly_scoped","scope":{"model":{"display_name":"Sonnet"}},"percent":12},
      {"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":59,
       "resets_at":"2026-09-13T10:59:59.898898+00:00"}
    ]}
    """.data(using: .utf8)!
    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.fiveHour?.usedPercent == 4)
    #expect(snapshot.sevenDay?.usedPercent == 98)
    #expect(snapshot.fableWeekly?.usedPercent == 59)
    #expect(snapshot.fableWeekly?.remainingPercent == 41)
    #expect(snapshot.fableWeekly?.resetsAt != nil)
    #expect(snapshot.fableWeeklyUpdatedAt == snapshot.updatedAt)
}

@Test func oldClaudeCacheStillWorksWithoutFable() throws {
    let data = #"{"provider":"claude","fiveHour":{"usedPercent":4},"updatedAt":"2026-09-12T20:00:00Z"}"#.data(using: .utf8)!
    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.fiveHour?.usedPercent == 4)
    #expect(snapshot.fableWeekly == nil)
    #expect(snapshot.fableWeeklyUpdatedAt == nil)
}

@Test func normalizedFableKeepsItsOwnFreshness() throws {
    let data = """
    {"provider":"claude","fiveHour":{"usedPercent":4},"updatedAt":"2026-09-12T20:00:00Z",
     "fableWeekly":{"usedPercent":59,"resetsAt":1789297199},
     "fableWeeklyUpdatedAt":"2026-09-12T19:00:00Z"}
    """.data(using: .utf8)!
    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.fableWeekly?.usedPercent == 59)
    #expect(UsageFreshness.needsUpdate(window: snapshot.fableWeekly,
                                     updatedAt: snapshot.fableWeeklyUpdatedAt, now: snapshot.updatedAt))
    #expect(!UsageFreshness.needsUpdate(window: snapshot.fiveHour,
                                      updatedAt: snapshot.updatedAt, now: snapshot.updatedAt))
}

@Test func fableZeroIsValidButMissingPercentageIsNot() throws {
    let data = #"{"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":0}]}"#.data(using: .utf8)!
    #expect(ClaudeStatusLineParser.parseData(data)?.fableWeekly?.usedPercent == 0)
    let missing = #"{"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Fable"}},"percent":null}]}"#.data(using: .utf8)!
    #expect(ClaudeStatusLineParser.parseData(missing) == nil)
}

@Test func parsesCodexTokenCountLine() throws {
    let line = """
    {"timestamp":"2026-06-27T10:44:40.227Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":130000},"last_token_usage":{"total_tokens":42},"model_context_window":260000},"rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1782564969},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1783151769},"plan_type":"prolite"}}}
    """

    let snapshot = try #require(CodexTokenCountParser.parseLine(line))
    #expect(snapshot.provider == .codex)
    #expect(snapshot.fiveHour?.usedPercent == 5)
    #expect(snapshot.fiveHour?.remainingPercent == 95)
    #expect(snapshot.sevenDay?.remainingPercent == 99)
    #expect(snapshot.context?.tokens == 130000)
    #expect(snapshot.context?.usedPercent == 50)
}

@Test func ignoresMalformedAndPartialCodexLines() {
    #expect(CodexTokenCountParser.parseLine("{\"type\":\"event_msg\"") == nil)
    #expect(CodexTokenCountParser.parseLine("{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"}}") == nil)
}

@Test func classifiesCodexRateLimitsByWindowDuration() throws {
    let line = """
    {"timestamp":"2026-07-13T11:09:13.649Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1784544840},"secondary":null,"plan_type":"prolite"}}}
    """

    let snapshot = try #require(CodexTokenCountParser.parseLine(line))
    #expect(snapshot.fiveHour == nil)
    #expect(snapshot.sevenDay?.usedPercent == 1)
    #expect(snapshot.sevenDay?.resetsAt?.timeIntervalSince1970 == 1_784_544_840)
}

@Test func classifiesReorderedCodexRateLimitsByWindowDuration() throws {
    let line = """
    {"timestamp":"2026-07-13T11:09:13.649Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1784544840},"secondary":{"used_percent":31.0,"window_minutes":300,"resets_at":1783952399},"plan_type":"prolite"}}}
    """

    let snapshot = try #require(CodexTokenCountParser.parseLine(line))
    #expect(snapshot.fiveHour?.usedPercent == 31)
    #expect(snapshot.sevenDay?.usedPercent == 8)
}

@Test func parsesClaudeStatusLineInput() throws {
    let data = """
    {
      "context_window": {
        "total_input_tokens": 1000,
        "total_output_tokens": 250,
        "used_percentage": 12.5,
        "remaining_percentage": 87.5
      },
      "rate_limits": {
        "five_hour": { "used_percentage": 40, "resets_at": 1782564969 },
        "seven_day": { "used_percentage": 12, "resets_at": 1783151769 }
      }
    }
    """.data(using: .utf8)!

    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.fiveHour?.remainingPercent == 60)
    #expect(snapshot.sevenDay?.usedPercent == 12)
    #expect(snapshot.context?.tokens == 1250)
    #expect(snapshot.context?.remainingPercent == 87.5)
}

@Test func parsesClaudeBridgeOutput() throws {
    let data = """
    {
      "provider": "claude",
      "fiveHour": { "usedPercent": 40, "remainingPercent": 60, "resetsAt": 1782564969 },
      "sevenDay": { "usedPercent": 12, "remainingPercent": 88, "resetsAt": 1783151769 },
      "context": { "usedPercent": 12.5, "remainingPercent": 87.5, "tokens": 1250 },
      "updatedAt": "2026-06-27T12:00:00Z",
      "source": "claude-statusline"
    }
    """.data(using: .utf8)!

    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.fiveHour?.remainingPercent == 60)
    #expect(snapshot.context?.tokens == 1250)
}

@Test func treatsZeroResetTimestampsAsUnknown() throws {
    let data = """
    {
      "provider": "claude",
      "fiveHour": { "usedPercent": 0, "remainingPercent": 100, "resetsAt": 0 },
      "sevenDay": { "usedPercent": 12, "remainingPercent": 88, "resetsAt": 1783151769 },
      "updatedAt": "2026-06-27T12:00:00Z",
      "source": "claude-statusline"
    }
    """.data(using: .utf8)!

    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.fiveHour?.resetsAt == nil)
    #expect(snapshot.fiveHour?.usedPercent == 0)
    #expect(snapshot.sevenDay?.resetsAt != nil)
}

@Test func parsesClaudeOAuthUsageAsRemainingPercent() throws {
    let data = """
    {
      "five_hour": {
        "utilization": 53,
        "resets_at": "2026-06-27T14:00:00.000000+00:00"
      },
      "seven_day": {
        "utilization": 27,
        "resets_at": "2026-06-28T12:00:00.000000+00:00"
      },
      "seven_day_sonnet": {
        "utilization": 0,
        "resets_at": "2026-06-28T12:00:00.000000+00:00"
      }
    }
    """.data(using: .utf8)!

    let snapshot = try #require(ClaudeStatusLineParser.parseData(data))
    #expect(snapshot.provider == .claude)
    #expect(snapshot.fiveHour?.usedPercent == 53)
    #expect(snapshot.fiveHour?.remainingPercent == 47)
    #expect(snapshot.sevenDay?.usedPercent == 27)
    #expect(snapshot.sevenDay?.remainingPercent == 73)
    #expect(snapshot.fiveHour?.resetsAt != nil)
}
