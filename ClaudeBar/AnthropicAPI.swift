import Foundation
import os

enum APIError: Error, CustomStringConvertible {
    case unauthorized
    case rateLimited
    case invalidGrant
    case http(statusCode: Int)
    case network(underlying: Error)
    case decode(message: String)

    var description: String {
        switch self {
        case .unauthorized: return "Not authorized (401/403)"
        case .rateLimited: return "Rate limited (429)"
        case .invalidGrant: return "Refresh token rejected"
        case .http(let statusCode): return "HTTP \(statusCode)"
        case .network(let underlying): return "Network error: \(underlying.localizedDescription)"
        case .decode(let message): return "Decode failed: \(message)"
        }
    }
}

struct OAuthUsage: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: Date?
    }

    struct LimitModel: Decodable, Sendable {
        let displayName: String?
    }

    struct LimitScope: Decodable, Sendable {
        let model: LimitModel?
    }

    struct Limit: Decodable, Sendable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: Date?
        let scope: LimitScope?
    }

    struct ExtraUsage: Decodable, Sendable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        let decimalPlaces: Int?
    }

    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let limits: [Limit]?
    let extraUsage: ExtraUsage?
}

struct OAuthProfile: Decodable, Sendable {
    struct ProfileAccount: Decodable, Sendable {
        let uuid: String?
        let email: String?
        let fullName: String?
        let displayName: String?
    }

    struct ProfileOrganization: Decodable, Sendable {
        let uuid: String?
        let name: String?
    }

    let account: ProfileAccount?
    let organization: ProfileOrganization?
}

struct RefreshedTokens: Decodable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Double?
}

enum AnthropicAPI {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private static let logger = Logger(subsystem: "net.vinnysaj.ClaudeBar", category: "api")

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = (try? fractional.parse(raw)) ?? (try? plain.parse(raw)) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        return decoder
    }()

    static func fetchUsage(accessToken: String) async throws -> OAuthUsage {
        try await self.get(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            accessToken: accessToken)
    }

    static func fetchProfile(accessToken: String) async throws -> OAuthProfile {
        try await self.get(
            url: URL(string: "https://api.anthropic.com/api/oauth/profile")!,
            accessToken: accessToken)
    }

    static func refresh(refreshToken: String) async throws -> RefreshedTokens {
        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": self.clientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, statusCode) = try await self.perform(request)
        guard (200..<300).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            self.logger.error("Token refresh failed (\(statusCode)): \(bodyText, privacy: .public)")
            if bodyText.contains("invalid_grant") { throw APIError.invalidGrant }
            throw self.errorFor(statusCode: statusCode)
        }
        return try self.decode(RefreshedTokens.self, from: data)
    }

    private static func get<Response: Decodable>(url: URL, accessToken: String) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, statusCode) = try await self.perform(request)
        guard (200..<300).contains(statusCode) else {
            throw self.errorFor(statusCode: statusCode)
        }
        return try self.decode(Response.self, from: data)
    }

    private static func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await self.session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, statusCode)
        } catch {
            throw APIError.network(underlying: error)
        }
    }

    private static func errorFor(statusCode: Int) -> APIError {
        switch statusCode {
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .http(statusCode: statusCode)
        }
    }

    private static func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            return try self.decoder.decode(type, from: data)
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
            self.logger.error("Decode failure for \(String(describing: type), privacy: .public): \(String(describing: error), privacy: .public) body: \(bodyText, privacy: .public)")
            throw APIError.decode(message: String(describing: error))
        }
    }
}
