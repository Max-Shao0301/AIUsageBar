import Foundation
import LocalAuthentication
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

    private struct CredentialItemMetadata {
        let account: String
        let modificationDate: Date
    }

    /// Service name used by Claude Desktop App when saving to Keychain
    private let serviceName = "Claude Code-credentials"

    /// Account name AIUsageBar uses for its own copy (avoids touching Claude Code CLI's item)
    private let ownAccount = "AIUsageBar-credentials"

    // MARK: Read
    func readCredentials(allowInteraction: Bool = true) throws -> ClaudeCredentials {
        let metadata = credentialItemMetadata()
        let ownMetadata = metadata.first { $0.account == ownAccount }
        let latestCLI = metadata
            .filter { $0.account != ownAccount }
            .max { $0.modificationDate < $1.modificationDate }
        let ownCredentials = try? credentials(
            account: ownAccount,
            allowInteraction: allowInteraction
        )

        // Claude Code rotates its Keychain item during login or token refresh.
        // Only touch that protected item when its metadata is newer than our copy.
        // Background refresh uses AuthenticationUIFail, so it never opens a password
        // dialog when access has not already been granted.
        if let latestCLI,
           ownMetadata == nil || latestCLI.modificationDate > ownMetadata!.modificationDate,
           let latestCredentials = try? credentials(
               account: latestCLI.account,
               allowInteraction: allowInteraction
           ) {
            try? saveCredentials(latestCredentials, allowInteraction: allowInteraction)
            return latestCredentials
        }

        if let ownCredentials {
            return ownCredentials
        }

        if let latestCLI,
           let latestCredentials = try? credentials(
               account: latestCLI.account,
               allowInteraction: allowInteraction
           ) {
            try? saveCredentials(latestCredentials, allowInteraction: allowInteraction)
            return latestCredentials
        }

        throw KeychainError.itemNotFound
    }

    private func credentialItemMetadata() -> [CredentialItemMetadata] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      serviceName,
            kSecReturnAttributes: true,
            kSecMatchLimit:       kSecMatchLimitAll,
            kSecUseAuthenticationContext: context
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let modificationDate = item[kSecAttrModificationDate as String] as? Date else {
                return nil
            }
            return CredentialItemMetadata(account: account, modificationDate: modificationDate)
        }
    }

    private func credentials(
        account: String,
        allowInteraction: Bool
    ) throws -> ClaudeCredentials {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            throw KeychainError.decodingFailed("SecItemCopyMatching 失敗（OSStatus: \(status)）")
        }
        guard let data = result as? Data else {
            throw KeychainError.decodingFailed("回傳資料非 Data 型別")
        }

        do {
            return try JSONDecoder().decode(ClaudeCredentials.self, from: data)
        } catch {
            throw KeychainError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: Clear cached item (call when token is rejected so next read re-fetches from CLI)
    func clearCachedCredentials() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: ownAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Write (always writes to AIUsageBar's own item — never touches Claude Code CLI's item)
    func saveCredentials(_ credentials: ClaudeCredentials, allowInteraction: Bool = true) throws {
        let data = try JSONEncoder().encode(credentials)

        let baseQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName,
            kSecAttrAccount: ownAccount
        ]
        var updateQuery = baseQuery
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        updateQuery[kSecUseAuthenticationContext] = context

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, [kSecValueData: data] as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
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
