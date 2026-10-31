import AppKit

@main
struct CampusAIFlowSupportTests {
    static func main() throws {
        testIDsAndRequestEncoding()
        testHistoryRequestAndResponse()
        testHistoryManagementProtocol()
        testChatSaveRequestAndResponse()
        testAttachmentProtocol()
        testChatAbortRequest()
        testCookieScope()
        testRefererValidation()
        testCASNativeLoginSupport()
        testChatWindowInputActionPolicy()
        testTranscriptStyleAdaptsToAppearance()
        testMarkdownTranscriptRendering()
        testAutomaticEntryNavigation()
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
            modelID: "2097156176776544256", thinkingMode: .balanced,
            traceID: "trace-fixture"
        )
        guard let data = data,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            fail("chat request body should serialize")
        }
        expect(payload["groupId"] as? String == "1966078115428446208", "groupId must preserve the 64-bit decimal string")
        expect(payload["aiLargeModelId"] as? String == "2097156176776544256", "model ID must preserve the 64-bit decimal string")
        expect(payload["text"] as? String == "问\"题\n中文", "question text must be JSON escaped without loss")
        expect(payload["thinkingMode"] as? String == "balanced", "thinkingMode should preserve the selected mode")
        expect(payload["debug"] as? Bool == true, "debug flag should match the observed webpage request")
        expect(payload["traceId"] as? String == "trace-fixture", "trace ID should be retained")
        expect(CampusAIRequestBuilder.chatBody(text: "x", groupID: "bad", modelID: "2",
                                               thinkingMode: .off, traceID: "t") == nil,
               "invalid IDs should not produce a chat request")
        let expectedModes: [(CampusAIThinkingMode, String)] = [
            (.off, "off"), (.fast, "fast"), (.balanced, "balanced"), (.deep, "deep")
        ]
        for (mode, rawValue) in expectedModes {
            guard let modeData = CampusAIRequestBuilder.chatBody(
                text: "x", groupID: "1966078115428446208", modelID: "2097156176776544256",
                thinkingMode: mode, traceID: "t"),
                let modePayload = (try? JSONSerialization.jsonObject(with: modeData)) as? [String: Any] else {
                fail("thinking mode request should serialize for \(rawValue)")
            }
            expect(modePayload["thinkingMode"] as? String == rawValue,
                   "thinkingMode should serialize the confirmed \(rawValue) mapping")
        }
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
        expect(payload["type"] as? Int == 2, "history lookup should use the website's observed agent history type")
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

    private static func testHistoryManagementProtocol() {
        expect(CampusAIEndpoint.historyDeletePath(sessionID: "1000000000000000002")
               == "/api/af-api-agent/agent/delHistoryData/1000000000000000002",
               "history deletion must use the observed per-session path")
        expect(CampusAIEndpoint.historyDeletePath(sessionID: "not-an-id") == nil,
               "invalid session IDs must not form a deletion path")

        guard let secondPageBody = CampusAIRequestBuilder.historyBody(
            agentID: "1966078115428446208", pageNumber: 2),
              let secondPagePayload = (try? JSONSerialization.jsonObject(with: secondPageBody)) as? [String: Any] else {
            fail("history pagination request should serialize")
        }
        expect(secondPagePayload["pageNum"] as? Int == 2,
               "history pagination should request the selected page")
        expect(CampusAIRequestBuilder.historyBody(agentID: "1966078115428446208", pageNumber: 0) == nil,
               "history pagination must reject non-positive page numbers")

        let pagedResponse = Data(#"{"status":null,"data":{"list":[{"id":"1000000000000000002","businessId":"1966078115428446208","topic":"synthetic topic","createTime":"2026-10-20T18:50:00"},{"id":"1000000000000000003","businessId":"3","topic":"other agent","createTime":"2026-10-20T18:49:32"}],"pageNum":2,"pages":3,"hasPreviousPage":true,"hasNextPage":true}}"#.utf8)
        guard let page = CampusAIHistoryResponse.page(from: pagedResponse,
                                                       expectedAgentID: "1966078115428446208",
                                                       requestedPageNumber: 2) else {
            fail("history page response should parse")
        }
        expect(page.entries.map(\.id) == ["1000000000000000002"],
               "history page should include only valid sessions belonging to the selected agent")
        expect(page.entries.first?.topic == "synthetic topic"
               && page.entries.first?.createTime == "2026-10-20T18:50:00",
               "history page should expose only the display title and creation time")
        expect(page.pageNumber == 2 && page.pageCount == 3
               && page.hasPreviousPage && page.hasNextPage,
               "history page should preserve server pagination state")

        let emptyResponse = Data(#"{"status":null,"data":{"list":[],"pageNum":1,"pages":0,"hasPreviousPage":false,"hasNextPage":false}}"#.utf8)
        guard let emptyPage = CampusAIHistoryResponse.page(from: emptyResponse,
                                                            expectedAgentID: "1966078115428446208",
                                                            requestedPageNumber: 1) else {
            fail("empty history page should parse")
        }
        expect(emptyPage.entries.isEmpty && !emptyPage.hasNextPage,
               "an empty history page should remain a valid empty result")

        let deleted = Data(#"{"status":1,"data":true,"msg":"synthetic"}"#.utf8)
        let failedStatus = Data(#"{"status":0,"data":true}"#.utf8)
        let falseResult = Data(#"{"status":1,"data":false}"#.utf8)
        let malformed = Data(#"{"status":1,"data":1}"#.utf8)
        expect(CampusAIHistoryDeleteResponse.deleted(from: deleted),
               "history deletion should require successful business status and boolean data")
        expect(!CampusAIHistoryDeleteResponse.deleted(from: failedStatus)
               && !CampusAIHistoryDeleteResponse.deleted(from: falseResult)
               && !CampusAIHistoryDeleteResponse.deleted(from: malformed),
               "failed or malformed deletion responses must not be treated as success")
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
        guard let continuedBody = CampusAIRequestBuilder.chatSaveBody(
            text: question, agentID: "1966078115428446208",
            groupID: "1000000000000000001", title: "fixture.docx"
        ), let continuedPayload = (try? JSONSerialization.jsonObject(with: continuedBody)) as? [String: Any] else {
            fail("existing-group attachment save should serialize")
        }
        expect(continuedPayload["groupId"] as? String == "1000000000000000001"
               && continuedPayload["title"] as? String == "fixture.docx",
               "attachment save should preserve the selected group and original file name")

        let created = Data(#"{"status":1,"data":{"groupId":"1000000000000000001","chatId":"fixture-chat"},"msg":"fixture"}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: created) == "1000000000000000001",
               "chat/save should yield only a validated group ID")
        let failureStatus = Data(#"{"status":0,"data":{"groupId":"1000000000000000001"}}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: failureStatus) == nil,
               "a failed business status must not yield a session ID")
        let malformedID = Data(#"{"status":1,"data":{"groupId":"not-an-id"}}"#.utf8)
        expect(CampusAIChatSaveResponse.groupID(from: malformedID) == nil,
               "malformed session IDs must be rejected")

        let identified = Data(#"{"status":1,"data":{"groupId":"1000000000000000001","chatId":"1000000000000000004"}}"#.utf8)
        let identifiers = CampusAIChatSaveResponse.identifiers(from: identified)
        expect(identifiers?.groupID == "1000000000000000001"
               && identifiers?.chatID == "1000000000000000004",
               "attachment metadata should use platform-returned group and chat IDs")
        expect(CampusAIChatSaveResponse.identifiers(from: identified,
                                                      expectedGroupID: "1000000000000000002") == nil,
               "attachment metadata must not cross conversation groups")
    }

    private static func testAttachmentProtocol() {
        let uploadBody = CampusAIAttachmentProtocol.uploadURLBody(
            fileName: "fixture.docx", fileSize: 9, folder: "agent-chat-file/20261020/"
        )
        guard let uploadBody = uploadBody,
              let uploadPayload = (try? JSONSerialization.jsonObject(with: uploadBody)) as? [String: Any] else {
            fail("attachment upload URL request should serialize")
        }
        expect(uploadPayload["id"] as? String == "" && uploadPayload["fileId"] as? String == "",
               "upload URL request should preserve the observed empty id fields")
        expect(uploadPayload["fileName"] as? String == "fixture.docx"
               && uploadPayload["fileSize"] as? Int == 9,
               "upload URL request should carry file name and byte size")
        expect(uploadPayload["chunkSize"] as? Int == 8 * 1024 * 1024
               && uploadPayload["contentType"] as? String == "application/octet-stream",
               "upload URL request should use the observed chunk size and content type")
        expect(CampusAIAttachmentProtocol.uploadURLBody(
            fileName: "fixture.docx", fileSize: 0, folder: "agent-chat-file/20261020/"
        ) == nil, "empty attachments should be rejected")
        expect(CampusAIAttachmentProtocol.uploadURLBody(
            fileName: "fixture.docx", fileSize: 9, folder: "../outside/"
        ) == nil, "upload folders should stay in the attachment namespace")

        let planResponse = Data(#"{"status":1,"data":{"uploadId":"upload-fixture","uploadUrls":["/ai-flow-files/ai-flow/agent-chat-file/20261020/opaque.docx?partNumber=1&X-Amz-Signature=fixture"],"fileName":"opaque.docx","folder":"agent-chat-file/20261020/"}}"#.utf8)
        let plan = CampusAIAttachmentProtocol.uploadPlan(from: planResponse)
        expect(plan?.uploadID == "upload-fixture" && plan?.uploadURLs.count == 1,
               "upload response should resolve the relative signed URL")
        expect(plan?.uploadURLs.first?.scheme == "https"
               && plan?.uploadURLs.first?.host == CampusAIEndpoint.host,
               "signed object uploads should stay on the platform HTTPS host")
        let untrustedPlan = Data(#"{"status":1,"data":{"uploadId":"upload-fixture","uploadUrls":["https://example.com/object?sig=fixture"],"fileName":"opaque.docx","folder":"agent-chat-file/20261020/"}}"#.utf8)
        expect(CampusAIAttachmentProtocol.uploadPlan(from: untrustedPlan) == nil,
               "signed object uploads must reject untrusted hosts")

        let mergeBody = CampusAIAttachmentProtocol.mergeBody(
            uploadID: "upload-fixture", fileName: "opaque.docx", folder: "agent-chat-file/20261020/"
        )
        guard let mergeBody = mergeBody,
              let mergePayload = (try? JSONSerialization.jsonObject(with: mergeBody)) as? [String: Any] else {
            fail("multipart merge request should serialize")
        }
        expect(mergePayload["uploadId"] as? String == "upload-fixture"
               && mergePayload["id"] as? String == "",
               "merge request should use the platform upload ID and observed empty id")
        let mergeResponse = Data(#"{"status":1,"data":{"fileName":"opaque","downloadUrl":"/ai-flow-files/ai-flow/agent-chat-file/20261020/opaque.docx","fullPath":"/ai-flow/agent-chat-file/20261020/opaque.docx"}}"#.utf8)
        guard let stored = CampusAIAttachmentProtocol.storedFile(from: mergeResponse) else {
            fail("merge response should yield platform file paths")
        }
        let draft = CampusAIAttachmentDraft(originalFileName: "fixture.docx", data: Data("binary".utf8), uid: 1700000000000)
        guard let extractBody = CampusAIAttachmentProtocol.extractBody(file: stored, draft: draft),
              let extractPayload = (try? JSONSerialization.jsonObject(with: extractBody)) as? [String: Any] else {
            fail("extract request should serialize")
        }
        expect(extractPayload["fileName"] as? String == "opaque"
               && extractPayload["downloadUrl"] as? String == stored.downloadURL
               && extractPayload["fullPath"] as? String == stored.fullPath,
               "extract request should use the merge response paths")
        expect(extractPayload["size"] as? Int == 6
               && extractPayload["originalFileName"] as? String == "fixture.docx"
               && extractPayload["uid"] as? Int64 == draft.uid,
               "extract request should carry byte size, original name, and attachment UID")
        let extractResponse = Data(#"{"status":1,"data":{"content":"fixture extracted text"}}"#.utf8)
        let content = CampusAIAttachmentProtocol.extractedContent(from: extractResponse)
        expect(content == "fixture extracted text", "extracted text should come from a successful response")
        expect(CampusAIAttachmentProtocol.businessSucceeded(from: Data(#"{"status":1,"data":true}"#.utf8)),
               "saveFileList should accept its successful boolean data payload")
        expect(CampusAIAttachmentProtocol.businessSucceeded(from: Data(#"{"status":1,"data":null}"#.utf8)),
               "saveFileList should validate business status without requiring an object payload")
        expect(!CampusAIAttachmentProtocol.businessSucceeded(from: Data(#"{"status":0,"data":{}}"#.utf8)),
               "file registration should reject a failed business response")

        let uploaded = CampusAIUploadedAttachment(
            originalFileName: draft.originalFileName, totalSize: draft.data.count, uid: draft.uid,
            downloadURL: stored.downloadURL, fullPath: stored.fullPath, content: content ?? ""
        )
        guard let fileListBody = CampusAIAttachmentProtocol.saveFileListBody(
            files: [uploaded], groupID: "1000000000000000001", chatID: "1000000000000000004"),
              let fileList = (try? JSONSerialization.jsonObject(with: fileListBody)) as? [[String: Any]],
              let fileRecord = fileList.first else {
            fail("saveFileList request should serialize as an array")
        }
        expect(fileRecord["groupId"] as? String == "1000000000000000001"
               && fileRecord["chatId"] as? String == "1000000000000000004",
               "file list should use IDs returned by chat/save")
        expect(fileRecord["downloadUrl"] as? String == stored.fullPath
               && fileRecord["fullPath"] as? String == stored.fullPath
               && fileRecord["send"] as? Int == 1,
               "file list should use the observed registered path and send flag")
        let message = CampusAIAttachmentProtocol.chatText(question: "请总结", files: [uploaded])
        expect(message.contains("请总结\n用户已上传文件内容参考：")
               && message.contains("文件1内容：\nfixture extracted text")
               && message.contains("文件1名称：fixture.docx"),
               "chat/send text should include the question and parsed attachment text")
    }

    private static func testChatAbortRequest() {
        expect(CampusAIEndpoint.chatAbortPath == "/api/af-api-agent/chat/abort",
               "active generation cancellation should use the observed abort endpoint")
        let traceID = "fixture-trace-id"
        guard let body = CampusAIRequestBuilder.chatAbortBody(traceID: traceID),
              let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            fail("chat/abort request body should serialize")
        }
        expect(payload.count == 1 && payload["traceId"] as? String == traceID,
               "chat/abort should carry only the active send request trace ID")
        expect(CampusAIRequestBuilder.chatAbortBody(traceID: "") == nil,
               "chat/abort must not be sent without a trace ID")
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

    private static func testRefererValidation() {
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
        expect(HFUTCASLoginSupport.isLoginPage(URL(string: "https://cas.hfut.edu.cn/cas/login?service=https%3A%2F%2Faipt.hfut.edu.cn")),
               "the current official CAS login page should be recognized")
        expect(HFUTCASLoginSupport.isCASHost(URL(string: "https://cas.hfut.edu.cn/cas/oauth2.0/authorize")),
               "all official CAS routes should be excluded from legacy page autofill")
        expect(HFUTCASLoginSupport.isEamsLoginPage(URL(string: "https://jxglstu.hfut.edu.cn/eams5-student/neusoft-sso/login")),
               "legacy credential automation may remain available on official EAMS SSO login page")
        expect(!HFUTCASLoginSupport.isEamsLoginPage(URL(string: "https://evil-hfut.edu.cn/eams5-student/neusoft-sso/login")),
               "legacy credential automation must reject lookalike campus hosts")
        expect(!HFUTCASLoginSupport.isLoginPage(URL(string: "http://cas.hfut.edu.cn/cas/login")),
               "CAS native controls must require HTTPS")
        expect(!HFUTCASLoginSupport.isLoginPage(URL(string: "https://evilcas.hfut.edu.cn/cas/login")),
               "lookalike CAS hosts must not be trusted")
        expect(!HFUTCASLoginSupport.isLoginPage(URL(string: "https://cas.hfut.edu.cn/cas/logout")),
               "CAS native controls must only activate on the login path")
        let now = Date()
        let tgcCookies = [
            cookie(domain: ".cas.hfut.edu.cn", path: "/", name: "CASTGC", value: "fixture-cas-ticket"),
            cookie(domain: "hfut.edu.cn", path: "/cas", name: "TGC", value: "fixture-parent-ticket"),
            cookie(domain: "evilhfut.edu.cn", path: "/", name: "CASTGC", value: "fixture-lookalike"),
            cookie(domain: "cas.hfut.edu.cn", path: "/", name: "TGC", value: "fixture-expired",
                   expires: now.addingTimeInterval(-10))
        ]
        expect(HFUTCASLoginSupport.tgcCookieValue(from: tgcCookies, now: now) == "fixture-cas-ticket",
               "shared CAS state must select a valid CAS-scoped ticket and reject lookalike or expired cookies")

        let username = "user\"; alert('username') //"
        let password = "p\\ass\nword'; alert('password') //"
        let captcha = "验证码\"; alert('captcha') //"
        guard let literal = HFUTCASLoginSupport.credentialsLiteral(
            username: username, password: password, captcha: captcha
        ), let encodedValues = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String],
              let script = HFUTCASLoginSupport.submitScript(
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
        expect(HFUTCASLoginSupport.captchaImageData(from: png) == Data([0x89, 0x50, 0x4e, 0x47]),
               "a bounded CAPTCHA image data URL should be accepted")
        expect(HFUTCASLoginSupport.captchaImageData(from: "https://cas.hfut.edu.cn/captcha") == nil,
               "native code must not fetch or accept a guessed CAPTCHA URL")
        expect(HFUTCASLoginSupport.captchaImageData(from: "data:image/svg+xml;base64,PHN2Zz4=") == nil,
               "unrecognized image formats should fall back to the CAS page")
        expect(HFUTCASLoginSupport.captchaImageData(from: "data:image/png;base64,%%%") == nil,
               "malformed image data must be rejected")
        let tooLarge = "data:image/png;base64,\(String(repeating: "A", count: 700_001))"
        expect(HFUTCASLoginSupport.captchaImageData(from: tooLarge) == nil,
               "oversized CAPTCHA data must be rejected")

        expect(HFUTCASLoginSupport.refreshCaptchaScript.contains("controls.refresh.click()")
               && !HFUTCASLoginSupport.refreshCaptchaScript.contains("fetch(")
               && !HFUTCASLoginSupport.refreshCaptchaScript.contains("XMLHttpRequest"),
               "refresh must use the current CAS page control rather than a guessed endpoint")
    }

    private static func testChatWindowInputActionPolicy() {
        expect(CampusAIInputActionPolicy.decision(for: .keyboardReturn, isSending: false) == .submit,
               "Return in an idle prompt should submit a message")
        expect(CampusAIInputActionPolicy.decision(for: .keyboardReturn, isSending: true) == .ignore,
               "Return must not cancel a reply already in progress")
        expect(CampusAIInputActionPolicy.decision(for: .sendButton, isSending: false) == .submit,
               "clicking Send while idle should submit a message")
        expect(CampusAIInputActionPolicy.decision(for: .sendButton, isSending: true) == .cancel,
               "clicking Stop while sending should cancel the reply")
    }

    private static func testTranscriptStyleAdaptsToAppearance() {
        let attributed = CampusAITranscriptStyle.attributedString("fixture", font: .systemFont(ofSize: 13))
        guard let foreground = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
              let lightAppearance = NSAppearance(named: .aqua),
              let darkAppearance = NSAppearance(named: .darkAqua) else {
            fail("transcript text should use a resolvable semantic foreground color")
        }
        var lightRGB: NSColor?
        var darkRGB: NSColor?
        lightAppearance.performAsCurrentDrawingAppearance {
            lightRGB = foreground.usingColorSpace(.deviceRGB)
        }
        darkAppearance.performAsCurrentDrawingAppearance {
            darkRGB = foreground.usingColorSpace(.deviceRGB)
        }
        guard let lightRGB = lightRGB, let darkRGB = darkRGB else {
            fail("transcript semantic color should resolve in both appearances")
        }
        var lightRed: CGFloat = 0
        var lightGreen: CGFloat = 0
        var lightBlue: CGFloat = 0
        var darkRed: CGFloat = 0
        var darkGreen: CGFloat = 0
        var darkBlue: CGFloat = 0
        lightRGB.getRed(&lightRed, green: &lightGreen, blue: &lightBlue, alpha: nil)
        darkRGB.getRed(&darkRed, green: &darkGreen, blue: &darkBlue, alpha: nil)
        let lightLuminance = (lightRed + lightGreen + lightBlue) / 3
        let darkLuminance = (darkRed + darkGreen + darkBlue) / 3
        expect(lightLuminance < darkLuminance,
               "semantic transcript text should be dark in Aqua and light in Dark Aqua")
    }

    private static func testMarkdownTranscriptRendering() {
        let rendered = CampusAITranscriptStyle.markdownAttributedString(
            "**bold** and `code`",
            font: .systemFont(ofSize: 13)
        )
        expect(rendered.string.contains("bold") && rendered.string.contains("code"),
               "Markdown rendering should preserve the visible content")
        expect(!rendered.string.contains("**") && !rendered.string.contains("`"),
               "Markdown markers should not be shown as literal response text")
        let boldRange = (rendered.string as NSString).range(of: "bold")
        expect(boldRange.location != NSNotFound && rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) != nil,
               "Markdown emphasis should produce styled attributed text")

        // 验证列表换行保留与项目符号渲染
        let listMarkdown = "专业课类\n- 计算机网络\n- 操作系统"
        let renderedList = CampusAITranscriptStyle.markdownAttributedString(listMarkdown, font: .systemFont(ofSize: 13))
        expect(renderedList.string.contains("• 计算机网络\n• 操作系统"),
               "Markdown list items must preserve separate lines with bullet symbols")

        // 验证系统噪音与标签残片清洗
        let noisyThinking = "nk</thi nk>Let me check<timestamp>Saturday, Oct 31, 2026</timestamp> @@@CurrentTime courses"
        let sanitized = CampusAITranscriptStyle.sanitize(noisyThinking)
        expect(!sanitized.contains("nk</thi nk>")
               && !sanitized.contains("timestamp")
               && !sanitized.contains("CurrentTime")
               && sanitized.contains("Let me check")
               && sanitized.contains("courses"),
               "Sanitizer must remove broken think tags, timestamp blocks, and placeholder tokens")

        // 验证思考过程与正式回复样式区分
        let thinkingAttributed = CampusAITranscriptStyle.markdownAttributedString("thinking content", font: .systemFont(ofSize: 13), isThinking: true)
        let thinkingColor = thinkingAttributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        expect(thinkingColor == NSColor.secondaryLabelColor,
               "Thinking text should use secondaryLabelColor for visual hierarchy")
    }

    private static func testAutomaticEntryNavigation() {
        let agentID = CampusAIEndpoint.defaultAgentID
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://one.hfut.edu.cn/home/index"), agentID: agentID)
               == .clickPortalAIPlatform,
               "the signed-in portal home should trigger its official AI platform entry")
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://aipt.hfut.edu.cn/index/agent"), agentID: agentID)
               == .clickAIPlaza,
               "the AI center agent route should trigger the observed plaza control")
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://aipt.hfut.edu.cn/index?forceIndex=1"), agentID: agentID)
               == .clickCampusAdvisor,
               "the observed AI plaza route should open the configured campus advisor")
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://aipt.hfut.edu.cn/index"), agentID: agentID)
               == .clickCampusAdvisor,
               "the plaza route should still trigger advisor discovery when forceIndex is stripped")
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://aipt.hfut.edu.cn/index?forceIndex=1"), agentID: "3") == nil,
               "a custom agent ID must not open the default campus advisor card")
        expect(CampusAIEntryNavigation.step(for: URL(string: "https://evilhfut.edu.cn/home/index"), agentID: agentID) == nil,
               "automatic portal navigation must reject lookalike hosts")
        expect(CampusAIEntryNavigation.step(for: URL(string: "http://one.hfut.edu.cn/home/index"), agentID: agentID) == nil,
               "automatic portal navigation must require HTTPS")

        let portalScript = CampusAIEntryNavigation.script(for: .clickPortalAIPlatform, agentID: agentID)
        expect(portalScript.contains("AI中台") && portalScript.contains("label.click()"),
               "portal automation should click the visible official AI platform entry")
        let plazaScript = CampusAIEntryNavigation.script(for: .clickAIPlaza, agentID: agentID)
        expect(plazaScript.contains(".menu-item") && plazaScript.contains("url.pathname === '/index'")
               && plazaScript.contains("合工大AI辅导员")
               && plazaScript.contains("createTreeWalker")
               && plazaScript.contains("scrollIntoView")
               && plazaScript.contains("root.scrollTop")
               && !plazaScript.contains("querySelectorAll('.title')")
               && plazaScript.contains("open-failed"),
               "plaza automation should tolerate SPA route changes, scroll to lazy cards, and open the target")
        let advisorScript = CampusAIEntryNavigation.script(for: .clickCampusAdvisor, agentID: agentID)
        expect(advisorScript.contains("createTreeWalker")
               && advisorScript.contains("scrollIntoView")
               && advisorScript.contains("root.scrollTop")
               && advisorScript.contains("detailURL.searchParams.get('id') === '\(agentID)'")
               && advisorScript.contains("open-failed"),
               "advisor navigation should scroll to the card and confirm the target route")
        let customAgentScript = CampusAIEntryNavigation.script(for: .clickAIPlaza, agentID: "3")
        expect(customAgentScript.contains("if (false)"),
               "a custom agent ID should stop at the plaza instead of opening the default advisor")
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

        expect(events.contains(.thinkingStarted)
               && events.contains(.thinking("SYNTHETIC_PRIVATE_REASONING"))
               && events.contains(.thinkingEnded),
               "thinking chunks should stay in their own stream events between explicit boundaries")
        expect(events.contains(.toolCallStarted), "tool calls should create a distinct UI event")
        expect(events.contains(.toolCallResult(success: true)), "tool results should expose success without output")
        expect(events.contains(.text("你")) && events.contains(.text("好")), "final text chunks should be preserved")
        expect(events.last == .completed && parser.receivedEnd, "is_end should complete the stream")
        let thinking = events.compactMap { event -> String? in
            guard case .thinking(let chunk) = event else { return nil }
            return chunk
        }.joined()
        let finalText = events.compactMap { event -> String? in
            guard case .text(let chunk) = event else { return nil }
            return chunk
        }.joined()
        expect(thinking == "SYNTHETIC_PRIVATE_REASONING" && !finalText.contains(thinking),
               "thinking and final text should remain separate")
        expect(!String(describing: events).contains("SYNTHETIC_PRIVATE_TOOL_OUTPUT"),
               "raw tool output must never reach UI events")
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
