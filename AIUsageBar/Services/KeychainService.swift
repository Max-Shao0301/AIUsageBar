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

    // MARK: Read
    func readCredentials() throws -> ClaudeCredentials {
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
            do {
                return try JSONDecoder().decode(ClaudeCredentials.self, from: data)
            } catch {
                throw KeychainError.decodingFailed(error.localizedDescription)
            }

        case errSecItemNotFound:
            throw KeychainError.itemNotFound

        default:
            throw KeychainError.decodingFailed("SecItemCopyMatching 失敗（OSStatus: \(status)）")
        }
    }

    // MARK: Write (update refreshed token)
    func saveCredentials(_ credentials: ClaudeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)

        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: serviceName
        ]

        let attributes: [CFString: Any] = [kSecValueData: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet, so add it
            var addQuery = query
            addQuery[kSecValueData] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(updateStatus)
        }
    }
}
