import Foundation
import AgentServices

final class SettingsFixture: URLProtocol {
    static let lock = NSLock()
    static var models: [SettingsFixture] = [], costs: [SettingsFixture] = []
    static var modelRequests = 0, holdCost = false, failCost = false
    static var costValues: [Bool] = []
    static var failJudge = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch request.url!.path {
        case "/models": Self.lock.withLock { Self.models.append(self); Self.modelRequests += 1 }
        case "/settings/economy":
            let value = FixtureURLProtocol.body(request)["enabled"] as? Bool ?? true
            let decision = Self.lock.withLock { () -> (Bool, Bool) in
                Self.costValues.append(value)
                if Self.holdCost { Self.costs.append(self) }
                return (Self.holdCost, Self.failCost)
            }
            if decision.0 { return }
            if decision.1 { fail() } else { deliver(["enabled": value]) }
        case "/health": deliver(["agent": true, "economy": ["enabled": true]])
        case "/companion/judge":
            if Self.lock.withLock({ Self.failJudge }) { fail() }
            else { deliver(["scores": Dictionary(uniqueKeysWithValues: ["speak", "draft", "research", "memory", "unsafe", "stop"].map { ($0, 0.0) })]) }
        default: deliver([:])
        }
    }
    func fail() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    func deliver(_ value: [String: Any]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func releaseModels(failed: Bool = false) {
        let list = lock.withLock { let value = models; models = []; return value }
        for item in list {
            if failed { item.fail() } else {
                let ids = ["z-ai/glm-5.2", "deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash:US"]
                item.deliver(["providers": [["id": "nous", "title": "Nous", "ready": true,
                                            "models": ids.map { ["id": $0, "title": $0] }]], "live": [:]])
            }
        }
    }
    static func releaseCosts() {
        let list = lock.withLock { holdCost = false; let value = costs; costs = []; return value }
        for item in list { item.deliver(["enabled": FixtureURLProtocol.body(item.request)["enabled"] as? Bool ?? true]) }
    }
}

@MainActor func connectionSettingsChecks() async throws {
    let saved = UserDefaults.standard.data(forKey: "agent-live.settings")
    defer { if let saved { UserDefaults.standard.set(saved, forKey: "agent-live.settings") } else { UserDefaults.standard.removeObject(forKey: "agent-live.settings") } }
    let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SettingsFixture.self]
    let bridge = try BridgeClient(endpoint: "https://settings.fixture.invalid", token: "synthetic", session: URLSession(configuration: config))
    let session = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    SettingsFixture.lock.withLock { SettingsFixture.models = []; SettingsFixture.costs = []; SettingsFixture.modelRequests = 0; SettingsFixture.holdCost = false; SettingsFixture.failCost = false; SettingsFixture.costValues = [] }
    let first = Task { await session.loadModels() }
    try await waitUntil { SettingsFixture.lock.withLock { SettingsFixture.modelRequests == 1 } }
    first.cancel() // Leaving settings while opening the model screen must not cancel shared discovery.
    let second = Task { await session.loadModels() }
    SettingsFixture.releaseModels(); await first.value; await second.value
    check(session.catalog?.providers.first?.models.count == 3 && SettingsFixture.lock.withLock { SettingsFixture.modelRequests == 1 }, "Delayed model discovery survives navigation and includes DeepSeek and its US variant")
    let restored = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    check(restored.catalog?.providers.first?.models.last?.id == "deepseek/deepseek-v4.1-flash:US", "The complete model catalog survives offline reopening")
    let otherBridge = try BridgeClient(endpoint: "https://other-settings.fixture.invalid", token: "synthetic", session: URLSession(configuration: config))
    let other = AgentSession(root: root, bridge: otherBridge, automaticMaintenance: false, nativeTranscription: false)
    check(other.catalog == nil, "A different host cannot inherit another host's model catalog")
    let refresh = Task { await session.loadModels(refresh: true) }
    try await waitUntil { SettingsFixture.lock.withLock { SettingsFixture.modelRequests == 2 } }
    SettingsFixture.releaseModels(failed: true); await refresh.value
    check(session.catalog?.providers.first?.models.count == 3 && !session.modelMessage.isEmpty, "Failed refresh preserves useful candidates and reports the connection issue")

    SettingsFixture.lock.withLock { SettingsFixture.failCost = true }
    await session.saveCostSettings(enabled: false)
    check(!session.costSaving && !session.savingCostSettings && session.settings.pendingEconomyUpdates[bridge.baseURL.absoluteString] == false, "Offline economy toggle changes immediately, persists its intent and releases the control")
    let costRestored = AgentSession(root: root, bridge: bridge, automaticMaintenance: false, nativeTranscription: false)
    check(!costRestored.costSaving, "Offline economy intent survives reopening")
    await session.checkConnection()
    check(!session.costSaving && session.settings.pendingEconomyUpdates[bridge.baseURL.absoluteString] == false, "An old server economy value cannot overwrite a pending user preference")
    SettingsFixture.lock.withLock { SettingsFixture.failCost = false }
    await session.checkConnection()
    check(!session.costSaving && session.settings.pendingEconomyUpdates[bridge.baseURL.absoluteString] == nil && session.costSettingStatus.contains("反映済み"), "Recovered connection applies the saved economy preference")

    SettingsFixture.lock.withLock { SettingsFixture.holdCost = true; SettingsFixture.costValues = [] }
    let saving = Task { await session.saveCostSettings(enabled: false) }
    try await waitUntil { SettingsFixture.lock.withLock { !SettingsFixture.costs.isEmpty } }
    await session.saveCostSettings(enabled: true)
    check(session.costSaving, "A second toggle remains usable while the previous save is pending")
    SettingsFixture.releaseCosts(); await saving.value
    check(session.costSaving && session.settings.pendingEconomyUpdates[bridge.baseURL.absoluteString] == nil && SettingsFixture.lock.withLock { SettingsFixture.costValues == [false, true] }, "Outdated acknowledgments cannot undo the latest economy choice")
    check(bridge.request("settings/economy", method: "POST").timeoutInterval == 6, "Offline settings do not wait the 150-second archive timeout")
    check(BridgeClient.companionFailureMessage(URLError(.timedOut)).contains("Tailscale"), "A transport outage is explained as connectivity rather than broken Jev authentication")
    session.settings.voice = .hermes; session.settings.liveConversation = false
    session.settings.companionEnabled = true; session.settings.economyFastMode = false
    session.settings.automaticDrafts = false; session.settings.directJev = false
    SettingsFixture.lock.withLock { SettingsFixture.failJudge = true }
    try await session.start()
    session.acceptTranscript("背景の会話です", id: "offline-background", final: true)
    try await waitUntil { !session.reacting && session.error != nil }
    check(session.error?.contains("Tailscale") == true, "An offline judgment exposes the transport cause")
    SettingsFixture.lock.withLock { SettingsFixture.failJudge = false }
    session.acceptTranscript("別の背景の会話です", id: "recovered-background", final: true)
    try await waitUntil { !session.reacting && session.error == nil }
    check(session.recording, "Successful recovered judgment clears only its stale error while keeping recording")
    await session.stop()
}
