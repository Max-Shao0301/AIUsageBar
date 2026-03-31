import Foundation

// MARK: - Errors
enum ClaudeServiceError: Error, LocalizedError {
    case noCredentials(String)
    case networkError(Error)
    case invalidResponse(Int)
    case decodingError(Error)
    case unauthorized
    case orgNotFound
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noCredentials(let d):   return d
        case .networkError(let e):    return "網路錯誤：\(e.localizedDescription)"
        case .invalidResponse(let c): return "伺服器回傳錯誤 HTTP \(c)"
        case .decodingError(let e):   return "資料解析失敗：\(e.localizedDescription)"
        case .unauthorized:           return "授權失效，請重新登入 Claude。"
        case .orgNotFound:            return "找不到組織資訊，請確認已登入 Claude Desktop App。"
        case .rateLimited:            return "請求頻率過高，請稍後再試。"
        }
    }
}

// MARK: - ClaudeService
final class ClaudeService {
    static let shared = ClaudeService()
    private init() {}

    // Cached org ID for the Cookie fallback strategy
    private var cachedOrgId: String?

    // Public OAuth client ID for Claude Code
    private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    // MARK: - Public: Fetch Usage
    func fetchUsage() async throws -> UsageData {
        // Strategy 1: Claude Code OAuth token (does not require Claude Desktop)
        if let credentials = try? KeychainService.shared.readCredentials() {
            do {
                let result = try await fetchUsageWithOAuth(credentials: credentials)
                print("[ClaudeService] 使用 Claude Code OAuth token")
                return result
            } catch ClaudeServiceError.unauthorized {
                print("[ClaudeService] OAuth token 無效，降級使用 Claude Desktop Cookie")
            } catch ClaudeServiceError.rateLimited {
                print("[ClaudeService] OAuth 頻率限制，降級使用 Claude Desktop Cookie")
            } catch {
                print("[ClaudeService] OAuth 失敗（\(error.localizedDescription)），降級使用 Claude Desktop Cookie")
            }
        } else {
            print("[ClaudeService] 找不到 Claude Code credentials，使用 Claude Desktop Cookie")
        }

        // Strategy 2: Claude Desktop session cookie (fallback)
        let result = try await fetchUsageWithCookie()
        print("[ClaudeService] 使用 Claude Desktop Cookie")
        return result
    }

    // MARK: - Strategy 1: OAuth

    private func fetchUsageWithOAuth(credentials: ClaudeCredentials, isRetry: Bool = false) async throws -> UsageData {
        var currentCredentials = credentials

        // Refresh the token if it has expired
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
            throw ClaudeServiceError.unauthorized
        case 429:
            // On 429, refresh the token and retry once
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

        // Save the refreshed token back to Keychain
        try? KeychainService.shared.saveCredentials(newCredentials)

        return newCredentials
    }

    // MARK: - Strategy 2: Cookie (fallback)

    private func fetchUsageWithCookie() async throws -> UsageData {
        let sessionKey: String
        do {
            sessionKey = try ChromeCookieService.shared.getSessionKey()
        } catch {
            throw ClaudeServiceError.noCredentials(error.localizedDescription)
        }

        let orgId: String
        if let cached = cachedOrgId {
            orgId = cached
        } else {
            orgId = try await fetchOrgId(sessionKey: sessionKey)
            cachedOrgId = orgId
        }

        return try await fetchUsageData(sessionKey: sessionKey, orgId: orgId)
    }

    // MARK: - Fetch Org ID (used by Cookie strategy)

    private func fetchOrgId(sessionKey: String) async throws -> String {
        let url = URL(string: "https://claude.ai/api/organizations")!
        let (data, response) = try await makeRequest(url: url, sessionKey: sessionKey)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.invalidResponse(0)
        }

        #if DEBUG
        print("🔍 [ClaudeService] /api/organizations HTTP \(http.statusCode)")
        #endif

        switch http.statusCode {
        case 200: break
        case 401, 403: throw ClaudeServiceError.unauthorized
        default: throw ClaudeServiceError.invalidResponse(http.statusCode)
        }

        struct OrgResponse: Codable { let uuid: String }
        let orgs = try JSONDecoder().decode([OrgResponse].self, from: data)
        guard let first = orgs.first else {
            throw ClaudeServiceError.orgNotFound
        }
        return first.uuid
    }

    // MARK: - Fetch Usage Data (used by Cookie strategy)

    private func fetchUsageData(sessionKey: String, orgId: String) async throws -> UsageData {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage")!
        let (data, response) = try await makeRequest(url: url, sessionKey: sessionKey)

        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.invalidResponse(0)
        }

        #if DEBUG
        let body = String(data: data, encoding: .utf8) ?? "(無法解碼)"
        print("🔍 [ClaudeService] /usage HTTP \(http.statusCode)\n\(body)")
        #endif

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(UsageData.self, from: data)
            } catch {
                throw ClaudeServiceError.decodingError(error)
            }
        case 401, 403:
            cachedOrgId = nil
            throw ClaudeServiceError.unauthorized
        default:
            throw ClaudeServiceError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - Shared Request Builder (used by Cookie strategy)

    private func makeRequest(url: URL, sessionKey: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json",         forHTTPHeaderField: "Accept")
        req.setValue("application/json",         forHTTPHeaderField: "Content-Type")
        req.setValue("web_claude_ai",            forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("https://claude.ai",        forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai",        forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }
    }
}
