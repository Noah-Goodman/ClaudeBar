import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible {
    case notFound
    case accessDenied
    case cancelled
    case missingEntitlement
    case unexpected(OSStatus)

    var description: String {
        switch self {
        case .notFound: return "Keychain item not found"
        case .accessDenied: return "Keychain access denied"
        case .cancelled: return "Keychain prompt cancelled"
        case .missingEntitlement: return "Keychain entitlement missing"
        case .unexpected(let status): return "Keychain error (\(status))"
        }
    }

    static func from(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound: return .notFound
        case errSecAuthFailed, errSecInteractionNotAllowed: return .accessDenied
        case errSecUserCanceled: return .cancelled
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .unexpected(status)
        }
    }
}

enum KeychainStore {
    /// The item Claude Code reads its OAuth credentials from.
    static let liveService = "Claude Code-credentials"
    static var liveAccount: String { NSUserName() }
    /// ClaudeBar's roster: a single item holding every managed account's
    /// credential blob (JSON, keyed by accountUuid). It lives in the Data
    /// Protection keychain, where access is granted by code-signing
    /// entitlements (team + access group) instead of per-binary ACLs and
    /// partition lists — no permission dialogs, ever, and access survives app
    /// updates. Bare `swift build` binaries cannot carry the required
    /// entitlement (that needs a provisioning profile), so they transparently
    /// fall back to a file-based login keychain item.
    static let rosterService = "ClaudeBar-accounts"
    static let rosterAccount = "roster"
    /// First keychain access group from this binary's code-signing
    /// entitlements ($(AppIdentifierPrefix) + bundle identifier); nil for
    /// unprovisioned dev builds, which use the file-based fallback.
    private static let rosterAccessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String]
        else { return nil }
        return groups.first
    }()

    /// Some installs keep credentials in a plain file instead of the keychain.
    private static var credentialsFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
    }

    // MARK: - Roster item (Data Protection keychain, file-based fallback)

    static func readRoster() throws -> Data {
        do {
            return try self.read(service: self.rosterService, account: self.rosterAccount, dataProtection: true)
        } catch KeychainError.missingEntitlement {
            // Unprovisioned dev binary: the file-based item is the store.
            return try self.read(service: self.rosterService, account: self.rosterAccount, dataProtection: false)
        }
    }

    static func writeRoster(_ data: Data) throws {
        do {
            try self.write(service: self.rosterService, account: self.rosterAccount, data: data, dataProtection: true)
        } catch KeychainError.missingEntitlement {
            try self.write(service: self.rosterService, account: self.rosterAccount, data: data, dataProtection: false)
        }
    }

    private static func query(service: String, account: String, dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain] = true
            if let group = self.rosterAccessGroup {
                query[kSecAttrAccessGroup] = group
            }
        }
        return query
    }

    private static func read(service: String, account: String, dataProtection: Bool) throws -> Data {
        var query = self.query(service: service, account: account, dataProtection: dataProtection)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.from(status)
        }
        return data
    }

    /// Update-if-exists, add otherwise. Only for ClaudeBar's own items — the
    /// live Claude Code item must go through `writeLiveBlob` instead.
    private static func write(service: String, account: String, data: Data, dataProtection: Bool) throws {
        let query = self.query(service: service, account: account, dataProtection: dataProtection)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.from(status) }

        var add = query
        add[kSecValueData] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.from(addStatus) }
    }


    // MARK: - Live credential blob (keychain, with file fallback)
    //
    // The claude CLI reads and writes this item by shelling out to
    // /usr/bin/security, which keeps it in the "apple-tool:" keychain
    // partition. Any write from a different signing identity — including a
    // native SecItemUpdate from ClaudeBar — rewrites the partition list to
    // the writer's team, after which the CLI's own reads fail the partition
    // check and macOS demands the login keychain password on every `claude`
    // launch. So ClaudeBar goes through /usr/bin/security for both reads and
    // writes, exactly like the CLI: the item stays in the apple-tool:
    // partition and neither side prompts.

    static func readLiveBlob() throws -> Data {
        let result = try Self.runSecurityTool(arguments: [
            "find-generic-password", "-s", self.liveService, "-a", self.liveAccount, "-w",
        ])
        switch result.status {
        case 0:
            var text = result.stdout
            while text.hasSuffix("\n") { text = String(text.dropLast()) }
            guard let data = text.data(using: .utf8), !data.isEmpty else {
                throw KeychainError.unexpected(errSecDecode)
            }
            return data
        case 44: // security(1) exit code for "item not found"
            let fileURL = self.credentialsFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw KeychainError.notFound
            }
            return try Data(contentsOf: fileURL)
        default:
            throw KeychainError.accessDenied
        }
    }

    static func writeLiveBlob(_ data: Data) throws {
        // Attribute-only probe (no decryption, never prompts) to detect
        // file-based installs, which have no keychain item to update.
        let probe = try Self.runSecurityTool(arguments: [
            "find-generic-password", "-s", self.liveService, "-a", self.liveAccount,
        ])
        if probe.status == 44 { // security(1) exit code for "item not found"
            let fileURL = self.credentialsFileURL
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try data.write(to: fileURL, options: .atomic)
                return
            }
            // No item and no file: fall through and create the item, exactly
            // as a CLI /login would.
        }

        // The hex payload rides on argv, matching what the claude CLI itself
        // does for blobs this size (`security -i` caps stdin lines at ~4KB).
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let result = try Self.runSecurityTool(arguments: [
            "add-generic-password", "-U",
            "-s", self.liveService, "-a", self.liveAccount, "-X", hex,
        ])
        guard result.status == 0 else {
            throw KeychainError.unexpected(OSStatus(result.status))
        }
    }

    private static func runSecurityTool(arguments: [String]) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw KeychainError.unexpected(errSecInternalComponent)
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
