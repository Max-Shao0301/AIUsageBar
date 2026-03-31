import Foundation
import Security

// MARK: - Errors
enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case decodingFailed(String)
    case saveFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "找不到 Claude 登入憑證。\n請確認已安裝並登入 Claude Desktop App。"
        case .decodingFailed(let detail):
            return "憑證格式解析失敗：\(detail)"
        case .saveFailed(let status):
            return "儲存憑證失敗（OSStatus: \(status)）"
        }
    }
}

// MARK: - KeychainService
final class KeychainService {
    static let shared = KeychainService()
    private init() {}

    /// Service name used by Claude Desktop App when saving to Keychain
    private let serviceName = "Claude Code-credentials"

    /// Account name AIUsageBar uses for its own copy (avoids touching Claude Code CLI's item)
    private let ownAccount = "AIUsageBar-credentials"

    // MARK: Read
    func readCredentials() throws -> ClaudeCredentials {
        // Always read from AIUsageBar's own item first — no Keychain prompt needed
        // since AIUsageBar itself owns this item.
        let ownQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: ownAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var ownResult: AnyObject?
        if SecItemCopyMatching(ownQuery as CFDictionary, &ownResult) == errSecSuccess,
           let data = ownResult as? Data,
           let creds = try? JSONDecoder().decode(ClaudeCredentials.self, from: data) {
            return creds
        }

        // First-time fallback: read from Claude Code CLI's item (will prompt once),
        // then immediately cache a copy into AIUsageBar's own item so future reads
        // never need to touch the CLI item again (and won't be affected by the CLI
        // recreating its item on token refresh).
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.decodingFailed("回傳資料非 Data 型別")
            }
            let creds: ClaudeCredentials
            do {
                creds = try JSONDecoder().decode(ClaudeCredentials.self, from: data)
            } catch {
                throw KeychainError.decodingFailed(error.localizedDescription)
            }
            // Cache into AIUsageBar's own item — subsequent reads will use this copy
            // and won't be disrupted when Claude Code CLI rotates its item.
            try? saveCredentials(creds)
            return creds

        case errSecItemNotFound:
            throw KeychainError.itemNotFound

        default:
            throw KeychainError.decodingFailed("SecItemCopyMatching 失敗（OSStatus: \(status)）")
        }
    }

    // MARK: Write (always writes to AIUsageBar's own item — never touches Claude Code CLI's item)
    func saveCredentials(_ credentials: ClaudeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: ownAccount
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }
}
