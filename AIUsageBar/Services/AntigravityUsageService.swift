import Foundation
import Darwin

enum AntigravityUsageServiceError: Error, LocalizedError {
    case cliNotInstalled
    case startupTimedOut
    case invalidResponse(Int)
    case invalidPayload
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return "找不到 agy CLI。請先安裝並登入 Antigravity CLI。"
        case .startupTimedOut:
            return "agy 啟動逾時。請先在終端機執行 agy 並完成登入。"
        case .invalidResponse(let statusCode):
            return "Antigravity 本機服務回傳錯誤 HTTP \(statusCode)。"
        case .invalidPayload:
            return "Antigravity 用量資料格式無法辨識。"
        case .networkError(let error):
            return "無法連線 Antigravity 本機服務：\(error.localizedDescription)"
        }
    }
}

/// Fetches the two shared Antigravity quota pools shown in its Model Quota UI.
///
/// The service reads the quota summary from the signed-in `agy` CLI's loopback
/// language server. When the CLI is not already running, it briefly starts an
/// interactive background session and immediately terminates that session after
/// reading the quota. This avoids handling Google OAuth credentials in the app.
final class AntigravityUsageService {
    static let shared = AntigravityUsageService()
    private init() {}

    private let localSession = URLSession(
        configuration: .ephemeral,
        delegate: LoopbackTrustDelegate(),
        delegateQueue: nil
    )

    func fetchUsage() async throws -> AntigravityUsageData {
        let ports = agyListeningPorts()
        if !ports.isEmpty {
            return try await fetchUsage(from: ports)
        }

        guard let cliPath = agyCLIPath() else {
            throw AntigravityUsageServiceError.cliNotInstalled
        }

        let backgroundSession = try AgyBackgroundSession(binaryPath: cliPath)
        defer { backgroundSession.stop() }

        try backgroundSession.start()
        return try await waitForUsageFromLaunchedCLI(backgroundSession)
    }

    private func fetchUsage(from ports: [Int]) async throws -> AntigravityUsageData {
        var lastError: Error?
        for port in ports {
            do {
                let data = try await fetchQuotaSummary(port: port)
                let groups = try parseGroups(from: data)
                return AntigravityUsageData(
                    gemini: groups.first(where: { $0.displayName.localizedCaseInsensitiveContains("gemini") }),
                    claudeAndGPT: groups.first(where: { group in
                        let name = group.displayName.lowercased()
                        return name.contains("claude") || name.contains("gpt")
                    })
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AntigravityUsageServiceError.invalidPayload
    }

    private func waitForUsageFromLaunchedCLI(_ backgroundSession: AgyBackgroundSession) async throws -> AntigravityUsageData {
        let deadline = Date().addingTimeInterval(15)
        var lastError: Error?

        while Date() < deadline {
            backgroundSession.drainOutput()
            let ports = agyListeningPorts()
            if !ports.isEmpty {
                do {
                    return try await fetchUsage(from: ports)
                } catch {
                    lastError = error
                }
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        if let lastError { throw lastError }
        throw AntigravityUsageServiceError.startupTimedOut
    }

    // MARK: - agy Local Server

    private func agyListeningPorts() -> [Int] {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-a", "-c", "agy", "-iTCP", "-sTCP:LISTEN"]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return []
        }
        guard task.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return []
        }

        let pattern = "127\\.0\\.0\\.1:([0-9]+)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let ports = expression.matches(in: text, range: range).compactMap { match -> Int? in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[valueRange])
        }
        return Array(Set(ports)).sorted()
    }

    private func agyCLIPath() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let configuredPath = environment["ANTIGRAVITY_CLI_PATH"] {
            candidates.append(configuredPath)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy"
        ])

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/agy" })
        }

        return candidates.first { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    private func fetchQuotaSummary(port: Int) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
        guard let url = components.url else { throw AntigravityUsageServiceError.invalidPayload }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.timeoutInterval = 5
        request.httpBody = Data("{}".utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await localSession.data(for: request)
        } catch {
            throw AntigravityUsageServiceError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityUsageServiceError.invalidResponse(0)
        }
        guard http.statusCode == 200 else {
            throw AntigravityUsageServiceError.invalidResponse(http.statusCode)
        }
        return data
    }

    // MARK: - Response Parsing

    private func parseGroups(from data: Data) throws -> [AntigravityQuotaGroup] {
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityUsageServiceError.invalidPayload
        }
        // Connect protocol responses wrap the language-server payload in `response`.
        let raw = outer["response"] as? [String: Any] ?? outer
        guard let rawGroups = raw["groups"] as? [[String: Any]] else {
            throw AntigravityUsageServiceError.invalidPayload
        }

        let groups = rawGroups.compactMap { rawGroup -> AntigravityQuotaGroup? in
            guard let displayName = rawGroup["displayName"] as? String,
                  let rawBuckets = rawGroup["buckets"] as? [[String: Any]] else {
                return nil
            }

            var fiveHour: AntigravityUsageWindow?
            var weekly: AntigravityUsageWindow?
            for bucket in rawBuckets {
                guard let window = parseWindow(bucket) else { continue }
                let descriptor = [bucket["window"], bucket["displayName"], bucket["bucketId"]]
                    .compactMap { $0 as? String }
                    .joined(separator: " ")
                    .lowercased()

                if descriptor.contains("week") {
                    weekly = window
                } else if descriptor.contains("hour") || descriptor.contains("5h") {
                    fiveHour = window
                }
            }

            guard fiveHour != nil || weekly != nil else { return nil }
            return AntigravityQuotaGroup(
                displayName: displayName,
                fiveHour: fiveHour,
                weekly: weekly
            )
        }

        guard !groups.isEmpty else { throw AntigravityUsageServiceError.invalidPayload }
        return groups
    }

    private func parseWindow(_ bucket: [String: Any]) -> AntigravityUsageWindow? {
        let remaining = number(bucket["remainingFraction"])
            ?? (bucket["remaining"] as? [String: Any]).flatMap { number($0["remainingFraction"]) }
        guard let remaining else { return nil }

        return AntigravityUsageWindow(
            usedPercent: min(max((1 - remaining) * 100, 0), 100),
            resetAt: parseDate(bucket["resetTime"])
        )
    }

    private func parseDate(_ value: Any?) -> Date? {
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

/// Owns only the short-lived `agy` process launched by AIUsageBar. A pseudo-terminal
/// is required because `agy` starts its local language server from an interactive CLI.
private final class AgyBackgroundSession {
    private let binaryPath: String
    private var processID: pid_t = 0
    private var primaryFD: Int32 = -1

    init(binaryPath: String) throws {
        self.binaryPath = binaryPath
    }

    deinit {
        stop()
    }

    func start() throws {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var windowSize = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&primaryFD, &secondaryFD, nil, nil, &windowSize) == 0 else {
            throw AntigravityUsageServiceError.startupTimedOut
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(primaryFD)
            close(secondaryFD)
            throw AntigravityUsageServiceError.startupTimedOut
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, primaryFD)
        posix_spawn_file_actions_addclose(&fileActions, secondaryFD)
        _ = NSHomeDirectory().withCString {
            posix_spawn_file_actions_addchdir(&fileActions, $0)
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            close(primaryFD)
            close(secondaryFD)
            throw AntigravityUsageServiceError.startupTimedOut
        }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = NSHomeDirectory()
        environment["TERM"] = "xterm-256color"
        environment["CI"] = "0"

        var arguments = [strdup(binaryPath), nil]
        defer {
            for case let pointer? in arguments {
                free(UnsafeMutableRawPointer(pointer))
            }
        }
        var environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") }
        environmentPointers.append(nil)
        defer {
            for case let pointer? in environmentPointers {
                free(UnsafeMutableRawPointer(pointer))
            }
        }

        var pid: pid_t = 0
        let result = binaryPath.withCString { executablePath in
            posix_spawn(&pid, executablePath, &fileActions, &attributes, &arguments, &environmentPointers)
        }
        close(secondaryFD)

        guard result == 0 else {
            close(primaryFD)
            throw AntigravityUsageServiceError.startupTimedOut
        }

        self.processID = pid
        self.primaryFD = primaryFD
    }

    func drainOutput() {
        guard primaryFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while read(primaryFD, &buffer, buffer.count) > 0 {}
    }

    func stop() {
        let pid = processID
        guard pid > 0 else {
            closePrimaryFD()
            return
        }

        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<5 {
            if waitpid(pid, &status, WNOHANG) == pid { break }
            usleep(50_000)
        }
        if waitpid(pid, &status, WNOHANG) == 0 {
            kill(-pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
        }

        processID = 0
        closePrimaryFD()
    }

    private func closePrimaryFD() {
        guard primaryFD >= 0 else { return }
        close(primaryFD)
        primaryFD = -1
    }
}

private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
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
