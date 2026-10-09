import Foundation
import AgentServices
import MeetingLive

private let spokenWakeForms = [
    "J EVこんにちは短くして", "J EVこんにちは返事して", "ジェブこんにちは返事して",
    "こんにちはJev返事して", "こんにちはJ EV返事して", "こんにちはJ E V返事して",
    "こんにちはジェブ返事して", "こんにちは返事して", "こんにちは全部返事して",
    "こんにちはJA部返事して", "こんにちはジョブ返事して", "こんにちはジェイプ返事して",
    "ジブ、聞こえますか", "こんにちは、Ｊ Ｅ Ｖ、短く返事して"
]

@MainActor func wakeRecognitionChecks() async throws {
    for text in spokenWakeForms {
        check(CompanionAddressing.requestsReply(text), "Recorded greeting is a direct reply request: " + text)
        check(GeminiCallIntent.parse(text) == .request, "The same greeting opens an on-demand Gemini call: " + text)
    }
    for text in ["全部", "こんにちは全部まとめて", "ジョブの設定を読む", "ジェブの話をしていた",
                 "こんにちはジェブの話をしていた", "「こんにちはJ EV返事して」と引用",
                 "こんにちはJev返事してって言う例", "友達に返事して"] {
        check(!CompanionAddressing.requestsReply(text), "Background mentions and quoted requests cannot bypass Jev: " + text)
        check(GeminiCallIntent.parse(text) == .none, "Background speech does not connect Gemini: " + text)
    }
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CompanionFixture.self]
    let bridge = try BridgeClient(endpoint: "https://wake.fixture.invalid", token: "fixture", session: URLSession(configuration: config))
    let session = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    session.settings = AgentSettings(); session.settings.voice = .hermes; session.settings.agentProvider = .nous
    session.settings.agentModel = "fixture-model"; session.settings.liveConversation = false
    session.settings.automaticDrafts = false
    CompanionFixture.lock.withLock { CompanionFixture.speakScore = 0.1 }
    defer { CompanionFixture.lock.withLock { CompanionFixture.speakScore = 0.95 } }
    try await session.start()
    for (index, text) in spokenWakeForms.enumerated() {
        let count = session.entries.filter { $0.source == "assistant" && $0.final }.count
        session.acceptTranscript(text, id: "wake-normal-\(index)", final: false)
        check(session.entries.filter { $0.source == "assistant" && $0.final }.count == count, "A partial greeting cannot start a reply")
        session.acceptTranscript(text, id: "wake-normal-\(index)", final: true)
        try await waitUntil { session.entries.filter { $0.source == "assistant" && $0.final }.count == count + 1 && !session.reacting }
    }
    check(!session.agentBusy, "Reply recognition does not authorize automatic work")
    await session.stop()

    let fastRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: fastRoot) }
    let fastConfig = URLSessionConfiguration.ephemeral; fastConfig.protocolClasses = [FastModeFixture.self]
    let fastBridge = try BridgeClient(endpoint: "https://wake-fast.fixture.invalid", token: "fixture", session: URLSession(configuration: fastConfig))
    let fast = AgentSession(root: fastRoot, bridge: fastBridge, automaticMaintenance: false, nativeTranscription: false)
    fast.settings = session.settings; fast.settings.economyFastMode = true
    FastModeFixture.lock.withLock { FastModeFixture.speakScore = 0.1; FastModeFixture.draftScore = 0 }
    defer { FastModeFixture.lock.withLock { FastModeFixture.speakScore = 0.95; FastModeFixture.draftScore = 0.95 } }
    try await fast.start()
    for (index, text) in spokenWakeForms.enumerated() {
        let count = fast.entries.filter { $0.source == "assistant" && $0.final }.count
        fast.acceptTranscript(text, id: "wake-fast-\(index)", final: true)
        try await waitUntil { fast.entries.filter { $0.source == "assistant" && $0.final }.count == count + 1 }
        FastModeFixture.releaseJudges()
        try await waitUntil { !fast.reacting }
    }
    check(!fast.agentBusy, "Repeated fast replies do not expand the action boundary")
    await fast.stop()

    let callRoot = temporaryRoot(); defer { try? FileManager.default.removeItem(at: callRoot) }
    var clients: [FixtureLive] = []
    let gemini = AgentSession(root: callRoot, bridge: fastBridge, voiceFactory: { _, _ in
        let client = FixtureLive(); clients.append(client); return client
    }, automaticMaintenance: false, nativeTranscription: false)
    gemini.settings = AgentSettings(); gemini.settings.companionEnabled = false
    try await gemini.start()
    for (index, text) in spokenWakeForms.enumerated() {
        gemini.acceptTranscript(text, id: "wake-gemini-\(index)", final: true)
        try await waitUntil { clients.count == index + 1 && clients[index].connecting }
        clients[index].release()
        try await waitUntil { gemini.connected && clients[index].texts == [text] }
        gemini.endGeminiCall()
    }
    check(gemini.recording && clients.count == spokenWakeForms.count, "Repeated Gemini calls survive the previous call ending")
    await gemini.stop()
}
