import Foundation
@testable import MeetingLive
import AgentServices

@MainActor
private final class ResumptionSocket: LiveSocket {
    var messages: [Result<Data, Error>] = []
    var waiter: CheckedContinuation<Data, Error>?
    var setups: [[String: Any]] = []
    var rejectResume = false
    var holdSetup = false
    func push(_ object: [String: Any]) throws { deliver(.success(try JSONSerialization.data(withJSONObject: object))) }
    func deliver(_ result: Result<Data, Error>) {
        if let waiter { self.waiter = nil; waiter.resume(with: result) }
        else { messages.append(result) }
    }
    func send(_ data: Data) async throws {
        guard let setup = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["setup"] as? [String: Any] else { return }
        setups.append(setup)
        if holdSetup { return }
        if rejectResume, (setup["sessionResumption"] as? [String: Any])?["handle"] != nil { try push(["error": ["code": 400]]) }
        else { try push(["setupComplete": [:]]) }
    }
    func receive() async throws -> Data {
        if !messages.isEmpty { return try messages.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func cancel() { waiter?.resume(throwing: LiveClientError.disconnected); waiter = nil }
}

private final class ResumptionHTTP: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "resumption.fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"context\":\"fixture context\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private func waitForResume(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(3)) }
    throw URLError(.timedOut)
}

@MainActor
func runLiveResumptionChecks() async throws {
    var sockets: [ResumptionSocket] = []
    let client = GeminiLiveClient(socketFactory: { _ in let socket = ResumptionSocket(); sockets.append(socket); return socket })
    var turns = 0, interruptions = 0, errors = 0, audio = 0
    client.onTurnComplete = { turns += 1 }; client.onInterrupted = { interruptions += 1 }
    client.onError = { _ in errors += 1 }; client.onAudio = { _, _ in audio += 1 }
    try await client.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "original context")
    expectNotNil(sockets[0].setups[0]["sessionResumption"])
    try sockets[0].push(["sessionResumptionUpdate": ["resumable": true, "newHandle": "fixture-handle-one"]])
    try sockets[0].push(["sessionResumptionUpdate": ["resumable": false]])
    try sockets[0].push(["goAway": ["timeLeft": "60s"]])
    try sockets[0].push(["serverContent": ["turnComplete": true, "modelTurn": ["parts": [["inlineData": ["mimeType": "audio/pcm;rate=24000", "data": "AAA="]]]]]])
    try await waitForResume { turns == 1 }
    expectTrue(client.isConnected); expectEqual(audio, 1); expectEqual(interruptions, 0); expectEqual(errors, 0)
    sockets[0].deliver(.failure(LiveClientError.connectionFailed))
    try await waitForResume { errors == 1 }
    expectEqual(interruptions, 0)
    try await client.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "new transcript context")
    expectEqual((sockets[1].setups[0]["sessionResumption"] as? [String: String])?["handle"], "fixture-handle-one")
    let original = sockets[1].setups[0]["systemInstruction"] as? [String: [[String: String]]]
    expectEqual(original?["parts"]?.first?["text"], "original context")
    client.disconnect()
    try await client.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "next recording")
    expectTrue((sockets[2].setups[0]["sessionResumption"] as? [String: String])?.isEmpty == true)
    client.disconnect()

    // A rejected resume handle falls back once without destroying the caller's lifecycle.
    sockets = []; errors = 0; turns = 0
    let fallback = GeminiLiveClient(socketFactory: { _ in
        let socket = ResumptionSocket(); socket.rejectResume = sockets.count == 1; sockets.append(socket); return socket
    })
    fallback.onError = { _ in errors += 1 }; fallback.onTurnComplete = { turns += 1 }
    try await fallback.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "old")
    try sockets[0].push(["sessionResumptionUpdate": ["resumable": true, "newHandle": "fixture-expired-handle"]])
    try sockets[0].push(["serverContent": ["turnComplete": true]])
    try await waitForResume { turns == 1 }
    fallback.suspend()
    try await fallback.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "fresh transcript")
    expectEqual(sockets.count, 3); expectEqual(errors, 0); expectTrue(fallback.isConnected)
    expectTrue((sockets[2].setups[0]["sessionResumption"] as? [String: String])?.isEmpty == true)
    fallback.disconnect()

    // Stopping a suspended setup must not silently open a replacement connection.
    sockets = []; turns = 0
    let stopped = GeminiLiveClient(socketFactory: { _ in
        let socket = ResumptionSocket(); socket.holdSetup = sockets.count == 1; sockets.append(socket); return socket
    })
    stopped.onTurnComplete = { turns += 1 }
    try await stopped.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "same")
    try sockets[0].push(["sessionResumptionUpdate": ["resumable": true, "newHandle": "fixture-stop-handle"]])
    try sockets[0].push(["serverContent": ["turnComplete": true]])
    try await waitForResume { turns == 1 }
    stopped.suspend()
    let attempt = Task { try await stopped.connect(apiKey: "fixture-key", model: "gemini-3.8-live", instructions: "same") }
    try await waitForResume { sockets.count == 2 && !sockets[1].setups.isEmpty }
    stopped.disconnect()
    do { try await attempt.value; expectTrue(false) } catch { expectEqual(error as? LiveClientError, .disconnected) }
    expectEqual(sockets.count, 2); expectFalse(stopped.isConnected)

    // Exercise the actual AgentSession path: renewal keeps recording and queued playback;
    // ending recording clears the handle before the next recording starts.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ResumptionHTTP.self]
    let bridge = try BridgeClient(endpoint: "https://resumption.fixture.invalid", token: "fixture", session: URLSession(configuration: configuration))
    sockets = []; var clients = 0; var playbackStops = 0
    let session = AgentSession(root: root, bridge: bridge, voiceFactory: { _, _ in
        clients += 1
        return GeminiLiveClient(socketFactory: { _ in let socket = ResumptionSocket(); sockets.append(socket); return socket })
    }, automaticMaintenance: false, nativeTranscription: false)
    session.settings.voice = .gemini; session.settings.liveConversation = true
    session.settings.geminiOnDemand = false
    session.onInterrupt = { playbackStops += 1 }
    try await session.start(); try await waitForResume { session.connected }
    try sockets[0].push(["sessionResumptionUpdate": ["resumable": true, "newHandle": "fixture-agent-handle"]])
    try sockets[0].push(["serverContent": ["turnComplete": true]])
    // FIFO processing barrier before the simulated transport failure.
    try await Task.sleep(for: .milliseconds(30))
    sockets[0].deliver(.failure(LiveClientError.connectionFailed))
    try await waitForResume { !session.connected }
    expectTrue(session.recording); expectEqual(playbackStops, 0)
    await session.connectVoice()
    expectTrue(session.connected); expectEqual(clients, 1); expectTrue(session.error == nil)
    expectEqual((sockets[1].setups[0]["sessionResumption"] as? [String: String])?["handle"], "fixture-agent-handle")
    await session.stop()
    expectGreaterThan(playbackStops, 0)
    try await session.start(); try await waitForResume { session.connected }
    expectEqual(clients, 2)
    expectTrue((sockets[2].setups[0]["sessionResumption"] as? [String: String])?.isEmpty == true)
    await session.stop()
}
