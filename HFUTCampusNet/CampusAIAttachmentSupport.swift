import Foundation
import CoreFoundation

struct CampusAIAttachmentDraft {
    let originalFileName: String
    let data: Data
    let uid: Int64
}

struct CampusAIUploadPlan {
    let uploadID: String
    let uploadURLs: [URL]
    let fileName: String
    let folder: String
}

struct CampusAIStoredFile {
    let fileName: String
    let downloadURL: String
    let fullPath: String
}

struct CampusAIUploadedAttachment {
    let originalFileName: String
    let totalSize: Int
    let uid: Int64
    let downloadURL: String
    let fullPath: String
    let content: String
}

struct CampusAIChatSaveIdentifiers {
    let groupID: String
    let chatID: String
}

enum CampusAIAttachmentProtocol {
    static let chunkSize = 8 * 1024 * 1024
    static let maximumFileSize = 100 * 1024 * 1024

    static func uploadURLBody(fileName: String, fileSize: Int, folder: String) -> Data? {
        guard !fileName.isEmpty, fileSize > 0, fileSize <= maximumFileSize,
              folder.range(of: "^agent-chat-file/[0-9]{8}/$", options: .regularExpression) != nil else {
            return nil
        }
        let payload: [String: Any] = [
            "id": "",
            "fileId": "",
            "fileName": fileName,
            "fileSize": fileSize,
            "chunkSize": chunkSize,
            "folder": folder,
            "contentType": "application/octet-stream"
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    static func uploadPlan(from data: Data) -> CampusAIUploadPlan? {
        guard let payload = successfulPayload(from: data),
              let uploadID = payload["uploadId"] as? String, !uploadID.isEmpty,
              let rawURLs = payload["uploadUrls"] as? [String], !rawURLs.isEmpty,
              let fileName = payload["fileName"] as? String, !fileName.isEmpty,
              let folder = payload["folder"] as? String,
              folder.range(of: "^agent-chat-file/[0-9]{8}/$", options: .regularExpression) != nil else {
            return nil
        }
        let baseURL = URL(string: "https://\(CampusAIEndpoint.host)")!
        let urls = rawURLs.compactMap { raw -> URL? in
            guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == CampusAIEndpoint.host,
                  url.user == nil, url.password == nil,
                  url.path.hasPrefix("/ai-flow-files/"),
                  !url.query.isNilOrEmpty,
                  url.fragment == nil else { return nil }
            return url
        }
        guard urls.count == rawURLs.count else { return nil }
        return CampusAIUploadPlan(uploadID: uploadID, uploadURLs: urls, fileName: fileName, folder: folder)
    }

    static func mergeBody(uploadID: String, fileName: String, folder: String) -> Data? {
        guard !uploadID.isEmpty, !fileName.isEmpty,
              folder.range(of: "^agent-chat-file/[0-9]{8}/$", options: .regularExpression) != nil else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "id": "", "uploadId": uploadID, "fileName": fileName, "folder": folder
        ])
    }

    static func storedFile(from data: Data) -> CampusAIStoredFile? {
        guard let payload = successfulPayload(from: data),
              let fileName = payload["fileName"] as? String, !fileName.isEmpty,
              let downloadURL = payload["downloadUrl"] as? String, downloadURL.hasPrefix("/ai-flow-files/"),
              let fullPath = payload["fullPath"] as? String, fullPath.hasPrefix("/ai-flow/") else { return nil }
        return CampusAIStoredFile(fileName: fileName, downloadURL: downloadURL, fullPath: fullPath)
    }

    static func extractBody(file: CampusAIStoredFile, draft: CampusAIAttachmentDraft) -> Data? {
        guard !draft.originalFileName.isEmpty, draft.data.count > 0,
              draft.data.count <= maximumFileSize, draft.uid > 0 else { return nil }
        return try? JSONSerialization.data(withJSONObject: [
            "fileName": file.fileName,
            "downloadUrl": file.downloadURL,
            "fullPath": file.fullPath,
            "size": draft.data.count,
            "originalFileName": draft.originalFileName,
            "uid": draft.uid
        ])
    }

    static func extractedContent(from data: Data) -> String? {
        guard let payload = successfulPayload(from: data),
              let content = payload["content"] as? String else { return nil }
        return content
    }

    static func businessSucceeded(from data: Data) -> Bool {
        successfulPayload(from: data) != nil
    }

    static func saveFileListBody(files: [CampusAIUploadedAttachment], groupID: String, chatID: String) -> Data? {
        guard !files.isEmpty, CampusAIEndpoint.validID(groupID), CampusAIEndpoint.validID(chatID) else { return nil }
        let records: [[String: Any]] = files.map { file in
            [
                "groupId": groupID,
                "chatId": chatID,
                "originalFileName": file.originalFileName,
                "totalSize": file.totalSize,
                "uid": file.uid,
                // The page's saveFileList request uses fullPath for both path fields.
                "downloadUrl": file.fullPath,
                "fullPath": file.fullPath,
                "send": 1
            ]
        }
        return try? JSONSerialization.data(withJSONObject: records)
    }

    static func chatText(question: String, files: [CampusAIUploadedAttachment]) -> String {
        guard !files.isEmpty else { return question }
        var result = question + "\n用户已上传文件内容参考：\n"
        for (index, file) in files.enumerated() {
            let number = index + 1
            result += "文件\(number)内容：\n\(file.content)\n\n"
            result += "文件\(number)名称：\(file.originalFileName)\n"
            result += "文件\(number)大小：\(String(format: "%.2f KB", Double(file.totalSize) / 1024))\n"
        }
        return result
    }

    static func folder(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd"
        return "agent-chat-file/\(formatter.string(from: date))/"
    }

    private static func successfulPayload(from data: Data) -> [String: Any]? {
        guard let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawStatus = response["status"] as? NSNumber,
              CFGetTypeID(rawStatus) != CFBooleanGetTypeID(), rawStatus.intValue == 1,
              let payload = response["data"] as? [String: Any] else { return nil }
        return payload
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

final class CampusAIAttachmentClient {
    enum Failure: Error {
        case invalidFile
        case network
        case platformRejected
        case invalidResponse
        case cancelled
    }

    private let files: [CampusAIAttachmentDraft]
    private let question: String
    private let agentID: String
    private let existingGroupID: String?
    private let cookies: [HTTPCookie]
    private let referer: URL?
    private let onProgress: (String) -> Void
    private let completion: (Result<(CampusAIChatSaveIdentifiers, String), Failure>) -> Void

    private let session: URLSession
    private var task: URLSessionDataTask?
    private var uploadedFiles: [CampusAIUploadedAttachment] = []
    private var fileIndex = 0
    private var completed = false

    init(files: [CampusAIAttachmentDraft], question: String, agentID: String,
         existingGroupID: String?, cookies: [HTTPCookie], referer: URL?,
         onProgress: @escaping (String) -> Void,
         completion: @escaping (Result<(CampusAIChatSaveIdentifiers, String), Failure>) -> Void) {
        self.files = files
        self.question = question
        self.agentID = agentID
        self.existingGroupID = existingGroupID
        self.cookies = cookies
        self.referer = referer
        self.onProgress = onProgress
        self.completion = completion

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: configuration)
    }

    func start() {
        guard !files.isEmpty, CampusAIEndpoint.validID(agentID),
              existingGroupID.map(CampusAIEndpoint.validID) ?? true,
              files.allSatisfy({ !$0.originalFileName.isEmpty && !$0.data.isEmpty
                  && $0.data.count <= CampusAIAttachmentProtocol.maximumFileSize && $0.uid > 0 }) else {
            finish(.failure(.invalidFile))
            return
        }
        uploadNextFile()
    }

    func cancel() {
        guard !completed else { return }
        completed = true
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    private func uploadNextFile() {
        guard !completed else { return }
        guard fileIndex < files.count else {
            saveAttachmentMessage()
            return
        }
        let draft = files[fileIndex]
        onProgress("正在上传附件 \(fileIndex + 1)/\(files.count)：\(draft.originalFileName)")
        let folder = CampusAIAttachmentProtocol.folder()
        guard let body = CampusAIAttachmentProtocol.uploadURLBody(
            fileName: draft.originalFileName, fileSize: draft.data.count, folder: folder
        ) else {
            finish(.failure(.invalidFile))
            return
        }
        performJSON(path: "common/getUploadUrl", body: body) { [weak self] result in
            guard let self = self, !self.completed else { return }
            guard case .success(let data) = result else { self.finishWith(result); return }
            guard let plan = CampusAIAttachmentProtocol.uploadPlan(from: data),
                  plan.folder == folder,
                  plan.uploadURLs.count == (draft.data.count + CampusAIAttachmentProtocol.chunkSize - 1)
                    / CampusAIAttachmentProtocol.chunkSize else {
                self.finish(.failure(.invalidResponse))
                return
            }
            self.upload(plan: plan, draft: draft, part: 0)
        }
    }

    private func upload(plan: CampusAIUploadPlan, draft: CampusAIAttachmentDraft, part: Int) {
        guard !completed else { return }
        guard part < plan.uploadURLs.count else {
            merge(plan: plan, draft: draft)
            return
        }
        let lowerBound = part * CampusAIAttachmentProtocol.chunkSize
        let upperBound = min(lowerBound + CampusAIAttachmentProtocol.chunkSize, draft.data.count)
        let chunk = draft.data.subdata(in: lowerBound..<upperBound)
        var request = URLRequest(url: plan.uploadURLs[part])
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("PUT", forHTTPHeaderField: "X-HTTP-Method-Override")
        request.httpBody = chunk
        task = session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self = self, !self.completed else { return }
                guard error == nil else { self.finish(.failure(.network)); return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    self.finish(.failure(status == 401 || status == 403 ? .platformRejected : .network))
                    return
                }
                self.upload(plan: plan, draft: draft, part: part + 1)
            }
        }
        task?.resume()
    }

    private func merge(plan: CampusAIUploadPlan, draft: CampusAIAttachmentDraft) {
        guard let body = CampusAIAttachmentProtocol.mergeBody(
            uploadID: plan.uploadID, fileName: plan.fileName, folder: plan.folder
        ) else {
            finish(.failure(.invalidResponse))
            return
        }
        performJSON(path: "common/merge", body: body) { [weak self] result in
            guard let self = self, !self.completed else { return }
            guard case .success(let data) = result else { self.finishWith(result); return }
            guard let storedFile = CampusAIAttachmentProtocol.storedFile(from: data),
                  let body = CampusAIAttachmentProtocol.extractBody(file: storedFile, draft: draft) else {
                self.finish(.failure(.invalidResponse))
                return
            }
            self.extract(storedFile: storedFile, draft: draft, body: body)
        }
    }

    private func extract(storedFile: CampusAIStoredFile, draft: CampusAIAttachmentDraft, body: Data) {
        performJSON(path: "chat/extractFile", body: body) { [weak self] result in
            guard let self = self, !self.completed else { return }
            guard case .success(let data) = result else { self.finishWith(result); return }
            guard let content = CampusAIAttachmentProtocol.extractedContent(from: data) else {
                self.finish(.failure(.invalidResponse))
                return
            }
            self.uploadedFiles.append(CampusAIUploadedAttachment(
                originalFileName: draft.originalFileName,
                totalSize: draft.data.count,
                uid: draft.uid,
                downloadURL: storedFile.downloadURL,
                fullPath: storedFile.fullPath,
                content: content
            ))
            self.fileIndex += 1
            self.uploadNextFile()
        }
    }

    private func saveAttachmentMessage() {
        guard let body = CampusAIRequestBuilder.chatSaveBody(
            text: question, agentID: agentID, groupID: existingGroupID,
            title: files.first?.originalFileName
        ) else {
            finish(.failure(.invalidResponse))
            return
        }
        onProgress("附件已上传，正在保存消息信息…")
        performJSON(path: "chat/save", body: body) { [weak self] result in
            guard let self = self, !self.completed else { return }
            guard case .success(let data) = result else { self.finishWith(result); return }
            guard let ids = CampusAIChatSaveResponse.identifiers(from: data, expectedGroupID: self.existingGroupID),
                  let fileListBody = CampusAIAttachmentProtocol.saveFileListBody(
                    files: self.uploadedFiles, groupID: ids.groupID, chatID: ids.chatID
                  ) else {
                self.finish(.failure(.invalidResponse))
                return
            }
            self.saveFileList(body: fileListBody, identifiers: ids)
        }
    }

    private func saveFileList(body: Data, identifiers: CampusAIChatSaveIdentifiers) {
        performJSON(path: "chat/saveFileList", body: body) { [weak self] result in
            guard let self = self, !self.completed else { return }
            guard case .success(let data) = result else { self.finishWith(result); return }
            guard CampusAIAttachmentProtocol.businessSucceeded(from: data) else {
                self.finish(.failure(.invalidResponse))
                return
            }
            let text = CampusAIAttachmentProtocol.chatText(question: self.question, files: self.uploadedFiles)
            self.finish(.success((identifiers, text)))
        }
    }

    private func performJSON(path: String, body: Data,
                             completion: @escaping (Result<Data, Failure>) -> Void) {
        let fullPath = "/api/af-api-agent/\(path)"
        let requestCookies = CampusAIEndpoint.cookies(from: cookies, requestPath: fullPath)
        guard let aiFlowCookie = CampusAIEndpoint.aiFlowCookie(from: requestCookies),
              let url = URL(string: path, relativeTo: CampusAIEndpoint.api)?.absoluteURL else {
            completion(.failure(.platformRejected))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(aiFlowCookie.value, forHTTPHeaderField: "aiflow")
        if let referer = referer, referer.host?.lowercased() == CampusAIEndpoint.host {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let cookieHeader = CampusAIEndpoint.cookieHeader(from: requestCookies) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        request.httpBody = body
        task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self, !self.completed else { return }
                if error != nil {
                    completion(.failure(.network))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    completion(.failure(status == 401 || status == 403 ? .platformRejected : .network))
                    return
                }
                guard let data = data else {
                    completion(.failure(.invalidResponse))
                    return
                }
                completion(.success(data))
            }
        }
        task?.resume()
    }

    private func finishWith(_ result: Result<Data, Failure>) {
        if case .failure(let failure) = result {
            finish(.failure(failure))
        } else {
            finish(.failure(.invalidResponse))
        }
    }

    private func finish(_ result: Result<(CampusAIChatSaveIdentifiers, String), Failure>) {
        guard !completed else { return }
        completed = true
        task = nil
        session.finishTasksAndInvalidate()
        completion(result)
    }
}
