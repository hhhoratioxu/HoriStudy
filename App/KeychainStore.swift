import Foundation
import Security

enum KeychainStore {
    static func contains(scope: CredentialScope) throws -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.service, kSecAttrAccount as String: scope.account,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw StudyError.message("无法读取钥匙串状态（\(status)）。") }
        return true
    }
    static func read(scope: CredentialScope) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.service, kSecAttrAccount as String: scope.account,
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
    static func save(_ key: String, scope: CredentialScope) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: scope.service, kSecAttrAccount as String: scope.account]
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
