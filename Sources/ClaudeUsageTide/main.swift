import AppKit
import ServiceManagement

/// Menu bar readout of the Claude subscription quota.
///
/// Design rule for this app: it should be installed once and then never need
/// attention. Nothing here blocks on setup, no failure is fatal, and the poll
/// loop keeps running through errors, sleep, and network drops.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage: Usage?
    private var lastError: String?

    /// 5 minutes. Each poll costs roughly 11 tokens, so ~3k/day.
    private let interval: TimeInterval = 300

    /// Drops the reset time from the menu bar, leaving just the percentage.
    /// On a notched Mac the bar runs out of room and macOS silently hides
    /// whatever overflows, so a narrower title is the difference between the
    /// reading being visible and not.
    private var compact: Bool {
        get { UserDefaults.standard.bool(forKey: "compactTitle") }
        set { UserDefaults.standard.set(newValue, forKey: "compactTitle") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Created exactly once. macOS keys the position you set with ⌘-drag on
        // the autosave name, and removing the item discards it — every
        // re-creation dropped the item back next to the notch, which is also
        // the first spot to be hidden when the menu bar overflows.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ClaudeUsageTide"
        render()

        // Both callbacks below are delivered on the main thread (a main-run-loop
        // timer, a `.main` queue observer), so asserting main-actor isolation
        // is accurate rather than a cast.
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 30

        // The repeating timer does not fire while the system is suspended, so a
        // reading is stale on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refresh()
    }

    /// Opening the app again from Spotlight while it is running: there is no
    /// window to bring forward, so take it as a request for a fresh reading.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        refresh()
        return true
    }

    // MARK: - Data

    private func refresh() {
        Task { @MainActor in
            do {
                usage = try await UsageFetcher.fetch()
                lastError = nil
            } catch UsageFetcher.FetchError.unauthorized {
                // The stored token has expired. A running Claude Code session
                // keeps its own copy in memory and will not write a fresh one
                // back, so waiting it out can mean hours of stale readings —
                // ask the CLI to renew, then try once more.
                await TokenRenewal.attempt()
                do {
                    usage = try await UsageFetcher.fetch()
                    lastError = nil
                } catch {
                    lastError = error.localizedDescription
                }
            } catch {
                // Keep the last good reading on screen; only the freshness marker changes.
                lastError = error.localizedDescription
            }
            render()
        }
    }

    // MARK: - Display

    private func render() {
        guard let button = statusItem.button else { return }

        if let usage {
            let percent = "\(Self.whole(usage.percent5h))%"
            let title = compact ? percent : "\(percent)·\(Self.clock(usage.fiveHour.resetsAt))"
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: lastError == nil ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ]
            )
        } else {
            button.attributedTitle = NSAttributedString(
                string: lastError == nil ? "···" : "—",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
            )
        }

        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        if let usage {
            menu.addItem(reading("5-hour", usage.fiveHour, style: .time))
            menu.addItem(reading("7-day", usage.sevenDay, style: .dayAndTime))
            menu.addItem(.separator())
            menu.addItem(info("Updated \(Self.clock(usage.fetchedAt))"))
        }

        if let lastError {
            menu.addItem(info(lastError))
        } else if usage == nil {
            menu.addItem(info("Loading…"))
        }

        menu.addItem(.separator())

        let now = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        now.target = self
        menu.addItem(now)

        let narrow = NSMenuItem(title: "Compact Display", action: #selector(toggleCompact), keyEquivalent: "")
        narrow.target = self
        narrow.state = compact ? .on : .off
        menu.addItem(narrow)

        // Under Homebrew, `brew services` owns launch at login. Offering our own
        // toggle too would register a second launcher and start the app twice.
        if !Self.managedByHomebrew {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = Self.launchAtLoginEnabled ? .on : .off
            menu.addItem(login)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private enum ResetStyle { case time, dayAndTime }

    private func reading(_ label: String, _ window: Window, style: ResetStyle) -> NSMenuItem {
        let reset = style == .time
            ? Self.clock(window.resetsAt)
            : Self.dayClock(window.resetsAt)
        return info("\(label)   \(Self.whole(window.percent))%   resets \(reset)")
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func toggleCompact() {
        compact.toggle()
        render()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if Self.launchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            lastError = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        render()
    }

    /// Set by bundle.sh when the Homebrew formula builds the app.
    private static let managedByHomebrew =
        Bundle.main.object(forInfoDictionaryKey: "ManagedByHomebrew") as? Bool ?? false

    private static var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    // MARK: - Formatting

    /// Rounds for display. `Int(_:)` traps on NaN or infinity, and a header that
    /// ever carried either should not be able to take the app down.
    private static func whole(_ value: Double) -> Int {
        value.isFinite ? Int(value.rounded()) : 0
    }

    /// "5:30am" — lowercase, no leading zero.
    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        return f.string(from: date).lowercased()
    }

    /// "Wed 8:00am", or just the time when it falls today.
    private static func dayClock(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return clock(date) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE"
        return "\(f.string(from: date)) \(clock(date))"
    }
}

private extension Usage {
    var percent5h: Double { fiveHour.percent }
}

/// `--probe` runs one fetch, prints the reading, and exits. Useful for checking
/// the credential + network path without opening the UI. Never prints the token.
if CommandLine.arguments.contains("--probe") {
    // Detached so the work cannot inherit the main actor: the main thread is
    // parked in dispatchMain() below, and a task queued behind it would never run.
    Task.detached {
        do {
            let usage = try await UsageFetcher.fetch()
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            print(String(format: "5h  %5.1f%%  resets %@", usage.fiveHour.percent, f.string(from: usage.fiveHour.resetsAt)))
            print(String(format: "7d  %5.1f%%  resets %@", usage.sevenDay.percent, f.string(from: usage.sevenDay.resetsAt)))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    dispatchMain()
}

// Top-level code runs on the main thread; say so, since AppDelegate is main-actor
// isolated. NSApplication holds its delegate weakly, and run() never returns, so
// the local keeps it alive for the life of the process.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
