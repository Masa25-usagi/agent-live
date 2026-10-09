import Foundation
import CoreFoundation

public struct BridgeConfiguration: Codable, Sendable {
    public var endpoint: String
    public init(endpoint: String = "http://127.0.0.1:8787") { self.endpoint = endpoint }
}

public enum BridgeError: LocalizedError {
    case invalidURL, rejected(Int), missingCredential, malformedResponse, agentEnded(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "接続先のURLを確認してください。"
        case .rejected(let code): return "サーバーへの接続を確認してください（\(code)）。記録は端末に残っています。"
        case .missingCredential: return "サーバーと接続してください。"
        case .malformedResponse: return "サーバーの応答を確認できませんでした。"
        case .agentEnded(let status): return status == "failed" ? "エージェントの作業が失敗しました。記録は残っています。" : "エージェントの作業は停止しています。"
        }
    }
}

public final class BridgeClient: @unchecked Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession
    private let syncLock = NSLock()
    private var receiptChecks: [String: Date] = [:]
    public init(endpoint: String, token: String, session: URLSession = .shared) throws {
        guard let url = URL(string: endpoint), ["https", "http"].contains(url.scheme), url.host != nil else { throw BridgeError.invalidURL }
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw BridgeError.missingCredential }
        self.baseURL = url; self.token = token; self.session = session
    }
    public func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = path == "health" ? 12 : path == "context" ? 8 : path == "companion/judge" ? 12 : path == "models" ? 35 : (path.hasPrefix("agent") || path.hasPrefix("live/")) ? 20 : 150
        return request
    }
    public static func connectionMessage(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            switch value.code {
            case NSURLErrorTimedOut:
                return "サーバーへの接続がタイムアウトしました。iPhoneのTailscaleと、選択したサーバーの電源・ネット接続を確認してください。記録は端末に残しています。"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "サーバーへ接続できません。Tailscaleとサーバーの起動状態を確認してください。音声の記録は端末で続けられます。"
            case NSURLErrorBadServerResponse:
                return "音声サービスの接続を確認できませんでした。設定でサービス・モデルとサーバーの接続を確認してください。音声の記録は続けています。"
            default: break
            }
        }
        return error.localizedDescription
    }
    public static func connectionMessage(_ message: String) -> String {
        if message.lowercased().contains("timed out") { return connectionMessage(URLError(.timedOut)) }
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost, .badServerResponse] {
            if URLError(code).localizedDescription == message { return connectionMessage(URLError(code)) }
        }
        return message
    }
    public func json(_ path: String, method: String = "GET", body: [String: Any]? = nil, query: [URLQueryItem]? = nil) async throws -> [String: Any] {
        var req = request(path, method: method)
        if let query, var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false) {
            components.queryItems = query; req.url = components.url
        }
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: req)
        try check(response)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BridgeError.malformedResponse }
        return result
    }
    public func transcribe(file: URL) async throws -> String {
        var req = request("transcribe", method: "POST"); req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        let (data, response) = try await session.upload(for: req, fromFile: file); try check(response)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let text = result["text"] as? String else { throw BridgeError.malformedResponse }
        return text
    }
    public func geminiCredential(model: String) async throws -> String {
        let value = try await json("live/gemini/credential", method: "POST", body: ["model": model])
        guard let key = value["token"] as? String, key.hasPrefix("auth_tokens/"), key.utf8.count <= 8192, value["model"] as? String == model else { throw BridgeError.malformedResponse }
        return key
    }
    public func companionJudge(_ payload: [String: Any], direct: Bool, hostMode: String) async throws -> [String: Any] {
        guard direct else { return try await json("companion/judge", method: "POST", body: payload) }
        guard baseURL.scheme == "https" || ["localhost", "127.0.0.1"].contains(baseURL.host) else { throw BridgeError.invalidURL }
        let credentialName = "jev:" + baseURL.absoluteString
        let manifest: [String: Any]
        if let saved = DeviceCredential.read(credentialName), let data = saved.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { manifest = object }
        else {
            manifest = try await json("companion/client-credential", method: "POST", body: [:])
            let data = try JSONSerialization.data(withJSONObject: manifest)
            try DeviceCredential.save(String(decoding: data, as: UTF8.self), name: credentialName)
        }
        guard let key = manifest["key"] as? String, !key.isEmpty, !key.contains("\n"), !key.contains("\r"),
              let model = manifest["model"] as? String, let questions = manifest["questions"] as? [String: Any], questions.count == 6,
              let text = payload["text"] as? String, text.count <= 8000, let policy = payload["policy"] as? [String: Any] else { throw BridgeError.malformedResponse }
        let state: [String: Any] = ["latest_utterance": text, "context": payload["context"] as? String ?? "", "policy": policy, "host_mode": hostMode]
        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, timeoutInterval: 8)
        req.httpMethod = "POST"; req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": questions])
        // The device key must not follow an HTTP redirect to another origin.
        let redirectSafe = URLSession(configuration: .ephemeral, delegate: NoCredentialRedirect(), delegateQueue: nil)
        defer { redirectSafe.invalidateAndCancel() }
        let (data, response) = try await redirectSafe.data(for: req)
        if let http = response as? HTTPURLResponse, [401, 403].contains(http.statusCode) { try? DeviceCredential.save("", name: credentialName) }
        try check(response)
        guard data.count <= 131_072, let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], let answers = result["answers"] as? [String: Any] else { throw BridgeError.malformedResponse }
        var scores: [String: Double] = [:]
        for name in ["speak", "draft", "research", "memory", "unsafe", "stop"] {
            guard let row = answers[name] as? [String: Any], row["type"] as? String == "noul", let value = row["noul"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, (0...1).contains(value.doubleValue) else { throw BridgeError.malformedResponse }
            scores[name] = value.doubleValue
        }
        return ["scores": scores, "judge": "jev", "transport": "device"]
    }
    @MainActor public func agent(input: String, sessionID: String, purpose: String = "think", requestID: String = UUID().uuidString, provider: String? = nil, model: String? = nil, frameSessionID: String? = nil, onProgress: (String) -> Void = { _ in }) async throws -> String {
        var admission: [String: Any] = ["input": input, "session_id": sessionID, "purpose": purpose, "request_id": requestID, "background": true]
        if let provider, !provider.isEmpty { admission["provider"] = provider }
        if let model, !model.isEmpty { admission["model"] = model }
        if let frameSessionID { admission["frame_session"] = frameSessionID }
        while true {
            try Task.checkCancellation()
            do {
                _ = try await json("agent", method: "POST", body: admission)
                break
            } catch {
                try Task.checkCancellation()
                guard Self.isTransient(error) else { throw error }
                onProgress("接続の回復を待っています。同じ依頼IDで再接続します。")
                try await Task.sleep(for: .seconds(5))
            }
        }
        while true {
            try Task.checkCancellation()
            let result: [String: Any]
            do { result = try await json("agent/status/" + sessionID, query: [URLQueryItem(name: "request_id", value: requestID)]) }
            catch {
                try Task.checkCancellation()
                guard Self.isTransient(error) else { throw error }
                onProgress("接続の回復を待っています。作業IDはサーバーに保存済みです。")
                try await Task.sleep(for: .seconds(5)); continue
            }
            if let responseID = result["request_id"] as? String, responseID != requestID { throw BridgeError.malformedResponse }
            let status = result["status"] as? String ?? ""
            if status == "completed" {
                guard let text = result["text"] as? String else { throw BridgeError.malformedResponse }
                return text
            }
            if ["failed", "cancelled", "stopped", "interrupted"].contains(status) { throw BridgeError.agentEnded(status) }
            onProgress(["awaiting_approval", "waiting_for_approval", "needs_attention"].contains(status) ? "Hermesで確認待ちです。必要なら作業を止められます。" : "エージェントが進めています")
            try await Task.sleep(for: .seconds(2))
        }
    }
    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? BridgeError, case .rejected(let code) = error { return [502, 503, 504].contains(code) }
        return (error as NSError).domain == NSURLErrorDomain
    }
    public func stopAgent(sessionID: String, requestID: String? = nil) async throws {
        var body = ["session_id": sessionID]; if let requestID { body["request_id"] = requestID }
        _ = try await json("agent/stop", method: "POST", body: body)
    }
    @MainActor public func streamReply(text: String, context: String, policy: CompanionPolicy, provider: String, model: String, frameSessionID: String? = nil, onDelta: (String) throws -> Void) async throws {
        var body: [String: Any] = ["text": text, "context": String(context.suffix(4_000)), "persona": policy.persona, "objective": policy.objective,
                                   "provider": provider, "model": model]
        if let frameSessionID { body["frame_session"] = frameSessionID }
        var req = request("conversation/reply", method: "POST"); req.timeoutInterval = 45
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: req); try check(response)
        var done = false, count = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 131_072, let data = line.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], event["error"] == nil else { throw BridgeError.malformedResponse }
            if let delta = event["delta"] as? String {
                count += delta.count; guard count <= 6000 else { throw BridgeError.malformedResponse }
                try onDelta(delta)
            } else if event["done"] as? Bool == true { done = true }
            else { throw BridgeError.malformedResponse }
        }
        try Task.checkCancellation()
        guard done, count > 0 else { throw BridgeError.malformedResponse }
    }
    @MainActor public func streamSpeak(_ text: String, provider: String? = nil, onPart: (Data) throws -> Void) async throws {
        var body = ["text": text]; if let provider, !provider.isEmpty { body["provider"] = provider }
        var req = request("tts", method: "POST"); req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: req); try check(response)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8), let part = try JSONSerialization.jsonObject(with: data) as? [String: Any], let encoded = part["audio"] as? String, let audio = Data(base64Encoded: encoded) else { throw BridgeError.malformedResponse }
            try onPart(audio)
        }
    }
    public func liveRequest(provider: String, sessionID: String? = nil, model: String? = nil) -> URLRequest {
        var req = request("live/" + provider)
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        var query: [URLQueryItem] = []
        if let sessionID { query.append(URLQueryItem(name: "session", value: sessionID)) }
        if let model, !model.isEmpty { query.append(URLQueryItem(name: "model", value: model)) }
        components.queryItems = query
        req.url = components.url
        return req
    }
    public func sendFrame(_ jpeg: Data, sessionID: String) async throws {
        var req = request("frame/" + sessionID, method: "POST"); req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: req, from: jpeg); try check(response)
    }
    public func latestFrame(sessionID: String) async throws -> Data {
        var req = request("frame/" + sessionID); req.timeoutInterval = 8
        let (data, response) = try await session.data(for: req); try check(response)
        guard data.count <= 2_000_000, data.starts(with: [0xff, 0xd8, 0xff]) else { throw BridgeError.malformedResponse }
        return data
    }
    public func synchronize(_ archive: RecordingArchive) async throws -> Int {
        var evicted = 0
        let checks = syncLock.withLock { receiptChecks }, now = Date()
        let pending = archive.pending().filter { checks[$0.id].map { now.timeIntervalSince($0) >= 30 } ?? true }
            .sorted { (checks[$0.id] ?? .distantPast) < (checks[$1.id] ?? .distantPast) }
        // New chunks take priority over repeated cloud receipt checks during long outages.
        for item in pending.prefix(24) {
            try Task.checkCancellation()
            let known = try await json("archive/" + item.id)
            var receipt = known
            if known["exists"] as? Bool != true {
                var req = request("archive/" + item.id, method: "PUT")
                req.setValue(item.mimeType, forHTTPHeaderField: "Content-Type")
                let metadata = try JSONEncoder().encode(item)
                req.setValue(metadata.base64EncodedString(), forHTTPHeaderField: "X-Archive-Metadata")
                let (data, response) = try await session.upload(for: req, fromFile: archive.file(for: item)); try check(response)
                receipt = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            syncLock.withLock { receiptChecks[item.id] = Date() }
            if receipt["cloud_verified"] as? Bool == true,
               let hash = receipt["sha256"] as? String, let fileID = receipt["cloud_file_id"] as? String {
                try archive.verifyAndEvict(id: item.id, sha256: hash, fileID: fileID); evicted += 1
                syncLock.withLock { _ = receiptChecks.removeValue(forKey: item.id) }
            }
        }
        return evicted
    }
    private func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw BridgeError.malformedResponse }
        guard (200..<300).contains(response.statusCode) else { throw BridgeError.rejected(response.statusCode) }
    }
}

private final class NoCredentialRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
