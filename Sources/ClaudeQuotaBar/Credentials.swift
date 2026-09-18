import CryptoKit
import Foundation

/// Reads Claude Code's OAuth access token.
///
/// Deliberately READ-ONLY. This never calls the refresh_token grant and never
/// writes back to the keychain. Refresh tokens rotate on use, so a second
/// process refreshing them races with Claude Code itself and invalidates both
/// copies — the failure mode that makes other trackers drop out intermittently.
/// When the token here is expired we surface a stale state and wait for Claude
/// Code to renew it on its own.
enum Credentials {

    enum LookupError: LocalizedError {
        case notFound
        case malformed

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Claude Code credentials found. Run `claude` in a terminal to sign in."
            case .malformed:
                return "Credentials are not in a readable format."
            }
        }
    }

    private struct Candidate {
        let token: String
        /// Absent when the payload carried no `expiresAt`.
        let expiresAt: Date?
    }

    /// Returns the freshest access token available, or throws if none can be read.
    ///
    /// Credentials can exist in more than one place at once — the keychain entry
    /// Claude Code keeps current, plus a `.credentials.json` that may be months
    /// stale from an older install. Taking the first hit found would happily use
    /// a long-dead token, so compare expiry and pick the newest.
    static func accessToken() throws -> String {
        var found: [Candidate] = []

        for service in serviceNameCandidates() {
            if let raw = readKeychain(service: service) {
                found.append(contentsOf: candidates(from: raw))
            }
        }
        if let raw = try? String(contentsOf: credentialsFile, encoding: .utf8) {
            found.append(contentsOf: candidates(from: raw))
        }

        guard !found.isEmpty else { throw LookupError.notFound }

        // `.distantPast` keeps an undated candidate as a last resort rather than
        // letting it outrank one we know is current.
        let best = found.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
        guard let token = best?.token else { throw LookupError.malformed }
        return token
    }

    private static func candidates(from raw: String) -> [Candidate] {
        guard let token = extractToken(from: raw) else { return [] }
        return [Candidate(token: token, expiresAt: expiry(from: raw))]
    }

    /// `expiresAt` is milliseconds since the epoch.
    private static func expiry(from raw: String) -> Date? {
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let millis = oauth["expiresAt"] as? Double else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    // MARK: - Locations

    private static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private static var credentialsFile: URL {
        configDirectory.appendingPathComponent(".credentials.json")
    }

    /// Claude Code v2.1.52+ suffixes the keychain service with a hash of the
    /// config directory. The default `~/.claude` keeps the unsuffixed name.
    private static func serviceNameCandidates() -> [String] {
        let base = "Claude Code-credentials"
        let path = configDirectory.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return [base, "\(base)-\(hash)"]
    }

    // MARK: - Reading

    private static func readKeychain(service: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]

        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }

        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Parses `{"claudeAiOauth": {"accessToken": "..."}}`.
    ///
    /// The keychain CLI truncates payloads above ~2KB, so a strict JSON decode
    /// can fail on a perfectly usable entry. Fall back to a narrow scan for the
    /// accessToken field rather than giving up.
    private static func extractToken(from raw: String) -> String? {
        if let data = raw.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String,
           !token.isEmpty {
            return token
        }

        guard let range = raw.range(of: "\"accessToken\"\\s*:\\s*\"([^\"]+)\"",
                                    options: .regularExpression) else { return nil }
        let match = String(raw[range])
        guard let open = match.range(of: "\"", options: .backwards, range: match.startIndex..<match.index(before: match.endIndex)) else {
            return nil
        }
        let token = String(match[open.upperBound..<match.index(before: match.endIndex)])
        return token.isEmpty ? nil : token
    }
}
