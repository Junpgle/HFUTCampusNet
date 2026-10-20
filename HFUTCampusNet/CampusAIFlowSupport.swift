import Foundation
import CoreFoundation

enum CampusAIEndpoint {
    static let host = "aipt.hfut.edu.cn"
    static let api = URL(string: "https://aipt.hfut.edu.cn/api/af-api-agent/")!
    static let defaultAgentID = "1966078115428446208"
    static let defaultModelID = "2097156176776544256"
    static let chatSendPath = "/api/af-api-agent/chat/send"
    static let lastGroupPath = "/api/af-api-agent/chat/lastGroup"

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
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == host,
              components.path == "/agent-detail",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        // Keep the target agent context while dropping opaque `after` and other query values.
        components.queryItems = [URLQueryItem(name: "id", value: agentID)]
        components.fragment = nil
        return components.url
    }
}

enum CampusAIRequestBuilder {
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

enum CampusAIGroupResponse {
    static func groupID(from data: Data, expectedAgentID: String) -> String? {
        guard CampusAIEndpoint.validID(expectedAgentID),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = response["status"] as? NSNumber,
              CFGetTypeID(status) != CFBooleanGetTypeID(), status.intValue == 1,
              let group = response["data"] as? [String: Any],
              let id = decimalID(group["id"]), CampusAIEndpoint.validID(id) else { return nil }
        if let rawAgentID = group["agentId"], !(rawAgentID is NSNull) {
            guard let returnedAgentID = decimalID(rawAgentID), returnedAgentID == expectedAgentID else { return nil }
        }
        return id
    }

    private static func decimalID(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.stringValue
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
