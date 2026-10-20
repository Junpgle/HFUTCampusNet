import Foundation

@main
struct CampusAIFlowSupportTests {
    static func main() throws {
        testIDsAndRequestEncoding()
        testHistoryRequestAndResponse()
        testChatSaveRequestAndResponse()
        testCookieScope()
        testNavigationTraceRedaction()
        testCASNativeLoginSupport()
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

    private static func testHistoryRequestAndResponse() {
        let body = CampusAIRequestBuilder.historyBody(agentID: "1966078115428446208")
        guard let body = body,
              let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            fail("history request body should serialize")
        }
        expect(payload["businessId"] as? String == "1966078115428446208",
               "history lookup must retain the agent ID as a decimal string")
        expect(payload["pageNum"] as? Int == 1 && payload["pageSize"] as? Int == 20,
               "history lookup should request the first page")
        expect(payload["groupId"] as? String == "" && payload["topic"] as? String == "",
               "history lookup should not filter to an unselected group or topic")
        expect(payload["type"] as? Int == 1, "history lookup should include the inferred agent history type")
        expect(CampusAIRequestBuilder.historyBody(agentID: "bad") == nil,
               "invalid agent IDs should not produce a history request")

        let response = Data(#"{"status":null,"data":{"total":"3","list":[{"id":"1000000000000000003","businessId":"3","userId":"ignored","topic":"synthetic","createTime":"2026-10-20T18:49:32"},{"id":"1000000000000000001","businessId":"1966078115428446208","userId":"ignored","topic":"synthetic","createTime":"2026-10-20T18:46:08"},{"id":"1000000000000000002","businessId":"1966078115428446208","userId":"ignored","topic":"synthetic","createTime":"2026-10-20T18:50:00"}]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: response, expectedAgentID: "1966078115428446208") == "1000000000000000002",
               "history lookup should choose the newest session for the expected agent")

        let numericID = Data(#"{"status":null,"data":{"list":[{"id":1000000000000000003,"businessId":1966078115428446208,"createTime":"2026-10-20T18:49:32"}]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: numericID, expectedAgentID: "1966078115428446208") == "1000000000000000003",
               "numeric 64-bit history IDs must not lose precision")

        let failedStatus = Data(#"{"status":0,"data":{"list":[{"id":"1000000000000000001","businessId":"1966078115428446208"}]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: failedStatus, expectedAgentID: "1966078115428446208") == nil,
               "business failure responses must not yield a session ID")
        let wrongAgent = Data(#"{"status":null,"data":{"list":[{"id":"1000000000000000001","businessId":"3"}]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: wrongAgent, expectedAgentID: "1966078115428446208") == nil,
               "history entries for another agent must be rejected")
        let malformed = Data(#"{"status":null,"data":{"list":[{"id":"invalid","businessId":"1966078115428446208"}]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: malformed, expectedAgentID: "1966078115428446208") == nil,
               "malformed session IDs must be rejected")
        let emptyHistory = Data(#"{"status":null,"data":{"total":"0","list":[]}}"#.utf8)
        expect(CampusAIHistoryResponse.recentGroupID(from: emptyHistory, expectedAgentID: "1966078115428446208") == nil,
               "an empty history must not fabricate a session ID")
        expect(CampusAIHistoryResponse.lookup(from: emptyHistory, expectedAgentID: "1966078115428446208") == .empty,
               "a valid empty history must be distinguishable from a malformed response")
        expect(CampusAIHistoryResponse.lookup(from: malformed, expectedAgentID: "1966078115428446208") == .invalid,
               "a malformed history must not be treated as an empty history")
        expect(CampusAIHistoryResponse.lookup(from: wrongAgent, expectedAgentID: "1966078115428446208") == .invalid,
               "an unrelated history record must not trigger new-session creation")
    }

    private static func testChatSaveRequestAndResponse() {
        expect(CampusAIEndpoint.chatSavePath == "/api/af-api-agent/chat/save",
               "first-message session creation must use the observed chat/save path")
        let question = "fixture first question"
        guard let body = CampusAIRequestBuilder.chatSaveBody(text: question, agentID: "1966078115428446208"),
              let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            fail("chat/save request body should serialize")
        }
        expect(payload["groupId"] is NSNull, "first-message creation must not invent a group ID")
        expect(payload["text"] as? String == question, "chat/save should receive the first user question")
        expect(payload["businessId"] as? String == "1966078115428446208",
               "chat/save should target the selected agent")
        expect(payload["businessType"] as? Int == 4 && payload["type"] as? Int == 2
               && payload["sender"] as? Int == 1,
               "chat/save enum values should match the observed first-message request")
        expect(payload["title"] as? String == question,
               "the first question should be used as the new conversation title")
        expect(CampusAIRequestBuilder.chatSaveBody(text: "x", agentID: "bad") == nil,
               "invalid agent IDs must not produce a chat/save request")

        let created = Data(#"{"status":1,"data":{"groupId":"1000000000000000001","chatId":"fixture-chat"},"msg":"fixture"}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: created) == "1000000000000000001",
               "chat/save should yield only a validated group ID")
        let failureStatus = Data(#"{"status":0,"data":{"groupId":"1000000000000000001"}}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: failureStatus) == nil,
               "a failed business status must not yield a session ID")
        let malformedID = Data(#"{"status":1,"data":{"groupId":"not-an-id"}}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: malformedID) == nil,
               "malformed session IDs must be rejected")
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

        let historyCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.historyPath, now: now)
        expect(!historyCookies.contains(where: { $0.name == "WrongPath" }),
               "cookies scoped to another API path must not be forwarded")
        let saveCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: CampusAIEndpoint.chatSavePath, now: now)
        expect(Set(saveCookies.map(\.name)) == Set(["AiFlow", "Route"]),
               "session creation must use the same narrowly scoped AI session cookies")
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
        expect(CampusAIEndpoint.agentReferer(agentID: "1966078115428446208")?.absoluteString
               == "https://aipt.hfut.edu.cn/agent-detail?id=1966078115428446208",
               "automatic history requests should use a clean target-agent referer")
    }

    private static func testCASNativeLoginSupport() {
        expect(CampusAICasLoginSupport.isLoginPage(URL(string: "https://cas.hfut.edu.cn/cas/login?service=https%3A%2F%2Faipt.hfut.edu.cn")),
               "the current official CAS login page should be recognized")
        expect(!CampusAICasLoginSupport.isLoginPage(URL(string: "http://cas.hfut.edu.cn/cas/login")),
               "CAS native controls must require HTTPS")
        expect(!CampusAICasLoginSupport.isLoginPage(URL(string: "https://evilcas.hfut.edu.cn/cas/login")),
               "lookalike CAS hosts must not be trusted")
        expect(!CampusAICasLoginSupport.isLoginPage(URL(string: "https://cas.hfut.edu.cn/cas/logout")),
               "CAS native controls must only activate on the login path")

        let username = "user\"; alert('username') //"
        let password = "p\\ass\nword'; alert('password') //"
        let captcha = "验证码\"; alert('captcha') //"
        guard let literal = CampusAICasLoginSupport.credentialsLiteral(
            username: username, password: password, captcha: captcha
        ), let encodedValues = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String],
              let script = CampusAICasLoginSupport.submitScript(
                username: username, password: password, captcha: captcha
              ) else {
            fail("native CAS credentials should serialize into a JavaScript data literal")
        }
        expect(encodedValues == [username, password, captcha],
               "quotes, slashes, newlines, and Chinese text must round-trip as credential data")
        expect(script.contains("const values = \(literal);"),
               "the form script must embed credentials only as a JSON array literal")
        expect(script.contains("controls.submit.click();")
               && !script.contains("form.submit()"),
               "native login must click the current official page's submit control")

        let png = "data:image/png;base64,\(Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString())"
        expect(CampusAICasLoginSupport.captchaImageData(from: png) == Data([0x89, 0x50, 0x4e, 0x47]),
               "a bounded CAPTCHA image data URL should be accepted")
        expect(CampusAICasLoginSupport.captchaImageData(from: "https://cas.hfut.edu.cn/captcha") == nil,
               "native code must not fetch or accept a guessed CAPTCHA URL")
        expect(CampusAICasLoginSupport.captchaImageData(from: "data:image/svg+xml;base64,PHN2Zz4=") == nil,
               "unrecognized image formats should fall back to the CAS page")
        expect(CampusAICasLoginSupport.captchaImageData(from: "data:image/png;base64,%%%") == nil,
               "malformed image data must be rejected")
        let tooLarge = "data:image/png;base64,\(String(repeating: "A", count: 700_001))"
        expect(CampusAICasLoginSupport.captchaImageData(from: tooLarge) == nil,
               "oversized CAPTCHA data must be rejected")

        expect(CampusAICasLoginSupport.refreshCaptchaScript.contains("controls.refresh.click()")
               && !CampusAICasLoginSupport.refreshCaptchaScript.contains("fetch(")
               && !CampusAICasLoginSupport.refreshCaptchaScript.contains("XMLHttpRequest"),
               "refresh must use the current CAS page control rather than a guessed endpoint")
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
