import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

final class ClaudeUsageParseTests: XCTestCase {
    func testParsesWindows() throws {
        let json = #"{"five_hour":{"utilization":28,"resets_at":"2026-09-07T10:14:00.000Z"},"seven_day":{"utilization":39.5,"resets_at":"2026-09-10T00:00:00Z"},"seven_day_opus":{"utilization":61.2,"resets_at":null}}"#
        let usage = try ClaudeUsage.parse(Data(json.utf8))
        XCTAssertEqual(usage.fiveHour?.utilizationPct, 28)
        XCTAssertEqual(usage.fiveHour?.remainingPct, 72)
        XCTAssertEqual(usage.fiveHour?.resetsAt, DateParsing.iso8601("2026-09-07T10:14:00.000Z"))
        XCTAssertEqual(usage.sevenDay?.resetsAt, DateParsing.iso8601("2026-09-10T00:00:00Z"))
        XCTAssertEqual(usage.weekly(for: "claude-opus")?.utilizationPct, 61.2)
        XCTAssertEqual(usage.weekly(for: "claude-sonnet")?.utilizationPct, 39.5)
        XCTAssertNil(usage.sevenDayOpus?.resetsAt)
    }

    func testRejectsUnknownShape() {
        XCTAssertThrowsError(try ClaudeUsage.parse(Data(#"{"foo":1}"#.utf8)))
    }
}

final class ClaudeTranscriptTests: XCTestCase {
    static let user = #"{"parentUuid":null,"isSidechain":false,"cwd":"/Users/me/proj","sessionId":"s-1","type":"user","message":{"role":"user","content":"fix auth bug in middleware\nmore details"},"uuid":"u1","timestamp":"2026-09-07T05:41:44.123Z"}"#
    static let assistant = #"{"cwd":"/Users/me/proj","sessionId":"s-1","type":"assistant","message":{"id":"msg_1","role":"assistant","model":"claude-opus-4-5-20251101","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":5000,"output_tokens":80}},"timestamp":"2026-09-07T05:42:10.000Z","entrypoint":"claude-desktop"}"#
    static let haiku = #"{"sessionId":"s-1","type":"assistant","message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":5,"output_tokens":7}},"timestamp":"2026-09-07T05:43:00Z"}"#
    static let summary = #"{"type":"summary","summary":"Auth fix","leafUuid":"x"}"#

    func testParsesUserAndAssistantLines() throws {
        let events = ClaudeTranscriptParser.parse([Self.user, Self.assistant, Self.summary, "garbage"].joined(separator: "\n"))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].role, .user)
        XCTAssertEqual(events[0].text, "fix auth bug in middleware\nmore details")
        XCTAssertEqual(events[0].cwd, "/Users/me/proj")
        XCTAssertEqual(events[1].role, .assistant)
        XCTAssertEqual(events[1].model, "claude-opus-4-5-20251101")
        XCTAssertEqual(events[1].tokensIn, 312)
        XCTAssertEqual(events[1].cacheReadTokens, 5000)
        XCTAssertEqual(events[1].outputTokens, 80)
        XCTAssertTrue(events[1].hasUsage)
        XCTAssertFalse(events[0].hasUsage)
        XCTAssertEqual(events[1].entrypoint, "claude-desktop")
        XCTAssertNil(events[0].entrypoint, "lines from builds without the field stay unlabelled")
    }

    func testReadsThinkingCompactionsAndTurnStarts() throws {
        let prompt = #"{"isSidechain":false,"sessionId":"s-c","type":"user","message":{"role":"user","content":"refactor the parser"},"timestamp":"2026-09-07T06:00:00.000Z"}"#
        let answer = #"{"isSidechain":false,"sessionId":"s-c","type":"assistant","message":{"id":"msg_c1","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"cache_creation_input_tokens":500,"cache_read_input_tokens":9000,"output_tokens":400,"output_tokens_details":{"thinking_tokens":150}}},"timestamp":"2026-09-07T06:00:30.000Z"}"#
        let boundary = #"{"parentUuid":null,"logicalParentUuid":"x","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","level":"info","compactMetadata":{"trigger":"auto","preTokens":999580},"timestamp":"2026-09-07T06:05:00.000Z","sessionId":"s-c"}"#
        let summary = #"{"isSidechain":false,"sessionId":"s-c","type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation."},"isCompactSummary":true,"isVisibleInTranscriptOnly":true,"timestamp":"2026-09-07T06:05:01.000Z"}"#
        let interrupted = #"{"isSidechain":false,"sessionId":"s-c","type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"timestamp":"2026-09-07T06:06:00.000Z"}"#
        let lines = [prompt, answer, boundary, summary, interrupted].joined(separator: "\n") + "\n"
        let fast = FastTranscriptParser.parse(Data(lines.utf8)), slow = ClaudeTranscriptParser.parse(lines)
        XCTAssertEqual(fast.map(\.isPrompt), [true, false, false, false, true], "a compaction's summary is not typed input")
        XCTAssertEqual(fast.map(\.isPrompt), slow.map(\.isPrompt))
        XCTAssertEqual(fast.map(\.isCompaction), [false, false, true, false, false])
        XCTAssertEqual(fast.map(\.isCompaction), slow.map(\.isCompaction))
        XCTAssertEqual([fast[1].thinkingTokens, slow[1].thinkingTokens], [150, 150])
        var accumulator = TranscriptAccumulator(path: "/p/s-c.jsonl", isSubagent: false)
        let events = accumulator.ingest(fast)
        XCTAssertEqual(events.map(\.cacheWriteTokens), [500])
        XCTAssertEqual(events.map(\.reasoningTokens), [150])
        XCTAssertEqual(accumulator.drainMarks(), [.init(.prompt, at: fast[0].timestamp), .init(.compaction, at: fast[2].timestamp)],
                       "an interruption ends a turn without starting one")
        XCTAssertEqual(accumulator.drainMarks(), [], "marks are handed over once")
        var subagent = TranscriptAccumulator(path: "/p/s-c/subagents/agent-a.jsonl", isSubagent: true)
        subagent.ingest(fast)
        XCTAssertEqual(subagent.drainMarks(), [], "a sub-agent's prompts are steps of its parent's turn")
    }

    func testALocalCommandAfterAnAnswerStartsNoTurn() throws {
        let prompt = #"{"isSidechain":false,"sessionId":"s-l","type":"user","message":{"role":"user","content":"Reply with one word"},"timestamp":"2026-09-21T17:58:27.231Z"}"#
        let answer = #"{"isSidechain":false,"sessionId":"s-l","type":"assistant","message":{"id":"msg_l","role":"assistant","model":"claude-haiku-4-5","content":[{"type":"text","text":"LOCAL"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"2026-09-21T17:58:28.170Z"}"#
        let caveat = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"},"isMeta":true,"timestamp":"2026-09-21T17:58:48.844Z","sessionId":"s-l"}"#
        let command = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/exit</command-name>\n            <command-message>exit</command-message>\n            <command-args></command-args>"},"timestamp":"2026-09-21T17:58:48.844Z","sessionId":"s-l"}"#
        let output = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Bye!</local-command-stdout>"},"timestamp":"2026-09-21T17:58:48.844Z","sessionId":"s-l"}"#
        let skill = #"{"isSidechain":false,"type":"user","message":{"role":"user","content":"<command-message>grilling</command-message>\n<command-name>/grilling</command-name>\n<command-args>the plan</command-args>"},"origin":{"kind":"human"},"timestamp":"2026-09-21T18:00:00.000Z","sessionId":"s-l"}"#
        let lines = [prompt, answer, caveat, command, output, skill].joined(separator: "\n") + "\n"
        let fast = FastTranscriptParser.parse(Data(lines.utf8)), slow = ClaudeTranscriptParser.parse(lines)
        XCTAssertEqual(fast.map(\.isPrompt), [true, false, false, false, false, true],
                       "a command the client runs itself is not input to the model; one that expands into a prompt is")
        XCTAssertEqual(fast.map(\.isPrompt), slow.map(\.isPrompt))
        var accumulator = TranscriptAccumulator(path: "/p/s-l.jsonl", isSubagent: false)
        accumulator.ingest(Array(fast.prefix(5)))
        XCTAssertEqual(accumulator.build()?.turn?.state, .completed, "/exit after the answer leaves the session waiting, not running")
        XCTAssertEqual(accumulator.drainMarks(), [.init(.prompt, at: fast[0].timestamp)])
    }

    func testTitleRules() {
        XCTAssertEqual(SessionTitle.from("  fix auth bug\nmore"), "fix auth bug")
        XCTAssertNil(SessionTitle.from("<command-name>/clear</command-name>"))
        XCTAssertNil(SessionTitle.from("   "))
        XCTAssertEqual(SessionTitle.from(String(repeating: "a", count: 80))?.count, 60)
        XCTAssertEqual(SessionTitle.named("\n <Draft> plan \nmore"), "<Draft> plan", "a given title keeps what a prompt title skips")
        XCTAssertNil(SessionTitle.named(" \n "))
    }

    func testFastParserMatchesJSONParserOnRealShapes() throws {
        let nestedUsage = #"{"cwd":"/Users/me/proj","sessionId":"s-9","type":"assistant","requestId":"req_9","message":{"id":"msg_9","role":"assistant","model":"claude-fable-5-1","content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"path":"a}b{"}}],"usage":{"input_tokens":3,"cache_creation_input_tokens":11,"cache_read_input_tokens":2000,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":11},"service_tier":"standard"}},"timestamp":"2026-09-07T05:50:00.000Z"}"#
        let toolResult = #"{"sessionId":"s-9","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"huge \"quoted\" output {\"usage\":{\"fake\":1}}"}]},"timestamp":"2026-09-07T05:50:01.000Z"}"#
        let escapedUser = #"{"sessionId":"s-9","cwd":"/Users/me/中文 dir","type":"user","message":{"role":"user","content":"修复 \"auth\" bug\nline two"},"timestamp":"2026-09-07T05:49:00.000Z"}"#
        let lines = [Self.user, Self.assistant, Self.haiku, nestedUsage, toolResult, escapedUser, Self.summary, "garbage"].joined(separator: "\n") + "\n"

        let fast = FastTranscriptParser.parse(Data(lines.utf8))
        let slow = ClaudeTranscriptParser.parse(lines)
        XCTAssertEqual(fast.count, 6)
        XCTAssertEqual(fast.count, slow.count, "the summary line has no timestamp, so both parsers skip it")
        let fastWithUsage = fast.filter(\.hasUsage)
        let slowWithUsage = slow.filter(\.hasUsage)
        XCTAssertEqual(fastWithUsage.map(\.tokensIn), slowWithUsage.map(\.tokensIn))
        XCTAssertEqual(fastWithUsage.map(\.outputTokens), slowWithUsage.map(\.outputTokens))
        XCTAssertEqual(fastWithUsage.map(\.model), slowWithUsage.map(\.model))
        XCTAssertEqual(fastWithUsage.map(\.usageKey), slowWithUsage.map(\.usageKey))
        XCTAssertEqual(fast.map(\.stopReason), slow.map(\.stopReason))
        XCTAssertEqual(fast.map(\.isSidechain), slow.map(\.isSidechain))
        XCTAssertEqual(fast.map(\.isPrompt), slow.map(\.isPrompt))
        XCTAssertEqual(fast.map(\.entrypoint), slow.map(\.entrypoint))
        XCTAssertEqual(fast.map(\.isPrompt), [true, false, false, false, false, true], "typed prompts start turns; tool results do not")
        let nested = try XCTUnwrap(fast.first { $0.requestId == "req_9" })
        XCTAssertEqual(nested.tokensIn, 14)
        XCTAssertEqual(nested.messageId, "msg_9")
        let result = try XCTUnwrap(fast.first { $0.timestamp == DateParsing.iso8601("2026-09-07T05:50:01.000Z") })
        XCTAssertEqual(result.role, .user)
        XCTAssertNil(result.text, "tool results never become session titles")
        XCTAssertFalse(result.hasUsage, "usage text inside a tool result is not counted")
        let escaped = try XCTUnwrap(fast.first { $0.timestamp == DateParsing.iso8601("2026-09-07T05:49:00.000Z") })
        XCTAssertEqual(escaped.text, "修复 \"auth\" bug\nline two")
        XCTAssertEqual(escaped.cwd, "/Users/me/中文 dir")
        XCTAssertEqual(fast.first?.text, "fix auth bug in middleware\nmore details")
    }

    func testFastParserReadsRoleAndStopReasonWrittenAfterLongContent() throws {
        // Current Claude Code builds write `type`, `cwd` and `sessionId` after the message, which can exceed the prefix.
        let body = String(repeating: "x", count: 5000)
        let assistant = #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-fable-5-1","id":"msg_long","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Write","input":{"content":"\#(body)","role":"user"}}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":9}},"requestId":"req_long","type":"assistant","uuid":"u1","timestamp":"2026-09-07T05:50:00.000Z","cwd":"/p","sessionId":"s-long"}"#
        let meta = #"{"parentUuid":"u1","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>\#(body)</local-command-stdout>"},"isMeta":true,"uuid":"u2","timestamp":"2026-09-07T05:50:01.000Z","cwd":"/p","sessionId":"s-long"}"#
        let done = #"{"parentUuid":"u2","isSidechain":false,"message":{"model":"claude-fable-5-1","id":"msg_done","type":"message","role":"assistant","content":[{"type":"text","text":"\#(body)"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":4}},"requestId":"req_done","type":"assistant","uuid":"u3","timestamp":"2026-09-07T05:50:02.000Z","cwd":"/p","sessionId":"s-long","entrypoint":"cli"}"#
        let lines = [assistant, meta, done].joined(separator: "\n") + "\n"
        let fast = FastTranscriptParser.parse(Data(lines.utf8))
        let slow = ClaudeTranscriptParser.parse(lines)
        XCTAssertEqual(fast.map(\.role), [.assistant, .user, .assistant])
        XCTAssertEqual(fast.map(\.role), slow.map(\.role))
        XCTAssertEqual(fast.map(\.outputTokens), [9, 0, 4])
        XCTAssertEqual(fast.map(\.stopReason), ["tool_use", nil, "end_turn"])
        XCTAssertEqual(fast.map(\.isPrompt), [false, false, false], "command output is not a prompt even when flagged after its content")
        XCTAssertEqual(fast.map(\.messageId), ["msg_long", nil, "msg_done"])
        XCTAssertEqual(fast.map(\.entrypoint), [nil, nil, "cli"], "entrypoint follows the content, so it is read from the tail")
        XCTAssertEqual(fast.map(\.sessionId), ["s-long", "s-long", "s-long"], "so is the session")
        XCTAssertEqual(fast.map(\.sessionId), slow.map(\.sessionId))
        XCTAssertEqual(fast.map(\.entrypoint), slow.map(\.entrypoint))
        XCTAssertEqual(fast.map(\.stopReason), slow.map(\.stopReason))
        XCTAssertEqual(fast.map(\.isPrompt), slow.map(\.isPrompt))
        XCTAssertEqual(fast.map(\.model), slow.map(\.model))
    }

    func testTurnStateEndsSessionsAtEndTurnOrInterruptionAndKeepsTheQuietLogFallback() throws {
        let base = DateParsing.iso8601("2026-09-07T06:00:00Z")!
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func user(_ text: String, at: TimeInterval) -> String {
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u","timestamp":"\#(iso.format(base.addingTimeInterval(at)))","sessionId":"s-turn"}"#
        }
        func assistant(_ stop: String, id: String, at: TimeInterval) -> String {
            #"{"parentUuid":"u","isSidechain":false,"message":{"model":"claude-fable-5-1","id":"\#(id)","type":"message","role":"assistant","content":[{"type":"text","text":"…"}],"stop_reason":\#(stop),"usage":{"input_tokens":1,"output_tokens":1}},"type":"assistant","uuid":"a","timestamp":"\#(iso.format(base.addingTimeInterval(at)))","sessionId":"s-turn"}"#
        }
        var accumulator = TranscriptAccumulator(path: "/x/s-turn.jsonl", isSubagent: false)
        func live(after lines: [String], at: TimeInterval) -> Bool {
            accumulator.ingest(FastTranscriptParser.parse(Data((lines.joined(separator: "\n") + "\n").utf8)))
            return accumulator.build()!.isLive(now: base.addingTimeInterval(at), threshold: 120)
        }
        XCTAssertTrue(live(after: [user("build it", at: 0), assistant("\"tool_use\"", id: "msg_1", at: 5)], at: 60), "a tool call keeps the turn running")
        XCTAssertTrue(live(after: [], at: 200), "a quiet log does not end a running turn: one tool call can take minutes")
        XCTAssertFalse(live(after: [], at: 5 + UsageRefresh.abandonedTurnTimeout + 1), "a turn quiet this long was abandoned")
        XCTAssertFalse(live(after: [assistant("\"end_turn\"", id: "msg_2", at: 300)], at: 301), "end_turn ends the session at once, not two minutes later")
        XCTAssertTrue(live(after: [user("and the tests", at: 400)], at: 401), "the next prompt restarts it")
        XCTAssertFalse(live(after: [assistant("\"tool_use\"", id: "msg_3", at: 405), user("[Request interrupted by user for tool use]", at: 410)], at: 411), "an interruption ends the turn without a completion")
        XCTAssertEqual(accumulator.build()?.completions.map(\.id), [RecordCoding.hash(["Claude", "s-turn", "msg_2"])])
        var legacy = TranscriptAccumulator(path: "/old/s-turn.jsonl", isSubagent: false)
        legacy.ingest(FastTranscriptParser.parse(Data((assistant("null", id: "msg_9", at: 0) + "\n").utf8)))
        XCTAssertTrue(legacy.build()!.isLive(now: base.addingTimeInterval(60), threshold: 120), "a build without stop reasons keeps the freshness rule")
        XCTAssertFalse(legacy.build()!.isLive(now: base.addingTimeInterval(600), threshold: 120))
    }

    func testStorePersistsAccumulatorsAcrossInstances() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-cache-\(UUID().uuidString)", isDirectory: true)
        let projects = base.appendingPathComponent("projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let file = projects.appendingPathComponent("s-1.jsonl")
        try (Self.user + "\n" + Self.assistant + "\n").write(to: file, atomically: true, encoding: .utf8)
        let ledgerURL = base.appendingPathComponent("usage-ledger.sqlite")

        let first = ClaudeTranscriptStore(roots: [projects.deletingLastPathComponent()], ledger: try UsageLedger(url: ledgerURL))
        let sessions = await first.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(sessions.first?.tokensOut, 80)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))

        // A second instance answers from the ledger without re-reading unchanged files.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let reopened = try UsageLedger(url: ledgerURL)
        let second = ClaudeTranscriptStore(roots: [projects.deletingLastPathComponent()], ledger: reopened)
        let cached = await second.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(cached.first?.tokensOut, 80)
        XCTAssertEqual(cached.first?.task, "fix auth bug in middleware")
        let buckets = try await reopened.buckets(since: .distantPast)
        XCTAssertEqual(buckets.map(\.tokensOut), [80])
    }

    func testDuplicateMessageLinesCountOnce() {
        let first = #"{"sessionId":"s-2","type":"assistant","requestId":"req_1","message":{"id":"msg_dup","role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"a"}],"usage":{"input_tokens":10,"output_tokens":20}},"timestamp":"2026-09-07T05:43:00Z"}"#
        let second = #"{"sessionId":"s-2","type":"assistant","requestId":"req_1","message":{"id":"msg_dup","role":"assistant","model":"claude-opus-4-5","content":[{"type":"tool_use","name":"Read"}],"usage":{"input_tokens":10,"output_tokens":20}},"timestamp":"2026-09-07T05:43:01Z"}"#
        var accumulator = TranscriptAccumulator(path: "/x/s-2.jsonl", isSubagent: false)
        let added = accumulator.ingest(ClaudeTranscriptParser.parse([first, second].joined(separator: "\n")))
        let session = try! XCTUnwrap(accumulator.build())
        XCTAssertEqual(added.map(\.key), ["m:msg_dup"])
        XCTAssertEqual(session.tokensOut, 20)
        XCTAssertEqual(ClaudeTranscriptParser.parseLine(first)?.usageKey, "m:msg_dup")
    }

    func testModelMapper() {
        XCTAssertEqual(ClaudeModelMapper.agentId(for: "claude-opus-4-5-20251101"), "claude-model:claude-opus-4-5-20251101")
        XCTAssertEqual(ClaudeModelMapper.agentId(for: "claude-sonnet-4-5"), "claude-model:claude-sonnet-4-5")
        XCTAssertEqual(ClaudeModelMapper.agentId(for: "claude-haiku-4-5"), "claude-model:claude-haiku-4-5")
        XCTAssertEqual(ClaudeModelMapper.agentId(for: "claude-fable-5-1"), "claude-model:claude-fable-5-1")
        XCTAssertEqual(ClaudeModelMapper.agentId(for: "custom-model"), "claude-model:custom-model")
        XCTAssertNil(ClaudeModelMapper.agentId(for: "<synthetic>"))
        XCTAssertNil(ClaudeModelMapper.agentId(for: nil))
    }

    func testModelInfoParsesVersions() {
        func name(_ id: String) -> String? { ClaudeModelInfo.parse(id)?.displayName }
        XCTAssertEqual(name("claude-opus-4-5-20251101"), "Opus 4.5")
        XCTAssertEqual(name("claude-opus-5"), "Opus 5")
        XCTAssertEqual(name("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(name("claude-sonnet-4-6"), "Sonnet 4.6")
        XCTAssertEqual(name("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(name("claude-3-5-haiku-20241022"), "Haiku 3.5")
        XCTAssertEqual(name("claude-3-7-sonnet-latest"), "Sonnet 3.7")
        XCTAssertEqual(name("us.anthropic.claude-3-5-sonnet-20241022-v2:0"), "Sonnet 3.5")
        XCTAssertNil(ClaudeModelInfo.parse("gpt-4o"))
        XCTAssertNil(ClaudeModelInfo.parse("<synthetic>"))
    }

    func testDiscoveryIncludesEveryVersionAndSubagentModel() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let found = ClaudeModelDiscovery.discover([
            (modelId: "claude-sonnet-4-6", seenAt: t0),
            (modelId: "claude-fable-5-1", seenAt: t0.addingTimeInterval(50)),
            (modelId: "claude-sonnet-5", seenAt: t0.addingTimeInterval(100)),
            (modelId: "<synthetic>", seenAt: t0.addingTimeInterval(200)),
            (modelId: "claude-haiku-4-5", seenAt: t0.addingTimeInterval(10)),
        ])
        XCTAssertEqual(found.map(\.modelId), ["claude-sonnet-5", "claude-fable-5-1", "claude-haiku-4-5", "claude-sonnet-4-6"])
        XCTAssertEqual(found[0].descriptor.model, "Sonnet 5")
        XCTAssertTrue(found[0].descriptor.enabled)
        XCTAssertTrue(found.allSatisfy { $0.descriptor.enabled }, "all model consumers are included")
    }

    func testAccumulatorBuildsSessionWithDominantModel() {
        var accumulator = TranscriptAccumulator(path: "/x/s-1.jsonl", isSubagent: false)
        let added = accumulator.ingest(ClaudeTranscriptParser.parse([Self.user, Self.assistant].joined(separator: "\n")))
            + accumulator.ingest(ClaudeTranscriptParser.parse(Self.haiku))
        let session = try! XCTUnwrap(accumulator.build())
        XCTAssertEqual(session.id, "s-1")
        XCTAssertEqual(session.task, "fix auth bug in middleware")
        XCTAssertEqual(session.dominantAgentId, "claude-model:claude-opus-4-5-20251101")
        XCTAssertEqual(added.map(\.agentId), ["claude-model:claude-opus-4-5-20251101", "claude-model:claude-haiku-4-5"], "each actual model keeps its own tokens")
        XCTAssertEqual(added.map(\.key), ["m:msg_1", "n:1"], "a line without a response id gets its own key")
        XCTAssertEqual(session.modelsSeen.keys.sorted(), ["claude-haiku-4-5", "claude-opus-4-5-20251101"])
        XCTAssertEqual(session.entrypoint, "claude-desktop", "kept from the last line that carried it")
        XCTAssertEqual(session.tokensIn, 312 + 5)
        XCTAssertEqual(session.tokensOut, 87)
        XCTAssertEqual(session.startedAt, DateParsing.iso8601("2026-09-07T05:41:44.123Z"))
        XCTAssertEqual(session.lastActivityAt, DateParsing.iso8601("2026-09-07T05:43:00Z"))
        XCTAssertTrue(session.isLive(now: session.lastActivityAt.addingTimeInterval(600), threshold: 120),
                      "the turn is still running, and a quiet log does not end it")
        XCTAssertFalse(session.isLive(now: session.lastActivityAt.addingTimeInterval(UsageRefresh.abandonedTurnTimeout + 1), threshold: 120))
    }

    func testStoreReadsIncrementally() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects/-Users-me-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s-1.jsonl")
        try (Self.user + "\n").write(to: file, atomically: true, encoding: .utf8)
        let store = ClaudeTranscriptStore(root: dir.deletingLastPathComponent())
        let first = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].tokensOut, 0)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.assistant + "\n").utf8))
        try handle.close()
        // Force a distinct modification date.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)

        let second = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].tokensOut, 80)
        let recorded = await store.usage(since: .distantPast)
        XCTAssertEqual(recorded.map(\.tokensOut), [80], "only the appended line reaches the ledger")
        let none = await store.sessions(modifiedSince: Date().addingTimeInterval(3600))
        XCTAssertEqual(none.count, 0)
    }

    func testStoreTakesTheSessionsGivenOrGeneratedTitle() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects/-Users-me-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s-1.jsonl")
        // Title lines carry no timestamp; the same text inside a message is escaped and names nothing.
        let quoted = #"{"cwd":"/Users/me/proj","sessionId":"s-1","type":"user","message":{"role":"user","content":"{\"type\":\"custom-title\",\"customTitle\":\"Not a title\"}"},"timestamp":"2026-09-07T05:41:50.000Z"}"#
        let generated = #"{"type":"ai-title","aiTitle":"Fix the auth middleware","sessionId":"s-1"}"#
        try ([Self.user, quoted, generated].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let store = ClaudeTranscriptStore(root: dir.deletingLastPathComponent())
        let first = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(first.map(\.task), ["Fix the auth middleware"], "a generated title beats the first prompt")

        let given = #"{"type":"custom-title","customTitle":"Auth \"middleware\" fix","sessionId":"s-1"}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(([given, Self.assistant, generated].joined(separator: "\n") + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)
        let second = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(second.map(\.task), ["Auth \"middleware\" fix"], "the name the session was given beats a later generated title")
        XCTAssertEqual(second.map(\.tokensOut), [80])
    }

    func testAForkCountsOnlyTheLinesOfItsOwnSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects", isDirectory: true)
        let project = root.appendingPathComponent("-Users-me-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        func prompt(_ session: String, _ text: String, at: String) -> String {
            #"{"sessionId":"\#(session)","cwd":"/Users/me/proj","type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"2026-09-07T\#(at)Z"}"#
        }
        // Current builds write the session after the message, beyond the start of a long line.
        func answer(_ session: String, _ id: String, input: Int, at: String) -> String {
            #"{"type":"assistant","message":{"id":"\#(id)","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"\#(String(repeating: "x", count: 4000))"}],"stop_reason":"end_turn","usage":{"input_tokens":\#(input),"cache_read_input_tokens":100,"output_tokens":5}},"timestamp":"2026-09-07T\#(at)Z","cwd":"/Users/me/proj","sessionId":"\#(session)"}"#
        }
        let parent = [#"{"type":"custom-title","customTitle":"Release plan","sessionId":"parent"}"#,
                      prompt("parent", "Plan the release", at: "06:00:00.000"), answer("parent", "msg_p", input: 10, at: "06:00:10.000")]
        try (parent.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent("parent.jsonl"), atomically: true, encoding: .utf8)
        // The fork's log starts with the parent's lines as they were, then continues under its own session.
        let fork = parent + [prompt("fork", "Try the other way", at: "07:00:00.000"), answer("fork", "msg_f", input: 20, at: "07:00:10.000")]
        try (fork.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent("fork.jsonl"), atomically: true, encoding: .utf8)

        let ledger = UsageLedger.inMemory(), store = ClaudeTranscriptStore(roots: [root], ledger: ledger)
        let sessions = Dictionary(uniqueKeysWithValues: await store.sessions(modifiedSince: .distantPast).map { ($0.id, $0) })
        XCTAssertEqual(sessions["parent"]?.task, "Release plan")
        XCTAssertEqual(sessions["fork"]?.task, "Try the other way", "the parent's name and first prompt are not the fork's")
        XCTAssertEqual(sessions["fork"]?.startedAt, DateParsing.iso8601("2026-09-07T07:00:00.000Z"))
        XCTAssertEqual(sessions["fork"]?.tokensIn, 20)
        let buckets = try await ledger.buckets(since: .distantPast, source: ClaudeTranscripts.source)
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.tokensIn }, 30, "the copied response counts once, in the parent's log")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.cacheReadTokens }, 200)
    }

    func testOnlyTheNewestCopyOfAMovedSessionCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects", isDirectory: true)
        let before = root.appendingPathComponent("-Users-me-old", isDirectory: true), after = root.appendingPathComponent("-Users-me-new", isDirectory: true)
        let agents = before.appendingPathComponent("s-m/subagents", isDirectory: true)
        for directory in [agents, after] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        func answer(_ id: String, output: Int, sidechain: Bool = false) -> String {
            #"{"isSidechain":\#(sidechain),"sessionId":"s-m","cwd":"/Users/me/repo","type":"assistant","message":{"id":"\#(id)","role":"assistant","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":\#(output)}},"timestamp":"2026-09-07T06:00:00.000Z"}"#
        }
        // Resumed after the repository moved: the session's log was copied into the new project's folder and continued there.
        let old = before.appendingPathComponent("s-m.jsonl"), new = after.appendingPathComponent("s-m.jsonl")
        try (answer("msg_1", output: 10) + "\n").write(to: old, atomically: true, encoding: .utf8)
        try ([answer("msg_1", output: 10), answer("msg_2", output: 20)].joined(separator: "\n") + "\n").write(to: new, atomically: true, encoding: .utf8)
        try (answer("msg_a", output: 4, sidechain: true) + "\n").write(to: agents.appendingPathComponent("agent-a.jsonl"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        // The listing can name the temporary directory by its resolved path; the project folder tells the copies apart.
        func folders(_ sessions: [TranscriptSession]) -> [String] {
            sessions.filter { !$0.isSubagent }.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent }
        }
        let ledger = UsageLedger.inMemory(), store = ClaudeTranscriptStore(roots: [root], ledger: ledger)
        let sessions = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(folders(sessions), ["-Users-me-new"], "the older copy is treated as missing")
        XCTAssertEqual(sessions.filter(\.isSubagent).count, 1, "a sub-agent's log is never a copy")
        var total = try await ledger.buckets(since: .distantPast, source: ClaudeTranscripts.source).reduce(0) { $0 + $1.tokensOut }
        XCTAssertEqual(total, 34)

        // Continued in the old folder again, that copy is the newest and the other leaves.
        try ([answer("msg_1", output: 10), answer("msg_3", output: 30)].joined(separator: "\n") + "\n").write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: old.path)
        let moved = await store.sessions(modifiedSince: .distantPast)
        XCTAssertEqual(folders(moved), ["-Users-me-old"])
        total = try await ledger.buckets(since: .distantPast, source: ClaudeTranscripts.source).reduce(0) { $0 + $1.tokensOut }
        XCTAssertEqual(total, 44)
    }

    private func claude(_ type: String, at: Date, message: [String: Any], extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": type, "sessionId": "claude-s", "cwd": "/Users/me/proj", "message": message,
                                     "timestamp": ISO8601DateFormatter().string(from: at)]
        object.merge(extra) { _, new in new }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
    private func claudeAssistant(_ stop: Any, id: String, at: Date, model: String = "claude-fable-5-1", block: String = "text",
                                 extra: [String: Any] = [:]) -> String {
        claude("assistant", at: at, message: ["id": id, "role": "assistant", "model": model, "stop_reason": stop,
            "content": [["type": block, block: "done"]], "usage": ["input_tokens": 3, "output_tokens": 2]], extra: extra)
    }

    func testClaudeEndTurnEmitsOncePerMessageAndIgnoresToolUseInterruptionsMetaAndSubagents() throws {
        let start = Date(timeIntervalSince1970: 1_788_850_000)
        let prompt = claude("user", at: start, message: ["role": "user", "content": "Fix the parser bug"])
        let toolCall = claudeAssistant("tool_use", id: "msg_1", at: start.addingTimeInterval(2))
        let toolResult = claude("user", at: start.addingTimeInterval(3), message: ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]])
        let meta = claude("user", at: start.addingTimeInterval(4), message: ["role": "user", "content": "<local-command-stdout>x</local-command-stdout>"], extra: ["isMeta": true])
        let finalLines = [claudeAssistant("end_turn", id: "msg_2", at: start.addingTimeInterval(5), block: "thinking"),
                          claudeAssistant("end_turn", id: "msg_2", at: start.addingTimeInterval(5))]
        let interrupted = [claude("user", at: start.addingTimeInterval(10), message: ["role": "user", "content": "Again"]),
                           claudeAssistant("tool_use", id: "msg_3", at: start.addingTimeInterval(11)),
                           claude("user", at: start.addingTimeInterval(12), message: ["role": "user", "content": "[Request interrupted by user for tool use]"])]
        let failed = claudeAssistant("end_turn", id: "msg_4", at: start.addingTimeInterval(13), model: "<synthetic>")
        let sidechain = claudeAssistant("end_turn", id: "msg_5", at: start.addingTimeInterval(14), extra: ["isSidechain": true])
        let cutoff = claudeAssistant("stop_sequence", id: "msg_6", at: start.addingTimeInterval(20))
        let lines = [prompt, toolCall, toolResult, meta] + finalLines + interrupted + [failed, sidechain, cutoff]
        let text = lines.joined(separator: "\n") + "\n"
        var t = TranscriptAccumulator(path: "/x/claude-s.jsonl", isSubagent: false)
        t.ingest(FastTranscriptParser.parse(Data(text.utf8)))
        let session = try XCTUnwrap(t.build())
        XCTAssertEqual(session.completions.map(\.id), [RecordCoding.hash(["Claude", "claude-s", "msg_2"]), RecordCoding.hash(["Claude", "claude-s", "msg_6"])])
        let first = session.completions[0]
        XCTAssertEqual(first.vendor, "Claude")
        XCTAssertEqual(first.sessionID, "claude-s")
        XCTAssertEqual(first.task, "Fix the parser bug")
        XCTAssertEqual(first.model, "Fable 5.1")
        XCTAssertEqual(first.startedAt, start, "the turn starts at the typed prompt, not at tool results or command output")
        XCTAssertEqual(first.completedAt, start.addingTimeInterval(5))
        var slow = TranscriptAccumulator(path: "/x/claude-s.jsonl", isSubagent: false)
        slow.ingest(ClaudeTranscriptParser.parse(text))
        XCTAssertEqual(slow.build()?.completions, session.completions, "both parsers see the same turns")
        var child = TranscriptAccumulator(path: "/x/subagents/agent-1.jsonl", isSubagent: true)
        child.ingest(FastTranscriptParser.parse(Data(text.utf8)))
        XCTAssertEqual(child.build()?.completions, [])
        let encoded = try JSONEncoder().encode(t)
        // The persisted completions are the live ones without what only memory keeps, such as the turn's token totals.
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        XCTAssertEqual(try sorted.encode(try JSONDecoder().decode(TranscriptAccumulator.self, from: encoded).build()?.completions),
                       try sorted.encode(session.completions))
        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        oldCache.removeValue(forKey: "completions"); oldCache.removeValue(forKey: "turnStartedAt")
        XCTAssertEqual(try JSONDecoder().decode(TranscriptAccumulator.self, from: JSONSerialization.data(withJSONObject: oldCache)).build()?.completions, [])
        t.ingest(FastTranscriptParser.parse(Data((finalLines.joined(separator: "\n") + "\n").utf8)))
        XCTAssertEqual(t.build()?.completions.count, 2, "replayed lines keep the same event ID")
        t.compactIfFinished(now: start.addingTimeInterval(3 * 86400))
        XCTAssertEqual(t.build()?.completions, [], "an idle file keeps no completions in the cache")
    }

    func testTheLastVisibleAnswerBecomesTheTurnsMessage() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = ISO8601DateFormatter().string(from: at)
        func line(_ block: String, _ body: String, id: String = "msg_1") -> Data {
            Data(#"{"type":"assistant","sessionId":"claude-s","cwd":"/p","message":{"id":"\#(id)","role":"assistant","model":"claude-fable-5-1","content":[{"type":"\#(block)","\#(block)":"\#(body)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"\#(stamp)"}"#.utf8)
        }
        XCTAssertEqual(FastTranscriptParser.parseLine(line("text", "done"))?.text, "done")
        XCTAssertNil(FastTranscriptParser.parseLine(line("thinking", "weighing it up"))?.text, "reasoning is not a visible answer")

        // A long answer costs a bounded read and is cut where the escape and the character both allow it.
        let long = String(repeating: "写完了 \"ok\"\n", count: FastTranscriptParser.messageLength / 9)
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [long]), as: UTF8.self).dropFirst(2).dropLast(2)
        let cut = try XCTUnwrap(FastTranscriptParser.parseLine(line("text", String(escaped), id: "msg_3"))?.text)
        XCTAssertLessThanOrEqual(cut.utf8.count, FastTranscriptParser.messageLength)
        XCTAssertGreaterThan(cut.utf8.count, FastTranscriptParser.messageLength / 2)
        XCTAssertTrue(long.hasPrefix(cut), "what is kept is the start of the answer, not a re-encoding of it")

        func event(_ offset: Double, role: TranscriptEvent.Role = .assistant, text: String? = nil, stop: String? = nil, id: String? = nil) -> TranscriptEvent {
            .init(timestamp: at.addingTimeInterval(offset), role: role, model: "claude-test", inputTokens: 0, cacheCreationTokens: 0,
                  cacheReadTokens: 0, outputTokens: 0, text: text, sessionId: "claude-session", cwd: nil, messageId: id,
                  stopReason: stop, isPrompt: role == .user && text != nil)
        }
        var accumulator = TranscriptAccumulator(path: "/fixture/claude-session.jsonl", isSubagent: false)
        accumulator.ingest([event(0, role: .user, text: "Build"), event(5, text: "Reading the file", stop: "tool_use")])
        XCTAssertEqual(accumulator.build()?.turn?.message, "Reading the file")
        accumulator.ingest([event(10, stop: "end_turn", id: "done")])
        XCTAssertEqual(accumulator.build()?.turn?.state, .completed)
        XCTAssertEqual(accumulator.build()?.turn?.message, "Reading the file", "a block without text keeps the answer the turn already gave")
        accumulator.ingest([event(20, role: .user, text: "Next")])
        XCTAssertNil(accumulator.build()?.turn?.message, "a new prompt has no answer yet")
    }

    /// The reminder of a finished turn carries the whole reply: every block the agent wrote after the turn's last input,
    /// as the desktop app writes them, one block per line with the thinking first. Words said before the last tool result
    /// are not part of it, and a line read twice adds nothing.
    func testACompletionCarriesTheWholeReplyAfterTheLastToolResult() throws {
        let session = "6c2d1e3f-8b52-4a4f-9d66-1e7f3a9b0c21"
        func assistant(_ id: String, _ block: String, stop: String, at: String) -> String {
            #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[\#(block)],"stop_reason":"\#(stop)","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":4}},"requestId":"req_\#(id)","type":"assistant","uuid":"u-\#(at)","timestamp":"2026-10-22T18:36:\#(at)Z","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/dev/project","sessionId":"\#(session)","version":"2.1.299"}"#
        }
        let prompt = #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"Explain the fix."},"uuid":"u0","timestamp":"2026-10-22T18:36:00.000Z","entrypoint":"claude-desktop","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        let before = assistant("msg_a", #"{"type":"text","text":"Let me look at the log first."}"#, stop: "tool_use", at: "01.000")
        let call = assistant("msg_a", #"{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/p/a.swift"}}"#, stop: "tool_use", at: "01.010")
        let result = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"file body"}]},"uuid":"u3","timestamp":"2026-10-22T18:36:02.000Z","entrypoint":"claude-desktop","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        let thinking = assistant("msg_b", #"{"type":"thinking","thinking":"","signature":"c2lnbmF0dXJl"}"#, stop: "end_turn", at: "08.972")
        let answer = assistant("msg_b", ###"{"type":"text","text":"## Why\n\nThe completion never took the reply: **only Codex** passed one.\n\n- First point\n- Second point"}"###, stop: "end_turn", at: "08.978")
        let closing = assistant("msg_b", #"{"type":"text","text":"Rebuild and try again."}"#, stop: "end_turn", at: "08.990")
        let stop = #"{"parentUuid":"p","isSidechain":false,"type":"system","subtype":"stop_hook_summary","timestamp":"2026-10-22T18:36:11.865Z","entrypoint":"claude-desktop","sessionId":"\#(session)"}"#
        func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

        var accumulator = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        // The thinking line ends the turn before the answer's own lines are written.
        accumulator.ingest(FastTranscriptParser.parse(data([prompt, before, call, result, thinking])))
        XCTAssertNil(try XCTUnwrap(accumulator.build()?.completions.last).reply, "nothing visible was said after the result yet")
        accumulator.ingest(FastTranscriptParser.parse(data([answer, closing, stop])))
        let expected = "## Why\n\nThe completion never took the reply: **only Codex** passed one.\n\n- First point\n- Second point"
            + "\n\nRebuild and try again."
        let completion = try XCTUnwrap(accumulator.build()?.completions.last)
        XCTAssertEqual(accumulator.build()?.completions.count, 1)
        XCTAssertEqual(completion.reply, expected, "every block after the last tool result, in order")
        XCTAssertEqual(completion.message, "Rebuild and try again.", "the short preview stays the last paragraph")
        XCTAssertFalse(completion.reply?.contains("Let me look") == true, "words before the last tool result are not the reply")

        // Reading the same lines again adds nothing.
        accumulator.ingest(FastTranscriptParser.parse(data([answer, closing])))
        XCTAssertEqual(accumulator.build()?.completions.last?.reply, expected)

        // The reply lives only in memory: the persisted summary and a completion report never hold it.
        let encoded = try JSONEncoder().encode(accumulator)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("only Codex"))
        XCTAssertNil(try JSONDecoder().decode(TranscriptAccumulator.self, from: encoded).build()?.completions.last?.reply)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(completion), as: UTF8.self).contains("only Codex"))

        // A very long reply is cut to what a reminder keeps.
        let long = String(repeating: "word ", count: 3000)
        var big = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        big.ingest(FastTranscriptParser.parse(data([prompt, assistant("msg_c", #"{"type":"text","text":"\#(long)"}"#, stop: "end_turn", at: "09.000")])))
        let cut = try XCTUnwrap(big.build()?.completions.last?.reply)
        XCTAssertEqual(cut.count, SessionCompletion.replyLength)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testAPendingQuestionShowsTheWordsWrittenBeforeItSinceTheLastToolResult() throws {
        let session = "8e4f3a5b-0d74-4c6b-9f88-3a9b5c1d2e43"
        func assistant(_ id: String, _ block: String, stop: String, at: String) -> String {
            #"{"parentUuid":"p","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"\#(id)","type":"message","role":"assistant","content":[\#(block)],"stop_reason":"\#(stop)","stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":4}},"requestId":"req_\#(id)","type":"assistant","uuid":"u-\#(at)","timestamp":"2026-10-22T19:10:\#(at)Z","userType":"external","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)","version":"2.1.299"}"#
        }
        func prompt(_ text: String, at: String) -> String {
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u-\#(at)","timestamp":"2026-10-22T19:10:\#(at)Z","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        }
        let first = prompt("Why did the build fail?", at: "00.000")
        let before = assistant("msg_a", #"{"type":"text","text":"Let me read the build log first."}"#, stop: "tool_use", at: "01.000")
        let call = assistant("msg_a", #"{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"make build"}}"#, stop: "tool_use", at: "01.010")
        let result = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"error: missing import"}]},"uuid":"u-r","timestamp":"2026-10-22T19:10:05.000Z","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        let thinking = assistant("msg_b", #"{"type":"thinking","thinking":"","signature":"c2lnbmF0dXJl"}"#, stop: "tool_use", at: "08.000")
        let answer = assistant("msg_b", ###"{"type":"text","text":"## Cause\n\nThe build failed on a **missing import** in `Sources/App.swift`."}"###, stop: "tool_use", at: "08.100")
        let attachment = #"{"parentUuid":"p","isSidechain":false,"type":"attachment","attachment":{"type":"hook_success"},"uuid":"u-att","timestamp":"2026-10-22T19:10:08.200Z","entrypoint":"cli","sessionId":"\#(session)"}"#
        let question = assistant("msg_b", #"{"type":"tool_use","id":"toolu_2","name":"AskUserQuestion","input":{"questions":[{"question":"What next?","options":[{"label":"Fix it"},{"label":"Stop"}]}]}}"#, stop: "tool_use", at: "08.300")
        let answered = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":"Fix it"}]},"uuid":"u-a","timestamp":"2026-10-22T19:10:30.000Z","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
        let expected = "## Cause\n\nThe build failed on a **missing import** in `Sources/App.swift`."

        var accumulator = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        // Words before a call to another tool stand only until that call: a question read before its result is no
        // reason to show them.
        accumulator.ingest(FastTranscriptParser.parse(data([first, before])))
        XCTAssertEqual(accumulator.build()?.activity?.reply, "Let me read the build log first.")
        accumulator.ingest(FastTranscriptParser.parse(data([call])))
        XCTAssertNil(accumulator.build()?.activity?.reply, "a call to another tool leaves the words before it behind")
        accumulator.ingest(FastTranscriptParser.parse(data([result, thinking])))
        XCTAssertNil(accumulator.build()?.activity?.reply, "nothing visible was said after the result yet")

        // Claude Code writes the question's call only once it is answered: while it waits, the answer is the newest line.
        accumulator.ingest(FastTranscriptParser.parse(data([answer, attachment])))
        XCTAssertEqual(accumulator.build()?.activity?.reply, expected, "the words after the last tool result, not the ones before it")
        let activity = ClaudeCodeProvider.activity(of: try XCTUnwrap(accumulator.build()), subagentsAt: nil, compaction: nil)
        XCTAssertEqual(activity.reply, expected, "the session the HUD reports carries them")
        // A build that writes the question's call first, as one more line of the same response, keeps them too.
        accumulator.ingest(FastTranscriptParser.parse(data([question])))
        XCTAssertEqual(accumulator.build()?.activity?.reply, expected)

        // The words live only in memory: the persisted summary never holds them, and its activity comes back without.
        let encoded = try JSONEncoder().encode(accumulator)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("missing import"))
        XCTAssertNil(try JSONDecoder().decode(TranscriptAccumulator.self, from: encoded).build()?.activity?.reply)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(activity), as: UTF8.self).contains("missing import"))

        // The answer to the question is the turn's next input: what it followed is no longer the newest.
        accumulator.ingest(FastTranscriptParser.parse(data([answered])))
        XCTAssertNil(accumulator.build()?.activity?.reply)

        // A question asked with nothing written before it shows nothing.
        var bare = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        bare.ingest(FastTranscriptParser.parse(data([first, thinking])))
        XCTAssertNil(bare.build()?.activity?.reply)
    }

    func testACompletionCarriesTheTurnsDurationTokensAndListPriceCost() throws {
        let previousLanguage = L10n.language
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(previousLanguage) }
        let session = "7d3e2f4a-9c63-4b5a-8e77-2f8a4b0c1d32"
        func assistant(_ id: String, model: String = "claude-opus-5-5", _ block: String, stop: String, at: String,
                       usage: String, sidechain: Bool = false) -> String {
            #"{"parentUuid":"p","isSidechain":\#(sidechain),"message":{"model":"\#(model)","id":"\#(id)","type":"message","role":"assistant","content":[\#(block)],"stop_reason":"\#(stop)","stop_sequence":null,"usage":{\#(usage)}},"requestId":"req_\#(id)","type":"assistant","uuid":"u-\#(id)-\#(at)","timestamp":"2026-10-22T18:\#(at)Z","userType":"external","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)","version":"2.1.299"}"#
        }
        func prompt(_ text: String, at: String) -> String {
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u-\#(at)","timestamp":"2026-10-22T18:\#(at)Z","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        }
        let text = #"{"type":"text","text":"Done."}"#
        let earlier = [prompt("First.", at: "30:00.000"),
                       assistant("msg_0", text, stop: "end_turn", at: "30:05.000",
                                 usage: #""input_tokens":9000,"cache_creation_input_tokens":9000,"cache_read_input_tokens":9000,"output_tokens":9000"#)]
        let call = assistant("msg_a", #"{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"/p/a.swift"}}"#, stop: "tool_use",
                             at: "40:01.000", usage: #""input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":50000,"output_tokens":200"#)
        let result = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"file body"}]},"uuid":"u-r","timestamp":"2026-10-22T18:40:02.000Z","entrypoint":"cli","cwd":"/Users/dev/project","sessionId":"\#(session)"}"#
        let finalUsage = #""input_tokens":10,"cache_creation_input_tokens":500,"cache_read_input_tokens":60000,"output_tokens":300"#
        // The answer's thinking and text lines are one response: its usage counts once.
        let thinking = assistant("msg_b", #"{"type":"thinking","thinking":"","signature":"c2ln"}"#, stop: "end_turn", at: "44:12.000", usage: finalUsage)
        let answer = assistant("msg_b", text, stop: "end_turn", at: "44:12.010", usage: finalUsage)
        func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

        var first = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        first.ingest(FastTranscriptParser.parse(data(earlier + [prompt("Fix it.", at: "40:00.000"), call, result])))
        // The persisted summary keeps the open turn's count, so a turn read across a restart still totals from its prompt.
        var accumulator = try JSONDecoder().decode(TranscriptAccumulator.self, from: JSONEncoder().encode(first))
        accumulator.ingest(FastTranscriptParser.parse(data([thinking])))
        accumulator.ingest(FastTranscriptParser.parse(data([answer])))
        let completion = try XCTUnwrap(accumulator.build()?.completions.last)
        XCTAssertEqual(accumulator.build()?.completions.count, 2)
        XCTAssertEqual(try XCTUnwrap(completion.duration), 252.01, accuracy: 0.001, "from the prompt to the answer's last line")
        // Only this turn's two responses, every kind: the earlier turn's 36,000 tokens stay out.
        XCTAssertEqual(completion.tokens, TokenKinds(cacheWrite: 1500, input: 110, reasoning: 0, output: 500, cacheRead: 110_000))
        XCTAssertEqual(completion.tokens?.total, 112_110)
        // claude-opus-5-5 per million: input $4, one-hour cache write $8, cache read $0.20, output $20.
        let cost = try XCTUnwrap(completion.listCost)
        XCTAssertEqual(cost.currency, "USD")
        XCTAssertEqual(cost.amount, Decimal(string: "0.04444"))
        XCTAssertEqual(cost.amount, ModelCatalog.cost(agentId: "claude-model:claude-opus-5-5",
            kinds: TokenKinds(cacheWrite: 1500, input: 110, output: 500, cacheRead: 110_000))?.amount, "the catalog's own price")
        XCTAssertEqual(completion.turnSummary, "4m 12s · 112k tok · $0.04 API")

        // The totals live only in memory, like the reply: a completion report never holds them.
        let decoded = try JSONDecoder().decode(SessionCompletion.self, from: JSONEncoder().encode(completion))
        XCTAssertNil(decoded.tokens)
        XCTAssertNil(decoded.listCost)
        var restored = accumulator
        restored.ingest(FastTranscriptParser.parse(data([prompt("Again.", at: "50:00.000"),
            assistant("msg_c", text, stop: "end_turn", at: "50:30.000", usage: #""input_tokens":1,"output_tokens":2"#)])))
        XCTAssertEqual(restored.build()?.completions.last?.tokens?.total, 3, "a new prompt starts the count afresh")

        // A model without a list price keeps its tokens and has no cost rather than a wrong one.
        var unpriced = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        unpriced.ingest(FastTranscriptParser.parse(data([prompt("Quick one.", at: "40:00.000"),
            assistant("msg_d", model: "claude-haiku-5-5", text, stop: "end_turn", at: "40:42.000", usage: #""input_tokens":1200,"output_tokens":34"#)])))
        let quick = try XCTUnwrap(unpriced.build()?.completions.last)
        XCTAssertEqual(quick.tokens?.total, 1234)
        XCTAssertNil(quick.listCost)
        XCTAssertEqual(quick.turnSummary, "42s · 1.2k tok")

        // A turn whose prompt was never read has no total, and a source without totals shows only what it knows.
        var partial = TranscriptAccumulator(path: "/logs/\(session).jsonl", isSubagent: false)
        partial.ingest(FastTranscriptParser.parse(data([answer])))
        XCTAssertNil(partial.build()?.completions.last?.tokens)
        XCTAssertNil(partial.build()?.completions.last?.turnSummary)
        let codex = SessionCompletion(sessionID: "s", vendor: "Codex", turnID: "t", task: "Task", model: "gpt-5.5",
                                      startedAt: Date(timeIntervalSince1970: 0), completedAt: Date(timeIntervalSince1970: 3725))
        XCTAssertEqual(codex.turnSummary, "1h 02m")
    }

    func testClaudePromptToolCompletionAndInterruptionDriveTheTurnState() throws {
        let now: Int64 = 1_800_000_000_000
        let base = Date(timeIntervalSince1970: Double(now) / 1000)
        func event(_ offset: Double, role: TranscriptEvent.Role = .assistant, prompt: String? = nil, stop: String? = nil, id: String? = nil, sidechain: Bool = false) -> TranscriptEvent {
            .init(timestamp: base.addingTimeInterval(offset), role: role, model: "claude-test", inputTokens: 0,
                cacheCreationTokens: 0, cacheReadTokens: 0, outputTokens: 0, text: prompt, sessionId: "claude-session", cwd: nil,
                messageId: id, stopReason: stop, isSidechain: sidechain, isPrompt: role == .user && prompt != nil)
        }
        var accumulator = TranscriptAccumulator(path: "/fixture/claude-session.jsonl", isSubagent: false)
        accumulator.ingest([event(0, role: .user, prompt: "Build"), event(10, stop: "tool_use")])
        let running = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(running.startedAtMs, now)
        XCTAssertEqual(running.observedAtMs, now + 10_000)
        accumulator.ingest([event(20, stop: "end_turn", id: "done")])
        let finished = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(finished.turnID, running.turnID)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.observedAtMs, now + 20_000)
        accumulator = try JSONDecoder().decode(TranscriptAccumulator.self, from: JSONEncoder().encode(accumulator))
        accumulator.ingest([event(30, role: .user, prompt: "Next"), event(31, stop: "end_turn", id: "done"), event(32, stop: "end_turn", id: "child", sidechain: true)])
        XCTAssertEqual(accumulator.build()?.turn?.state, .running, "a delayed duplicate or child completion must not stop new work")
        accumulator.ingest([event(40, role: .user, prompt: "[Request interrupted by user]")])
        XCTAssertEqual(accumulator.build()?.turn?.state, .ended)
        XCTAssertEqual(accumulator.build()?.turn?.startedAtMs, now + 30_000)
    }

    func testAnAnswerWrittenAfterALaterStampedAttachmentStillEndsTheTurn() throws {
        // Claude Code writes its deferred-tools record before the answer, stamped a moment after it.
        let lines = [
            #"{"isSidechain":false,"sessionId":"s-a","type":"user","message":{"role":"user","content":"Explain"},"timestamp":"2026-09-28T10:42:56.354Z"}"#,
            #"{"isSidechain":false,"sessionId":"s-a","type":"attachment","attachment":{"type":"deferred_tools_record"},"timestamp":"2026-09-28T10:44:37.496Z"}"#,
            #"{"isSidechain":false,"sessionId":"s-a","type":"assistant","message":{"id":"msg_a","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Done"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}},"timestamp":"2026-09-28T10:44:37.494Z"}"#,
        ]
        var accumulator = TranscriptAccumulator(path: "/p/s-a.jsonl", isSubagent: false)
        accumulator.ingest(FastTranscriptParser.parse(Data((lines.joined(separator: "\n") + "\n").utf8)))
        let turn = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(turn.state, .completed)
        XCTAssertEqual(turn.observedAtMs, RecordCoding.milliseconds(try XCTUnwrap(DateParsing.iso8601("2026-09-28T10:44:37.494Z"))))
    }

    func testAStopHookSummaryOrATurnDurationEndsATurnThatNoEndTurnCompleted() throws {
        // Lines as Claude Code 2.1 writes them, keys and lines in its own order.
        let tail = #""userType":"external","entrypoint":"cli","cwd":"/p","sessionId":"s-stop","version":"2.1.273","gitBranch":"main"}"#
        func prompt(_ text: String, at time: String) -> String {
            #"{"parentUuid":null,"isSidechain":false,"promptId":"p-\#(time)","type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u-\#(time)","timestamp":"2026-10-14T10:\#(time)Z","permissionMode":"default",\#(tail)"#
        }
        func answer(_ block: String, stop: String, output: Int = 40, at time: String) -> String {
            #"{"parentUuid":"u","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_\#(time)","type":"message","role":"assistant","content":[\#(block)],"stop_reason":"\#(stop)","stop_sequence":null,"stop_details":null,"usage":{"input_tokens":3,"cache_creation_input_tokens":20,"cache_read_input_tokens":900,"output_tokens":\#(output)}},"requestId":"req_\#(time)","type":"assistant","uuid":"a-\#(time)","timestamp":"2026-10-14T10:\#(time)Z",\#(tail)"#
        }
        let apiError = #"{"parentUuid":"u","isSidechain":false,"type":"assistant","uuid":"e","timestamp":"2026-10-14T10:01:09.627Z","message":{"diagnostics":null,"id":"e1","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"text","text":"API Error: Can't reach the API server"}]},"isApiErrorMessage":true,\#(tail)"#
        let result = #"{"parentUuid":"a","isSidechain":false,"promptId":"p","type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok","is_error":false}]},"uuid":"r","timestamp":"2026-10-14T10:00:06.000Z","toolUseResult":{"stdout":"ok"},"sourceToolAssistantUUID":"a",\#(tail)"#
        let hook = #"{"parentUuid":"a","isSidechain":false,"attachment":{"type":"hook_success","hookName":"Stop","toolUseID":"t","hookEvent":"Stop","content":"","stdout":"","stderr":"","exitCode":0,"command":"callback","durationMs":12},"type":"attachment","uuid":"h","timestamp":"2026-10-14T10:00:40.300Z",\#(tail)"#
        let queued = #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-14T10:09:00.000Z","sessionId":"s-stop","content":"and then"}"#
        func summary(at time: String) -> String {
            #"{"parentUuid":"a","isSidechain":false,"type":"system","subtype":"stop_hook_summary","hookCount":1,"hookInfos":[{"command":"callback"}],"hookErrors":[],"hookAdditionalContext":[],"preventedContinuation":false,"stopReason":"","hasOutput":false,"level":"suggestion","timestamp":"2026-10-14T10:\#(time)Z","uuid":"s-\#(time)","toolUseID":"t",\#(tail)"#
        }
        func duration(at time: String) -> String {
            #"{"parentUuid":"a","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":8451,"messageCount":7,"timestamp":"2026-10-14T10:\#(time)Z","uuid":"d-\#(time)","isMeta":false,\#(tail)"#
        }
        func ingest(_ lines: [String]) -> (events: [TranscriptEvent], accumulator: TranscriptAccumulator) {
            let text = lines.joined(separator: "\n") + "\n"
            let fast = FastTranscriptParser.parse(Data(text.utf8))
            XCTAssertEqual(fast.map(\.isStop), ClaudeTranscriptParser.parse(text).map(\.isStop), "both parsers see the same stops")
            var accumulator = TranscriptAccumulator(path: "/p/s-stop.jsonl", isSubagent: false)
            accumulator.ingest(fast)
            return (fast, accumulator)
        }
        func ms(_ time: String) -> Int64 { RecordCoding.milliseconds(DateParsing.iso8601("2026-10-14T10:\(time)Z")!) }

        // An answer cut off at max_tokens leaves no end_turn; Claude Code then runs the Stop hooks and writes their summary.
        let cutOff = [prompt("Summarise the plan", at: "00:00.000"),
                      answer(#"{"type":"tool_use","id":"toolu_1","name":"Read","input":{}}"#, stop: "tool_use", at: "00:05.000"), result,
                      answer(#"{"type":"text","text":"The plan has three"}"#, stop: "max_tokens", output: 32000, at: "00:40.000"), hook, queued]
        XCTAssertEqual(ingest(cutOff).accumulator.build()?.turn?.state, .running, "a cut-off answer alone does not end the turn")
        let read = ingest(cutOff + [summary(at: "00:40.350")])
        XCTAssertEqual(read.events.map(\.isStop), [false, false, false, false, false, false, true])
        let stopped = try XCTUnwrap(read.accumulator.build())
        XCTAssertEqual(stopped.turn?.state, .completed, "the Stop hooks' summary ends the turn")
        XCTAssertEqual(stopped.turn?.observedAtMs, ms("00:40.350"))
        XCTAssertEqual(stopped.turn?.startedAtMs, ms("00:00.000"))
        XCTAssertEqual(stopped.turn?.message, "The plan has three")
        XCTAssertEqual(stopped.completions, [], "a turn that gave no complete answer is not announced as one")
        XCTAssertFalse(stopped.isLive(now: Date(timeIntervalSince1970: Double(ms("00:41.000")) / 1000), threshold: 120))
        // A Stop hook that sends the agent back to work leaves it working again.
        let resumed = ingest(cutOff + [summary(at: "00:40.350"), answer(#"{"type":"text","text":"Continuing"}"#, stop: "tool_use", at: "00:45.000")])
        XCTAssertEqual(resumed.accumulator.build()?.turn?.state, .running)

        // A failed request ends with a synthetic message and, in builds that time turns, the turn's duration.
        let failed = ingest([prompt("Try again", at: "01:00.000"), apiError, duration(at: "01:09.638")]).accumulator.build()
        XCTAssertEqual(failed?.turn?.state, .completed)
        XCTAssertEqual(failed?.turn?.observedAtMs, ms("01:09.638"))

        // After end_turn, or after an interruption, the line that follows changes nothing.
        let answered = ingest([prompt("Explain", at: "02:00.000"), answer(#"{"type":"text","text":"Done"}"#, stop: "end_turn", at: "02:10.000"),
                               hook, summary(at: "02:10.402")]).accumulator.build()
        XCTAssertEqual(answered?.turn?.state, .completed)
        XCTAssertEqual(answered?.turn?.observedAtMs, ms("02:10.000"))
        XCTAssertEqual(answered?.completions.count, 1)
        let interrupted = ingest([prompt("Ask me", at: "03:00.000"),
                                  answer(#"{"type":"tool_use","id":"toolu_2","name":"AskUserQuestion","input":{}}"#, stop: "tool_use", at: "03:02.000"),
                                  prompt("[Request interrupted by user for tool use]", at: "03:30.614"), duration(at: "03:30.616")]).accumulator.build()
        XCTAssertEqual(interrupted?.turn?.state, .ended)
    }

    func testAnAgentWokenWithoutAPromptResumesItsTurn() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ offset: Double, role: TranscriptEvent.Role = .assistant, prompt: String? = nil, stop: String? = nil, id: String? = nil) -> TranscriptEvent {
            .init(timestamp: base.addingTimeInterval(offset), role: role, model: "claude-test", inputTokens: 0, cacheCreationTokens: 0,
                  cacheReadTokens: 0, outputTokens: 0, text: prompt, sessionId: "claude-session", cwd: nil, messageId: id,
                  stopReason: stop, isPrompt: role == .user && prompt != nil)
        }
        var accumulator = TranscriptAccumulator(path: "/fixture/claude-session.jsonl", isSubagent: false)
        accumulator.ingest([event(0, role: .user, prompt: "Research this"), event(5, stop: "tool_use", id: "launch"), event(9, stop: "end_turn", id: "waiting")])
        let stopped = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(stopped.state, .completed)
        // A sub-agent's report arrives as a queue record and a meta line, neither of them a prompt.
        accumulator.ingest([event(60, role: .other), event(61, role: .user), event(62, stop: "tool_use", id: "reading")])
        let resumed = try XCTUnwrap(accumulator.build()?.turn)
        XCTAssertEqual(resumed.state, .running)
        XCTAssertEqual(resumed.turnID, stopped.turnID, "the agent is still working on what it was asked")
        XCTAssertEqual(resumed.observedAtMs, RecordCoding.milliseconds(base.addingTimeInterval(62)))
        accumulator.ingest([event(70, stop: "end_turn", id: "report")])
        XCTAssertEqual(accumulator.build()?.turn?.state, .completed)
        XCTAssertEqual(accumulator.build()?.completions.count, 2)
    }

    func testSubagentLogsFollowTheirOwnTurnWithoutCompletionsOrMarks() throws {
        func line(_ type: String, _ message: String, at second: Int) -> String {
            #"{"isSidechain":true,"agentId":"a1","sessionId":"s-p","type":"\#(type)","message":\#(message),"timestamp":"2026-09-28T10:00:\#(String(format: "%02d", second)).000Z"}"#
        }
        func call(_ id: String, _ name: String, stop: String, at second: Int) -> String {
            line("assistant", #"{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t-\#(id)","name":"\#(name)","input":{}}],"stop_reason":\#(stop),"usage":{"input_tokens":1,"output_tokens":1}}"#, at: second)
        }
        let prompt = line("user", #"{"role":"user","content":"Review the parser"}"#, at: 0)
        let working = call("msg_1", "Read", stop: "null", at: 5)
        let result = line("user", #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}"#, at: 6)
        let answer = line("assistant", #"{"id":"msg_2","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Found it"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#, at: 9)
        let handBack = call("msg_3", "StructuredOutput", stop: "\"tool_use\"", at: 9)
        let interrupted = line("user", #"{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#, at: 9)
        let returned = line("user", #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"t-msg_3","content":"Structured output provided successfully"}]}"#, at: 10)
        func build(_ lines: [String], path: String = "/p/s-p/subagents/agent-a1.jsonl") -> TranscriptSession? {
            let text = lines.joined(separator: "\n") + "\n"
            XCTAssertEqual(FastTranscriptParser.parse(Data(text.utf8)).map(\.returnsStructuredOutput),
                           ClaudeTranscriptParser.parse(text).map(\.returnsStructuredOutput))
            var agent = TranscriptAccumulator(path: path, isSubagent: true)
            agent.ingest(FastTranscriptParser.parse(Data(text.utf8)))
            XCTAssertEqual(agent.drainMarks(), [], "a sub-agent's prompts are steps of its parent's turn")
            return agent.build()
        }
        XCTAssertEqual(build([prompt, working, result])?.turn?.state, .running)
        let done = try XCTUnwrap(build([prompt, working, result, answer]))
        XCTAssertEqual(done.turn?.state, .completed)
        XCTAssertEqual(done.completions, [], "only the session's own agent reports completions")
        let workflow = "/p/s-p/subagents/workflows/wf_1/agent-b2.jsonl"
        XCTAssertEqual(build([prompt, working, result, handBack, returned], path: workflow)?.turn?.state, .completed,
                       "a workflow agent stops once it hands back its result, without an end_turn")
        XCTAssertEqual(build([prompt, working, result, interrupted], path: workflow)?.turn?.state, .ended)
    }

    /// A final Claude response whose usage includes cached input.
    static func endTurn(_ id: String, at date: Date) -> String {
        #"{"sessionId":"s","type":"assistant","message":{"id":"\#(id)","role":"assistant","model":"claude-test","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":800}},"timestamp":"\#(date.ISO8601Format())","entrypoint":"claude-desktop"}"#
    }

    func testCompletionTimestampUsesLastBlockAcrossBatchesAndRestarts() throws {
        let now = Date(timeIntervalSince1970: 1_788_850_000)
        let prompt = #"{"sessionId":"s","type":"user","message":{"role":"user","content":"Test"},"timestamp":"\#(now.ISO8601Format())"}"#
        var acc = TranscriptAccumulator(path: "/s.jsonl", isSubagent: false)
        var counted = acc.ingest(FastTranscriptParser.parse(Data((prompt + "\n" + Self.endTurn("msg_one", at: now.addingTimeInterval(10))).utf8))).count
        acc = try JSONDecoder().decode(TranscriptAccumulator.self, from: JSONEncoder().encode(acc))
        counted += acc.ingest(FastTranscriptParser.parse(Data(Self.endTurn("msg_one", at: now.addingTimeInterval(80)).utf8))).count
        counted += acc.ingest(FastTranscriptParser.parse(Data(Self.endTurn("msg_one", at: now.addingTimeInterval(10)).utf8))).count
        let completion = try XCTUnwrap(acc.build()?.completions.first)
        XCTAssertEqual(acc.build()?.completions.count, 1)
        XCTAssertEqual(completion.startedAt, now)
        XCTAssertEqual(completion.completedAt, now.addingTimeInterval(80))
        XCTAssertEqual(counted, 1, "blocks of one response count once, also after a restart")
        XCTAssertEqual(acc.build()?.cacheReadTokens, 800)
    }

    func testLedgerResumesAfterAppendedLinesAndARestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let logs = directory.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = logs.appendingPathComponent("s.jsonl"), ledgerURL = directory.appendingPathComponent("usage-ledger.sqlite")
        let date = Date()
        let first = Self.endTurn("msg_one", at: date) + "\n"
        try first.write(to: file, atomically: true, encoding: .utf8)
        let transcripts = ClaudeTranscriptStore(roots: [logs], ledger: try UsageLedger(url: ledgerURL))
        _ = await transcripts.index(modifiedSince: .distantPast)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.endTurn("msg_two", at: date.addingTimeInterval(1)) + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(5)], ofItemAtPath: file.path)
        let updated = await transcripts.index(modifiedSince: .distantPast)
        XCTAssertEqual(updated.sessions.first?.tokensOut, 40)
        let scan = await transcripts.lastScan
        XCTAssertEqual(scan.bytesRead, Int(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! UInt64) - first.utf8.count,
                       "only the appended line is read")
        let reopened = ClaudeTranscriptStore(roots: [logs], ledger: try UsageLedger(url: ledgerURL))
        let recovered = await reopened.index(modifiedSince: .distantPast)
        XCTAssertEqual(recovered.sessions.first?.tokensOut, 40)
        let usage = await reopened.usage(since: .distantPast)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.tokensOut }, 40)
    }
}

final class UsageAnalyticsTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    let now = DateParsing.iso8601("2026-09-06T06:32:00Z")! // Sunday 14:32 CST

    func testActivityGridNormalises() {
        let monday = DateParsing.iso8601("2026-08-31T02:00:00Z")! // Monday 10:00 CST
        let usage = [
            UsageBucket(start: monday, agentId: "a", tokensIn: 400, tokensOut: 100),
            UsageBucket(start: monday.addingTimeInterval(3600), agentId: "a", tokensIn: 200, tokensOut: 50),
        ]
        let grid = UsageAnalytics.activityGrid(usage: usage, since: .distantPast, calendar: calendar)
        XCTAssertEqual(grid.rows[0][10], 1)
        XCTAssertEqual(grid.rows[0][11], 0.5)
        XCTAssertEqual(grid.rows[6][10], 0)
        XCTAssertEqual(grid.tokens[0][10], 500)
        XCTAssertEqual(grid.tokens[0][11], 250)
        XCTAssertEqual(grid.tokens[6][10], 0)
    }

    func testActivityGridRetainsEveryModelAndVersion() {
        let monday = DateParsing.iso8601("2026-08-31T02:00:00Z")!
        let usage: [UsageBucket] = [
            .init(start: monday, agentId: "claude-model:opus-4-8", tokensIn: 80, tokensOut: 20),
            .init(start: monday.addingTimeInterval(900), agentId: "claude-model:opus-4-8", tokensIn: 8, tokensOut: 2),
            .init(start: monday, agentId: "claude-model:opus-5", tokensIn: 150, tokensOut: 50),
            .init(start: monday, agentId: "codex-model:new-model", tokensIn: 1, tokensOut: 0),
            .init(start: monday.addingTimeInterval(-900), agentId: "outside-range", tokensIn: 999, tokensOut: 0),
        ]
        let grid = UsageAnalytics.activityGrid(usage: usage, since: monday, calendar: calendar)
        XCTAssertEqual(grid.tokensByModel[0][10], ["claude-model:opus-4-8": 110, "claude-model:opus-5": 200, "codex-model:new-model": 1])
        XCTAssertEqual(grid.tokens[0][10], 311)
        XCTAssertEqual(grid.rows[0][10], 1)
        XCTAssertEqual(grid.tokensByModel[0][11], [:])
        XCTAssertEqual(grid.tokens.flatMap { $0 }.reduce(0, +), 311)
    }

    func testBurnRateStartsAfterAnObservedReset() {
        let samples = [
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-3600), remainingPct: 50),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-2700), remainingPct: 45),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-1800), remainingPct: 100),
            QuotaSample(agentId: "a", timestamp: now, remainingPct: 98),
        ]
        let cycle = QuotaCycle(resetAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        let rate = UsageAnalytics.burnRate(samples: samples, cycle: cycle, now: now)
        XCTAssertEqual(rate?.pctPerHour ?? 0, 4, accuracy: 1e-9)
        XCTAssertNil(UsageAnalytics.burnRate(samples: Array(samples.prefix(1)), cycle: cycle, now: now))
    }

    func testCapStats() {
        let samples = [
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-7200), remainingPct: 3),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-7000), remainingPct: 0),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-6400), remainingPct: 0),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-5800), remainingPct: 100),
            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-300), remainingPct: 0.2),
        ]
        let stats = UsageAnalytics.capStats(samples: samples, now: now)
        XCTAssertEqual(stats.hits, 2)
        XCTAssertEqual(stats.totalWait, 1200 + 300, accuracy: 1e-6)
        XCTAssertEqual(stats.longestWait, 1200, accuracy: 1e-6)
        XCTAssertEqual(stats.longestAt, now.addingTimeInterval(-7000))
        XCTAssertEqual(UsageAnalytics.capStats(samples: [], now: now), .none)
    }

}

final class QuotaHistoryStoreTests: XCTestCase {
    func testImportsTheJSONHistoryOnceAndPersistsInTheLedger() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("quota-history.json"), ledgerURL = directory.appendingPathComponent("usage-ledger.sqlite")
        let now = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode([QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-40 * 86400), remainingPct: 1),
                            QuotaSample(agentId: "a", timestamp: now.addingTimeInterval(-60), remainingPct: 80)]).write(to: legacy)
        let store = QuotaHistoryStore(ledger: try UsageLedger(url: ledgerURL), scope: "claude", importing: legacy)
        await store.append([QuotaSample(agentId: "a", timestamp: now, remainingPct: 72)], now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "the JSON history is removed once imported")
        let reloaded = QuotaHistoryStore(ledger: try UsageLedger(url: ledgerURL), scope: "claude")
        let samples = await reloaded.samples(agentId: "a", since: .distantPast)
        XCTAssertEqual(samples.map(\.remainingPct), [80, 72], "readings older than the retention window are not imported")
        let other = QuotaHistoryStore(ledger: try UsageLedger(url: ledgerURL), scope: "codex")
        await other.removeAll()
        let kept = await reloaded.count
        XCTAssertEqual(kept, 2, "forgetting one provider's readings keeps the others")
    }
}

final class ClaudeCodeProviderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        L10n.setLanguage(.zhHans)
    }

    override func tearDown() {
        L10n.setLanguage(.system)
        super.tearDown()
    }

    private func fakeEngine(script: String) throws -> ClaudeEngineUsageClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("claude")
        try script.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return ClaudeEngineUsageClient(executable: fake, workingDirectory: dir, timeout: 10)
    }

    /// An engine that answers `get_usage` with the given `rate_limits` object.
    private func fakeEngine(rateLimits: String, subscription: String = "max") throws -> ClaudeEngineUsageClient {
        let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"agent-hud-usage","response":{"subscription_type":"\#(subscription)","rate_limits_available":true,"rate_limits":\#(rateLimits)}}}"#
        return try fakeEngine(script: "#!/bin/bash\nread -r l\necho '\(response)'\n")
    }

    func testBuildsReportFromMocks() async throws {
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects", isDirectory: true)
        let project = root.appendingPathComponent("-Users-me-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        func line(_ ts: Date, model: String, out: Int, session: String, text: String? = nil) -> String {
            if let text {
                return #"{"sessionId":"\#(session)","cwd":"/Users/me/proj","type":"user","message":{"role":"user","content":"\#(text)"},"timestamp":"\#(iso.format(ts))"}"#
            }
            return #"{"sessionId":"\#(session)","cwd":"/Users/me/proj","type":"assistant","message":{"role":"assistant","model":"\#(model)","usage":{"input_tokens":100,"output_tokens":\#(out)}},"timestamp":"\#(iso.format(ts))"}"#
        }
        let done = #"{"sessionId":"live","cwd":"/Users/me/proj","type":"assistant","message":{"id":"msg_done","role":"assistant","model":"claude-opus-4-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0}},"timestamp":"\#(iso.format(now.addingTimeInterval(-1390)))"}"#
        let live = [
            line(now.addingTimeInterval(-1500), model: "", out: 0, session: "live", text: "fix auth bug"),
            line(now.addingTimeInterval(-1400), model: "claude-opus-4-5", out: 900, session: "live"),
            done,
            line(now.addingTimeInterval(-1350), model: "", out: 0, session: "live", text: "now the tests"),
            line(now.addingTimeInterval(-30), model: "claude-opus-4-5", out: 100, session: "live"),
        ].joined(separator: "\n") + "\n"
        let ended = [
            line(now.addingTimeInterval(-7200), model: "", out: 0, session: "old", text: "optimize db"),
            line(now.addingTimeInterval(-7000), model: "claude-sonnet-4-5", out: 300, session: "old"),
        ].joined(separator: "\n") + "\n"
        try live.write(to: project.appendingPathComponent("live.jsonl"), atomically: true, encoding: .utf8)
        try ended.write(to: project.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)

        let resets = now.addingTimeInterval(2 * 3600 + 14 * 60)
        let weeklyResets = now.addingTimeInterval(2 * 86400)
        let body = #"{"five_hour":{"utilization":28,"resets_at":"\#(iso.format(resets))"},"seven_day":{"utilization":39,"resets_at":"\#(iso.format(weeklyResets))"},"seven_day_opus":{"utilization":61,"resets_at":"\#(iso.format(weeklyResets))"}}"#
        let account = ProviderAccount.unresolved(provider: "Claude", home: "")
        let history = QuotaHistoryStore()
        await history.append([
            QuotaSample(agentId: account.windowID(ClaudeUsage.sessionRowId), timestamp: now.addingTimeInterval(-2 * 3600), remainingPct: 80),
            QuotaSample(agentId: account.windowID(ClaudeUsage.weeklyRowId), timestamp: now.addingTimeInterval(-5 * 86400), remainingPct: 100),
            QuotaSample(agentId: account.windowID("claude-weekly-opus"), timestamp: now.addingTimeInterval(-2 * 86400), remainingPct: 90)
        ], now: now)
        let transcripts = ClaudeTranscriptStore(root: root)
        let provider = ClaudeCodeProvider(
            engine: try fakeEngine(rateLimits: body),
            transcripts: transcripts,
            history: history,
            clock: { now }
        )
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        XCTAssertNil(report.notice)
        XCTAssertEqual(report.subscriptions, ["Claude": "max"])

        XCTAssertEqual(report.snapshots.map(\.agentId), ["claude-session", "claude-weekly", "claude-weekly-opus"].map(account.windowID), "one row per quota window")
        XCTAssertEqual(report.discoveredAgents.map(\.model), ["window.session", "window.weekly", "window.weekly.Opus"])
        XCTAssertEqual(report.discoveredAgents.map(\.allModels), [true, true, false], "the account's rows keep the flag")
        XCTAssertEqual(report.discoveredAgents.map(\.name), ["Current session", "Weekly limit · All models", "Weekly limit · Opus"])
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-session"))?.remainingPct, 72)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-session"))?.windowDuration, 5 * 3600)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-weekly"))?.windowDuration, 7 * 86400)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-weekly-opus"))?.windowDuration, 7 * 86400)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-weekly"))?.remainingPct, 61)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-weekly-opus"))?.remainingPct, 39)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-session"))?.resetAt?.timeIntervalSince1970 ?? 0, resets.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(report.consumers.map(\.id), ["claude-model:claude-opus-4-5", "claude-model:claude-sonnet-4-5"], "models seen in transcripts, most recent first")

        XCTAssertEqual(report.sessions.count, 2)
        XCTAssertEqual(report.completions.count, 1)
        let completion = try XCTUnwrap(report.completions.first)
        XCTAssertEqual(completion.vendor, "Claude")
        XCTAssertEqual(completion.sessionID, "live")
        XCTAssertEqual(completion.task, "fix auth bug")
        XCTAssertEqual(completion.model, "Opus 4.5")
        XCTAssertEqual(try XCTUnwrap(completion.startedAt).timeIntervalSince1970, now.addingTimeInterval(-1500).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(completion.completedAt.timeIntervalSince1970, now.addingTimeInterval(-1390).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(report.sessions[0].id, "live")
        XCTAssertTrue(report.sessions[0].isLive)
        XCTAssertEqual(report.sessions[0].task, "fix auth bug")
        XCTAssertEqual(report.sessions[0].agentId, "claude-model:claude-opus-4-5")
        XCTAssertEqual(report.sessions[0].terminal, "proj")
        XCTAssertEqual(report.sessions[0].tokensOut, 1000)
        XCTAssertEqual(report.consumerIdsByQuota[account.windowID("claude-session")], ["claude-model:claude-opus-4-5", "claude-model:claude-sonnet-4-5"])
        XCTAssertEqual(report.consumerIdsByQuota[account.windowID("claude-weekly-opus")], ["claude-model:claude-opus-4-5"])
        XCTAssertFalse(report.sessions[1].isLive)
        XCTAssertEqual(report.sessions[1].agentId, "claude-model:claude-sonnet-4-5")
        // Both sessions fall inside the 5h window: live has 1200 of 1600 tokens → 75 % of the 28 % used.
        XCTAssertEqual(try XCTUnwrap(report.sessions[0].pctOfWindow), 21, accuracy: 1e-6)

        let opus = await transcripts.usage(since: now.addingTimeInterval(-7200)).filter { $0.agentId == "claude-model:claude-opus-4-5" }
        XCTAssertEqual(opus.map(\.total).reduce(0, +), 1200)
        let periods = Set([-1400.0, -30.0].map { offset in
            Date(timeIntervalSince1970: (DateParsing.iso8601(iso.format(now.addingTimeInterval(offset)))!.timeIntervalSince1970 / 900).rounded(.down) * 900)
        })
        XCTAssertEqual(Set(opus.map(\.start)), periods, "each response lands in the 15-minute period of its line")
        XCTAssertEqual(try XCTUnwrap(report.insightsByAgent[account.windowID("claude-session")]?.burnRatePctPerHour), 4, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(report.insightsByAgent[account.windowID("claude-weekly")]?.burnRatePctPerHour), 39.0 / 120, accuracy: 1e-6,
                       "the weekly forecast includes readings older than the selected 48-hour statistics range")
        XCTAssertEqual(try XCTUnwrap(report.insightsByAgent[account.windowID("claude-weekly-opus")]?.burnRatePctPerHour), 51.0 / 48, accuracy: 1e-6)
        _ = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        let stored = await history.samples(agentId: account.windowID(ClaudeUsage.sessionRowId), since: .distantPast)
        XCTAssertEqual(stored.count, 2, "each engine observation appends one sample; a poll served from the cache does not")
    }

    func testEngineModeUsesGetUsageAndDiscoversFromTranscripts() async throws {
        // Keep the clock inside the recorded response's window, regardless of the test's wall-clock date.
        let now = DateParsing.iso8601("2026-09-07T10:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let line = #"{"sessionId":"f","cwd":"/p","type":"assistant","message":{"id":"m1","role":"assistant","model":"claude-fable-5-1","usage":{"input_tokens":10,"output_tokens":5}},"timestamp":"\#(iso.format(now.addingTimeInterval(-60)))"}"#
        try (line + "\n").write(to: root.appendingPathComponent("f.jsonl"), atomically: true, encoding: .utf8)
        let engine = try fakeEngine(script: "#!/bin/bash\nread -r l\necho '\(ClaudeEngineTests.response)'\n")
        let provider = ClaudeCodeProvider(
            engine: engine,
            transcripts: ClaudeTranscriptStore(root: root.deletingLastPathComponent()),
            history: QuotaHistoryStore(),
            clock: { now }
        )
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        XCTAssertNil(report.notice)
        XCTAssertEqual(report.subscriptions, ["Claude": "max"])
        let account = ProviderAccount.unresolved(provider: "Claude", home: "")
        XCTAssertEqual(report.discoveredAgents.map(\.id), ["claude-session", "claude-weekly"].map(account.windowID))
        XCTAssertEqual(report.consumers.map(\.id), ["claude-model:claude-fable-5-1"])
        XCTAssertEqual(report.consumers.first?.model, "Fable 5.1")
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-session"))?.remainingPct, 79)
        XCTAssertEqual(report.snapshot(for: account.windowID("claude-weekly"))?.remainingPct, 30)
        XCTAssertEqual(report.sessions.first?.agentId, "claude-model:claude-fable-5-1")
    }

    func testReturnsAllIndexedSessionsForRangeFiltering() async throws {
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-sessions-\(UUID().uuidString)")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<12 {
            let line: [String: Any] = [
                "sessionId": "session-\(index)", "type": "user",
                "message": ["role": "user", "content": "Task \(index)"],
                "timestamp": now.addingTimeInterval(-Double(index) * 3600).ISO8601Format(),
            ]
            var data = try JSONSerialization.data(withJSONObject: line)
            data.append(0x0a)
            try data.write(to: project.appendingPathComponent("session-\(index).jsonl"))
        }
        let provider = ClaudeCodeProvider(
            engine: try fakeEngine(rateLimits: #"{"five_hour":{"utilization":10}}"#),
            transcripts: ClaudeTranscriptStore(root: root), history: QuotaHistoryStore(), clock: { now }
        )
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 169)
        XCTAssertEqual(report.sessions.count, 12, "the view controls how many sessions are expanded")
        XCTAssertEqual(report.sessions.first?.id, "session-0")
        XCTAssertEqual(report.sessions.last?.id, "session-11")
    }

    func testUnavailablePlanLimitsKeepLocalDataWithNotice() async throws {
        let now = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)/projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = #"{"sessionId":"k","cwd":"/p","type":"user","message":{"role":"user","content":"api key session"},"timestamp":"\#(now.addingTimeInterval(-60).ISO8601Format())"}"#
        try (line + "\n").write(to: root.appendingPathComponent("k.jsonl"), atomically: true, encoding: .utf8)
        let response = #"{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}"#
        let provider = ClaudeCodeProvider(
            engine: try fakeEngine(script: "#!/bin/bash\nread -r l\necho '\(response)'\n"),
            transcripts: ClaudeTranscriptStore(root: root.deletingLastPathComponent()),
            history: QuotaHistoryStore(),
            clock: { now }
        )
        let report = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
        XCTAssertEqual(report.notice, "当前登录方式没有订阅额度（API key 或第三方平台）")
        XCTAssertEqual(report.sourceNotices["Claude"], report.notice, "the notice is shown under Claude")
        XCTAssertEqual(report.readingIssues, [:], "a login without plan limits has no current account and no failed read")
        XCTAssertEqual(report.quotaNotices, [:])
        XCTAssertTrue(report.snapshots.isEmpty)
        XCTAssertEqual(report.sessions.map(\.id), ["k"], "sessions still come from local logs")
    }

    func testEngineFailureThrows() async throws {
        let provider = ClaudeCodeProvider(
            engine: try fakeEngine(script: "#!/bin/bash\nread -r l\necho boom >&2\nexit 1\n"),
            transcripts: ClaudeTranscriptStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-empty-\(UUID().uuidString)")),
            history: QuotaHistoryStore()
        )
        do {
            _ = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
            XCTFail("expected failure")
        } catch let error as ClaudeDataError {
            XCTAssertEqual(error, .engineFailed("boom\n"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testEngineMissingThrows() async {
        let provider = ClaudeCodeProvider(
            engine: nil,
            transcripts: ClaudeTranscriptStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-empty-\(UUID().uuidString)")),
            history: QuotaHistoryStore()
        )
        do {
            _ = try await provider.fetchAccountAndLocalUsage(agents: [], historyHours: 48)
            XCTFail("expected failure")
        } catch let error as ClaudeDataError {
            XCTAssertEqual(error, .engineNotFound)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testQuotaFailureAndMissingEngineStillReportLocalCompletions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date()
        try (ClaudeTranscriptTests.endTurn("msg_one", at: date) + "\n").write(to: directory.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let script = directory.appendingPathComponent("engine")
        try "#!/bin/sh\necho called >> calls\nread line\necho boom >&2\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // The engine exits as soon as it has read the request; the deadline only bounds a stalled launch.
        let engine = ClaudeEngineUsageClient(executable: script, workingDirectory: directory, timeout: 10)
        for client in [engine, nil] {
            let history = QuotaHistoryStore(), transcripts = ClaudeTranscriptStore(root: directory)
            let provider = ClaudeCodeProvider(engine: client, transcripts: transcripts, history: history)
            for _ in 0..<2 {
                await provider.refreshAccountUsage(historyHours: 721)
                let result = try await provider.fetchUsage(agents: [], historyHours: 721)
                XCTAssertEqual(result.completions.count, 1)
                XCTAssertEqual(result.sessions.map(\.client), ["Claude Code Desktop"])
                let recorded = await transcripts.usage(since: .distantPast)
                XCTAssertEqual(recorded.first?.cacheReadTokens, 800)
                XCTAssertNotNil(result.notice)
                XCTAssertTrue(result.snapshots.isEmpty)
            }
            let count = await history.count
            XCTAssertEqual(count, 0)
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "called\ncalled\n",
                       "each account refresh asks the engine; how often is the collector's to decide")
    }

    func testAMonthOfTokensListsOnlyTheSessionsOfTheLastSevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        func reply(_ session: String, model: String, daysAgo: Double) throws {
            let at = now.addingTimeInterval(-daysAgo * 86400), file = directory.appendingPathComponent("\(session).jsonl")
            try (#"{"sessionId":"\#(session)","type":"assistant","message":{"id":"msg_\#(session)","role":"assistant","model":"\#(model)","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}},"timestamp":"\#(at.ISO8601Format())","entrypoint":"cli"}"# + "\n")
                .write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
        }
        try reply("recent", model: "claude-opus-5", daysAgo: 2)
        try reply("old", model: "claude-haiku-4-5", daysAgo: 20)
        let transcripts = ClaudeTranscriptStore(root: directory)
        let provider = ClaudeCodeProvider(engine: nil, transcripts: transcripts, history: QuotaHistoryStore(), clock: { now })
        // The host widens the hours to a month, as it does while the local network is on.
        let report = try await provider.fetchUsage(agents: [], historyHours: 31 * 24 + 25)
        XCTAssertEqual(report.sessions.map(\.id), ["recent"])
        XCTAssertEqual(Set(report.consumers.map(\.id)), ["claude-model:claude-opus-5", "claude-model:claude-haiku-4-5"],
                       "models still come from the month the tokens are read for")
        let recorded = await transcripts.usage(since: now.addingTimeInterval(-31 * 86400))
        XCTAssertEqual(recorded.reduce(0) { $0 + $1.tokensIn }, 200, "both logs' tokens are recorded")

        // With no session of the week left, a failed engine read still keeps the month's local data.
        try FileManager.default.removeItem(at: directory.appendingPathComponent("recent.jsonl"))
        let quiet = ClaudeCodeProvider(engine: try fakeEngine(script: "#!/bin/bash\nread -r l\necho boom >&2\nexit 1\n"),
                                       transcripts: ClaudeTranscriptStore(root: directory), history: QuotaHistoryStore(), clock: { now })
        let local = try await quiet.fetchAccountAndLocalUsage(agents: [], historyHours: 31 * 24 + 25)
        XCTAssertEqual(local.sessions.map(\.id), [])
        XCTAssertEqual(local.consumers.map(\.id), ["claude-model:claude-haiku-4-5"])
        XCTAssertEqual(local.typedReadingIssues["Claude"]?.kind, .readFailed, "the engine's failure is the report's notice")
    }

    func testASessionKeepsRunningWhileItsSubagentsWork() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("projects/-p", isDirectory: true)
        let agents = project.appendingPathComponent("s-bg/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true), now = Date()
        func line(_ type: String, _ message: String, ago: TimeInterval, sidechain: Bool = false) -> String {
            #"{"isSidechain":\#(sidechain),"sessionId":"s-bg","cwd":"/p","type":"\#(type)","message":\#(message),"timestamp":"\#(iso.format(now.addingTimeInterval(-ago)))"}"#
        }
        func assistant(_ id: String, stop: String, ago: TimeInterval, sidechain: Bool = false) -> String {
            line("assistant", #"{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"…"}],"stop_reason":\#(stop),"usage":{"input_tokens":1,"output_tokens":1}}"#,
                 ago: ago, sidechain: sidechain)
        }
        // The agent starts a background sub-agent and ends its turn while the sub-agent works.
        try ([line("user", #"{"role":"user","content":"Research the options"}"#, ago: 600),
              assistant("msg_launch", stop: "\"tool_use\"", ago: 598),
              assistant("msg_wait", stop: "\"end_turn\"", ago: 590)].joined(separator: "\n") + "\n")
            .write(to: project.appendingPathComponent("s-bg.jsonl"), atomically: true, encoding: .utf8)
        let agentLog = agents.appendingPathComponent("agent-a1.jsonl")
        try ([line("user", #"{"role":"user","content":"Compare the options"}"#, ago: 597, sidechain: true),
              assistant("msg_a1", stop: "null", ago: 30, sidechain: true)].joined(separator: "\n") + "\n")
            .write(to: agentLog, atomically: true, encoding: .utf8)
        let provider = ClaudeCodeProvider(engine: nil, transcripts: ClaudeTranscriptStore(root: base.appendingPathComponent("projects")),
                                          history: QuotaHistoryStore())

        var report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertEqual(report.sessions.map(\.id), ["s-bg"], "a sub-agent belongs to its session rather than listing as one")
        XCTAssertNil(report.sessions.first?.endedAt, "the session runs while its sub-agent does")
        XCTAssertEqual(report.turns.map(\.state), [.running])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.turns.first).observedAtMs, RecordCoding.milliseconds(now.addingTimeInterval(-31)),
                                    "the sub-agent's work is the session's latest event")
        XCTAssertEqual(report.completions.count, 1, "the agent's own answer still counts as a completion")

        let handle = try FileHandle(forWritingTo: agentLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant("msg_a2", stop: "\"end_turn\"", ago: 5, sidechain: true) + "\n").utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: agentLog.path)
        report = try await provider.fetchUsage(agents: [], historyHours: 24)
        XCTAssertNotNil(report.sessions.first?.endedAt, "the session stops with its last sub-agent")
        XCTAssertEqual(report.turns.map(\.state), [.completed])
    }
}

final class CooperativeIndexingTests: XCTestCase {
    func testIndexStepHonoursBudgetNewestFirstThenCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-index-\(UUID().uuidString)/projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let now = Date()
        for i in 0..<6 {
            let ts = iso.format(now.addingTimeInterval(TimeInterval(-i * 600)))
            let line = #"{"sessionId":"s\#(i)","cwd":"/p","type":"assistant","message":{"id":"m\#(i)","role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":\#(i + 1)}},"timestamp":"\#(ts)"}"#
            let file = root.appendingPathComponent("s\(i).jsonl")
            try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(TimeInterval(-i * 600))], ofItemAtPath: file.path)
        }
        let store = ClaudeTranscriptStore(root: root.deletingLastPathComponent())
        let first = await store.index(modifiedSince: .distantPast, timeBudget: 0)
        XCTAssertEqual(first.sessions.count, 1, "a zero budget still reads the newest file")
        XCTAssertEqual(first.sessions.first?.id, "s0")
        XCTAssertEqual(first.pending, 5)

        let second = await store.index(modifiedSince: .distantPast, timeBudget: 0)
        XCTAssertEqual(second.sessions.map(\.id).sorted(), ["s0", "s1"])
        XCTAssertEqual(second.pending, 4)

        let all = await store.index(modifiedSince: .distantPast, timeBudget: 10)
        XCTAssertEqual(all.sessions.count, 6)
        XCTAssertEqual(all.pending, 0)
        let again = await store.index(modifiedSince: .distantPast, timeBudget: 0)
        XCTAssertEqual(again.sessions.count, 6, "unchanged files need no work")
        XCTAssertEqual(again.pending, 0)
        let stats = await store.lastScan
        XCTAssertEqual(stats.filesRead, 0)
    }
}

extension CooperativeIndexingTests {
    func testATranscriptThatCannotBeReadIsNotPendingAndWaitsToBeTriedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-index-\(UUID().uuidString)/projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let file = root.appendingPathComponent("s-1.jsonl")
        try (ClaudeTranscriptTests.user + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let store = ClaudeTranscriptStore(root: root.deletingLastPathComponent())
        let first = await store.index(modifiedSince: .distantPast)
        XCTAssertEqual(first.pending, 0, "a transcript that cannot be read leaves nothing indexing")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let second = await store.index(modifiedSince: .distantPast)
        let scan = await store.lastScan
        XCTAssertEqual(scan.filesRead, 0, "it waits out its pause before it is tried again")
        XCTAssertEqual(second.pending, 0)
    }
}

final class AccumulatorCompactionTests: XCTestCase {
    func testCompactionDropsDedupeSetOnlyForIdleFiles() {
        let line = ClaudeTranscriptTests.assistant
        var fresh = TranscriptAccumulator(path: "/a/s-1.jsonl", isSubagent: false)
        var counted = fresh.ingest(ClaudeTranscriptParser.parse(line)).count
        let stamp = DateParsing.iso8601("2026-09-07T05:42:10.000Z")!
        fresh.compactIfFinished(now: stamp.addingTimeInterval(3600))
        // Still active: a duplicate of the same message is still recognised.
        counted += fresh.ingest(ClaudeTranscriptParser.parse(line)).count
        XCTAssertEqual(counted, 1)

        var old = TranscriptAccumulator(path: "/b/s-1.jsonl", isSubagent: false)
        counted = old.ingest(ClaudeTranscriptParser.parse(line)).count
        old.compactIfFinished(now: stamp.addingTimeInterval(3 * 86400))
        counted += old.ingest(ClaudeTranscriptParser.parse(line)).count
        XCTAssertEqual(counted, 2, "after compaction the keys are gone; finished files never get appended anyway, and the ledger keeps one row per key")
    }

    func testAnIdleLogReadOverTwoPollsCountsAResponseSplitBetweenThemOnce() async throws {
        // Claude Code writes a line per content block of a response, each with its usage. A day-old log read from its start
        // stops at 4 MiB on no time budget (`TailLogStore.chunkSize`), here between the two blocks of one response.
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-split-\(UUID().uuidString)/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-p"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects.deletingLastPathComponent()) }
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86400))
        func block(_ type: String, output: Int) -> String {
            #"{"parentUuid":"r","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_split","type":"message","role":"assistant","content":[{"type":"\#(type)","\#(type)":"…"}],"stop_reason":null,"usage":{"input_tokens":3,"output_tokens":\#(output)}},"requestId":"req_split","type":"assistant","uuid":"a-\#(type)","timestamp":"\#(stamp)","sessionId":"s-split"}"#
        }
        let first = block("thinking", output: 16), second = block("text", output: 231)
        let output = String(repeating: "x", count: (4 << 20) - first.utf8.count - 300)
        let result = #"{"parentUuid":"p","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t","type":"tool_result","content":"\#(output)"}]},"uuid":"r","timestamp":"\#(stamp)","sessionId":"s-split"}"#
        try ([result, first, second].joined(separator: "\n") + "\n").write(to: projects.appendingPathComponent("-p/s-split.jsonl"), atomically: true, encoding: .utf8)
        let store = ClaudeTranscriptStore(roots: [projects], ledger: UsageLedger.inMemory())
        var pass = await store.index(modifiedSince: .distantPast, timeBudget: 0)
        XCTAssertEqual(pass.pending, 1, "the read stopped after the first block")
        pass = await store.index(modifiedSince: .distantPast, timeBudget: 0)
        XCTAssertEqual(pass.pending, 0)
        XCTAssertEqual(pass.sessions.first?.tokensOut, 16, "the response counts once, from its first line, as in a read in one go")
        let usage = await store.usage(since: .distantPast)
        XCTAssertEqual(usage.reduce(0) { $0 + $1.tokensOut }, 16)
    }
}
