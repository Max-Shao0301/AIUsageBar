import Foundation

struct AntigravityOAuthClient: Sendable {
    let id: String
    let secret: String
}

/// Reads the installed-app OAuth configuration bundled in Antigravity's language server.
/// The values stay in memory and are never logged or copied into AIUsageBar's storage.
struct AntigravityOAuthClientDiscovery: Sendable {
    private static let clientIDPattern = #"[0-9]{6,}-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com"#
    private static let clientSecretPattern = #"GOCSPX-[A-Za-z0-9_-]{28}"#

    nonisolated func discover() -> AntigravityOAuthClient? {
        for executable in languageServerPaths() {
            guard let strings = runStrings(executable),
                  let id = firstMatch(Self.clientIDPattern, in: strings),
                  let secret = firstMatch(Self.clientSecretPattern, in: strings)
            else { continue }
            return AntigravityOAuthClient(id: id, secret: secret)
        }
        return nil
    }

    nonisolated private func languageServerPaths() -> [String] {
        let fileManager = FileManager.default
        let applicationDirectories = [
            "/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        let bundleNames = ["Antigravity.app", "Antigravity IDE.app"]

        return applicationDirectories.flatMap { directory in
            bundleNames.map { bundleName in
                URL(fileURLWithPath: directory)
                    .appendingPathComponent(bundleName)
                    .appendingPathComponent("Contents/Resources/bin/language_server")
                    .path
            }
        }.filter(fileManager.fileExists(atPath:))
    }

    nonisolated private func runStrings(_ executable: String) -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/strings")
        task.arguments = [executable]
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }
}
