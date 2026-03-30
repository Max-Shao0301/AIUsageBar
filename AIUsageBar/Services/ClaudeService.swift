import Foundation

// MARK: - Errors
enum ClaudeServiceError: Error, LocalizedError {
    case noCredentials(String)
    case networkError(Error)
    case invalidResponse(Int)
    case decodingError(Error)
    case unauthorized
    case orgNotFound

    var errorDescription: String? {
        switch self {
        case .noCredentials(let d):   return d
        case .networkError(let e):    return "網路錯誤：\(e.localizedDescription)"
        case .invalidResponse(let c): return "伺服器回傳錯誤 HTTP \(c)"
        case .decodingError(let e):   return "資料解析失敗：\(e.localizedDescription)"
        case .unauthorized:           return "授權失效，請重新登入 Claude Desktop App。"
        case .orgNotFound:            return "找不到組織資訊，請確認已登入 Claude Desktop App。"
        }
    }
}

// MARK: - ClaudeService（Session Cookie 版本）
final class ClaudeService {
    static let shared = ClaudeService()
    private init() {}

    // 快取 orgId 避免每次都重新查詢
    private var cachedOrgId: String?

    // MARK: - Public: Fetch Usage
    func fetchUsage() async throws -> UsageData {

        // Step 1：取得 Session Key
        let sessionKey: String
        do {
            sessionKey = try ChromeCookieService.shared.getSessionKey()
            print("✅ [ClaudeService] Session key obtained (length: \(sessionKey.count))")
        } catch {
            throw ClaudeServiceError.noCredentials(error.localizedDescription)
        }

        // Step 2：取得 Org ID（有快取就直接用）
        let orgId: String
        if let cached = cachedOrgId {
            orgId = cached
        } else {
            orgId = try await fetchOrgId(sessionKey: sessionKey)
            cachedOrgId = orgId
            print("✅ [ClaudeService] Org ID: \(orgId)")
        }

        // Step 3：查詢使用量
        return try await fetchUsageData(sessionKey: sessionKey, orgId: orgId)
    }

    // MARK: - 取得 Org ID
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

        // 解析 [{uuid: "...", ...}, ...]
        struct OrgResponse: Codable {
            let uuid: String
        }

        let orgs = try JSONDecoder().decode([OrgResponse].self, from: data)
        guard let first = orgs.first else {
            throw ClaudeServiceError.orgNotFound
        }
        return first.uuid
    }

    // MARK: - 查詢使用量
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
            // Org ID 可能已失效，清掉快取下次重新取
            cachedOrgId = nil
            throw ClaudeServiceError.unauthorized
        default:
            throw ClaudeServiceError.invalidResponse(http.statusCode)
        }
    }

    // MARK: - 共用 Request 建立
    private func makeRequest(url: URL, sessionKey: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)",    forHTTPHeaderField: "Cookie")
        req.setValue("application/json",            forHTTPHeaderField: "Accept")
        req.setValue("application/json",            forHTTPHeaderField: "Content-Type")
        req.setValue("web_claude_ai",               forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("https://claude.ai",           forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai",           forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            throw ClaudeServiceError.networkError(error)
        }
    }
}
