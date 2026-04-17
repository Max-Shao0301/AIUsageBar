import Foundation

// MARK: - Errors
enum ClaudeServiceError: Error, LocalizedError {
    case noCredentials(String)
    case networkError(Error)
    case invalidResponse(Int)
    case decodingError(Error)
    case unauthorized
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noCredentials(let d):   return d
        case .networkError(let e):    return "網路錯誤：\(e.localizedDescription)"
        case .invalidResponse(let c): return "伺服器回傳錯誤 HTTP \(c)"
        case .decodingError(let e):   return "資料解析失敗：\(e.localizedDescription)"
        case .unauthorized:           return "授權失效，請重新登入 Claude。"
        case .rateLimited:            return "請求頻率過高，請稍後再試。"
        }
    }
}

// MARK: - ClaudeService
final class ClaudeService {
    static let shared = ClaudeService()
    private init() {}

    private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // MARK: - Public: Fetch Usage

    func fetchUsage() async throws -> UsageData {
        guard let credentials = try? KeychainService.shared.readCredentials() else {
            throw ClaudeServiceError.noCredentials("找不到 Claude Code 登入憑證。\n請確認已安裝並登入 Claude Code CLI。")
        }
        let result = try await fetchUsageWithOAuth(credentials: credentials)
        print("✅ [ClaudeService] 使用 Claude Code OAuth token")
        return result
    }

    // MARK: - OAuth

    private func fetchUsageWithOAuth(credentials: ClaudeCredentials, isRetry: Bool = false) async throws -> UsageData {
        var currentCredentials = credentials

        if credentials.claudeAiOauth.isExpired,
           let refreshToken = credentials.claudeAiOauth.refreshToken {
            currentCredentials = try await refreshOAuthToken(refreshToken: refreshToken)
        }

        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(currentCredentials.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json",  forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.invalidResponse(0)
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(UsageData.self, from: data)
            } catch {
                throw ClaudeServiceError.decodingError(error)
            }
        case 401, 403:
            // Clear cached item so next attempt re-reads from Claude Code CLI
            KeychainService.shared.clearCachedCredentials()
            throw ClaudeServiceError.unauthorized
        case 429:
            if !isRetry, let refreshToken = currentCredentials.claudeAiOauth.refreshToken {
                let refreshed = try await refreshOAuthToken(refreshToken: refreshToken)
                return try await fetchUsageWithOAuth(credentials: refreshed, isRetry: true)
            }
            throw ClaudeServiceError.rateLimited
        default:
            throw ClaudeServiceError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - Token Refresh

    private func refreshOAuthToken(refreshToken: String) async throws -> ClaudeCredentials {
        let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": refreshToken,
            "client_id":     oauthClientId
        ]
        req.httpBody = try? JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClaudeServiceError.unauthorized
        }

        struct TokenResponse: Codable {
            let accessToken:  String
            let refreshToken: String?
            let expiresIn:    Double?
            enum CodingKeys: String, CodingKey {
                case accessToken  = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn    = "expires_in"
            }
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ClaudeServiceError.decodingError(error)
        }

        let expiresAt = tokenResponse.expiresIn.map { Date().timeIntervalSince1970 + $0 }
        let newCredentials = ClaudeCredentials(
            claudeAiOauth: ClaudeOAuthCredentials(
                accessToken:  tokenResponse.accessToken,
                refreshToken: tokenResponse.refreshToken ?? refreshToken,
                expiresAt:    expiresAt
            )
        )

        try? KeychainService.shared.saveCredentials(newCredentials)
        return newCredentials
    }
}
