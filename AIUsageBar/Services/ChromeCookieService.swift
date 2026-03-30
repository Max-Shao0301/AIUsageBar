import Foundation
import Security
import CommonCrypto
import SQLite3

// MARK: - Chromium Cookie Decryptor（macOS）
// Claude Desktop App 是 Electron（Chromium）App
// macOS 上的 Cookie 加密流程：
//   1. 在 Keychain 存一組隨機 password（服務名稱：Claude Safe Storage）
//   2. PBKDF2(password, salt="saltysalt", iter=1003) → 16-byte AES Key
//   3. AES-128-CBC(key, iv=" "*16) 加密 cookie value，前綴 "v10" 或 "v11"

final class ChromeCookieService {
    static let shared = ChromeCookieService()
    private init() {}

    private let cookieDBPath = NSHomeDirectory()
        + "/Library/Application Support/Claude/Cookies"

    // MARK: - Public
    func getSessionKey() throws -> String {
        let rawPasswordData = try safeStorageRawData()
        return try readAndDecryptSessionKey(rawPasswordData: rawPasswordData)
    }

    // MARK: - Step 1：從 Keychain 取得 Safe Storage 原始 bytes
    private func safeStorageRawData() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "Claude Safe Storage",
            kSecAttrAccount: "Claude Key",
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CookieError.safeStorageKeyNotFound
        }
        #if DEBUG
        print("🔑 [ChromeCookieService] Keychain raw data length=\(data.count)")
        #endif
        return data
    }

    // MARK: - Step 2：多策略推導 AES Key
    private func deriveKey(from rawData: Data, strategy: KeyStrategy) -> Data? {
        let salt = Array("saltysalt".utf8)
        switch strategy {

        // 策略 A：標準 Chromium PBKDF2-SHA1，1003 iterations，16-byte key
        case .pbkdf2SHA1_1003_16:
            var derivedKey = [UInt8](repeating: 0, count: 16)
            let result = rawData.withUnsafeBytes { pwdPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdPtr.baseAddress?.assumingMemoryBound(to: CChar.self), rawData.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    &derivedKey, 16
                )
            }
            return result == kCCSuccess ? Data(derivedKey) : nil

        // 策略 B：PBKDF2-SHA1，1 iteration（某些 Electron 版本）
        case .pbkdf2SHA1_1_16:
            var derivedKey = [UInt8](repeating: 0, count: 16)
            let result = rawData.withUnsafeBytes { pwdPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdPtr.baseAddress?.assumingMemoryBound(to: CChar.self), rawData.count,
                    salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1,
                    &derivedKey, 16
                )
            }
            return result == kCCSuccess ? Data(derivedKey) : nil

        // 策略 C：直接用 Keychain 的前 16 bytes 當 AES Key（跳過 PBKDF2）
        case .rawKeyFirst16:
            guard rawData.count >= 16 else { return nil }
            return rawData.prefix(16)

        // 策略 D：SHA256 hash 前 16 bytes
        case .sha256First16:
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            rawData.withUnsafeBytes { ptr in
                _ = CC_SHA256(ptr.baseAddress, CC_LONG(rawData.count), &hash)
            }
            return Data(hash.prefix(16))
        }
    }

    enum KeyStrategy: CaseIterable {
        case pbkdf2SHA1_1003_16
        case pbkdf2SHA1_1_16
        case rawKeyFirst16
        case sha256First16
    }

    // MARK: - Step 3：讀 SQLite + 多策略試解密
    private func readAndDecryptSessionKey(rawPasswordData: Data) throws -> String {
        let encryptedData = try readEncryptedSessionKey()

        // PBKDF2 key（PKCS7 驗證正確）
        guard let pbkdf2Key = deriveKey(from: rawPasswordData, strategy: .pbkdf2SHA1_1003_16) else {
            throw CookieError.keyDerivationFailed
        }

        // AES-128-CBC 解密（IV = spaces，key 已確認正確）
        let iv = Data(repeating: 0x20, count: 16)
        guard let raw = tryCBCDecryptRaw(encryptedData.dropFirst(3), key: pbkdf2Key, iv: iv) else {
            throw CookieError.decryptionFailed("AES 解密失敗")
        }

        // Cookie 前 32 bytes 是 binary header，session key 從 "sk-ant-" 開始
        guard let markerData = "sk-ant-".data(using: .utf8),
              let range = raw.range(of: markerData) else {
            throw CookieError.decryptionFailed("找不到 sk-ant- 標記，decrypted=\(raw.count) bytes")
        }

        let sessionKeyData = raw[range.lowerBound...]
        guard let sessionKey = String(data: sessionKeyData, encoding: .utf8) else {
            throw CookieError.decryptionFailed("session key UTF-8 解碼失敗")
        }

        return sessionKey
    }

    private func readEncryptedSessionKey() throws -> Data {
        // 複製 DB 到暫存位置（避免 Chromium 的檔案鎖）
        let tempPath = NSTemporaryDirectory() + "aiu_claude_cookies.db"
        let src = URL(fileURLWithPath: cookieDBPath)
        let dst = URL(fileURLWithPath: tempPath)

        try? FileManager.default.removeItem(at: dst)
        do {
            try FileManager.default.copyItem(at: src, to: dst)
        } catch {
            throw CookieError.cannotReadCookieDB(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: dst) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieError.cannotReadCookieDB("sqlite3_open 失敗")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE (host_key = '.claude.ai' OR host_key = 'claude.ai')
          AND name = 'sessionKey'
        ORDER BY expires_utc DESC LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CookieError.sessionKeyNotFound
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw CookieError.sessionKeyNotFound
        }

        let size = Int(sqlite3_column_bytes(stmt, 0))
        guard let blobPtr = sqlite3_column_blob(stmt, 0), size > 3 else {
            throw CookieError.sessionKeyNotFound
        }
        return Data(bytes: blobPtr, count: size)
    }

    // MARK: - Step 4：AES-128-CBC 解密（帶驗證）
    private func tryCBCDecrypt(_ cipher: Data, key: Data, iv: Data) -> String? {
        guard let raw = tryCBCDecryptRaw(cipher, key: key, iv: iv) else { return nil }
        // 嘗試 UTF-8
        if let s = String(data: raw, encoding: .utf8), s.count > 10 { return s }
        // 嘗試去除 null bytes
        let trimmed = raw.filter { $0 != 0 }
        if let s = String(data: Data(trimmed), encoding: .utf8), s.count > 10 { return s }
        return nil
    }

    private func tryCBCDecryptRaw(_ cipher: Data, key: Data, iv: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = key.withUnsafeBytes { kp in
            iv.withUnsafeBytes { ip in
                cipher.withUnsafeBytes { cp in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionPKCS7Padding),
                            kp.baseAddress, key.count, ip.baseAddress,
                            cp.baseAddress, cipher.count,
                            &out, out.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess, outLen > 0 else { return nil }
        return Data(out.prefix(outLen))
    }

}

// MARK: - Errors
enum CookieError: Error, LocalizedError {
    case safeStorageKeyNotFound
    case keyDerivationFailed
    case cannotReadCookieDB(String)
    case sessionKeyNotFound
    case decryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .safeStorageKeyNotFound:       return "Keychain 找不到 Claude Safe Storage。"
        case .keyDerivationFailed:          return "AES Key 推導失敗。"
        case .cannotReadCookieDB(let d):    return "無法讀取 Cookie 資料庫：\(d)"
        case .sessionKeyNotFound:           return "Cookie 資料庫中找不到 sessionKey。\n請確認已登入 Claude Desktop App。"
        case .decryptionFailed(let d):      return "Cookie 解密失敗：\(d)"
        }
    }
}
