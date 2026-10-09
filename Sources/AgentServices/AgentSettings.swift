import Foundation
import Security
import CryptoKit
import MeetingLive

public enum AgentContainer {
    public static var groupIdentifier: String { Bundle.main.object(forInfoDictionaryKey: "AgentLiveAppGroup") as? String ?? "group.local.agentlive" }
    public static var broadcastIdentifier: String { Bundle.main.object(forInfoDictionaryKey: "AgentLiveBroadcastBundle") as? String ?? "local.agentlive.ios.broadcast" }
}

public enum VoiceProvider: String, Codable, CaseIterable, Identifiable {
    case gemini, openai, grok, hermes
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gemini: return "Gemini Live"; case .openai: return "GPT Realtime"; case .grok: return "Grok Voice（音声API）"; case .hermes: return "Hermes（サブスク対応）" }
    }
    public var seesImages: Bool { self == .gemini || self == .openai }
    public var defaultModel: String {
        switch self { case .gemini: return GeminiLiveClient.defaultModel; case .openai: return OpenAIRealtimeClient.defaultModel; case .grok: return "grok-voice-latest"; case .hermes: return "" }
    }
}

public enum AgentInferenceProvider: String, Codable, CaseIterable, Identifiable {
    case current = "", grok = "xai-oauth", nous = "nous"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .current: return "Hermesの現在の設定"; case .grok: return "Grok（サブスク）"; case .nous: return "Nous Portal（サブスク枠）" }
    }
}

public enum AgentSpeechProvider: String, Codable, CaseIterable, Identifiable {
    case automatic = "", edge = "edge", nous = "nous"
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: return "標準（日本語）"; case .edge: return "Edge（日本語）"; case .nous: return "Nous（サブスク枠）" }
    }
}

public struct ConversationModel: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}
public struct InferenceChoice: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let ready: Bool
    public let models: [ConversationModel]
    public let message: String?
}
public struct ConversationCatalog: Codable, Sendable {
    public let providers: [InferenceChoice]
    public let live: [String: [ConversationModel]]
}

public struct AgentSettings: Codable {
    public var endpoint = BridgeConfiguration().endpoint
    public var voice: VoiceProvider = .gemini
    public var liveConversation = true
    public var recordVideo = false
    public var autoRecord = false
    public var autoResearch = false
    public var offlineMegabytes = 512
    public var agentProvider: AgentInferenceProvider = .current
    public var agentModel = ""
    public var voiceModels: [String: String] = [:]
    public var speechProvider: AgentSpeechProvider = .automatic
    public var onDeviceTranscription = true
    public var economyFastMode = false
    public var directJev = false
    public var directGemini = false
    public var geminiFastMode = false
    public var geminiOnDemand = true
    public var geminiIdleSeconds: Double = 60
    public var companionEnabled = true
    public var automaticDrafts = true
    public var objective = "日々の会話を理解し、必要なときに短く助言し、調査や案・試作品の作成を手伝う"
    public var selectedVoiceModel: String { voiceModels[voice.rawValue] ?? voice.defaultModel }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case endpoint, voice, liveConversation, recordVideo, autoRecord, autoResearch, offlineMegabytes
        case agentProvider, agentModel, voiceModels, speechProvider
        case onDeviceTranscription, economyFastMode, directJev, directGemini, geminiFastMode, geminiOnDemand, geminiIdleSeconds, companionEnabled, automaticDrafts, objective
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        voice = try values.decodeIfPresent(VoiceProvider.self, forKey: .voice) ?? voice
        liveConversation = try values.decodeIfPresent(Bool.self, forKey: .liveConversation) ?? liveConversation
        recordVideo = try values.decodeIfPresent(Bool.self, forKey: .recordVideo) ?? recordVideo
        autoRecord = try values.decodeIfPresent(Bool.self, forKey: .autoRecord) ?? autoRecord
        autoResearch = try values.decodeIfPresent(Bool.self, forKey: .autoResearch) ?? autoResearch
        offlineMegabytes = try values.decodeIfPresent(Int.self, forKey: .offlineMegabytes) ?? offlineMegabytes
        agentProvider = try values.decodeIfPresent(AgentInferenceProvider.self, forKey: .agentProvider) ?? agentProvider
        agentModel = try values.decodeIfPresent(String.self, forKey: .agentModel) ?? agentModel
        voiceModels = try values.decodeIfPresent([String: String].self, forKey: .voiceModels) ?? voiceModels
        speechProvider = try values.decodeIfPresent(AgentSpeechProvider.self, forKey: .speechProvider) ?? speechProvider
        onDeviceTranscription = try values.decodeIfPresent(Bool.self, forKey: .onDeviceTranscription) ?? onDeviceTranscription
        economyFastMode = try values.decodeIfPresent(Bool.self, forKey: .economyFastMode) ?? economyFastMode
        directJev = try values.decodeIfPresent(Bool.self, forKey: .directJev) ?? directJev
        directGemini = try values.decodeIfPresent(Bool.self, forKey: .directGemini) ?? directGemini
        geminiFastMode = try values.decodeIfPresent(Bool.self, forKey: .geminiFastMode) ?? geminiFastMode
        geminiOnDemand = try values.decodeIfPresent(Bool.self, forKey: .geminiOnDemand) ?? geminiOnDemand
        geminiIdleSeconds = try values.decodeIfPresent(Double.self, forKey: .geminiIdleSeconds) ?? geminiIdleSeconds
        companionEnabled = try values.decodeIfPresent(Bool.self, forKey: .companionEnabled) ?? companionEnabled
        automaticDrafts = try values.decodeIfPresent(Bool.self, forKey: .automaticDrafts) ?? automaticDrafts
        objective = try values.decodeIfPresent(String.self, forKey: .objective) ?? objective
    }
    public static func load() -> AgentSettings {
        guard let data = UserDefaults.standard.data(forKey: "agent-live.settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    public func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "agent-live.settings") } }
}

/// iPhone keys remain accessible after first unlock. The ad-hoc Mac beta uses a private user file.
public enum DeviceCredential {
    private static let service = "local.agent-live.device"
    #if os(macOS)
    private static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AgentLive/Credentials", isDirectory: true) }
    private static func file(_ name: String) -> URL { directory.appendingPathComponent(SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined() + ".credential") }
    #endif
    public static func read(_ name: String = "bridge") -> String? {
        #if os(macOS)
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: name, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #endif
    }
    public static func save(_ value: String, name: String = "bridge") throws {
        #if os(macOS)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Data(value.utf8).write(to: file(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound { code = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
        #endif
    }
}
