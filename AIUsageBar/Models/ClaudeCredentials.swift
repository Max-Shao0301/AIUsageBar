import Foundation

// MARK: - OAuth Credentials (structure stored in Keychain)
struct ClaudeOAuthCredentials: Codable {
    let accessToken:  String
    let refreshToken: String?
    let expiresAt:    Double?   // Unix timestamp

    enum CodingKeys: String, CodingKey {
        case accessToken  = "accessToken"
        case refreshToken = "refreshToken"
        case expiresAt    = "expiresAt"
    }

    /// Whether the token has expired (treated as expired 60 seconds early to avoid race conditions)
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 > (expiresAt - 60)
    }
}

// MARK: - Wrapper (JSON structure saved into Keychain by the claude.ai Desktop App)
struct ClaudeCredentials: Codable {
    let claudeAiOauth: ClaudeOAuthCredentials

    enum CodingKeys: String, CodingKey {
        case claudeAiOauth = "claudeAiOauth"
    }
}
