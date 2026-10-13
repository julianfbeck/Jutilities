# AGENTS.md

Jutilities is a native macOS 15+ menu-bar app. Keep app UI and operating-system integration in `Sources/Jutilities`, and independently testable storage, parsing and planning code in `Sources/JutilitiesCore`.

## Build and verification

- Use XcodeBuildMCP tools or its CLI for macOS builds and tests. Do not invoke raw `xcodebuild`, `xcrun` or `simctl`.
- The supported CLI version is 2.7.0. Edit the canonical `project.yml` and generate the untracked Xcode project with `xcodegen generate --spec project.yml`.
- Run `xcodebuildmcp swift-package test --package-path "$PWD"` for core changes. Run `xcodebuildmcp macos test --project-path "$PWD/Jutilities.xcodeproj" --scheme Jutilities --derived-data-path "$PWD/build/TestDerivedData"` for app integration and native tests.
- Build the Release app with the XcodeBuildMCP command documented in README.md. Use `--preview` to inspect fixture UI without capturing real clipboard content or changing power settings.
- Do not test real sleep, screen locking or administrator/account-password operations automatically. Test pure command plans, parsing and timing with fixtures. Never inspect the developer's real clipboard history for a test or screenshot.

## Data and permissions

- Clipboard data and credentials are private. Never commit databases, clipboard exports, personal logs, secrets or screenshots containing real user data. Documentation screenshots must use preview fixtures.
- Keep 60-day expiry consistent for history, pinned entries, payloads and search indexes. Refresh retention when content is captured again or reused by copying or pasting from Jutilities. Exported backups remain user-owned and are not silently deleted.
- Preserve database transactions, foreign keys, private permissions, backup validation and schema checks. Use meaningful tests for deletion, retention, backup integrity and error behavior.
- Keep password-manager and sensitive pasteboard exclusions. They are best effort, not a promise that arbitrary copied secrets cannot enter history.
- Do not request Accessibility unless the user chooses automatic paste. Copy-only mode must work without it.
- Keep-awake assertions must be released on stop, timeout and quit. Starting or stopping a session must not rewrite global power preferences.
- Change saved power settings only after explicit Apply. Validate every command argument; never interpolate arbitrary shell text.
- Administrator authorization belongs to macOS. Password-delay credentials may exist only briefly for an explicit user operation, must stay out of argv, logs and files, and must not be saved. Keep subprocess output sanitized and operations bounded.
- Never equate a preference write or CLI readback with proof of actual screen-lock behavior. Report failures and provide the native settings fallback.

## Contributions

Keep changes focused and use SwiftUI/AppKit rather than a web wrapper. Do not add network access, telemetry, third-party dependencies, cloud sync or a privileged background helper without an explicit product requirement. Document visible behavior changes and the checks actually run.

Keep `scripts/` local and ignored. Do not commit personal setup or deployment helpers, machine-specific paths, credentials, or developer-generated artifacts. Public build and test instructions and CI must work from a fresh clone without local scripts.
