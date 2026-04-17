import Foundation

// MARK: - Errors
enum CodexUsageServiceError: Error, LocalizedError {
    case notSignedIn
    case networkError(Error)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "找不到 Codex 登入憑證。\n請確認已安裝並登入 Codex CLI。"
        case .networkError(let e):
            return "網路錯誤：\(e.localizedDescription)"
        case .unauthorized:
            return "授權失效，請重新登入 Codex。"
        }
    }
}

// MARK: - CodexUsageService
final class CodexUsageService {
    static let shared = CodexUsageService()
    private init() {}

    private let authFilePath = NSHomeDirectory() + "/.codex/auth.json"
    private let oauthClientId = "app_EMoamEEZ73f0CkXaXp7hrann"

    // MARK: - Public

    func fetchUsage() async throws -> CodexUsageData {
        guard let auth = loadAuthFile() else {
            throw CodexUsageServiceError.notSignedIn
        }
        let result = try await fetchUsageWithOAuth(auth: auth)
        print("[CodexUsageService] 使用 OAuth API")
        return result
    }

    // MARK: - Auth File

    private struct CodexAuthFile: Codable {
        let tokens: Tokens

        struct Tokens: Codable {
            let accessToken:  String
            let refreshToken: String?
            let accountId:    String?

            enum CodingKeys: String, CodingKey {
                case accessToken  = "access_token"
                case refreshToken = "refresh_token"
                case accountId    = "account_id"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tokens
        }
    }

    private func loadAuthFile() -> CodexAuthFile? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: authFilePath)) else { return nil }
        return try? JSONDecoder().decode(CodexAuthFile.self, from: data)
    }

    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func isTokenExpired(_ token: String) -> Bool {
        guard let expiry = jwtExpiry(token) else { return false }
        return Date() > expiry.addingTimeInterval(-60)
    }

    // MARK: - OAuth

    private func fetchUsageWithOAuth(auth: CodexAuthFile, isRetry: Bool = false) async throws -> CodexUsageData {
        var accessToken = auth.tokens.accessToken
        var currentAuth = auth

        if isTokenExpired(accessToken), let refreshToken = auth.tokens.refreshToken {
            currentAuth = try await refreshOAuthToken(auth: auth, refreshToken: refreshToken)
            accessToken = currentAuth.tokens.accessToken
        }

        let accountId = currentAuth.tokens.accountId ?? ""
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)",  forHTTPHeaderField: "Authorization")
        req.setValue(accountId,                forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json",       forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw CodexUsageServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageServiceError.networkError(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(CodexUsageData.self, from: data)
        case 401, 403:
            if !isRetry, let refreshToken = currentAuth.tokens.refreshToken {
                let refreshed = try await refreshOAuthToken(auth: currentAuth, refreshToken: refreshToken)
                return try await fetchUsageWithOAuth(auth: refreshed, isRetry: true)
            }
            throw CodexUsageServiceError.unauthorized
        default:
            throw CodexUsageServiceError.networkError(URLError(.badServerResponse))
        }
    }

    // MARK: - Token Refresh

    private func refreshOAuthToken(auth: CodexAuthFile, refreshToken: String) async throws -> CodexAuthFile {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
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

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CodexUsageServiceError.unauthorized
        }

        struct TokenResponse: Codable {
            let accessToken:  String
            let refreshToken: String?
            enum CodingKeys: String, CodingKey {
                case accessToken  = "access_token"
                case refreshToken = "refresh_token"
            }
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        saveUpdatedTokens(
            accessToken:  tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            accountId:    auth.tokens.accountId
        )

        return CodexAuthFile(tokens: .init(
            accessToken:  tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            accountId:    auth.tokens.accountId
        ))
    }

    private func saveUpdatedTokens(accessToken: String, refreshToken: String, accountId: String?) {
        let fileURL = URL(fileURLWithPath: authFilePath)
        guard var raw = (try? Data(contentsOf: fileURL))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }

        if var tokens = raw["tokens"] as? [String: Any] {
            tokens["access_token"]  = accessToken
            tokens["refresh_token"] = refreshToken
            raw["tokens"] = tokens
        }
        raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        if let data = try? JSONSerialization.data(withJSONObject: raw, options: .prettyPrinted) {
            try? data.write(to: fileURL)
        }
    }
}
