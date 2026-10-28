import Foundation
import Security

/// 极简 Keychain 封装：只存账号 token（敏感信息不落 UserDefaults）
enum Keychain {
    // Preserve existing production credentials; isolate only explicitly configured UI tests.
    private static let service: String = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VOCAB_UI_TEST_API"] == "http://127.0.0.1:18765" {
            return Bundle.main.bundleIdentifier ?? "com.zorro.vocab"
        }
        #endif
        return "com.zorro.vocab"
    }()
    @discardableResult
    static func save(_ value: String, for key: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        // Update in place so a failed replacement does not first destroy the old item.
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update != errSecItemNotFound { return update }
        var item = query
        item[kSecValueData as String] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return added
    }

    static func load(_ key: String) -> String? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
