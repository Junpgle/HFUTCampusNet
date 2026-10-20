import Foundation
import CoreFoundation

enum CampusAIEndpoint {
    static let host = "aipt.hfut.edu.cn"
    static let api = URL(string: "https://aipt.hfut.edu.cn/api/af-api-agent/")!
    static let defaultAgentID = "1966078115428446208"
    static let defaultModelID = "2097156176776544256"
    static let chatSendPath = "/api/af-api-agent/chat/send"
    static let historyPath = "/api/af-api-agent/agent/getHistoryData"

    static func validID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil,
              let number = Int64(trimmed) else { return false }
        return number > 0
    }

    static func cookies(from all: [HTTPCookie], requestPath: String, now: Date = Date()) -> [HTTPCookie] {
        all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let isAiFlow = cookie.name.caseInsensitiveCompare("AiFlow") == .orderedSame
            let domainMatches = host == domain || (domain == "hfut.edu.cn" && isAiFlow)
            let path = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = requestPath == path
                || (requestPath.hasPrefix(path)
                    && (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"))
            let notExpired = cookie.expiresDate.map { $0 > now } ?? true
            let isCASTicket = ["CASTGC", "TGC"].contains(cookie.name.uppercased())

            // Keep the normal WebKit session, while excluding CAS credentials from native API headers.
            // Only cookies whose declared domain and path cover this exact AI API request are eligible.
            return domainMatches && pathMatches && notExpired && !isCASTicket
        }
    }

    static func aiFlowCookie(from cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { $0.name.caseInsensitiveCompare("AiFlow") == .orderedSame && !$0.value.isEmpty }
    }

    static func cookieHeader(from cookies: [HTTPCookie]) -> String? {
        HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    static func referer(from url: URL?, agentID: String) -> URL? {
        guard validID(agentID), let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.path == "/agent-detail",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        // Keep the target agent context while dropping opaque `after` and other query values.
        return agentReferer(agentID: agentID)
    }

    static func agentReferer(agentID: String) -> URL? {
        guard validID(agentID) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/agent-detail"
        components.queryItems = [URLQueryItem(name: "id", value: agentID)]
        return components.url
    }
}

enum CampusAIRequestBuilder {
    static func historyBody(agentID: String) -> Data? {
        guard CampusAIEndpoint.validID(agentID) else { return nil }
        // The page's POST /agent/getHistoryData uses these fields. Pagination/filter defaults
        // are inferred from the observed request shape and need a live App-session check.
        let payload: [String: Any] = [
            "businessId": agentID,
            "groupId": "",
            "pageNum": 1,
            "pageSize": 20,
            "topic": "",
            "type": 1
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    static func chatBody(text: String, groupID: String, modelID: String, traceID: String) -> Data? {
        guard CampusAIEndpoint.validID(groupID), CampusAIEndpoint.validID(modelID) else { return nil }
        let payload: [String: Any] = [
            "text": text,
            // The working browser request sends these 64-bit identifiers as decimal strings.
            "groupId": groupID,
            "aiLargeModelId": modelID,
            "thinkingMode": "balanced",
            "debug": false,
            "traceId": traceID
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}

enum CampusAIHistoryResponse {
    static func recentGroupID(from data: Data, expectedAgentID: String) -> String? {
        guard CampusAIEndpoint.validID(expectedAgentID),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let rawStatus = response["status"], !(rawStatus is NSNull) {
            guard let status = rawStatus as? NSNumber,
                  CFGetTypeID(status) != CFBooleanGetTypeID(), status.intValue == 1 else { return nil }
        }
        guard let payload = response["data"] as? [String: Any],
              let records = payload["list"] as? [Any] else { return nil }

        let candidates = records.enumerated().compactMap { index, value -> (id: String, createdAt: Date?, index: Int)? in
            guard let record = value as? [String: Any],
                  let businessID = decimalID(record["businessId"]), businessID == expectedAgentID,
                  let id = decimalID(record["id"]), CampusAIEndpoint.validID(id) else { return nil }
            return (id, date(from: record["createTime"]), index)
        }
        return candidates.max { lhs, rhs in
            switch (lhs.createdAt, rhs.createdAt) {
            case let (left?, right?):
                if left != right { return left < right }
                return lhs.index > rhs.index
            case (_?, nil):
                return false
            case (nil, _?):
                return true
            case (nil, nil):
                return lhs.index > rhs.index
            }
        }?.id
    }

    private static func decimalID(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
    }

    private static func date(from value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }

        let localFormatter = DateFormatter()
        localFormatter.locale = Locale(identifier: "en_US_POSIX")
        localFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return localFormatter.date(from: value)
    }
}

enum CampusAISSEStatus: Equatable {
    case thinking
    case toolStarted
    case toolSucceeded
    case toolFailed
}

enum CampusAISSEEvent: Equatable {
    case text(String)
    case status(CampusAISSEStatus)
    case completed
    case failed
    case incomplete
    case responseTooLarge
}

struct CampusAISSEParser {
    private(set) var receivedEnd = false
    private(set) var failed = false

    private var pending = Data()
    private var totalBytes = 0
    private let maximumFrameBytes: Int
    private let maximumResponseBytes: Int

    init(maximumFrameBytes: Int = 2_000_000, maximumResponseBytes: Int = 32_000_000) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    mutating func append(_ data: Data) -> [CampusAISSEEvent] {
        guard !failed, !receivedEnd else { return [] }
        totalBytes += data.count
        guard totalBytes <= maximumResponseBytes else {
            failed = true
            return [.responseTooLarge]
        }
        pending.append(data)

        var events: [CampusAISSEEvent] = []
        while let range = nextFrameRange() {
            events.append(contentsOf: readFrame(pending.subdata(in: 0..<range.lowerBound)))
            pending.removeSubrange(0..<range.upperBound)
            if failed || receivedEnd {
                pending.removeAll(keepingCapacity: false)
                break
            }
        }

        if !failed && !receivedEnd && pending.count > maximumFrameBytes {
            failed = true
            events.append(.responseTooLarge)
        }
        return events
    }

    mutating func finish() -> [CampusAISSEEvent] {
        guard !failed else { return [] }
        var events: [CampusAISSEEvent] = []
        if !pending.isEmpty {
            events.append(contentsOf: readFrame(pending))
            pending.removeAll(keepingCapacity: false)
        }
        if !failed && !receivedEnd {
            failed = true
            events.append(.incomplete)
        }
        return events
    }

    private func nextFrameRange() -> Range<Data.Index>? {
        let lf = pending.range(of: Data("\n\n".utf8))
        let crlf = pending.range(of: Data("\r\n\r\n".utf8))
        return [lf, crlf].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private mutating func readFrame(_ data: Data) -> [CampusAISSEEvent] {
        guard let frame = String(data: data, encoding: .utf8) else { return [] }
        let dataLines = frame.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let value = String(line.dropFirst(5))
            return value.hasPrefix(" ") ? String(value.dropFirst()) : value
        }
        let json = dataLines.joined(separator: "\n")
        guard !json.isEmpty, let bytes = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { return [] }

        let type = object["type"] as? String ?? ""
        if type == "error" || hasServerError(object["error"]) {
            failed = true
            return [.failed]
        }

        var events: [CampusAISSEEvent] = []
        switch type {
        case "text":
            if let content = object["content"] as? String { events.append(.text(content)) }
        case "thinking_start":
            events.append(.status(.thinking))
        case "tool_call_start":
            events.append(.status(.toolStarted))
        case "tool_call_result":
            let call = object["tool_call"] as? [String: Any]
            events.append(.status((call?["status"] as? String) == "success" ? .toolSucceeded : .toolFailed))
        default:
            break
        }

        if object["is_end"] as? Bool == true {
            receivedEnd = true
            events.append(.completed)
        }
        return events
    }

    private func hasServerError(_ value: Any?) -> Bool {
        guard let value = value, !(value is NSNull) else { return false }
        if let flag = value as? Bool { return flag }
        if let message = value as? String { return !message.isEmpty }
        if let number = value as? NSNumber { return number.intValue != 0 }
        return true
    }
}

enum CampusAISafeNavigationTrace {
    static func line(event: String, url: URL, target: String) -> String {
        let host = url.host?.lowercased() ?? "<unknown>"
        let path = safePath(url.path)
        let keys = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
        let query = keys.isEmpty ? "none" : keys.sorted().joined(separator: ",")
        return "\(event) target=\(target) host=\(host) path=\(path) queryKeys=\(query)"
    }

    private static func safePath(_ path: String) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { raw -> String in
            let segment = String(raw)
            let decoded = segment.removingPercentEncoding ?? segment
            let lower = decoded.lowercased()
            let looksLikeSecret = decoded.hasPrefix("ST-")
                || lower.contains("ticket=")
                || lower.contains("token=")
                || decoded.range(of: "^[0-9]{15,}$", options: .regularExpression) != nil
                || decoded.range(of: "^[A-Za-z0-9_-]{16,}$", options: .regularExpression) != nil
            return looksLikeSecret ? "<redacted>" : segment
        }
        let value = segments.joined(separator: "/")
        return value.isEmpty ? "/" : value
    }
}
