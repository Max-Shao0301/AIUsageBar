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
            return "找不到 Codex 用量快取資料。"
        }
    }
}

// MARK: - CodexUsageService
final class CodexUsageService {
    static let shared = CodexUsageService()
    private init() {}

    private let usageURLMarker = Data("https://chatgpt.com/backend-api/wham/usage".utf8)
    private let brotliPaths = [
        "/opt/homebrew/bin/brotli",
        "/usr/local/bin/brotli",
        "/usr/bin/brotli"
    ]

    func fetchUsage() async throws -> CodexUsageData {
        // 這裡走本機快取，不打官方公開 API
        try loadUsageFromCache()
    }

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
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                    return nil
                }
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

            let offsets = Array(Set(candidateOffsets)).sorted()

            for offset in offsets {
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(compressed)
            stdinPipe.fileHandleForWriting.closeFile()

            let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // Chromium cache tail 常帶附加位元組，brotli 可能回非 0，但輸出仍是完整 JSON
            guard !output.isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }
}
