import Foundation

struct LanguageServerEndpoint: Sendable {
    let csrfToken: String
    let ports: [Int]
    let extensionPort: Int?
}

/// Discovers Antigravity's local Connect-RPC server without launching the CLI.
struct LanguageServerDiscovery: Sendable {
    struct Options: Sendable {
        let processName: String
        let markers: [String]
        let csrfFlag: String
        let portFlag: String?
    }

    nonisolated func discover(_ options: Options) -> LanguageServerEndpoint? {
        guard let processes = run("/bin/ps", ["-ax", "-o", "pid=,command="]) else { return nil }

        for candidate in candidates(in: processes, options: options) {
            let csrfToken: String
            if options.csrfFlag.isEmpty {
                csrfToken = ""
            } else if let value = flagValue(options.csrfFlag, in: candidate.command) {
                csrfToken = value
            } else {
                continue
            }

            let extensionPort = options.portFlag
                .flatMap { flagValue($0, in: candidate.command) }
                .flatMap(Int.init)
            let ports = listeningPorts(for: candidate.pid)
            guard !ports.isEmpty || extensionPort != nil else { continue }

            return LanguageServerEndpoint(
                csrfToken: csrfToken,
                ports: ports,
                extensionPort: extensionPort
            )
        }
        return nil
    }

    nonisolated private func candidates(
        in output: String,
        options: Options
    ) -> [(pid: Int32, command: String)] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let separator = text.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(text[..<separator]) else { return nil }

            let command = String(text[text.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard matchesProcess(command, name: options.processName),
                  matchesMarkers(command, markers: options.markers) else { return nil }
            return (pid, command)
        }
    }

    nonisolated private func matchesProcess(_ command: String, name: String) -> Bool {
        let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let executableName = (executable as NSString).lastPathComponent.lowercased()
        let lowerName = name.lowercased()
        return executableName == lowerName || command.lowercased().contains("/\(lowerName)")
    }

    nonisolated private func matchesMarkers(_ command: String, markers: [String]) -> Bool {
        guard !markers.isEmpty else { return true }
        let normalized = markers.map { $0.lowercased() }
        for flag in ["--ide_name", "--override_ide_name", "--app_data_dir"] {
            if let value = flagValue(flag, in: command)?.lowercased() {
                return normalized.contains(value)
            }
        }
        let lowerCommand = command.lowercased()
        return normalized.contains { lowerCommand.contains("/\($0)/") }
    }

    nonisolated private func flagValue(_ flag: String, in command: String) -> String? {
        let arguments = command.split(separator: " ").map(String.init)
        for (index, argument) in arguments.enumerated() {
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
            let prefix = flag + "="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }
        return nil
    }

    nonisolated private func listeningPorts(for pid: Int32) -> [Int] {
        let lsofPaths = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let path = lsofPaths.first(where: FileManager.default.fileExists(atPath:)),
              let output = run(path, ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
        else { return [] }

        var ports = Set<Int>()
        for line in output.split(whereSeparator: \Character.isNewline) where line.contains("LISTEN") {
            for token in line.split(separator: " ").reversed() {
                guard let colon = token.lastIndex(of: ":"),
                      let port = Int(token[token.index(after: colon)...]),
                      (1..<65_536).contains(port) else { continue }
                ports.insert(port)
                break
            }
        }
        return ports.sorted()
    }

    nonisolated private func run(_ executable: String, _ arguments: [String]) -> String? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        // Drain stdout while the child is running so a full pipe cannot deadlock
        // a large `ps` result before waitUntilExit() returns.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
