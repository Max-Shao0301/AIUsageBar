import Foundation

// MARK: - OAuth Credentials（存在 Keychain 裡的結構）
struct ClaudeOAuthCredentials: Codable {
    let accessToken:  String
    let refreshToken: String?
    let expiresAt:    Double?   // Unix timestamp

    enum CodingKeys: String, CodingKey {
        case accessToken  = "accessToken"
        case refreshToken = "refreshToken"
        case expiresAt    = "expiresAt"
    }

    /// token 是否已過期（提前 60 秒視為過期，避免 race condition）
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 > (expiresAt - 60)
    }
}

// MARK: - Wrapper（claude.ai Desktop App 存入 Keychain 的 JSON 結構）
struct ClaudeCredentials: Codable {
    let claudeAiOauth: ClaudeOAuthCredentials

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}
