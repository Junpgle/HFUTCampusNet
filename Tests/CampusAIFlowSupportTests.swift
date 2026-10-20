import Foundation

@main
struct CampusAIFlowSupportTests {
    static func main() throws {
        testIDsAndRequestEncoding()
        testGroupResponseDecoding()
        testCookieScope()
        testNavigationTraceRedaction()
        try testSanitizedSSEFixture()
        testSSEVariantsAndErrors()
        testIncompleteAndOversizedStreams()
        print("CampusAIFlowSupportTests: all checks passed")
    }

    private static func testIDsAndRequestEncoding() {
        expect(CampusAIEndpoint.validID("1966078115428446208"), "19-digit platform IDs should be accepted")
        expect(CampusAIEndpoint.validID("9223372036854775807"), "Int64.max should be accepted")
        expect(!CampusAIEndpoint.validID("9223372036854775808"), "values above Int64.max should be rejected")
        expect(!CampusAIEndpoint.validID("0"), "zero is not a valid platform ID")
        expect(!CampusAIEndpoint.validID("1.0"), "non-decimal IDs should be rejected")

        let data = CampusAIRequestBuilder.chatBody(
            text: "问\"题\n中文", groupID: "1966078115428446208",
            modelID: "2097156176776544256", traceID: "trace-fixture"
        )
        guard let data = data,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("chat request body should serialize")
        }
        expect(payload["groupId"] as? String == "1966078115428446208", "groupId must preserve the 64-bit decimal string")
        expect(payload["aiLargeModelId"] as? String == "2097156176776544256", "model ID must preserve the 64-bit decimal string")
        expect(payload["text"] as? String == "问\"题\n中文", "question text must be JSON escaped without loss")
        expect(payload["thinkingMode"] as? String == "balanced", "thinkingMode should match the observed request")
        expect(payload["debug"] as? Bool == false, "debug output must remain disabled")
        expect(payload["traceId"] as? String == "trace-fixture", "trace ID should be retained")
        expect(CampusAIRequestBuilder.chatBody(text: "x", groupID: "bad", modelID: "2", traceID: "t") == nil,
               "invalid IDs should not produce a chat request")
    }

    private static func testGroupResponseDecoding() {
        let numeric = Data(#"{"status":1,"data":{"id":1966078115428446208,"agentId":1966078115428446208}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: numeric, expectedAgentID: "1966078115428446208") == "1966078115428446208",
               "numeric 64-bit group IDs must not lose precision")

        let string = Data(#"{"status":1,"data":{"id":"1966078115428446209","agentId":"1966078115428446208"}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: string, expectedAgentID: "1966078115428446208") == "1966078115428446209",
               "string group IDs should be accepted")

        let wrongAgent = Data(#"{"status":1,"data":{"id":"1966078115428446209","agentId":"3"}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: wrongAgent, expectedAgentID: "1966078115428446208") == nil,
               "a group returned for a different agent must be rejected")
        let missingAgent = Data(#"{"status":1,"data":{"id":"1966078115428446209"}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: missingAgent, expectedAgentID: "1966078115428446208") == "1966078115428446209",
               "responses without agentId should remain compatible with the agent-scoped lookup")
        let malformedAgent = Data(#"{"status":1,"data":{"id":"1966078115428446209","agentId":true}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: malformedAgent, expectedAgentID: "1966078115428446208") == nil,
               "a present but malformed agent association must be rejected")
        let failure = Data(#"{"status":0,"data":{"id":"1966078115428446209"}}"#.utf8)
        expect(CampusAIGroupResponse.groupID(from: failure, expectedAgentID: "1966078115428446208") == nil,
               "business failure responses must not yield a group ID")
    }

    private static func testCookieScope() {
        let now = Date()
        let cookies = [
            cookie(domain: ".hfut.edu.cn", path: "/", name: "AiFlow", value: "fixture-ai-session"),
            cookie(domain: "aipt.hfut.edu.cn", path: "/api/af-api-agent", name: "Route", value: "fixture-route"),
            cookie(domain: ".hfut.edu.cn", path: "/", name: "ParentRoute", value: "fixture-parent-route"),
            cookie(domain: ".hfut.edu.cn", path: "/", name: "CASTGC", value: "fixture-cas-ticket"),
            cookie(domain: "cas.hfut.edu.cn", path: "/", name: "TGC", value: "fixture-cas-tgc"),
            cookie(domain: "aipt.hfut.edu.cn", path: "/elsewhere", name: "WrongPath", value: "fixture-path"),
            cookie(domain: "evilhfut.edu.cn", path: "/", name: "WrongDomain", value: "fixture-domain"),
            cookie(domain: "aipt.hfut.edu.cn", path: "/", name: "Expired", value: "fixture-expired",
                   expires: now.addingTimeInterval(-10))
        ]
        let sendCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.chatSendPath, now: now)
        let names = Set(sendCookies.map(\.name))
        expect(names == Set(["AiFlow", "Route"]), "only unexpired cookies scoped to the AI API should be retained")
        expect(CampusAIEndpoint.aiFlowCookie(from: sendCookies)?.value == "fixture-ai-session",
               "the platform session cookie should be identifiable")

        let lastGroupCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.lastGroupPath, now: now)
        expect(!lastGroupCookies.contains(where: { $0.name == "WrongPath" }),
               "cookies scoped to another API path must not be forwarded")
    }

    private static func testNavigationTraceRedaction() {
        let url = URL(string: "https://cas.hfut.edu.cn/cas/login/ST-hidden-ticket/opaque-callback-state?service=https%3A%2F%2Faipt.hfut.edu.cn%2Findex%2Fagent&ticket=ST-secret&state=secret-state")!
        let line = CampusAISafeNavigationTrace.line(event: "redirect", url: url, target: "main")
        expect(line.contains("host=cas.hfut.edu.cn"), "trace should retain the host")
        expect(line.contains("path=/cas/login/<redacted>/<redacted>"), "ticket-like and opaque path segments should be redacted")
        expect(line.contains("queryKeys=service,state,ticket"), "trace should retain query parameter names")
        expect(!line.contains("ST-hidden-ticket") && !line.contains("ST-secret")
               && !line.contains("aipt.hfut.edu.cn") && !line.contains("secret-state"),
               "trace must not retain URL parameter values or path tickets")

        let referer = CampusAIEndpoint.referer(
            from: URL(string: "https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208&after=opaque-state"),
            agentID: "1966078115428446208"
        )
        expect(referer?.absoluteString == "https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208",
               "API Referer should retain the agent ID and omit opaque query values")
        expect(CampusAIEndpoint.referer(from: URL(string: "https://aipt.hfut.edu.cn/index/agent?token=opaque"),
                                         agentID: "1966078115428446208") == nil,
               "unrelated AI center routes should not be used as API Referer")
    }

    private static func testSanitizedSSEFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/campus-ai-sse-sanitized.sse")
        let data = try Data(contentsOf: fixture)
        var parser = CampusAISSEParser()
        var events: [CampusAISSEEvent] = []

        // Tiny byte chunks intentionally split JSON, delimiters, and multi-byte Chinese text.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 3, data.count)
            events += parser.append(data.subdata(in: offset..<end))
            offset = end
        }
        events += parser.finish()

        expect(events.contains(.status(.thinking)), "thinking should produce only a generic status")
        expect(events.contains(.status(.toolStarted)), "tool calls should produce a generic status")
        expect(events.contains(.status(.toolSucceeded)), "tool result should expose only its status")
        expect(events.contains(.text("你")) && events.contains(.text("好")), "final text chunks should be preserved")
        expect(events.last == .completed && parser.receivedEnd, "is_end should complete the stream")
        let rendered = String(describing: events)
        expect(!rendered.contains("SYNTHETIC_PRIVATE_REASONING")
               && !rendered.contains("SYNTHETIC_PRIVATE_TOOL_OUTPUT"),
               "thinking and tool output must never reach UI events")
    }

    private static func testSSEVariantsAndErrors() {
        let multiline = Data("data:{\"type\":\"text\",\r\ndata:\"content\":\"你好\",\"is_end\":true}\r\n\r\n".utf8)
        var parser = CampusAISSEParser()
        var events: [CampusAISSEEvent] = []
        for byte in multiline {
            events += parser.append(Data([byte]))
        }
        events += parser.finish()
        expect(events == [.text("你好"), .completed], "CRLF and multi-line data fields should parse across byte splits")

        var errorParser = CampusAISSEParser()
        let error = Data("data:{\"type\":\"error\",\"error\":\"SYNTHETIC_PRIVATE_SERVER_DETAIL\"}\n\n".utf8)
        expect(errorParser.append(error) == [.failed], "server error payload should map to a safe failure event")
        expect(!String(describing: errorParser).contains("SYNTHETIC_PRIVATE_SERVER_DETAIL"),
               "server error details should not be retained by the parser")

        var flaggedErrorParser = CampusAISSEParser()
        let flaggedError = Data("data:{\"type\":\"text\",\"error\":true,\"content\":\"do not show\"}\n\n".utf8)
        expect(flaggedErrorParser.append(flaggedError) == [.failed], "top-level error flags should stop the stream")
    }

    private static func testIncompleteAndOversizedStreams() {
        var incomplete = CampusAISSEParser()
        _ = incomplete.append(Data("data:{\"type\":\"text\",\"content\":\"partial\"}\n\n".utf8))
        expect(incomplete.finish() == [.incomplete], "a closed stream without is_end should be reported as incomplete")

        var finalFrame = CampusAISSEParser()
        let finalWithoutSeparator = Data("data:{\"type\":\"text\",\"content\":\"答\",\"is_end\":true}".utf8)
        expect(finalFrame.append(finalWithoutSeparator).isEmpty, "an unterminated final frame should wait for stream close")
        expect(finalFrame.finish() == [.text("答"), .completed], "finish should parse an unterminated final frame")

        var oversizedFrame = CampusAISSEParser(maximumFrameBytes: 8, maximumResponseBytes: 100)
        expect(oversizedFrame.append(Data("123456789".utf8)) == [.responseTooLarge], "oversized frames should stop parsing")

        var oversizedResponse = CampusAISSEParser(maximumFrameBytes: 100, maximumResponseBytes: 4)
        expect(oversizedResponse.append(Data("12345".utf8)) == [.responseTooLarge], "total response memory should be bounded")
    }

    private static func cookie(domain: String, path: String, name: String, value: String,
                               expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain, .path: path, .name: name, .value: value, .secure: "TRUE"
        ]
        if let expires = expires { properties[.expires] = expires }
        guard let cookie = HTTPCookie(properties: properties) else {
            fatalError("test cookie could not be created")
        }
        return cookie
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
