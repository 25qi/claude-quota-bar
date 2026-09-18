import Foundation

/// Nudges Claude Code into renewing its own OAuth token.
///
/// We never redeem the refresh token ourselves. Refresh tokens rotate on use, so
/// a second process doing the exchange races with Claude Code and invalidates
/// both copies. Instead we ask the `claude` CLI to do it, which keeps Claude Code
/// the sole owner of the credential and the sole writer to the keychain.
///
/// This is needed because an already-running Claude Code session holds its token
/// in memory and does not write refreshed credentials back. Working all day in
/// one session can leave the stored token expired for hours.
enum TokenRenewal {

    /// The free attempt: an auth command that touches no model. Costs nothing,
    /// takes about 0.2s.
    private static let cheap = ["auth", "status"]

    /// The paid fallback: a minimal turn, stripped of tools, MCP and the default
    /// system prompt. Roughly 1k tokens, so it is rate limited below.
    private static let expensive = [
        "-p", "--model", "haiku",
        "--tools", "",
        "--strict-mcp-config",
        "--system-prompt", "Reply: ok",
        "1",
    ]

    /// Never escalate to the paid path more than once an hour. Without this, a
    /// genuinely broken login (signed out, revoked) would burn ~1k tokens on
    /// every poll for as long as it stayed broken.
    private static let escalationInterval: TimeInterval = 3600
    private static var lastEscalation: Date?

    /// Runs the cheap renewal, and the paid one if it is due. Returns once the
    /// CLI has exited, so the caller can re-read credentials and retry.
    static func attempt() async {
        await run(cheap, timeout: 15)

        let due = lastEscalation.map { Date().timeIntervalSince($0) >= escalationInterval } ?? true
        guard due else { return }
        lastEscalation = Date()
        await run(expensive, timeout: 120)
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) async {
        guard let executable = locateCLI() else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let task = Process()
                task.executableURL = executable
                task.arguments = arguments
                // The output is irrelevant; we only want the side effect on the
                // stored credential. Discard it so the pipes cannot fill and stall.
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                task.standardInput = FileHandle.nullDevice

                do {
                    try task.run()
                } catch {
                    continuation.resume()
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while task.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if task.isRunning { task.terminate() }

                continuation.resume()
            }
        }
    }

    /// A menu bar app inherits a bare PATH from launchd, so `claude` has to be
    /// found by hand rather than relied on being resolvable.
    private static func locateCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
