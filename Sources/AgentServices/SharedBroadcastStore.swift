import Foundation
import Security

/// Keychain sharing works with the Personal Team profile's keychain wildcard; no App Group is required.
/// Only this app and its signed broadcast extension receive the shared access-group entitlement.
public enum SharedBroadcastStore {
    private static let service = "local.agentlive.broadcast"
    private static var group: String? { Bundle.main.object(forInfoDictionaryKey: "AgentLiveKeychainGroup") as? String }
    private static func query(_ name: String) -> [String: Any]? {
        guard let group, !group.isEmpty, !group.contains("$(") else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: name, kSecAttrAccessGroup as String: group]
    }
    public static func read(_ name: String) -> [String: Any]? {
        guard var query = query(name) else { return nil }
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count <= 16_384 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    public static func save(_ value: [String: Any], name: String) throws {
        guard let query = query(name) else { throw BridgeError.missingCredential }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard data.count <= 16_384 else { throw BridgeError.malformedResponse }
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound { code = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard code == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
    }
    public static func remove(_ name: String) { if let query = query(name) { SecItemDelete(query as CFDictionary) } }
}
