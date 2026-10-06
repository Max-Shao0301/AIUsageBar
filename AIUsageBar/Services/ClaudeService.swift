import Foundation

enum ClaudeServiceError: Error, LocalizedError {
    case noCredentials(String)
    case networkError(Error)
    case invalidResponse(Int)
    case decodingError(Error)
    case unauthorized
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .noCredentials(let message):
            return message
        case .networkError(let error):
            return "網路錯誤：\(error.localizedDescription)"
        case .invalidResponse(let code):
            return "伺服器回傳錯誤（HTTP \(code)）"
        case .decodingError(let error):
            return "資料解析失敗：\(error.localizedDescription)"
        case .unauthorized:
            return "授權失效，請重新登入 Claude。"
        case .rateLimited:
            return "Claude 用量 API 暫時限制存取，稍後會自動重試。"
        }
    }
}

final class ClaudeService {
    static let shared = ClaudeService()

    private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let oauthScopes = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    private var rateLimitedUntil: Date?

    private init() {}

    func fetchUsage(allowKeychainInteraction: Bool = false) async throws -> UsageData {
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            throw ClaudeServiceError.rateLimited
        }
        let candidates = credentialCandidates(allowKeychainInteraction: allowKeychainInteraction)
        guard !candidates.isEmpty else {
            throw ClaudeServiceError.noCredentials(
                "找不到 Claude Code 登入憑證。\n請確認已安裝並登入 Claude Code CLI。"
            )
        }

        var lastAuthorizationError: Error?
        for candidate in candidates {
            do {
                let result = try await fetchUsageWithOAuth(
                    state: candidate,
                    allowKeychainInteraction: allowKeychainInteraction
                )
                rateLimitedUntil = nil
                print("✅ [ClaudeService] 使用 \(candidate.source.label) OAuth token")
                return result
            } catch ClaudeServiceError.unauthorized {
                lastAuthorizationError = ClaudeServiceError.unauthorized
                if case .keychain = candidate.source {
                    KeychainService.shared.clearCachedCredentials()
                }
            }
        }
        throw lastAuthorizationError ?? ClaudeServiceError.unauthorized
    }

    // MARK: - Credentials

    private struct CredentialState {
        var credentials: ClaudeCredentials
        let source: CredentialSource
    }

    private enum CredentialSource {
        case keychain
        case file(URL)

        var label: String {
            switch self {
            case .keychain: return "Claude Code Keychain"
            case .file: return "Claude Code credentials file"
            }
        }
    }

    private func credentialCandidates(allowKeychainInteraction: Bool) -> [CredentialState] {
        var candidates: [CredentialState] = []
        if let credentials = try? KeychainService.shared.readCredentials(
            allowInteraction: allowKeychainInteraction
        ) {
            candidates.append(CredentialState(credentials: credentials, source: .keychain))
        }

        let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? "~/.claude"
        let path = (home as NSString).expandingTildeInPath + "/.credentials.json"
        let url = URL(fileURLWithPath: path)
        if let data = try? Data(contentsOf: url),
           let credentials = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
           !candidates.contains(where: {
               $0.credentials.claudeAiOauth.accessToken == credentials.claudeAiOauth.accessToken
           }) {
            candidates.append(CredentialState(credentials: credentials, source: .file(url)))
        }
        return candidates
    }

    // MARK: - Usage

    private func fetchUsageWithOAuth(
        state initialState: CredentialState,
        isRetry: Bool = false,
        allowKeychainInteraction: Bool
    ) async throws -> UsageData {
        var state = initialState
        if state.credentials.claudeAiOauth.isExpired,
           let refreshToken = state.credentials.claudeAiOauth.refreshToken {
            state = try await refreshOAuthToken(
                state: state,
                refreshToken: refreshToken,
                allowKeychainInteraction: allowKeychainInteraction
            )
        }

        var components = URLComponents(string: "https://api.anthropic.com/api/oauth/usage")!
        components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Bearer \(state.credentials.claudeAiOauth.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.280 (external, cli)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.networkError(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(UsageData.self, from: data)
            } catch {
                throw ClaudeServiceError.decodingError(error)
            }
        case 401, 403:
            if !isRetry, let refreshToken = state.credentials.claudeAiOauth.refreshToken {
                let refreshed = try await refreshOAuthToken(
                    state: state,
                    refreshToken: refreshToken,
                    allowKeychainInteraction: allowKeychainInteraction
                )
                return try await fetchUsageWithOAuth(
                    state: refreshed,
                    isRetry: true,
                    allowKeychainInteraction: allowKeychainInteraction
                )
            }
            throw ClaudeServiceError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 300
            rateLimitedUntil = Date().addingTimeInterval(min(max(retryAfter, 60), 3_600))
            throw ClaudeServiceError.rateLimited
        default:
            throw ClaudeServiceError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - Token refresh

    private func refreshOAuthToken(
        state: CredentialState,
        refreshToken: String,
        allowKeychainInteraction: Bool
    ) async throws -> CredentialState {
        let url = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
            "scope": oauthScopes
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeServiceError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 400 || http.statusCode == 401 {
                throw ClaudeServiceError.unauthorized
            }
            throw ClaudeServiceError.invalidResponse(http.statusCode)
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ClaudeServiceError.decodingError(error)
        }

        let credentials = ClaudeCredentials(
            claudeAiOauth: ClaudeOAuthCredentials(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken ?? refreshToken,
                expiresAt: token.expiresIn.map {
                    (Date().timeIntervalSince1970 + $0) * 1_000
                }
            )
        )
        let refreshed = CredentialState(credentials: credentials, source: state.source)
        persist(
            refreshed,
            replacing: state,
            allowKeychainInteraction: allowKeychainInteraction
        )
        return refreshed
    }

    private func persist(
        _ refreshed: CredentialState,
        replacing original: CredentialState,
        allowKeychainInteraction: Bool
    ) {
        switch refreshed.source {
        case .keychain:
            do {
                try KeychainService.shared.saveCredentials(
                    refreshed.credentials,
                    allowInteraction: allowKeychainInteraction
                )
            } catch {
                print("[ClaudeService] 無法儲存更新後的 Keychain token：\(error.localizedDescription)")
            }

        case .file(let url):
            do {
                let data = try Data(contentsOf: url)
                guard let current = try? JSONDecoder().decode(ClaudeCredentials.self, from: data),
                      current.claudeAiOauth.accessToken == original.credentials.claudeAiOauth.accessToken,
                      var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    print("[ClaudeService] 登入資料已被 Claude Code 更新，略過舊 token 寫回")
                    return
                }

                var oauth = json["claudeAiOauth"] as? [String: Any] ?? [:]
                oauth["accessToken"] = refreshed.credentials.claudeAiOauth.accessToken
                oauth["refreshToken"] = refreshed.credentials.claudeAiOauth.refreshToken
                oauth["expiresAt"] = refreshed.credentials.claudeAiOauth.expiresAt
                json["claudeAiOauth"] = oauth
                let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
                let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                try output.write(to: url, options: .atomic)
                if let permissions {
                    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                }
            } catch {
                print("[ClaudeService] 無法儲存更新後的 credentials file：\(error.localizedDescription)")
            }
        }
    }
}
