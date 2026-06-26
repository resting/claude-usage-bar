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

/// Runs a fixed shell command (`claude -p hi`) whenever the 5-hour usage window resets.
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
/// Each entry records the ISO-8601 timestamp, exit code, stdout, and stderr, so failures
/// (e.g. `claude` not on PATH) are diagnosable without attaching a debugger.
/// The directory is created automatically on first write.
@MainActor
class ResetCommandService: ObservableObject {
    static let command = "claude -p hi"

    @Published private(set) var isEnabled: Bool

    /// The `resetsAt` value seen on the previous poll — used to detect a genuine rollover.
    private var previousResetsAt: Date?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "autoRunOnResetEnabled")
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: "autoRunOnResetEnabled")
        // Clear the baseline so toggling on never double-fires for the current window.
        previousResetsAt = nil
    }

    /// Called from `UsageService.fetchUsage()` after every successful fetch.
    /// Mirrors the shape of `NotificationService.checkAndNotify`.
    func handleReset(resetsAt: Date?, now: Date = Date()) {
        let previous = previousResetsAt
        defer { previousResetsAt = resetsAt }

        guard isEnabled else { return }
        guard didWindowReset(previous: previous, current: resetsAt, now: now) else { return }

        runCommand()
    }

    // MARK: - Command execution

    private func runCommand() {
        let cmd = Self.command
        appendLog("=== \(timestamp()) Running: \(cmd) ===")

        // Spawn via the user's login shell so PATH is fully loaded (e.g. ~/.zshrc, nvm, homebrew).
        // Without -l the GUI app's minimal PATH would fail to resolve `claude`.
        Task.detached(priority: .background) {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = ["-lc", cmd]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe

            do {
                try proc.run()
                proc.waitUntilExit()

                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let status = proc.terminationStatus

                await MainActor.run {
                    self.appendLog("exit: \(status)")
                    if !stdout.isEmpty { self.appendLog("stdout:\n\(stdout.trimmingCharacters(in: .newlines))") }
                    if !stderr.isEmpty { self.appendLog("stderr:\n\(stderr.trimmingCharacters(in: .newlines))") }
                    self.appendLog("=== done ===\n")
                }
            } catch {
                await MainActor.run {
                    self.appendLog("error launching process: \(error.localizedDescription)\n")
                }
            }
        }
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
