# Plan: Reset command runs `claude -p hi` then `claude -p /usage`

**Date:** 2026-07-13
**Status:** Approved — execute with Sonnet

## Goal

Restore `claude -p hi` as the primary reset-trigger command (it kickstarts the
5-hour block session), then follow it with `claude -p /usage` to capture session
state. Log both responses to `~/Library/Logs/ClaudeUsageBar/reset-command.log`:

- `claude -p hi` → log the full response (stdout).
- `claude -p /usage` → keep the existing filter; log only the trimmed
  `Current session: ...` line (with the existing "not found" fallback).

Settings toggle label must read `claude -p hi` again.

## Files

### 1. `macos/Sources/ClaudeUsageBar/ResetCommandService.swift`

- Change `static let command = "claude -p /usage"` back to
  `static let command = "claude -p hi"`.
- Add `static let usageCommand = "claude -p /usage"`.
- Refactor the `Task.detached` body in `runCommand()`:
  - Extract a small nonisolated/static helper that runs one shell command via
    `$SHELL -lc` and returns `(status: Int32, stdout: String, stderr: String)`
    — same Process/Pipe code as today.
  - Run `Self.command` first. Log: header line (`=== <ts> Running: claude -p hi ===`
    — keep current header format), `exit: <status>`, full trimmed stdout,
    stderr if non-empty.
  - Then run `Self.usageCommand`. Log: `=== <ts> Running: claude -p /usage ===`,
    `exit: <status>`, then the `extractCurrentSessionLine(from:)` result — or
    the existing "Current session line not found in output" fallback when
    stdout is non-empty — stderr if non-empty, then `=== done ===\n`.
  - Keep the launch-error catch path logging per command.
- Update the class-level doc comment and the line-16 summary comment to
  describe the two-command sequence.
- Keep `extractCurrentSessionLine(from:)` unchanged (tests cover it).

### 2. `macos/Sources/ClaudeUsageBar/SettingsView.swift`

- No code change expected: the toggle label interpolates
  `ResetCommandService.command`, so it reverts to `claude -p hi` automatically.
  Verify only. Optionally mention in the caption that `/usage` output is also
  logged — not required.

### 3. Tests — `macos/Tests/ClaudeUsageBarTests/ResetCommandServiceTests.swift`

- Existing `extractCurrentSessionLine` tests stay valid; run the suite.
- If any test asserts `ResetCommandService.command == "claude -p /usage"`,
  update it to `"claude -p hi"`.

## Verification

- `swift build` (or `xcodebuild`) from `macos/` succeeds.
- `swift test` — all tests pass (59 baseline).
- Do NOT commit — leave changes in working tree for review.
