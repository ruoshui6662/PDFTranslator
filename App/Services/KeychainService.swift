import Foundation
import Security

/// Stores and retrieves API Keys securely in macOS Keychain Services.
/// API Keys are never written to `UserDefaults` or logs.
public enum KeychainService {
    private static let serviceName = "com.pdftranslator.app.apikeys"

    public static func saveAPIKey(_ key: String, for providerID: String) -> Bool {
        let account = "provider.\(providerID)"
        let data = Data(key.utf8)

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }

    public static func loadAPIKey(for providerID: String) -> String? {
        let account = "provider.\(providerID)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // ad-hoc 签名没有稳定 Team ID，钥匙串无法记住应用信任，每次读取都会弹窗。
            // 失败时返回 nil，由调用方降级为空密钥，不阻塞设置页与翻译任务。
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
