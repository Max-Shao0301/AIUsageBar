import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum CodexUsageServiceError: Error, LocalizedError {
    case notSignedIn
    case networkError(Error)
    case unauthorized
    case invalidResponse(Int)
    case decodingError(Error)
    case credentialsChanged

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "找不到 Codex 登入憑證。\n請確認已安裝並登入 Codex CLI。"
        case .networkError(let error):
            return "網路錯誤：\(error.localizedDescription)"
        case .unauthorized:
            return "授權失效，請重新登入 Codex。"
        case .invalidResponse(let status):
            return "Codex 用量服務回傳錯誤 HTTP \(status)。"
        case .decodingError(let error):
            return "Codex 用量資料解析失敗：\(error.localizedDescription)"
        case .credentialsChanged:
            return "Codex 登入資料剛剛已更新，稍後會自動重試。"
        }
    }
}

final class CodexUsageService {
    static let shared = CodexUsageService()

    private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let keychainService = "Codex Auth"

    private init() {}

    func fetchUsage(allowKeychainInteraction: Bool = false) async throws -> CodexUsageData {
        let candidates = loadAuthCandidates(allowKeychainInteraction: allowKeychainInteraction)
        guard !candidates.isEmpty else { throw CodexUsageServiceError.notSignedIn }

        var lastAuthError: Error?
        for state in candidates {
            do {
                let result = try await fetchUsageWithOAuth(
                    state: state,
                    allowKeychainInteraction: allowKeychainInteraction
                )
                print("[CodexUsageService] 使用 \(state.source.label)")
                return result
            } catch CodexUsageServiceError.unauthorized {
                lastAuthError = CodexUsageServiceError.unauthorized
            } catch CodexUsageServiceError.credentialsChanged {
                lastAuthError = CodexUsageServiceError.credentialsChanged
            }
        }
        throw lastAuthError ?? CodexUsageServiceError.unauthorized
    }

    // MARK: - Authentication sources

    private struct AuthTokens {
        var accessToken: String
        var refreshToken: String?
        var accountID: String?
        var idToken: String?
    }

    private struct AuthState {
        var tokens: AuthTokens
        var raw: [String: Any]
        let source: AuthSource
    }

    private enum AuthSource {
        case file(URL)
        case keychain(account: String)

        var label: String {
            switch self {
            case .file: return "Codex auth.json"
            case .keychain: return "Codex Keychain"
            }
        }
    }

    private func loadAuthCandidates(allowKeychainInteraction: Bool) -> [AuthState] {
        var candidates: [AuthState] = []
        let homes = codexHomes()

        for home in homes {
            let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            if let state = loadFile(url), !contains(state, in: candidates) {
                candidates.append(state)
            }
        }

        for home in homes {
            let account = keychainAccount(for: home)
            if let state = loadKeychain(
                account: account,
                allowInteraction: allowKeychainInteraction
            ), !contains(state, in: candidates) {
                candidates.append(state)
            }
        }
        return candidates
    }

    private func codexHomes() -> [String] {
        var values: [String] = []
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            values.append((configured as NSString).expandingTildeInPath)
        }
        values.append((("~/.codex") as NSString).expandingTildeInPath)
        values.append((("~/.config/codex") as NSString).expandingTildeInPath)

        var seen = Set<String>()
        return values.filter { seen.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
    }

    private func contains(_ candidate: AuthState, in states: [AuthState]) -> Bool {
        states.contains {
            $0.tokens.accessToken == candidate.tokens.accessToken &&
            $0.tokens.accountID == candidate.tokens.accountID
        }
    }

    private func loadFile(_ url: URL) -> AuthState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parseAuth(data, source: .file(url))
    }

    private func loadKeychain(account: String, allowInteraction: Bool) -> AuthState? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return parseAuth(data, source: .keychain(account: account))
    }

    private func parseAuth(_ data: Data, source: AuthSource) -> AuthState? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = raw["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else { return nil }

        return AuthState(
            tokens: AuthTokens(
                accessToken: accessToken,
                refreshToken: tokens["refresh_token"] as? String,
                accountID: tokens["account_id"] as? String,
                idToken: tokens["id_token"] as? String
            ),
            raw: raw,
            source: source
        )
    }

    private func reload(_ source: AuthSource, allowKeychainInteraction: Bool) -> AuthState? {
        switch source {
        case .file(let url):
            return loadFile(url)
        case .keychain(let account):
            return loadKeychain(account: account, allowInteraction: allowKeychainInteraction)
        }
    }

    private func keychainAccount(for home: String) -> String {
        let expanded = (home as NSString).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "cli|" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Usage

    private func fetchUsageWithOAuth(
        state initialState: AuthState,
        isRetry: Bool = false,
        allowKeychainInteraction: Bool
    ) async throws -> CodexUsageData {
        var state = initialState

        if needsRefresh(state.tokens.accessToken),
           let refreshToken = state.tokens.refreshToken {
            if let live = reload(state.source, allowKeychainInteraction: allowKeychainInteraction),
               live.tokens.accessToken != state.tokens.accessToken {
                state = live
            } else {
                state = try await refreshOAuthToken(
                    state: state,
                    refreshToken: refreshToken,
                    allowKeychainInteraction: allowKeychainInteraction
                )
            }
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(state.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageBar", forHTTPHeaderField: "User-Agent")
        if let accountID = state.tokens.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexUsageServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageServiceError.networkError(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(CodexUsageData.self, from: data)
            } catch {
                throw CodexUsageServiceError.decodingError(error)
            }
        case 401, 403:
            if !isRetry, let refreshToken = state.tokens.refreshToken {
                let refreshed: AuthState
                if let live = reload(state.source, allowKeychainInteraction: allowKeychainInteraction),
                   live.tokens.accessToken != state.tokens.accessToken {
                    refreshed = live
                } else {
                    refreshed = try await refreshOAuthToken(
                        state: state,
                        refreshToken: refreshToken,
                        allowKeychainInteraction: allowKeychainInteraction
                    )
                }
                return try await fetchUsageWithOAuth(
                    state: refreshed,
                    isRetry: true,
                    allowKeychainInteraction: allowKeychainInteraction
                )
            }
            throw CodexUsageServiceError.unauthorized
        default:
            throw CodexUsageServiceError.invalidResponse(http.statusCode)
        }
    }

    private func needsRefresh(_ accessToken: String) -> Bool {
        guard let expiry = jwtExpiry(accessToken) else { return false }
        return expiry.timeIntervalSinceNow <= 5 * 60
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
              let expiry = (json["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    // MARK: - Token refresh

    private func refreshOAuthToken(
        state: AuthState,
        refreshToken: String,
        allowKeychainInteraction: Bool
    ) async throws -> AuthState {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data([
            "grant_type=refresh_token",
            "client_id=\(oauthClientID.formEncoded)",
            "refresh_token=\(refreshToken.formEncoded)"
        ].joined(separator: "&").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexUsageServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageServiceError.networkError(URLError(.badServerResponse))
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            throw CodexUsageServiceError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexUsageServiceError.invalidResponse(http.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw CodexUsageServiceError.unauthorized
        }

        // A newer CLI login always wins over the refresh that just completed.
        if let live = reload(state.source, allowKeychainInteraction: allowKeychainInteraction),
           live.tokens.accessToken != state.tokens.accessToken ||
           live.tokens.refreshToken != state.tokens.refreshToken {
            return live
        }

        var refreshed = state
        refreshed.tokens.accessToken = accessToken
        refreshed.tokens.refreshToken = (json["refresh_token"] as? String) ?? refreshToken
        refreshed.tokens.idToken = (json["id_token"] as? String) ?? state.tokens.idToken
        persist(
            refreshed,
            replacing: state,
            allowKeychainInteraction: allowKeychainInteraction
        )
        return refreshed
    }

    private func persist(
        _ refreshed: AuthState,
        replacing original: AuthState,
        allowKeychainInteraction: Bool
    ) {
        var raw = original.raw
        var tokens = raw["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = refreshed.tokens.accessToken
        tokens["refresh_token"] = refreshed.tokens.refreshToken
        if let idToken = refreshed.tokens.idToken { tokens["id_token"] = idToken }
        raw["tokens"] = tokens
        raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else {
            print("[CodexUsageService] 無法序列化更新後的 token")
            return
        }

        do {
            switch refreshed.source {
            case .file(let url):
                guard let live = loadFile(url),
                      live.tokens.accessToken == original.tokens.accessToken,
                      live.tokens.refreshToken == original.tokens.refreshToken else {
                    throw CodexUsageServiceError.credentialsChanged
                }
                let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                try data.write(to: url, options: .atomic)
                if let permissions {
                    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                }

            case .keychain(let account):
                let context = LAContext()
                context.interactionNotAllowed = !allowKeychainInteraction
                let base: [CFString: Any] = [
                    kSecClass: kSecClassGenericPassword,
                    kSecAttrService: keychainService,
                    kSecAttrAccount: account
                ]
                var query = base
                query[kSecUseAuthenticationContext] = context
                let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
                guard status == errSecSuccess else {
                    throw CodexUsageServiceError.credentialsChanged
                }
            }
        } catch {
            print("[CodexUsageService] 無法儲存更新後的 token：\(error.localizedDescription)")
        }
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}
