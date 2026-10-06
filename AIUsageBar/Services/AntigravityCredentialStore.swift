import CryptoKit
import Foundation
import LocalAuthentication
import Security

struct AntigravityCredential {
    let accessToken: String?
    let refreshToken: String?
    let expiry: Date?
}

/// Reads Antigravity's OAuth credential without modifying its Keychain item.
final class AntigravityCredentialStore {
    static let shared = AntigravityCredentialStore()

    private let service = "gemini"
    private let account = "antigravity"
    private let refreshBuffer: TimeInterval = 60

    private init() {}

    func load(allowInteraction: Bool) throws -> AntigravityCredential? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed {
            throw AntigravityUsageServiceError.credentialStoreUnavailable
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AntigravityUsageServiceError.credentialStoreUnavailable
        }

        let raw = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
        guard let credential = Self.parse(raw) else {
            throw AntigravityUsageServiceError.invalidCredential
        }
        return credential
    }

    func usableAccessToken(from credential: AntigravityCredential) -> String? {
        guard credential.expiry.map({ $0.timeIntervalSinceNow > refreshBuffer }) ?? true else { return nil }
        return credential.accessToken?.trimmedNonEmpty
    }

    func cachedToken(matching credential: AntigravityCredential) -> String? {
        guard let fingerprint = fingerprint(of: credential.refreshToken),
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CachedToken.self, from: data),
              cache.credentialFingerprint == fingerprint,
              cache.expiresAt > Date().addingTimeInterval(refreshBuffer).timeIntervalSince1970,
              let token = cache.accessToken.trimmedNonEmpty else {
            return nil
        }
        return token
    }

    func cache(accessToken: String, expiresIn: TimeInterval, refreshToken: String) {
        guard let fingerprint = fingerprint(of: refreshToken) else { return }
        let value = CachedToken(
            accessToken: accessToken,
            expiresAt: Date().addingTimeInterval(expiresIn).timeIntervalSince1970,
            credentialFingerprint: fingerprint
        )
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cacheURL.path
            )
        } catch {
            print("[Antigravity] 無法儲存短期 token cache：\(error.localizedDescription)")
        }
    }

    func discardCache() {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIUsageBar/antigravity-auth.json")
    }

    private func fingerprint(of refreshToken: String?) -> String? {
        guard let value = refreshToken?.trimmedNonEmpty else { return nil }
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct CachedToken: Codable {
        let accessToken: String
        let expiresAt: TimeInterval
        let credentialFingerprint: String
    }

    nonisolated static func parse(_ raw: String) -> AntigravityCredential? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            let encoded = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        }

        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let token = text.hasPrefix("Bearer ") ? String(text.dropFirst(7)) : text
            return token.trimmedNonEmpty.map { AntigravityCredential(accessToken: $0, refreshToken: nil, expiry: nil) }
        }

        return credential(from: root)
    }

    nonisolated private static func credential(from object: [String: Any]) -> AntigravityCredential? {
        let source = object["token"] as? [String: Any] ?? object
        let access = firstString(in: source, keys: ["access_token", "accessToken", "token", "id_token"])
        let refresh = firstString(in: source, keys: ["refresh_token", "refreshToken"])
        let expiry = firstString(in: source, keys: ["expiry", "expires_at", "expiresAt"]).flatMap(parseDate)

        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let value = credential(from: nested) {
                    return value
                }
            }
            return nil
        }
        return AntigravityCredential(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    nonisolated private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { (object[$0] as? String)?.trimmedNonEmpty }.first
    }

    nonisolated private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
