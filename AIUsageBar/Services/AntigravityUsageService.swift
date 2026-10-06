import Foundation

enum AntigravityUsageServiceError: Error, LocalizedError {
    case authenticationRequired
    case credentialStoreUnavailable
    case invalidCredential
    case unavailable
    case invalidResponse(Int)
    case invalidPayload
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "找不到 Antigravity 登入憑證。請先開啟 Antigravity 或執行 agy 登入。"
        case .credentialStoreUnavailable:
            return "無法讀取 Antigravity Keychain 憑證，請手動重新整理並允許存取。"
        case .invalidCredential:
            return "Antigravity 登入憑證格式無法辨識。"
        case .unavailable:
            return "Antigravity 用量服務暫時無法連線。"
        case .invalidResponse(let statusCode):
            return "Antigravity 用量服務回傳錯誤 HTTP \(statusCode)。"
        case .invalidPayload:
            return "Antigravity 用量資料格式無法辨識。"
        case .networkError(let error):
            return "Antigravity 網路錯誤：\(error.localizedDescription)"
        }
    }
}

/// Reads quota directly from Antigravity's language server or Google Cloud Code.
/// It never launches `agy`, so a background refresh cannot start an OAuth browser flow.
final class AntigravityUsageService {
    static let shared = AntigravityUsageService()

    private static let languageServerService = "exa.language_server_pb.LanguageServerService"
    private static let cloudCodeBases = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    private static let quotaSummaryPath = "/v1internal:retrieveUserQuotaSummary"
    private static let fetchModelsPath = "/v1internal:fetchAvailableModels"
    private static let loadCodeAssistPath = "/v1internal:loadCodeAssist"
    private static let retrieveQuotaPath = "/v1internal:retrieveUserQuota"

    private let credentialStore = AntigravityCredentialStore.shared
    private let discovery = LanguageServerDiscovery()
    private let oauthClientDiscovery = AntigravityOAuthClientDiscovery()
    private let localSession = URLSession(
        configuration: .ephemeral,
        delegate: LoopbackTrustDelegate(),
        delegateQueue: nil
    )

    private init() {}

    func fetchUsage(allowKeychainInteraction: Bool = false) async throws -> AntigravityUsageData {
        if let usage = await probeLanguageServer(
            processName: "language_server",
            markers: ["antigravity", "antigravity-ide"],
            csrfFlag: "--csrf_token",
            portFlag: "--extension_server_port"
        ) {
            print("[Antigravity] 使用 Antigravity language server")
            return usage
        }
        if let usage = await probeLanguageServer(
            processName: "agy",
            markers: [],
            csrfFlag: "",
            portFlag: nil
        ) {
            print("[Antigravity] 使用 agy language server")
            return usage
        }
        let usage = try await probeCloudCode(allowKeychainInteraction: allowKeychainInteraction)
        print("[Antigravity] 使用 Keychain OAuth + Cloud Code API")
        return usage
    }

    // MARK: - Language server

    private func probeLanguageServer(
        processName: String,
        markers: [String],
        csrfFlag: String,
        portFlag: String?
    ) async -> AntigravityUsageData? {
        let options = LanguageServerDiscovery.Options(
            processName: processName,
            markers: markers,
            csrfFlag: csrfFlag,
            portFlag: portFlag
        )
        let discovery = self.discovery
        guard let endpoint = await Task.detached(priority: .utility, operation: {
            discovery.discover(options)
        }).value else { return nil }

        var addresses = endpoint.ports.flatMap { [(scheme: "https", port: $0), (scheme: "http", port: $0)] }
        if let extensionPort = endpoint.extensionPort {
            addresses.append((scheme: "http", port: extensionPort))
        }

        for address in addresses {
            if let response = await callLanguageServer(
                scheme: address.scheme,
                port: address.port,
                csrfToken: endpoint.csrfToken,
                method: "RetrieveUserQuotaSummary"
            ), response.statusCode == 200,
               let usage = parseQuotaSummary(response.data) {
                return usage
            }

            if let response = await callLanguageServer(
                scheme: address.scheme,
                port: address.port,
                csrfToken: endpoint.csrfToken,
                method: "GetUserStatus"
            ), response.statusCode == 200 {
                let models = parseLanguageServerStatus(response.data)
                if !models.isEmpty { return buildLegacyUsage(models) }
            }

            if let response = await callLanguageServer(
                scheme: address.scheme,
                port: address.port,
                csrfToken: endpoint.csrfToken,
                method: "GetCommandModelConfigs"
            ), response.statusCode == 200 {
                let models = parseLanguageServerModels(response.data)
                if !models.isEmpty { return buildLegacyUsage(models) }
            }
        }
        return nil
    }

    private func callLanguageServer(
        scheme: String,
        port: Int,
        csrfToken: String,
        method: String
    ) async -> ServiceResponse? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(Self.languageServerService)/\(method)") else {
            return nil
        }
        let metadata: [String: String] = [
            "ideName": "antigravity",
            "extensionName": "antigravity",
            "ideVersion": "unknown",
            "locale": "en"
        ]
        let body = try? JSONSerialization.data(withJSONObject: ["metadata": metadata])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        if !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        }

        guard let (data, response) = try? await localSession.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return ServiceResponse(data: data, statusCode: http.statusCode)
    }

    // MARK: - Cloud Code

    private func probeCloudCode(allowKeychainInteraction: Bool) async throws -> AntigravityUsageData {
        let store = credentialStore
        let credential = try store.load(allowInteraction: allowKeychainInteraction)
        guard let credential else { throw AntigravityUsageServiceError.authenticationRequired }

        var tokens: [String] = []
        if let token = store.usableAccessToken(from: credential) { tokens.append(token) }
        if let token = store.cachedToken(matching: credential), !tokens.contains(token) { tokens.append(token) }

        var sawAuthenticationFailure = false
        for token in tokens {
            switch await fetchCloudCode(token: token) {
            case .success(let usage): return usage
            case .authenticationFailed: sawAuthenticationFailure = true
            case .unavailable: continue
            }
        }

        if (tokens.isEmpty || sawAuthenticationFailure), let refreshToken = credential.refreshToken {
            switch await refreshGoogleToken(refreshToken) {
            case .success(let token, let expiresIn):
                store.cache(accessToken: token, expiresIn: expiresIn, refreshToken: refreshToken)
                switch await fetchCloudCode(token: token) {
                case .success(let usage): return usage
                case .authenticationFailed: throw AntigravityUsageServiceError.authenticationRequired
                case .unavailable: throw AntigravityUsageServiceError.unavailable
                }
            case .authenticationFailed:
                store.discardCache()
                throw AntigravityUsageServiceError.authenticationRequired
            case .unavailable:
                throw AntigravityUsageServiceError.unavailable
            }
        }

        if sawAuthenticationFailure { throw AntigravityUsageServiceError.authenticationRequired }
        throw AntigravityUsageServiceError.unavailable
    }

    private func fetchCloudCode(token: String) async -> CloudProbeResult {
        switch await postCloudCode(path: Self.quotaSummaryPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authenticationFailed: return .authenticationFailed
        case .success(let data):
            if let usage = parseQuotaSummary(data) { return .success(usage) }
        case .unavailable: break
        }

        switch await postCloudCode(path: Self.fetchModelsPath, token: token, userAgent: "antigravity", body: [:]) {
        case .authenticationFailed: return .authenticationFailed
        case .success(let data):
            let models = parseCloudModels(data)
            if !models.isEmpty { return .success(buildLegacyUsage(models)) }
        case .unavailable: break
        }

        var project: String?
        switch await postCloudCode(path: Self.loadCodeAssistPath, token: token, userAgent: "agy", body: [:]) {
        case .authenticationFailed: return .authenticationFailed
        case .success(let data): project = parseProject(data)
        case .unavailable: break
        }

        var quota = await postCloudCode(
            path: Self.retrieveQuotaPath,
            token: token,
            userAgent: "agy",
            body: project.map { ["project": $0] } ?? [:]
        )
        if case .unavailable = quota, project != nil {
            quota = await postCloudCode(path: Self.retrieveQuotaPath, token: token, userAgent: "agy", body: [:])
        }
        switch quota {
        case .authenticationFailed: return .authenticationFailed
        case .success(let data):
            let models = parseQuotaModels(data)
            if !models.isEmpty { return .success(buildLegacyUsage(models)) }
        case .unavailable: break
        }
        return .unavailable
    }

    private func postCloudCode(
        path: String,
        token: String,
        userAgent: String,
        body: [String: String]
    ) async -> CloudResponse {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        for base in Self.cloudCodeBases {
            guard let url = URL(string: base + path) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = payload
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 401 || http.statusCode == 403 { return .authenticationFailed }
            if (200..<300).contains(http.statusCode) { return .success(data) }
        }
        return .unavailable
    }

    private func refreshGoogleToken(_ refreshToken: String) async -> TokenRefreshResult {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return .unavailable }
        let discovery = oauthClientDiscovery
        guard let client = await Task.detached(priority: .utility, operation: {
            discovery.discover()
        }).value else { return .unavailable }
        let fields = [
            "client_id=\(client.id.formEncoded)",
            "client_secret=\(client.secret.formEncoded)",
            "refresh_token=\(refreshToken.formEncoded)",
            "grant_type=refresh_token"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(fields.joined(separator: "&").utf8)
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        if (200..<300).contains(http.statusCode),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["access_token"] as? String {
            return .success(token, (json["expires_in"] as? NSNumber)?.doubleValue ?? 3_600)
        }
        if (400..<500).contains(http.statusCode), http.statusCode != 408, http.statusCode != 429 {
            return .authenticationFailed
        }
        return .unavailable
    }

    // MARK: - Mapping

    private func parseQuotaSummary(_ data: Data) -> AntigravityUsageData? {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root = outer["response"] as? [String: Any] ?? outer
        guard let groups = root["groups"] as? [[String: Any]] else { return nil }

        var windows: [String: AntigravityUsageWindow] = [:]
        let accepted = Set(["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        for bucket in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) {
            guard let identifier = bucket["bucketId"] as? String,
                  accepted.contains(identifier),
                  windows[identifier] == nil,
                  let remaining = number(bucket["remainingFraction"]) else { continue }
            windows[identifier] = usageWindow(remaining: remaining, resetValue: bucket["resetTime"])
        }

        return makeUsage(
            geminiFiveHour: windows["gemini-5h"],
            geminiWeekly: windows["gemini-weekly"],
            thirdPartyFiveHour: windows["3p-5h"],
            thirdPartyWeekly: windows["3p-weekly"]
        )
    }

    private func parseLanguageServerStatus(_ data: Data) -> [NormalizedModel] {
        guard let outer = dictionary(data),
              let status = outer["userStatus"] as? [String: Any],
              let cascade = status["cascadeModelConfigData"] as? [String: Any],
              let configs = cascade["clientModelConfigs"] as? [[String: Any]] else { return [] }
        return normalizeModels(configs)
    }

    private func parseLanguageServerModels(_ data: Data) -> [NormalizedModel] {
        guard let configs = dictionary(data)?["clientModelConfigs"] as? [[String: Any]] else { return [] }
        return normalizeModels(configs)
    }

    private func parseCloudModels(_ data: Data) -> [NormalizedModel] {
        guard let models = dictionary(data)?["models"] as? [String: Any] else { return [] }
        return models.compactMap { identifier, value in
            guard let object = value as? [String: Any], object["isInternal"] as? Bool != true else { return nil }
            return normalizedModel(object, fallbackIdentifier: identifier)
        }
    }

    private func parseQuotaModels(_ data: Data) -> [NormalizedModel] {
        guard let buckets = dictionary(data)?["buckets"] as? [[String: Any]] else { return [] }
        return buckets.compactMap { bucket in
            guard let identifier = bucket["modelId"] as? String else { return nil }
            return NormalizedModel(
                label: identifier,
                identifier: identifier,
                remaining: number(bucket["remainingFraction"]) ?? 0,
                resetAt: parseDate(bucket["resetTime"])
            )
        }
    }

    private func parseProject(_ data: Data) -> String? {
        dictionary(data)?["cloudaicompanionProject"] as? String
    }

    private func dictionary(_ data: Data) -> [String: Any]? {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return outer["response"] as? [String: Any] ?? outer
    }

    private func normalizeModels(_ configs: [[String: Any]]) -> [NormalizedModel] {
        configs.compactMap { normalizedModel($0, fallbackIdentifier: nil) }
    }

    private func normalizedModel(_ object: [String: Any], fallbackIdentifier: String?) -> NormalizedModel? {
        let label = (object["displayName"] as? String) ?? (object["label"] as? String)
        guard let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let modelOrAlias = object["modelOrAlias"] as? [String: Any]
        let identifier = (object["model"] as? String) ?? (modelOrAlias?["model"] as? String) ?? fallbackIdentifier
        let quota = object["quotaInfo"] as? [String: Any]
        return NormalizedModel(
            label: label,
            identifier: identifier,
            remaining: number(quota?["remainingFraction"]) ?? 0,
            resetAt: parseDate(quota?["resetTime"])
        )
    }

    private func buildLegacyUsage(_ models: [NormalizedModel]) -> AntigravityUsageData {
        let blacklist = Set([
            "MODEL_CHAT_20706", "MODEL_CHAT_23310",
            "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
            "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
            "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12"
        ])
        var gemini: NormalizedModel?
        var thirdParty: NormalizedModel?

        for model in models where model.identifier.map({ !blacklist.contains($0) }) ?? true {
            if model.label.lowercased().contains("gemini") {
                if gemini == nil || model.remaining < gemini!.remaining { gemini = model }
            } else if thirdParty == nil || model.remaining < thirdParty!.remaining {
                thirdParty = model
            }
        }

        return makeUsage(
            geminiFiveHour: gemini.map { usageWindow(remaining: $0.remaining, resetValue: $0.resetAt) },
            geminiWeekly: nil,
            thirdPartyFiveHour: thirdParty.map { usageWindow(remaining: $0.remaining, resetValue: $0.resetAt) },
            thirdPartyWeekly: nil
        )
    }

    private func makeUsage(
        geminiFiveHour: AntigravityUsageWindow?,
        geminiWeekly: AntigravityUsageWindow?,
        thirdPartyFiveHour: AntigravityUsageWindow?,
        thirdPartyWeekly: AntigravityUsageWindow?
    ) -> AntigravityUsageData {
        AntigravityUsageData(
            gemini: geminiFiveHour == nil && geminiWeekly == nil ? nil : AntigravityQuotaGroup(
                displayName: "Gemini Models",
                fiveHour: geminiFiveHour,
                weekly: geminiWeekly
            ),
            claudeAndGPT: thirdPartyFiveHour == nil && thirdPartyWeekly == nil ? nil : AntigravityQuotaGroup(
                displayName: "Claude and GPT Models",
                fiveHour: thirdPartyFiveHour,
                weekly: thirdPartyWeekly
            )
        )
    }

    private func usageWindow(remaining: Double, resetValue: Any?) -> AntigravityUsageWindow {
        AntigravityUsageWindow(
            usedPercent: min(max((1 - remaining) * 100, 0), 100),
            resetAt: resetValue as? Date ?? parseDate(resetValue)
        )
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private struct ServiceResponse {
    let data: Data
    let statusCode: Int
}

private struct NormalizedModel {
    let label: String
    let identifier: String?
    let remaining: Double
    let resetAt: Date?
}

private enum CloudProbeResult {
    case success(AntigravityUsageData)
    case authenticationFailed
    case unavailable
}

private enum CloudResponse {
    case success(Data)
    case authenticationFailed
    case unavailable
}

private enum TokenRefreshResult {
    case success(String, TimeInterval)
    case authenticationFailed
    case unavailable
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? self
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           (host == "127.0.0.1" || host == "localhost"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
