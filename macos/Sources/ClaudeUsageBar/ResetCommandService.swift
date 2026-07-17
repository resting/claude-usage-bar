import Foundation

/// Pure logic: returns true when the 5-hour window has genuinely rolled over.
///
/// The check is: the OLD reset time is now in the past (the window expired)
/// AND the NEW reset time is still in the future (a fresh window started).
/// This is robust against the API returning slightly different future timestamps
/// on each poll (e.g. server computing "now + 5h"), which would falsely trigger
/// a naive `curr > prev` comparison on every single interval.
func didWindowReset(previous: Date?, current: Date?, now: Date = Date()) -> Bool {
    guard let prev = previous else { return false }
    guard let curr = current else { return false }
    return prev <= now && curr > now
}

/// Pure logic: returns true when `now`'s local time-of-day falls within the
/// `[start, end)` window, both measured as minutes since midnight.
///
/// The window wraps across midnight when `start > end` (e.g. 22:00–06:00 means
/// "10pm through 6am"). A zero-length window (`start == end`) matches nothing.
func isWithinIgnoreWindow(
    startMinutes: Int,
    endMinutes: Int,
    now: Date = Date(),
    calendar: Calendar = .current
) -> Bool {
    guard startMinutes != endMinutes else { return false }
    let comps = calendar.dateComponents([.hour, .minute], from: now)
    let current = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    if startMinutes < endMinutes {
        return current >= startMinutes && current < endMinutes
    } else {
        return current >= startMinutes || current < endMinutes
    }
}

/// Runs two fixed shell commands (`claude -p hi` then `claude -p /usage`) whenever the
/// 5-hour usage window resets.
///
/// ## How reset detection works
///
/// After each successful API poll, `UsageService.fetchUsage()` calls
/// `handleReset(resetsAt:)` with the next reset timestamp from `usage.fiveHour.resetsAtDate`.
/// That timestamp is a **future** date (e.g. "resets in 3h 55m"). The service stores the
/// previous value and compares using `didWindowReset`, which checks:
///
///   - The **old** reset time is now in the past  →  the previous window expired
///   - The **new** reset time is in the future    →  a fresh window has started
///
/// A naive `new > old` comparison would fire on every poll because the API computes
/// `resetsAt` server-side as "now + 5h", producing a slightly later timestamp each time.
/// The past/future check is immune to that drift.
///
/// ## Log output
///
/// All runs are logged to:
///   `~/Library/Logs/ClaudeUsageBar/reset-command.log`
///
/// `claude -p hi` runs first (its full trimmed stdout is logged), followed by
/// `claude -p /usage` (only the extracted `Current session: ...` line is logged).
/// Each entry records the ISO-8601 timestamp, exit code, and output, so failures
/// (e.g. `claude` not on PATH) are diagnosable without attaching a debugger.
/// The directory is created automatically on first write.
@MainActor
class ResetCommandService: ObservableObject {
    static let command = "claude -p hi"
    static let usageCommand = "claude -p /usage"

    @Published private(set) var isEnabled: Bool

    /// When enabled, a reset that lands inside `[ignoreStartMinutes, ignoreEndMinutes)`
    /// (local time-of-day) is ignored and dropped — the command does not run for it.
    @Published private(set) var ignoreWindowEnabled: Bool
    @Published private(set) var ignoreStartMinutes: Int
    @Published private(set) var ignoreEndMinutes: Int

    /// The `resetsAt` value seen on the previous poll — used to detect a genuine rollover.
    private var previousResetsAt: Date?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "autoRunOnResetEnabled")
        ignoreWindowEnabled = UserDefaults.standard.bool(forKey: "ignoreWindowEnabled")
        // Default to a 23:00–07:00 quiet window when nothing is stored yet.
        ignoreStartMinutes = (UserDefaults.standard.object(forKey: "ignoreWindowStartMinutes") as? Int) ?? (23 * 60)
        ignoreEndMinutes = (UserDefaults.standard.object(forKey: "ignoreWindowEndMinutes") as? Int) ?? (7 * 60)
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: "autoRunOnResetEnabled")
        // Clear the baseline so toggling on never double-fires for the current window.
        previousResetsAt = nil
    }

    func setIgnoreWindowEnabled(_ value: Bool) {
        ignoreWindowEnabled = value
        UserDefaults.standard.set(value, forKey: "ignoreWindowEnabled")
    }

    func setIgnoreStartMinutes(_ value: Int) {
        ignoreStartMinutes = value
        UserDefaults.standard.set(value, forKey: "ignoreWindowStartMinutes")
    }

    func setIgnoreEndMinutes(_ value: Int) {
        ignoreEndMinutes = value
        UserDefaults.standard.set(value, forKey: "ignoreWindowEndMinutes")
    }

    /// True when the ignore window is enabled and `now` falls inside it.
    private func isInIgnoreWindow(now: Date) -> Bool {
        guard ignoreWindowEnabled else { return false }
        return isWithinIgnoreWindow(startMinutes: ignoreStartMinutes, endMinutes: ignoreEndMinutes, now: now)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Called from `UsageService.fetchUsage()` after every successful fetch.
    /// Mirrors the shape of `NotificationService.checkAndNotify`.
    func handleReset(resetsAt: Date?, now: Date = Date()) {
        let previous = previousResetsAt
        defer { previousResetsAt = resetsAt }

        guard isEnabled else { return }
        guard didWindowReset(previous: previous, current: resetsAt, now: now) else { return }

        if isInIgnoreWindow(now: now) {
            appendLog("=== \(timestamp()) Reset detected but within ignore window "
                + "(\(formatMinutes(ignoreStartMinutes))–\(formatMinutes(ignoreEndMinutes))) — skipping ===")
            return
        }

        runCommand()
    }

    /// Called once on app launch. Runs the command unconditionally when the
    /// setting is enabled, since there's no prior `resetsAt` to compare against yet.
    func runOnAppLaunchIfEnabled(now: Date = Date()) {
        guard isEnabled else { return }
        if isInIgnoreWindow(now: now) {
            appendLog("=== \(timestamp()) App launch within ignore window "
                + "(\(formatMinutes(ignoreStartMinutes))–\(formatMinutes(ignoreEndMinutes))) — skipping ===")
            return
        }
        runCommand()
    }

    // MARK: - Command execution

    /// Extracts the "Current session: ..." line from `claude -p /usage` output.
    nonisolated static func extractCurrentSessionLine(from output: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("Current session:") }
    }

    /// Runs `claude -p hi` (logging its full trimmed stdout), then `claude -p /usage`
    /// (logging only the extracted "Current session: ..." line) — in that order.
    private func runCommand() {
        let firstCmd = Self.command
        let usageCmd = Self.usageCommand
        appendLog("=== \(timestamp()) Running: \(firstCmd) ===")

        // Spawn via the user's login shell so PATH is fully loaded (e.g. ~/.zshrc, nvm, homebrew).
        // Without -l the GUI app's minimal PATH would fail to resolve `claude`.
        Task.detached(priority: .background) {
            do {
                let result = try Self.runShell(firstCmd)
                await MainActor.run {
                    self.appendLog("exit: \(result.status)")
                    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.appendLog(trimmed) }
                    if !result.stderr.isEmpty { self.appendLog("stderr:\n\(result.stderr.trimmingCharacters(in: .newlines))") }
                }
            } catch {
                await MainActor.run {
                    self.appendLog("error launching process: \(error.localizedDescription)\n")
                }
            }

            await MainActor.run {
                self.appendLog("=== \(self.timestamp()) Running: \(usageCmd) ===")
            }

            do {
                let result = try Self.runShell(usageCmd)
                await MainActor.run {
                    self.appendLog("exit: \(result.status)")
                    if let sessionLine = Self.extractCurrentSessionLine(from: result.stdout) {
                        self.appendLog(sessionLine)
                    } else if !result.stdout.isEmpty {
                        self.appendLog("Current session line not found in output")
                    }
                    if !result.stderr.isEmpty { self.appendLog("stderr:\n\(result.stderr.trimmingCharacters(in: .newlines))") }
                    self.appendLog("=== done ===\n")
                }
            } catch {
                await MainActor.run {
                    self.appendLog("error launching process: \(error.localizedDescription)\n")
                }
            }
        }
    }

    /// Runs `command` via the user's login shell (`$SHELL -lc`) and captures its exit
    /// status, stdout, and stderr. `nonisolated` so it can execute on the background
    /// thread inside `Task.detached` without hopping onto the main actor.
    private nonisolated static func runShell(_ command: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", command]

        // Run from a dedicated empty directory. Without this the app's cwd (`/` or `~`
        // for a GUI app) becomes `claude`'s project root, and its directory scan walks
        // into TCC-protected folders (Downloads, Photos) — prompts get attributed to
        // this app since it is the responsible parent process.
        let workDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeUsageBar/run", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        proc.currentDirectoryURL = workDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus, stdout, stderr)
    }

    // MARK: - Logging

    /// `~/Library/Logs/ClaudeUsageBar/reset-command.log`
    static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeUsageBar/reset-command.log")
    }

    private func appendLog(_ message: String) {
        print("[ResetCommand] \(message)")

        let url = Self.logFileURL
        let dir = url.deletingLastPathComponent()

        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                handle.write(data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            print("[ResetCommand] Failed to write log: \(error.localizedDescription)")
        }
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
