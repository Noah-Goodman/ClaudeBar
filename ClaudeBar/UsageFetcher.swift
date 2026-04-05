import Foundation
import Darwin

enum FetchError: Error {
    case claudeNotInstalled
    case timedOut
    case parseFailed(String)
}

actor CLISession {
    static let shared = CLISession()

    private var process: Process?
    private var primaryFD: Int32 = -1
    private var primaryHandle: FileHandle?
    private var secondaryHandle: FileHandle?
    private var startedAt: Date?

    private let autoResponses: [String: String] = [
        "Do you trust the files in this folder?": "y\r",
        "Quick safety check:": "\r",
        "Yes, I trust this folder": "\r",
        "Ready to code here?": "\r",
        "Press Enter to continue": "\r",
        "Show plan": "\r",
        "Show plan usage limits": "\r",
    ]

    func fetchUsage() async throws -> String {
        let binary = Self.findClaudeBinary()
        guard let binary else { throw FetchError.claudeNotInstalled }

        try self.ensureStarted(binary: binary)

        if let startedAt {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed < 2.0 {
                try await Task.sleep(nanoseconds: UInt64((2.0 - elapsed) * 1_000_000_000))
            }
        }

        self.drain()
        try self.write("/usage\r")

        let stopNeedles = [
            "currentsession",
            "currentweek",
            "failedtoloadusagedata",
        ]

        var buffer = Data()
        var scanText = ""
        var triggeredKeys = Set<String>()
        let deadline = Date().addingTimeInterval(20)
        var lastOutput = Date()

        while Date() < deadline {
            let chunk = self.readChunk()
            if !chunk.isEmpty {
                buffer.append(chunk)
                lastOutput = Date()
                if let text = String(data: chunk, encoding: .utf8) {
                    scanText.append(text)
                    if scanText.count > 16384 { scanText = String(scanText.suffix(8192)) }
                }
            }

            if scanText.contains("\u{001B}[6n") {
                try? self.write("\u{001B}[1;1R")
            }

            let stripped = Self.stripANSI(scanText).lowercased().filter { !$0.isWhitespace }

            for (needle, response) in self.autoResponses {
                let normalizedNeedle = needle.lowercased().filter { !$0.isWhitespace }
                if !triggeredKeys.contains(normalizedNeedle) && stripped.contains(normalizedNeedle) {
                    try? self.write(response)
                    triggeredKeys.insert(normalizedNeedle)
                }
            }

            if stopNeedles.contains(where: stripped.contains) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let finalChunk = self.readChunk()
                if !finalChunk.isEmpty { buffer.append(finalChunk) }
                break
            }

            if !buffer.isEmpty && Date().timeIntervalSince(lastOutput) >= 3.0 {
                break
            }

            try? self.write("\r")
            try await Task.sleep(nanoseconds: 800_000_000)

            if let process, !process.isRunning {
                throw FetchError.timedOut
            }
        }

        self.reset()

        guard !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) else {
            throw FetchError.timedOut
        }

        return Self.stripANSI(text)
    }

    func reset() {
        if let process, process.isRunning {
            try? self.write("/exit\r")
        }
        try? self.primaryHandle?.close()
        try? self.secondaryHandle?.close()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            if pid > 0 { kill(-pid, SIGTERM) }
        }
        self.process = nil
        self.primaryHandle = nil
        self.secondaryHandle = nil
        self.primaryFD = -1
        self.startedAt = nil
    }

    private func ensureStarted(binary: String) throws {
        if let process, process.isRunning { return }
        self.reset()

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var window = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &window) == 0 else {
            throw FetchError.parseFailed("openpty failed")
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        let primaryHandle = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)

        let workDir = Self.probeDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--allowed-tools", ""]
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle
        process.currentDirectoryURL = workDir

        var environment = Self.enrichedEnvironment()
        environment["PWD"] = workDir.path
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        process.environment = environment

        try process.run()

        let pid = process.processIdentifier
        if pid > 0 { setpgid(pid, pid) }

        self.process = process
        self.primaryFD = primaryFD
        self.primaryHandle = primaryHandle
        self.secondaryHandle = secondaryHandle
        self.startedAt = Date()
    }

    private func readChunk() -> Data {
        guard self.primaryFD >= 0 else { return Data() }
        var result = Data()
        while true {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(self.primaryFD, &buffer, buffer.count)
            if bytesRead > 0 {
                result.append(contentsOf: buffer.prefix(bytesRead))
                continue
            }
            break
        }
        return result
    }

    private func drain() { _ = self.readChunk() }

    private func write(_ text: String) throws {
        guard let data = text.data(using: .utf8), self.primaryFD >= 0 else { return }
        data.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            var offset = 0
            var retries = 0
            while offset < rawBytes.count {
                let written = Darwin.write(self.primaryFD, base.advanced(by: offset), rawBytes.count - offset)
                if written > 0 { offset += written; retries = 0; continue }
                if written < 0 && (errno == EAGAIN || errno == EINTR || errno == EWOULDBLOCK) {
                    retries += 1
                    if retries > 200 { break }
                    usleep(5000)
                    continue
                }
                break
            }
        }
    }

    // MARK: - Environment

    private static func enrichedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.enrichedPATH(environment: environment)
        if environment["HOME"]?.isEmpty ?? true {
            environment["HOME"] = NSHomeDirectory()
        }
        if environment["TERM"]?.isEmpty ?? true {
            environment["TERM"] = "xterm-256color"
        }
        if environment["COLORTERM"]?.isEmpty ?? true {
            environment["COLORTERM"] = "truecolor"
        }
        if environment["LANG"]?.isEmpty ?? true {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    private static func enrichedPATH(environment: [String: String]) -> String {
        var paths: [String] = []
        let home = NSHomeDirectory()

        let extraPaths = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.local/share/claude",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.volta/bin",
            "\(home)/.fnm/aliases/default/bin",
        ]
        paths.append(contentsOf: extraPaths)

        if let loginShellPATH = Self.loginShellPATH() {
            paths.append(contentsOf: loginShellPATH.split(separator: ":").map(String.init))
        }

        if let existingPATH = environment["PATH"] {
            paths.append(contentsOf: existingPATH.split(separator: ":").map(String.init))
        }

        var seen = Set<String>()
        return paths.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private nonisolated(unsafe) static var cachedLoginPATH: String?
    private static func loginShellPATH() -> String? {
        if let cached = self.cachedLoginPATH { return cached }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.cachedLoginPATH = result
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Binary resolution

    static func findClaudeBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["CLAUDE_CLI_PATH"],
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ].compactMap { $0 }

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return Self.resolveSymlink(path)
            }
        }

        if let shellResolved = Self.shellCommandV("claude") {
            return shellResolved
        }

        return nil
    }

    private static func resolveSymlink(_ path: String) -> String {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? path
    }

    private static func shellCommandV(_ tool: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(tool)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return path
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    static func stripANSI(_ text: String) -> String {
        let pattern = #"\u001B\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func probeDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("ClaudeBar/Probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum UsageParser {
    struct ParsedUsage: Sendable {
        let sessionPercentUsed: Int?
        let weeklyPercentUsed: Int?
        let sonnetPercentUsed: Int?
        let sessionReset: String?
        let weeklyReset: String?
        let sonnetReset: String?
    }

    static func parse(_ text: String) throws -> ParsedUsage {
        let panelText = Self.trimToUsagePanel(text) ?? text
        let lines = panelText.components(separatedBy: .newlines)
        let normalizedLines = lines.map { Self.normalize($0) }

        var sessionPct = Self.extractPercent(label: "currentsession", lines: lines, normalizedLines: normalizedLines)
        var weeklyPct = Self.extractPercent(label: "currentweekallmodels", lines: lines, normalizedLines: normalizedLines)
            ?? Self.extractPercent(label: "currentweek", lines: lines, normalizedLines: normalizedLines)
        var sonnetPct = Self.extractPercent(label: "currentweeksonnet", lines: lines, normalizedLines: normalizedLines)
            ?? Self.extractPercent(label: "currentweeksonnetonly", lines: lines, normalizedLines: normalizedLines)

        if sessionPct == nil || weeklyPct == nil || sonnetPct == nil {
            let ordered = Self.allPercents(lines)
            if sessionPct == nil, ordered.indices.contains(0) { sessionPct = ordered[0] }
            if weeklyPct == nil, ordered.indices.contains(1) { weeklyPct = ordered[1] }
            if sonnetPct == nil, ordered.indices.contains(2) { sonnetPct = ordered[2] }
        }

        guard sessionPct != nil else {
            throw FetchError.parseFailed("Could not find session usage in CLI output")
        }

        let sessionReset = Self.extractReset(label: "currentsession", lines: lines, normalizedLines: normalizedLines)
        let weeklyReset = Self.extractReset(label: "currentweekallmodels", lines: lines, normalizedLines: normalizedLines)
            ?? Self.extractReset(label: "currentweek", lines: lines, normalizedLines: normalizedLines)
        let sonnetReset = Self.extractReset(label: "currentweeksonnet", lines: lines, normalizedLines: normalizedLines)
            ?? Self.extractReset(label: "currentweeksonnetonly", lines: lines, normalizedLines: normalizedLines)

        return ParsedUsage(
            sessionPercentUsed: sessionPct.map { 100 - $0 },
            weeklyPercentUsed: weeklyPct.map { 100 - $0 },
            sonnetPercentUsed: sonnetPct.map { 100 - $0 },
            sessionReset: sessionReset,
            weeklyReset: weeklyReset,
            sonnetReset: sonnetReset)
    }

    private static func extractPercent(label: String, lines: [String], normalizedLines: [String]) -> Int? {
        for (index, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = lines.dropFirst(index).prefix(12)
            for candidate in window {
                if let percent = Self.percentFromLine(candidate) { return percent }
            }
        }
        return nil
    }

    private static func percentFromLine(_ line: String) -> Int? {
        if Self.isStatusContextLine(line) { return nil }

        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line)
        else { return nil }

        let rawValue = Double(line[valueRange]) ?? 0
        let clamped = max(0, min(100, rawValue))
        let lower = line.lowercased()

        if ["used", "spent", "consumed"].contains(where: lower.contains) {
            return Int(max(0, 100 - clamped).rounded())
        }
        if ["left", "remaining", "available"].contains(where: lower.contains) {
            return Int(clamped.rounded())
        }
        return nil
    }

    private static func isStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        return ["opus", "sonnet", "haiku", "default"].contains(where: lower.contains)
    }

    private static func allPercents(_ lines: [String]) -> [Int] {
        lines.compactMap { Self.percentFromLine($0) }
    }

    private static func extractReset(label: String, lines: [String], normalizedLines: [String]) -> String? {
        for (index, normalizedLine) in normalizedLines.enumerated() where normalizedLine.contains(label) {
            let window = lines.dropFirst(index).prefix(14)
            for candidate in window {
                let normalized = Self.normalize(candidate)
                if normalized.hasPrefix("current") && !normalized.contains(label) { break }
                if let reset = Self.resetFromLine(candidate) { return reset }
            }
        }
        return nil
    }

    private static func resetFromLine(_ line: String) -> String? {
        guard let range = line.range(of: "Resets", options: .caseInsensitive) else { return nil }
        var cleaned = String(line[range.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let parenStart = cleaned.lastIndex(of: "(") {
            cleaned = String(cleaned[..<parenStart])
                .trimmingCharacters(in: .whitespaces)
        }
        return cleaned
    }

    private static func trimToUsagePanel(_ text: String) -> String? {
        guard let settingsRange = text.range(of: "Settings:", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        let tail = text[settingsRange.lowerBound...]
        guard tail.range(of: "Usage", options: .caseInsensitive) != nil else { return nil }
        let lower = tail.lowercased()
        guard lower.contains("%") && (lower.contains("used") || lower.contains("left") || lower.contains("remaining"))
        else { return nil }
        return String(tail)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}
