import Foundation

struct Window {
    /// 0-100.
    let percent: Double
    let resetsAt: Date
}

struct Usage {
    let fiveHour: Window
    let sevenDay: Window
    let fetchedAt: Date
}

/// Asks the Messages API for the cheapest possible completion and reads the
/// unified rate-limit headers off the response. The reply itself is discarded —
/// the headers are the payload we care about, and they come straight from the
/// server, so they always agree with the real quota.
enum UsageFetcher {

    enum FetchError: LocalizedError {
        case unauthorized
        case badResponse(Int)
        case missingHeaders

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Token expired and renewal has not taken yet. Retrying automatically."
            case .badResponse(let code):
                return "API returned \(code)"
            case .missingHeaders:
                return "Response carried no usage headers"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static func fetch() async throws -> Usage {
        let token = try Credentials.accessToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.badResponse(0)
        }

        // A 429 is not a failure here: it means the account is at its limit,
        // which is exactly what we are measuring, and the headers still arrive.
        let hasHeaders = http.value(forHTTPHeaderField: Header.fiveHourUtilization) != nil
        guard http.statusCode == 200 || hasHeaders else {
            throw http.statusCode == 401 || http.statusCode == 403
                ? FetchError.unauthorized
                : FetchError.badResponse(http.statusCode)
        }

        guard let usage = parse(http) else { throw FetchError.missingHeaders }
        return usage
    }

    private enum Header {
        static let fiveHourUtilization = "anthropic-ratelimit-unified-5h-utilization"
        static let fiveHourReset = "anthropic-ratelimit-unified-5h-reset"
        static let sevenDayUtilization = "anthropic-ratelimit-unified-7d-utilization"
        static let sevenDayReset = "anthropic-ratelimit-unified-7d-reset"
    }

    private static func parse(_ response: HTTPURLResponse) -> Usage? {
        func number(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap(Double.init)
        }

        guard let fiveUtil = number(Header.fiveHourUtilization) else { return nil }
        let now = Date()

        let fiveReset = number(Header.fiveHourReset).map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval(5 * 3600)
        // A reset time already in the past means the window rolled over and the
        // server has not yet issued a new one — report it as empty, not stale.
        let fivePercent = fiveReset < now ? 0 : fiveUtil * 100

        let sevenUtil = number(Header.sevenDayUtilization) ?? 0
        let sevenReset = number(Header.sevenDayReset).map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval(7 * 24 * 3600)

        return Usage(
            fiveHour: Window(percent: fivePercent, resetsAt: fiveReset),
            sevenDay: Window(percent: sevenUtil * 100, resetsAt: sevenReset),
            fetchedAt: now
        )
    }
}
