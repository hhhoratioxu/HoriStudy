import Foundation
import Security

enum KeychainStore {
    static let service = "com.hhhoratioxu.HoriStudy.openai"
    static func read() throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else {
            throw StudyError.message("无法读取钥匙串中的 API 密钥（\(status)）。")
        }
        return text
    }
    static func save(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
        if key.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw StudyError.message("无法移除钥匙串密钥（\(status)）。")
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(key.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
                throw StudyError.message("无法将 API 密钥保存到钥匙串。")
            }
        } else if status != errSecSuccess { throw StudyError.message("无法更新钥匙串密钥（\(status)）。") }
    }
}
