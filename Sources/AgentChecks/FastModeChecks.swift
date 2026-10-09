import Foundation
import AgentServices
import MeetingLive

func fastPolicyChecks() throws {
    let boundary = UtteranceBoundary(fast: true)
    check(!boundary.shouldEnd(age: 1, silence: 0.1, unchanged: 0.1, hasText: true), "Fast endpoint preserves changing speech")
    check(boundary.shouldEnd(age: 2, silence: 0.5, unchanged: 0.3, hasText: true), "Fast endpoint ends a genuine pause")
    check(boundary.shouldEnd(age: 3, silence: 0.0, unchanged: 1.3, hasText: true), "Room noise cannot hold a stable caption for 35 seconds")
    check(!boundary.shouldEnd(age: 3, silence: 0, unchanged: 1.3, hasText: false), "No speculative action is derived from noise without words")
    var sentences = ReplySentences()
    check(sentences.append("こんにちは").isEmpty, "Speech never reads an unfinished tiny fragment")
    check(sentences.append("。次の文です！続き") == ["こんにちは。", "次の文です！"], "Streaming speech keeps complete sentences in order")
    check(sentences.append("", final: true) == ["続き"], "A trailing reply fragment is spoken exactly once")
    check(sentences.append("", final: true).isEmpty, "Finishing the reply twice does not duplicate speech")
    check(GeminiCallIntent.parse("ジェミニ、こんにちは") == .request, "A clear Gemini address opens a call")
    check(GeminiCallIntent.parse("ジェブ、教えて") == .request, "The companion name can open a Gemini call")
    for text in ["バイバイ", "さようなら", "切るね"] { check(GeminiCallIntent.parse(text) == .close, "Goodbye closes only the Gemini call") }
    check(GeminiCallIntent.parse("接続を切らないで、ずっとつないでおいて") == .keepOpen, "An explicit continuous-call instruction overrides idle closure")
    check(GeminiCallIntent.parse("「バイバイ」って言う例です") == .none, "Quoted goodbye is not a disconnect command")
    check(GeminiCallIntent.parse("接続を切ってはいけない") == .none, "A negated goodbye is not a disconnect command")
    var gate = DeviceSilenceGate()
    check(gate.feed(Data(repeating: 0, count: 32_000)).isEmpty, "Device-direct economy mode does not upload persistent silence")
    let speech = Data([0xff, 0x03])
    check(gate.feed(speech).compactMap { $0 }.reduce(0) { $0 + $1.count } == 9_602, "Device silence gating retains lead-in and quiet speech")
    check(gate.feed(Data(repeating: 0, count: 38_400)).filter { $0 == nil }.count == 1, "Device gate sends one ordered audioStreamEnd")
    let old = try JSONDecoder().decode(AgentSettings.self, from: Data("{}".utf8))
    check(!old.economyFastMode && !old.directJev && !old.directGemini && old.geminiOnDemand && old.geminiIdleSeconds == 60, "Migration keeps direct-key experiments opt-in and Gemini demand-connected")
}

final class FastModeFixture: URLProtocol {
    static let lock = NSLock()
    static var judges: [FastModeFixture] = [], replies: [FastModeFixture] = []
    static var replyCount = 0, draftCount = 0, ttsCount = 0
    static var holdReplies = false
    private var cancelled = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, body = FixtureURLProtocol.body(request)
        if path == "/companion/judge" { Self.lock.withLock { Self.judges.append(self) }; return }
        if path == "/conversation/reply" {
            let hold = Self.lock.withLock { Self.replyCount += 1; if Self.holdReplies { Self.replies.append(self) }; return Self.holdReplies }
            if !hold { deliver(Data("{\"delta\":\"速い返答です。\"}\n{\"done\":true}\n".utf8)) }; return
        }
        var object: [String: Any] = [:]
        if path == "/context" { object = ["context": ""] }
        if path == "/agent" { if body["purpose"] as? String == "draft" { Self.lock.withLock { Self.draftCount += 1 } }; object = ["status": "running"] }
        if path.hasPrefix("/agent/status/") {
            let policy = path.contains("rules-")
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "request_id" }?.value ?? ""
            object = ["status": policy ? "completed" : "running", "request_id": id,
                      "text": String(decoding: try! JSONSerialization.data(withJSONObject: CompanionPolicy.baseline(objective: "試作").dictionary), as: UTF8.self)]
        }
        if path == "/tts" { Self.lock.withLock { Self.ttsCount += 1 } }
        deliver(try! JSONSerialization.data(withJSONObject: object))
    }
    private func deliver(_ data: Data) {
        guard !Self.lock.withLock({ cancelled }) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    static func releaseJudges() {
        let pending = lock.withLock { let value = judges; judges = []; return value }
        let data = try! JSONSerialization.data(withJSONObject: ["scores": ["speak": 0.95, "draft": 0.95, "research": 0.0, "memory": 0.0, "unsafe": 0.0, "stop": 0.0]])
        pending.forEach { $0.deliver(data) }
    }
    static func releaseReplies() {
        let pending = lock.withLock { let value = replies; replies = []; return value }
        pending.forEach { $0.deliver(Data("{\"delta\":\"古い返答です。\"}\n{\"done\":true}\n".utf8)) }
    }
    override func stopLoading() { Self.lock.withLock { cancelled = true } }
}

@MainActor func fastModeChecks() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FastModeFixture.self]
    let bridge = try BridgeClient(endpoint: "https://fast.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let session = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    session.settings = AgentSettings(); session.settings.voice = .hermes; session.settings.agentProvider = .nous
    session.settings.agentModel = "fixture-model"; session.settings.economyFastMode = true; session.settings.liveConversation = false
    try await session.start(); try await waitUntil { session.behaviorPolicy != nil }
    session.acceptTranscript("ジェブ、こんにちは", id: "fast-turn", final: false)
    check(FastModeFixture.lock.withLock { FastModeFixture.replyCount == 0 && FastModeFixture.judges.isEmpty }, "Partial words cannot trigger a billed fast reply or Jev action")
    session.acceptTranscript("ジェブ、こんにちは", id: "fast-turn", final: true)
    session.acceptTranscript("ジェブ、こんにちは", id: "fast-turn", final: true)
    try await waitUntil { session.entries.contains { $0.source == "assistant" && $0.final } }
    check(FastModeFixture.lock.withLock { FastModeFixture.replyCount == 1 && FastModeFixture.draftCount == 0 && !FastModeFixture.judges.isEmpty }, "A single fast reply finishes before Jev, without admitting work early")
    FastModeFixture.releaseJudges()
    try await waitUntil { FastModeFixture.lock.withLock { FastModeFixture.draftCount == 1 } }
    check(FastModeFixture.lock.withLock { FastModeFixture.ttsCount == 0 }, "Fast text mode has no network TTS request")
    session.stopWork()
    FastModeFixture.lock.withLock { FastModeFixture.holdReplies = true }
    session.acceptTranscript("ジェブ、次の質問です", id: "obsolete-fast", final: true)
    try await waitUntil { FastModeFixture.lock.withLock { FastModeFixture.replyCount == 2 } }
    session.acceptTranscript("新しく話しています", id: "new-speaking", final: false)
    FastModeFixture.releaseReplies(); FastModeFixture.releaseJudges()
    try await Task.sleep(for: .milliseconds(50))
    check(!session.entries.contains { $0.text == "古い返答です。" }, "New speech rejects a late obsolete fast reply")
    let id = session.sessionID; session.setEconomyFastMode(false)
    check(session.recording && session.sessionID == id, "Fast mode can be disabled without ending the recording")
    await session.stop(); FastModeFixture.releaseJudges(); FastModeFixture.releaseReplies()
    FastModeFixture.lock.withLock { FastModeFixture.holdReplies = false }
}

@MainActor func geminiCallChecks() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FastModeFixture.self]
    let bridge = try BridgeClient(endpoint: "https://call.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    var clients: [FixtureLive] = []
    let session = AgentSession(root: root, bridge: bridge, voiceFactory: { _, _ in let value = FixtureLive(); clients.append(value); return value }, automaticMaintenance: false, nativeTranscription: false)
    session.settings = AgentSettings(); session.settings.companionEnabled = false
    try await session.start(); try await Task.sleep(for: .milliseconds(30))
    check(clients.isEmpty && session.recording && !session.geminiCallActive, "Starting recording does not connect to Gemini")
    session.acceptTranscript("ジェミニ、こんにちは", id: "call", final: false)
    check(clients.isEmpty, "An unstable partial does not open Gemini")
    session.acceptTranscript("ジェミニ、こんにちは", id: "call", final: true)
    try await waitUntil { clients.count == 1 && clients[0].connecting }; clients[0].release()
    try await waitUntil { session.connected && clients[0].texts.count == 1 }
    check(clients[0].texts == ["ジェミニ、こんにちは"], "The utterance that opened the call is sent once after setup")
    session.acceptTranscript("バイバイ", id: "bye", final: true)
    check(!session.geminiCallActive && clients[0].disconnected && session.recording, "Goodbye disconnects Gemini while preserving recording")
    session.startGeminiCall(); try await waitUntil { clients.count == 2 && clients[1].connecting }; clients[1].release()
    try await waitUntil { session.connected }
    session.checkGeminiIdle(now: Date().addingTimeInterval(61))
    check(!session.geminiCallActive && session.recording, "Idle Gemini is disconnected after the configured interval")
    session.acceptTranscript("接続を切らずにずっとつないでおいて", id: "continuous", final: true)
    try await waitUntil { clients.count == 3 && clients[2].connecting }; clients[2].release()
    try await waitUntil { session.connected }
    session.checkGeminiIdle(now: Date().addingTimeInterval(600))
    check(session.geminiCallActive && session.keepingGeminiConnected, "Explicit keep-open instruction prevents automatic idle hangup")
    session.acceptTranscript("切るね", id: "continuous-end", final: true)
    check(!session.geminiCallActive && !session.keepingGeminiConnected, "Goodbye resets the continuous-call exception")
    session.settings.companionEnabled = true
    session.acceptTranscript("必要な質問ですか？", id: "late-question", final: true)
    try await waitUntil { FastModeFixture.lock.withLock { !FastModeFixture.judges.isEmpty } }
    session.acceptTranscript("さようなら", id: "late-bye", final: true)
    FastModeFixture.releaseJudges(); try await Task.sleep(for: .milliseconds(50))
    check(!session.geminiCallActive && clients.count == 3, "Delayed Jev judgment cannot reopen a call after goodbye")
    await session.stop()
}
