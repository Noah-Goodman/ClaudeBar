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
            if elapsed < 2.5 {
                try await Task.sleep(nanoseconds: UInt64((2.5 - elapsed) * 1_000_000_000))
            }
        }

        // Drain the welcome screen, auto-respond to any prompts that appeared during boot.
        try await self.handleBootPrompts(deadline: Date().addingTimeInterval(3.0))

        try self.write("/usage\r")

        var buffer = Data()
        var scanText = ""
        var triggeredKeys = Set<String>()
        let deadline = Date().addingTimeInterval(25)
        var lastOutputAt = Date()
        var sectionsSeenAt: Date?
        var nudged = false

        while Date() < deadline {
            let chunk = self.readChunk()
            if !chunk.isEmpty {
                buffer.append(chunk)
                lastOutputAt = Date()
                if let text = String(data: chunk, encoding: .utf8) {
                    scanText.append(text)
                    if scanText.count > 65536 { scanText = String(scanText.suffix(32768)) }
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

            if stripped.contains("failedtoloadusagedata") || stripped.contains("ratelimitexceeded") {
                try await Task.sleep(nanoseconds: 800_000_000)
                let finalChunk = self.readChunk()
                if !finalChunk.isEmpty { buffer.append(finalChunk) }
                break
            }

            let hasSession = stripped.contains("currentsession")
            let hasWeekly = stripped.contains("currentweek")
            if hasSession && hasWeekly {
                if sectionsSeenAt == nil { sectionsSeenAt = Date() }
                // The first render of the /usage panel often emits text incrementally with
                // CSI cursor-advance escapes between letters (e.g. "Rese\u{1B}[1Cs\u{1B}[1CM\u{1B}[1Cy"
                // for "Resets May"), which our ANSI strip flattens to mangled text. A benign
                // arrow-key nudge (down then up) forces a clean full re-render at the same
                // scroll position.
                if !nudged, let sectionsSeenAt, Date().timeIntervalSince(sectionsSeenAt) >= 0.4 {
                    try? self.write("\u{001B}[B")
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try? self.write("\u{001B}[A")
                    nudged = true
                    lastOutputAt = Date()
                }
                if nudged {
                    let sinceLastOutput = Date().timeIntervalSince(lastOutputAt)
                    let sinceSeen = Date().timeIntervalSince(sectionsSeenAt ?? Date())
                    if sinceLastOutput >= 1.2 || sinceSeen >= 6.0 {
                        break
                    }
                }
            }

            if !buffer.isEmpty && Date().timeIntervalSince(lastOutputAt) >= 5.0 {
                // No progress for 5s without seeing the headings — give up.
                break
            }

            try await Task.sleep(nanoseconds: 200_000_000)

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

    private func handleBootPrompts(deadline: Date) async throws {
        var triggeredKeys = Set<String>()
        var scanText = ""
        while Date() < deadline {
            let chunk = self.readChunk()
            if !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) {
                scanText.append(text)
                if scanText.count > 16384 { scanText = String(scanText.suffix(8192)) }
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
            try await Task.sleep(nanoseconds: 150_000_000)
        }
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
        let spaced = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let collapsePattern = #" {2,}"#
        guard let collapseRegex = try? NSRegularExpression(pattern: collapsePattern) else { return spaced }
        let spacedRange = NSRange(spaced.startIndex..<spaced.endIndex, in: spaced)
        return collapseRegex.stringByReplacingMatches(in: spaced, range: spacedRange, withTemplate: " ")
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
        let fablePercentUsed: Int?
        let sessionReset: String?
        let weeklyReset: String?
        let fableReset: String?
        let extraUsagePercentUsed: Int?
        let extraUsageReset: String?
        let extraUsageSpent: String?
        let extraUsageUnlimited: Bool
    }

    private struct Metric {
        let usedPercent: Int?
        let reset: String?
        let spent: String?
        let unlimited: Bool
    }

    // Every section heading in the /usage panel, normalized to alphanumeric-only.
    // Used as boundaries when we slice the text into per-metric windows.
    private static let allSectionKeys = [
        "currentsession",
        "currentweekallmodels",
        "currentweek",
        "currentweekfable",
        "extrausage",
        "additionalusage",
        "exrausage",
    ]

    static func parse(_ text: String) throws -> ParsedUsage {
        let lines = text.components(separatedBy: .newlines)
        let normalizedLines = lines.map { Self.normalize($0) }

        let session = Self.findMetric(
            primaryKeys: ["currentsession"],
            mustNotContain: ["week"],
            lines: lines, normalizedLines: normalizedLines)

        let weekly = Self.findMetric(
            primaryKeys: ["currentweekallmodels", "currentweek"],
            mustNotContain: ["fable"],
            lines: lines, normalizedLines: normalizedLines)

        let fable = Self.findMetric(
            primaryKeys: ["currentweekfable"],
            mustNotContain: [],
            lines: lines, normalizedLines: normalizedLines)

        let extra = Self.findMetric(
            primaryKeys: ["extrausage", "additionalusage", "exrausage"],
            mustNotContain: [],
            lines: lines, normalizedLines: normalizedLines)

        guard let session, session.usedPercent != nil else {
            throw FetchError.parseFailed("Could not find session usage in CLI output")
        }

        return ParsedUsage(
            sessionPercentUsed: session.usedPercent,
            weeklyPercentUsed: weekly?.usedPercent,
            fablePercentUsed: fable?.usedPercent,
            sessionReset: session.reset,
            weeklyReset: weekly?.reset,
            fableReset: fable?.reset,
            extraUsagePercentUsed: extra?.usedPercent,
            extraUsageReset: extra?.reset,
            extraUsageSpent: extra?.spent,
            extraUsageUnlimited: extra?.unlimited ?? false)
    }

    /// Find a metric by walking the text and locating the LAST occurrence of one of the
    /// label keys that has usable data (percent + direction, or "Unlimited"). The /usage
    /// panel re-renders multiple times (loading skeleton -> partial -> full); the latest
    /// render is the one we trust.
    private static func findMetric(
        primaryKeys: [String],
        mustNotContain: [String],
        lines: [String], normalizedLines: [String]) -> Metric?
    {
        var best: Metric?
        for index in 0..<normalizedLines.count {
            let nl = normalizedLines[index]
            let matchesKey = primaryKeys.contains(where: nl.contains)
            guard matchesKey else { continue }
            if mustNotContain.contains(where: nl.contains) { continue }

            // Window: this line through the next section heading, capped at 16 lines.
            var endIdx = min(index + 16, lines.count)
            for j in (index + 1)..<min(index + 16, normalizedLines.count) {
                let candidate = normalizedLines[j]
                let isOtherSection = Self.allSectionKeys.contains(where: { key in
                    primaryKeys.contains(key) ? false : candidate.contains(key)
                })
                if isOtherSection {
                    endIdx = j
                    break
                }
            }
            let window = Array(lines[index..<endIdx])

            let usedPercent = Self.findPercentUsed(in: window)
            let reset = Self.findReset(in: window)
            let spent = Self.findSpent(in: window)
            let unlimited = window.contains { $0.lowercased().contains("unlimited") }

            // Carry forward fields from the previous best when the new render's value
            // is missing. The percent can change minute-to-minute so we always take the
            // latest, but reset/spent are slow-changing — if a later render mangled them
            // we'd rather keep the earlier clean version than drop them entirely.
            if usedPercent != nil || unlimited {
                best = Metric(
                    usedPercent: usedPercent,
                    reset: reset ?? best?.reset,
                    spent: spent ?? best?.spent,
                    unlimited: unlimited)
            }
        }
        return best
    }

    private static func findPercentUsed(in lines: [String]) -> Int? {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\s*%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        for line in lines {
            if Self.isStatusContextLine(line) { continue }
            let lower = line.lowercased()
            let isUsed = ["used", "spent", "consumed"].contains(where: lower.contains)
            let isLeft = ["left", "remaining", "available"].contains(where: lower.contains)
            guard isUsed || isLeft else { continue }

            let nsRange = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange),
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: line) else { continue }

            let raw = Double(line[valueRange]) ?? 0
            let clamped = max(0, min(100, raw))
            return isUsed ? Int(clamped.rounded()) : Int(max(0, 100 - clamped).rounded())
        }
        return nil
    }

    private static func findReset(in lines: [String]) -> String? {
        for line in lines {
            guard let range = line.range(of: "Resets ", options: .caseInsensitive) else { continue }
            var cleaned = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parenStart = cleaned.firstIndex(of: "(") {
                cleaned = String(cleaned[..<parenStart]).trimmingCharacters(in: .whitespaces)
            }
            // Reject mangled output (e.g., "Resets " with single chars and gaps from a
            // partial render that got overlaid mid-frame). A clean reset always carries
            // a recognizable time token.
            let lower = cleaned.lowercased()
            let timeTokens = ["am", "pm", ":",
                              "jan", "feb", "mar", "apr", "may", "jun",
                              "jul", "aug", "sep", "oct", "nov", "dec",
                              "mon", "tue", "wed", "thu", "fri", "sat", "sun"]
            let hasTime = timeTokens.contains(where: lower.contains)
            if !cleaned.isEmpty && hasTime {
                return cleaned
            }
        }
        return nil
    }

    private static func findSpent(in lines: [String]) -> String? {
        let pattern = #"\$[\d,]+(?:\.\d{2})?\s*/\s*\$[\d,]+(?:\.\d{2})?\s+spent"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: nsRange),
               let r = Range(match.range, in: line) {
                return String(line[r])
            }
        }
        return nil
    }

    private static func isStatusContextLine(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let lower = line.lowercased()
        return ["opus", "sonnet", "haiku", "fable", "mythos", "default"].contains(where: lower.contains)
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }
}
