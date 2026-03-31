import Foundation

// MARK: - Errors
enum CodexUsageServiceError: Error, LocalizedError {
    case cacheDirectoryNotFound
    case usageCacheNotFound

    var errorDescription: String? {
        switch self {
        case .cacheDirectoryNotFound:
            return "找不到 Codex 快取資料夾。"
        case .usageCacheNotFound:
            return "找不到 Codex 用量資料。請確認已安裝並登入 Codex。"
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
        // Strategy 1: OAuth API (preferred, does not require Codex App to be running)
        if let auth = loadAuthFile() {
            do {
                let result = try await fetchUsageWithOAuth(auth: auth)
                print("✅ [CodexUsageService] 使用 OAuth API")
                return result
            } catch {
                print("⚠️ [CodexUsageService] OAuth 失敗（\(error.localizedDescription)），降級使用 Cache")
            }
        } else {
            print("ℹ️ [CodexUsageService] 找不到 ~/.codex/auth.json，使用 Cache")
        }

        // Strategy 2: Read from Codex App local cache (fallback)
        let result = try loadUsageFromCache()
        print("✅ [CodexUsageService] 使用 Codex Cache")
        return result
    }

    // MARK: - Strategy 1: OAuth

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

    /// Parses the JWT payload to get the expiry time
    private func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        // JWT uses base64url (- and _); Data(base64Encoded:) requires standard base64 (+ and /)
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

    private func fetchUsageWithOAuth(auth: CodexAuthFile, isRetry: Bool = false) async throws -> CodexUsageData {
        var accessToken = auth.tokens.accessToken
        var currentAuth = auth

        // Refresh the token if it has expired
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
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageServiceError.usageCacheNotFound
        }

        switch http.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(CodexUsageData.self, from: data)
            } catch {
                throw error
            }
        case 401, 403:
            // On 401/403, refresh the token and retry once
            if !isRetry, let refreshToken = currentAuth.tokens.refreshToken {
                let refreshed = try await refreshOAuthToken(auth: currentAuth, refreshToken: refreshToken)
                return try await fetchUsageWithOAuth(auth: refreshed, isRetry: true)
            }
            throw CodexUsageServiceError.usageCacheNotFound
        default:
            throw CodexUsageServiceError.usageCacheNotFound
        }
    }

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
            throw CodexUsageServiceError.usageCacheNotFound
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

        // Write the refreshed token back to ~/.codex/auth.json (preserving other fields in the original file)
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

    /// Updates only the token fields in auth.json, preserving all other fields (e.g. id_token)
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

    // MARK: - Strategy 2: Local Cache (fallback)

    private let usageURLMarker = Data("https://chatgpt.com/backend-api/wham/usage".utf8)
    private let brotliPaths = [
        "/opt/homebrew/bin/brotli",
        "/usr/local/bin/brotli",
        "/usr/bin/brotli"
    ]

    private func loadUsageFromCache() throws -> CodexUsageData {
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Codex/Cache/Cache_Data")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cacheDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CodexUsageServiceError.cacheDirectoryNotFound
        }

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        let sortedFiles = urls
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }

        let decoder = JSONDecoder()

        for fileURL in sortedFiles {
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            guard let markerRange = fileData.range(of: usageURLMarker) else { continue }

            let start = markerRange.upperBound
            let end = min(fileData.count, start + 180)
            if start >= end { continue }

            var candidateOffsets: [Int] = []
            candidateOffsets.append(contentsOf: start...min(start + 24, fileData.count - 1))
            for i in start..<end {
                if fileData[i] == 0x1b || fileData[i] == 0x0b || fileData[i] == 0x8b {
                    candidateOffsets.append(i)
                }
            }

            for offset in Array(Set(candidateOffsets)).sorted() {
                let slice = fileData[offset...]
                guard let jsonData = decompressBrotli(Data(slice)) else { continue }
                if let decoded = try? decoder.decode(CodexUsageData.self, from: jsonData),
                   decoded.rateLimit?.primaryWindow != nil {
                    return decoded
                }
            }
        }

        throw CodexUsageServiceError.usageCacheNotFound
    }

    private func decompressBrotli(_ compressed: Data) -> Data? {
        let fm = FileManager.default
        let executable = brotliPaths.first(where: { fm.isExecutableFile(atPath: $0) })

        let process = Process()
        if let executable {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-d"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["brotli", "-d"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
        }

        let stdinPipe  = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = Pipe()

        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(compressed)
            stdinPipe.fileHandleForWriting.closeFile()
            let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !output.isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }
}
