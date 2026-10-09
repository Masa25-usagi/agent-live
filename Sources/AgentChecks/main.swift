import Foundation
import AgentServices
import MeetingLive
import MeetingCore
@preconcurrency import AVFoundation
import CoreImage

var failures = 0
var checkSettings = AgentSettings.load()
let originalSettings = UserDefaults.standard.data(forKey: "agent-live.settings")
defer {
    if let originalSettings { UserDefaults.standard.set(originalSettings, forKey: "agent-live.settings") }
    else { UserDefaults.standard.removeObject(forKey: "agent-live.settings") }
}
checkSettings.companionEnabled = false; checkSettings.save()
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { failures += 1; print("FAIL: " + message) } }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
do {
    let archive = try RecordingArchive(root: root)
    archive.segmentSeconds = 0.01
    try archive.start(sessionID: "test-session")
    try archive.appendAudio(Data(repeating: 1, count: 1000), source: "microphone")
    try archive.appendTranscript(text: "保存前には消さない", source: "user", final: true)
    try archive.finish()
    check(archive.pending().filter { $0.kind == "audio" }.count == 4, "Audio crossing boundaries is preserved")
    let audio = archive.pending().filter { $0.kind == "audio" }
    check(audio.reduce(0) { $0 + $1.bytes - 44 } == 1000, "No input sample is lost when rotating")
    let reloaded = try RecordingArchive(root: root)
    check(reloaded.pending().count == archive.pending().count, "Pending uploads survive restart")
    let first = audio[0]
    do { try reloaded.verifyAndEvict(id: first.id, sha256: "wrong", fileID: "file"); check(false, "Wrong receipt rejected") } catch {}
    check(FileManager.default.fileExists(atPath: reloaded.file(for: first).path), "Wrong receipt keeps original")
    try reloaded.verifyAndEvict(id: first.id, sha256: first.sha256, fileID: "verified-file")
    check(!FileManager.default.fileExists(atPath: reloaded.file(for: first).path), "Verified copy releases local storage")
    check(reloaded.inventory.first { $0.id == first.id }?.cloudVerified == true, "Receipt is durable")
    reloaded.maximumPendingBytes = reloaded.pendingBytes
    try reloaded.start()
    do { try reloaded.appendAudio(Data(repeating: 0, count: 2), source: "microphone"); check(false, "Pending capacity enforced") } catch {}
    print("Archive checks: \(failures) failures")
} catch { failures += 1; print("FAIL: \(error.localizedDescription)") }


func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
func recoveryChecks() throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info: [String: Any] = ["id": "interrupted", "sessionID": "original-session", "source": "microphone", "rate": 16000, "startedAt": 100]
    try JSONSerialization.data(withJSONObject: info).write(to: root.appendingPathComponent("interrupted.recovery.json"))
    try (RecordingArchive.wavHeader(bytes: 0, rate: 16000) + Data([1, 2, 3, 4, 5])).write(to: root.appendingPathComponent("interrupted.wav.part"))
    let archive = try RecordingArchive(root: root)
    check(archive.pending().first?.bytes == 48, "Crash recovery preserves complete PCM16 samples")
    check(archive.pending().first?.sessionID == "original-session", "Crash recovery preserves session identity")
    let item = archive.pending()[0], destination = try RecordingArchive(root: temporaryRoot())
    defer { try? FileManager.default.removeItem(at: destination.root) }
    try destination.adopt(item, from: archive.file(for: item))
    check(destination.pending()[0].id == item.id, "ReplayKit adoption preserves the server upload identifier")
    var confirmed = destination.inventory
    confirmed[0].cloudVerified = true; confirmed[0].cloudFileID = "drive-file"
    try JSONEncoder().encode(confirmed).write(to: destination.root.appendingPathComponent("index.json"), options: .atomic)
    let resumed = try RecordingArchive(root: destination.root)
    check(!FileManager.default.fileExists(atPath: resumed.file(for: item).path), "Restart completes deletion after a persisted verified receipt")
    try Data("broken".utf8).write(to: destination.root.appendingPathComponent("index.json"))
    do { _ = try RecordingArchive(root: destination.root); check(false, "A corrupt index must not be silently replaced") } catch {}

    let retryRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: retryRoot) }
    let retry = try RecordingArchive(root: retryRoot)
    try retry.start(sessionID: "retry-seal"); try retry.appendAudio(Data(repeating: 0, count: 200), source: "microphone")
    let blocked = retryRoot.appendingPathComponent("index.json")
    try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
    do { try retry.finish(); check(false, "Injected index write failure must surface") } catch {}
    try FileManager.default.removeItem(at: blocked); try retry.finish()
    let retried = try RecordingArchive(root: retryRoot)
    check(retried.pending().first?.bytes == 244, "Sealing retries after rename and index write failure")
    let fullRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: fullRoot) }
    let full = try RecordingArchive(root: fullRoot); full.segmentSeconds = 0.01; full.maximumPendingBytes = 1000; try full.start()
    do { try full.appendAudio(Data(repeating: 0, count: 1000), source: "mic"); check(false, "Segment headers count toward the storage limit") } catch {}
}
func pcm(_ samples: [Int16]) -> Data { samples.reduce(into: Data()) { data, sample in var value = sample.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } } }
func mixerChecks() {
    var mixer = LiveInputMixer(); mixer.appendRemote(pcm([30000, -30000]))
    let output = mixer.mixMicrophone(pcm([30000, -30000]))
    check(output == pcm([30000, -30000]), "Mixing preserves duration and avoids clipping")
    mixer.appendRemote(Data(repeating: 0, count: 64000))
    check(mixer.mixMicrophone(pcm([1000])).count == 2, "Remote backlog cannot stretch mic-clock duration")
    check(mixer.mixMicrophone(Data([1])).isEmpty, "Malformed PCM cannot read beyond its buffer")
}
func interruptionChecks() {
    var capture = AudioCaptureLifecycle()
    check(!capture.interruptionBegan(), "A permission alert before microphone activation is not reported as a recording interruption")
    capture.started()
    check(capture.interruptionBegan() && capture.state.paused, "A running capture enters the interrupted state")
    check(!capture.interruptionEnded(shouldResume: false) && capture.state == .resumeRequired, "A system refusal to auto-resume offers explicit recovery")
    capture.resumed()
    check(capture.state == .recording, "Successful manual recovery restores capture")
    _ = capture.interruptionBegan()
    check(capture.interruptionEnded(shouldResume: true), "A resumable interruption requests capture and playback recovery")
    capture.stopped()
    check(!capture.interruptionEnded(shouldResume: true) && !capture.state.paused, "A late end notification never restarts stopped recording")
}
func speechAudioChecks() throws {
    let samples = pcm(Array(repeating: Int16(1000), count: 1600))
    let wave = RecordingArchive.wavHeader(bytes: samples.count, rate: 16_000) + samples
    check(EncodedSpeechAudio.fileExtension(for: wave) == "wav" && EncodedSpeechAudio.mimeType(for: wave) == "audio/wav", "A WAV speech response keeps its container rather than being mislabeled MP3")
    let decoded = try EncodedSpeechAudio.decode(wave)
    check((4400...5000).contains(decoded.count), "Provider WAV is converted to 24 kHz mono PCM without losing its duration")
    check(decoded.withUnsafeBytes { abs(Int($0.loadUnaligned(fromByteOffset: decoded.count / 4 * 2, as: Int16.self))) > 500 }, "Provider speech remains audible after conversion")
    do { _ = try EncodedSpeechAudio.decode(Data("invalid audio".utf8)); check(false, "Malformed speech cannot be scheduled for playback") } catch {}
}

final class FixtureURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var outageUploads = 0
    static var workPosts: [[String: String]] = []
    static var workCompleted = false
    static var workResult = "Fixture work result"
    static var workStops = 0
    static var admissionFailures = 0
    static var workspacePaths: [String] = []
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096), collected = Data()
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; collected.append(contentsOf: bytes.prefix(count)) }
            data = collected
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var status = 200, value = "{\"context\":\"Fixture memory\"}"
        if request.url?.path == "/settings/economy" {
            value = String(data: try! JSONSerialization.data(withJSONObject: ["enabled": Self.body(request)["enabled"] as? Bool ?? true]), encoding: .utf8)!
        }
        if request.url?.host == "timeout.fixture.invalid" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        if request.url?.host == "outage.fixture.invalid" {
            if request.url?.path == "/transcribe" { status = 503; value = "{}" }
            else if request.httpMethod == "PUT" { Self.lock.withLock { Self.outageUploads += 1 }; status = 201; value = "{\"exists\":true,\"cloud_verified\":false}" }
            else { value = "{\"exists\":false,\"status\":\"pending\"}" }
        }
        if request.url?.host == "work.fixture.invalid" {
            let payload = Self.body(request), path = request.url!.path
            var object: [String: Any] = [:]
            Self.lock.withLock {
                if path == "/agent" {
                    Self.workPosts.append(payload.compactMapValues { $0 as? String })
                    if Self.admissionFailures > 0 { Self.admissionFailures -= 1; status = 503 }
                    else { status = 202; object = ["status": "running"] }
                } else if path.hasPrefix("/agent/status/") {
                    let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "request_id" }?.value ?? ""
                    object = ["status": Self.workCompleted ? "completed" : "running", "text": Self.workResult, "request_id": id]
                } else if path == "/agent/stop" { Self.workStops += 1; object = ["stop_requested": true] }
                else if path.hasPrefix("/workspaces/") {
                    Self.workspacePaths.append(path)
                    object = ["files": [["name": "index.html", "path": "/artifacts/" + path.split(separator: "/").last! + "/index.html", "ticket": "fixture-ticket"]]]
                }
            }
            value = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        let data = Data(value.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor func waitUntil(_ predicate: () -> Bool, line: Int = #line) async throws {
    for _ in 0..<700 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
    check(false, "Timed out waiting for fixture lifecycle at line \(line)")
}
@MainActor func workLifecycleChecks() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
    let bridge = try BridgeClient(endpoint: "https://work.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    session.settings.companionEnabled = false
    session.settings.agentProvider = .current; session.settings.agentModel = ""
    session.settings.liveConversation = false
    try await session.start(); let workSession = session.sessionID
    session.beginWork("作業を続けてください")
    try await waitUntil { FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts.count == 1 } }
    await session.stop()
    check(session.agentBusy, "Stopping recording keeps Hermes work running")
    try await session.start()
    check(session.agentBusy && session.sessionID != workSession, "Starting a new recording preserves the original work identity")
    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workCompleted = true }
    try await waitUntil { !session.agentBusy && !session.artifacts.isEmpty }
    check(session.agentResult == "Fixture work result", "Work completes after recording was stopped and restarted")
    check(session.artifacts[0].url.path.contains(workSession), "Artifacts stay attached to the original work session")
    await session.stop()
    let restored = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    restored.settings.companionEnabled = false
    check(restored.agentResult == "Fixture work result" && !restored.recording, "The last result survives reopening without starting recording")
    await restored.refreshArtifacts()
    check(restored.artifacts.first?.url.path.contains(workSession) == true, "Reopened artifact links use their saved work session")

    let pendingRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: pendingRoot) }
    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workCompleted = false; FixtureURLProtocol.workPosts = []; FixtureURLProtocol.workspacePaths = [] }
    var original: AgentSession? = AgentSession(root: pendingRoot, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    original?.settings.companionEnabled = false
    original?.settings.agentProvider = .grok; original?.settings.agentModel = "grok-fixture"
    original?.settings.speechProvider = .edge
    original?.beginWork("再接続する同じ作業")
    try await waitUntil { FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts.count == 1 } }
    let initial = FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts[0] }
    check(initial["provider"] == "xai-oauth" && initial["model"] == "grok-fixture", "The admitted request contains the selected subscription and model")
    original = nil
    let reopened = AgentSession(root: pendingRoot, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    reopened.settings.companionEnabled = false
    reopened.settings.agentProvider = .nous; reopened.settings.agentModel = "nous-fixture"
    reopened.beginWork("元の依頼を上書きしてはいけない")
    reopened.resumeWork()
    try await waitUntil { FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts.count >= 2 } }
    let retry = FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts[1] }
    check(initial == retry, "Reopening reuses the request ID, input, session and pinned model after settings changed")
    check(!reopened.recording, "Resuming work does not activate microphone recording")
    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workCompleted = true; FixtureURLProtocol.workResult = "Recovered result" }
    try await waitUntil { !reopened.agentBusy }
    check(reopened.agentResult == "Recovered result" && !FileManager.default.fileExists(atPath: pendingRoot.appendingPathComponent("active-work.json").path), "Recovered completion replaces the persisted pending request")

    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workCompleted = false; FixtureURLProtocol.workPosts = [] }
    reopened.beginWork("停止される作業")
    try await waitUntil { FixtureURLProtocol.lock.withLock { !FixtureURLProtocol.workPosts.isEmpty } }
    reopened.stopWork()
    try await waitUntil { FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workStops > 0 } }
    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workCompleted = true; FixtureURLProtocol.workResult = "Obsolete result" }
    try await Task.sleep(for: .milliseconds(40))
    check(!reopened.agentBusy && reopened.agentResult == "Recovered result", "Explicit work cancellation rejects obsolete results")

    FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts = []; FixtureURLProtocol.admissionFailures = 1; FixtureURLProtocol.workResult = "Retry result" }
    let result = try await bridge.agent(input: "Same input", sessionID: "retry-session", requestID: "retry-key")
    let posts = FixtureURLProtocol.lock.withLock { FixtureURLProtocol.workPosts }
    check(result == "Retry result" && posts.count == 2 && posts[0] == posts[1], "A transient admission error retries the exact same request")
}
@MainActor final class FixtureLive: LiveConversationProvider {
    var onAudio: ((Data, Double) -> Void)?; var onText: ((String) -> Void)?; var onInputTranscript: ((String, String, Bool) -> Void)?
    var onInterrupted: (() -> Void)?; var onError: ((String) -> Void)?; var onTurnComplete: (() -> Void)?; var onToolCall: ((String, [String: Any], String) -> Void)?
    var connecting = false; var gate: CheckedContinuation<Void, Never>?; var disconnected = false; var model = ""
    func connect(apiKey: String, model: String, instructions: String) async throws { self.model = model; connecting = true; await withCheckedContinuation { gate = $0 } }
    func release() { gate?.resume(); gate = nil }
    var texts: [String] = []
    func sendAudio(_ data: Data) async throws {}; func sendFrame(_ jpeg: Data) async throws {}; func sendText(_ text: String) async throws { texts.append(text) }
    func sendToolResponse(callId: String, name: String, response: [String: Any]) async throws {}
    func disconnect() { disconnected = true }
}
func settingsChecks() throws {
    let legacy: [String: Any] = ["endpoint": "https://legacy.fixture.invalid", "voice": "grok", "liveConversation": false,
        "recordVideo": true, "autoRecord": true, "autoResearch": true, "offlineMegabytes": 1024]
    let migrated = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
    check(migrated.endpoint == "https://legacy.fixture.invalid" && migrated.voice == .grok && !migrated.liveConversation, "New settings preserve legacy pairing and voice preferences")
    check(migrated.recordVideo && migrated.autoRecord && migrated.autoResearch && migrated.offlineMegabytes == 1024, "Legacy capture settings survive migration")
    check(migrated.agentProvider == .current && migrated.agentModel.isEmpty && migrated.speechProvider == .automatic && migrated.selectedVoiceModel == "grok-voice-latest", "Missing fields get defaults without resetting existing settings")
    var settings = migrated; settings.voiceModels = ["gemini": "gemini-fixture", "grok": "grok-voice-latest"]
    settings.agentProvider = .nous; settings.agentModel = "nous-fixture"; settings.speechProvider = .nous
    let restored = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings))
    check(restored.voiceModels == settings.voiceModels && restored.agentModel == "nous-fixture" && restored.speechProvider == .nous, "All model selections survive reopening")
}
@MainActor func hotSwitchChecks() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
    let bridge = try BridgeClient(endpoint: "https://fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    var clients: [FixtureLive] = [], requests: [URLRequest] = []
    let session = AgentSession(root: root, bridge: bridge, voiceFactory: { _, request in let client = FixtureLive(); clients.append(client); requests.append(request); return client }, automaticMaintenance: false, nativeTranscription: false)
    session.settings.companionEnabled = false
    session.settings = AgentSettings(); session.settings.companionEnabled = false
    session.settings.geminiOnDemand = false // This fixture exercises transport switching, independent of call gating.
    try await session.start(); let id = session.sessionID
    try await waitUntil { clients.count == 1 && clients[0].connecting }
    let obsoleteText = clients[0].onText, obsoleteAudio = clients[0].onAudio
    session.acceptAudio(pcm([100, 200]))
    session.selectVoiceModel("gemini-fixture")
    try await waitUntil { clients.count == 2 && clients[1].connecting }
    clients[0].release(); obsoleteText?("obsolete"); obsoleteAudio?(pcm([300]), 24000)
    try await Task.sleep(for: .milliseconds(20))
    check(session.recording && !session.connected && session.connecting && session.entries.isEmpty, "Changing a model during setup rejects the previous connection and callbacks")
    clients[1].release(); try await waitUntil { session.connected }
    check(clients[1].model == "gemini-fixture", "Reconnection uses the selected Live model")
    await session.saveCostSettings(enabled: false)
    try await waitUntil { clients.count == 3 && clients[2].connecting }
    check(!session.costSaving && session.recording && session.sessionID == id, "Economy mode can change while the same recording continues")
    clients[2].release(); try await waitUntil { session.connected }
    session.acceptAudio(pcm([300, 400])); session.selectVoice(.hermes)
    try await waitUntil { session.settings.voice == .hermes && session.conversationEnabled && !session.connected }
    check(session.conversationEnabled && session.recording && !session.connected, "Hermes conversation remains enabled without pretending to be a Live connection")
    var speechInterrupts = 0; session.onInterrupt = { speechInterrupts += 1 }
    await session.saveCostSettings(enabled: true)
    check(speechInterrupts == 0 && session.recording, "Economy changes leave an existing Hermes speech reply playing")
    await session.toggleConversation()
    check(!session.settings.liveConversation && !session.conversationEnabled && session.recording, "Hermes voice can be turned off without stopping recording")
    session.selectVoice(.grok); session.setConversationEnabled(true)
    try await waitUntil { clients.count == 4 && clients[3].connecting }
    check(clients[3].model == "grok-voice-latest" && requests[3].url?.query?.contains("grok-voice-latest") == true, "Grok Voice uses its own model and forwards that model to the relay")
    clients[3].release(); try await waitUntil { session.connected }
    session.acceptAudio(pcm([500, 600])); await session.stop()
    let audio = session.archive.pending().filter { $0.kind == "audio" && $0.source == "microphone" }
    let saved = try audio.reduce(into: Data()) { output, item in output.append(try Data(contentsOf: session.archive.file(for: item)).dropFirst(44)) }
    check(session.sessionID == id && saved == pcm([100, 200, 300, 400, 500, 600]), "Voice, model and economy switching preserve every original recording sample")
    let timeoutBridge = try BridgeClient(endpoint: "https://timeout.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let timeoutRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: timeoutRoot) }
    let timedOut = AgentSession(root: timeoutRoot, bridge: timeoutBridge, automaticMaintenance: false, nativeTranscription: false)
    timedOut.settings.companionEnabled = false
    await timedOut.checkConnection()
    check(timedOut.error?.contains("Tailscale") == true && timedOut.error?.contains("タイムアウト") == true, "Timeouts explain how to restore connectivity in Japanese")
}
@MainActor func sessionChecks() async throws {
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
    let bridge = try BridgeClient(endpoint: "https://fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let live = FixtureLive()
    let session = AgentSession(root: root, bridge: bridge, voiceFactory: { _, _ in live }, automaticMaintenance: false, nativeTranscription: false)
    session.settings.companionEnabled = false
    session.settings.voice = .gemini; session.settings.liveConversation = true
    session.settings.geminiOnDemand = false
    try await session.start()
    for _ in 0..<100 where !live.connecting { try await Task.sleep(for: .milliseconds(5)) }
    check(live.connecting, "A recording starts its live connection")
    let lateAudio = live.onAudio, lateText = live.onText
    await session.stop(); live.release()
    try await Task.sleep(for: .milliseconds(20))
    lateAudio?(pcm([1000]), 24000); lateText?("obsolete response")
    check(!session.recording && !session.connected && !session.connecting, "Stopping during setup cannot revive the session")
    check(session.entries.isEmpty && session.archive.pending().isEmpty, "Old audio and text callbacks cannot change a stopped archive")
    check(live.disconnected, "The stopped provider is disconnected")

    let offlineRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: offlineRoot) }
    let offlineBridge = try BridgeClient(endpoint: "https://outage.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let offline = AgentSession(root: offlineRoot, bridge: offlineBridge, automaticMaintenance: false, nativeTranscription: false)
    offline.settings.companionEnabled = false
    offline.settings.liveConversation = false
    try await offline.start(); offline.acceptAudio(pcm([1000, 2000])); await offline.stop()
    await offline.synchronizeNow()
    check(FixtureURLProtocol.lock.withLock { FixtureURLProtocol.outageUploads } == 1, "STT failure does not block uploading the original audio")
    check(offline.archive.pending().count == 1 && FileManager.default.fileExists(atPath: offline.archive.file(for: offline.archive.pending()[0]).path), "An unverified cloud receipt keeps the original on device")
}
final class VideoResults: @unchecked Sendable {
    let lock = NSLock(); var files: [URL] = []; var errors: [String] = []
    func add(_ url: URL) { lock.withLock { files.append(url) } }
    func error(_ text: String) { lock.withLock { errors.append(text) } }
}
func videoChecks() async throws {
    let directory = temporaryRoot(); defer { try? FileManager.default.removeItem(at: directory) }
    let results = VideoResults()
    let encoder = try VideoSegmentEncoder(directory: directory, onSegment: { file, _, _ in results.add(file) }, onError: results.error)
    var pixel: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess, let pixel else { throw ArchiveError.invalidAudio }
    CIContext().render(CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: pixel)
    for i in 0...42 { encoder.append(pixel, at: CMTime(seconds: Double(i) / 2, preferredTimescale: 600)) }
    await withCheckedContinuation { continuation in encoder.finish { continuation.resume() } }
    let files = results.lock.withLock { results.files }, errors = results.lock.withLock { results.errors }
    check(errors.isEmpty && files.count == 2, "Video chunks finalize and all callbacks finish before ownership is released")
    for file in files {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first, let format = try await track.load(.formatDescriptions).first else { check(false, "Recorded video can be opened"); continue }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        check(max(dimensions.width, dimensions.height) <= 720, "Screen recording has bounded video dimensions")
        let duration = try await asset.load(.duration)
        check(CMTimeGetSeconds(duration) > 0, "Sealed MP4 has a playable timeline")
    }
}


final class CompanionFixture: URLProtocol {
    static let lock = NSLock()
    static var judgments = 0
    static var admissions: [[String: String]] = []
    static var stopped = 0
    static var holdVoiceReply = false
    static var speakScore = 0.95
    static var judgeUnavailable = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path, body = FixtureURLProtocol.body(request)
        var object: [String: Any] = [:], status = 200
        Self.lock.withLock {
            if path == "/companion/judge" {
                Self.judgments += 1
                if Self.judgeUnavailable { status = 503 }
                else { object = ["scores": ["speak": Self.speakScore, "draft": 0.95, "research": 0.0, "memory": 0.0, "unsafe": 0.0, "stop": 0.0]] }
            } else if path == "/agent" {
                Self.admissions.append(body.compactMapValues { $0 as? String }); status = 202; object = ["status": "running"]
            } else if path.hasPrefix("/agent/status/") {
                let session = path.split(separator: "/").last.map(String.init) ?? ""
                let requestID = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "request_id" }?.value ?? ""
                let policy = session.hasPrefix("rules-")
                object = ["status": policy || (session.hasSuffix("-voice") && !Self.holdVoiceReply) ? "completed" : "running", "request_id": requestID,
                          "text": policy ? String(decoding: try! JSONSerialization.data(withJSONObject: CompanionPolicy.baseline(objective: "試作").dictionary), as: UTF8.self) : "短い返答です。"]
            } else if path == "/agent/stop" { Self.stopped += 1; object = ["stop_requested": true] }
            else if path == "/tts" { object = ["audio": Data("fixture audio".utf8).base64EncodedString()] }
            else if path == "/context" { object = ["context": ""] }
        }
        let data = (try! JSONSerialization.data(withJSONObject: object)) + Data([10])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@MainActor func companionChecks() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionFixture.self]
    let bridge = try BridgeClient(endpoint: "https://companion.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let session = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    session.settings.companionEnabled = false
    session.settings.voice = .hermes; session.settings.companionEnabled = true; session.settings.agentProvider = .nous
    session.settings.agentModel = "fixture-model"; session.settings.liveConversation = true; session.settings.automaticDrafts = true
    var spoken = 0; session.onEncodedAudio = { _ in spoken += 1 }
    try await session.start(); try await waitUntil { session.behaviorPolicy != nil }
    session.acceptTranscript("小さい時計", id: "turn1", final: false)
    try await Task.sleep(for: .milliseconds(20))
    check(CompanionFixture.lock.withLock { CompanionFixture.judgments == 0 }, "Partial captions never trigger Jev or automatic work")
    session.acceptTranscript("小さい時計を作りたい", id: "turn1", final: true)
    session.acceptTranscript("小さい時計を作りたい", id: "turn1", final: true)
    try await waitUntil { session.agentBusy && spoken == 1 }
    check(CompanionFixture.lock.withLock { CompanionFixture.judgments == 1 }, "The finalized utterance is judged once")
    session.acceptTranscript("時計の色も変えたい", id: "turn2", final: true)
    try await waitUntil { spoken == 2 }
    check(session.agentBusy, "A short spoken response completes while the long draft remains running")
    let queued = root.appendingPathComponent("queued-work.json")
    check(FileManager.default.fileExists(atPath: queued.path), "A second automatic request is persisted while Hermes is busy")
    let admitted = CompanionFixture.lock.withLock { CompanionFixture.admissions }
    check(admitted.filter { $0["purpose"] == "draft" }.count == 1 && admitted.filter { $0["purpose"] == "reply" }.count == 2, "Voice replies use their own conversation and do not drop while work is running")
    CompanionFixture.lock.withLock { CompanionFixture.holdVoiceReply = true }
    session.acceptTranscript("時計の数字を大きくして", id: "turn3", final: true)
    try await waitUntil { CompanionFixture.lock.withLock { CompanionFixture.admissions.filter { $0["purpose"] == "reply" }.count == 3 } }
    session.acceptTranscript("もう一つ", id: "turn4", final: false)
    CompanionFixture.lock.withLock { CompanionFixture.holdVoiceReply = false }
    try await waitUntil { !session.reacting }
    check(spoken == 2, "A new partial utterance suppresses a stale voice response still being generated")
    session.acceptTranscript("もう一つ時計を作りたい", id: "turn4", final: true)
    try await waitUntil { spoken == 3 }
    session.stopWork(); check(!FileManager.default.fileExists(atPath: queued.path), "Stop discards queued automatic work durably")
    let beforeMutedReply = session.entries.filter { $0.source == "assistant" }.count
    session.settings.automaticDrafts = false
    session.setConversationEnabled(false)
    session.acceptTranscript("ジェブ、こんにちは", id: "muted1", final: true)
    try await waitUntil { session.entries.filter { $0.source == "assistant" }.count == beforeMutedReply + 1 }
    check(spoken == 3 && !session.settings.liveConversation, "A muted subscription conversation returns text without playing TTS")
    CompanionFixture.lock.withLock { CompanionFixture.holdVoiceReply = true }
    session.setConversationEnabled(true)
    session.acceptTranscript("短く返事して", id: "muted2", final: true)
    try await waitUntil { CompanionFixture.lock.withLock { CompanionFixture.admissions.filter { $0["purpose"] == "reply" }.count == 6 } }
    session.setConversationEnabled(false)
    CompanionFixture.lock.withLock { CompanionFixture.holdVoiceReply = false }
    try await waitUntil { session.entries.filter { $0.source == "assistant" }.count == beforeMutedReply + 2 }
    check(spoken == 3, "Muting while Hermes generates preserves its text reply and suppresses pending speech")
    let beforeDirectReplies = session.entries.filter { $0.source == "assistant" }.count
    CompanionFixture.lock.withLock { CompanionFixture.speakScore = 0.1 }
    session.acceptTranscript("ジェブこんにちは。短く返事して", id: "wake-low", final: true)
    try await waitUntil { session.entries.filter { $0.source == "assistant" }.count == beforeDirectReplies + 1 }
    let beforeBackground = CompanionFixture.lock.withLock { CompanionFixture.judgments }
    session.acceptTranscript("ジェブについて書かれたメモ", id: "background-low", final: true)
    try await waitUntil { CompanionFixture.lock.withLock { CompanionFixture.judgments > beforeBackground } && !session.reacting }
    check(session.entries.filter { $0.source == "assistant" }.count == beforeDirectReplies + 1, "A background mention still uses Jev's response decision")
    session.sendText("こんにちは")
    try await waitUntil { session.entries.filter { $0.source == "assistant" }.count == beforeDirectReplies + 2 }
    let beforeOutageDrafts = CompanionFixture.lock.withLock { CompanionFixture.admissions.filter { $0["purpose"] == "draft" }.count }
    session.settings.automaticDrafts = true
    CompanionFixture.lock.withLock { CompanionFixture.judgeUnavailable = true }
    session.acceptTranscript("ねえ、ジェブ、こんにちは", id: "wake-outage", final: true)
    try await waitUntil { session.entries.filter { $0.source == "assistant" }.count == beforeDirectReplies + 3 }
    check(CompanionFixture.lock.withLock { CompanionFixture.admissions.filter { $0["purpose"] == "draft" }.count == beforeOutageDrafts }, "An explicit reply during a Jev outage grants no automatic work")
    check(spoken == 3, "Direct text answers preserve voice-off even when Jev is unavailable")
    CompanionFixture.lock.withLock { CompanionFixture.speakScore = 0.95; CompanionFixture.judgeUnavailable = false }
    await session.stop()
    check(!session.recording && !session.reacting, "Stopping recording cancels the immediate reaction lifecycle")
    let scores: [String: Any] = ["speak": 1.0, "draft": 1.0, "research": 0.0, "memory": 0.0, "unsafe": true, "stop": 0.0]
    do { _ = try CompanionJudgment(["scores": scores], allowDrafts: true); check(false, "Boolean probability rejected") } catch {}
    let unsafe: [String: Double] = ["speak": 0.8, "draft": 1, "research": 1, "memory": 1, "unsafe": 0.95, "stop": 0]
    let unsafeJudgment = try CompanionJudgment(["scores": unsafe], allowDrafts: true)
    check(unsafeJudgment.action == nil, "An unsafe request may be discussed but never starts automatic work")
    check(CompanionAddressing.requestsReply("Ｊｅｖ, hello") && CompanionAddressing.requestsReply("ジェブこんにちは"), "Direct addressing recognizes speech without inserted punctuation")
    check(!CompanionAddressing.requestsReply("「ジェブ、こんにちは」と引用") && !CompanionAddressing.requestsReply("ジェブの話をしていた"), "Quotes and third-person mentions are not direct reply requests")
}

do { try settingsChecks(); try recoveryChecks(); mixerChecks(); interruptionChecks(); try speechAudioChecks(); try await sessionChecks(); try await hotSwitchChecks(); try await workLifecycleChecks(); try await companionChecks(); try fastPolicyChecks(); try await fastModeChecks(); try await geminiCallChecks(); try await videoChecks(); try await connectionSettingsChecks(); try await wakeRecognitionChecks() }
catch { failures += 1; print("FAIL: extended checks: \(error)") }
print("Agent checks complete: \(failures) failures")
exit(failures == 0 ? 0 : 1)
