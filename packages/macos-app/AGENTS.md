# AGENTS.md — packages/macos-app

Native macOS client for FUTO Backups (PoC): SwiftUI app that logs in with the device flow, backs up chosen folders
with the bundled FUTO restic through the bundled restic-proxy, on a schedule.

## Zero comments

Never write code comments or doc comments. Names carry the meaning. The only exception is a non-obvious *why* a
reader would otherwise miss; these are rare. Re-read your diff and delete every comment before committing.

## Tooling

- Run everything from `packages/macos-app` through mise: `mise run mac:build`, `mise run mac:test`,
  `mise run mac:lint`, `mise run mac:format`, `mise run mac:check` (lint + build + test).
  The mise env sets `DEVELOPER_DIR` to Xcode; plain `swift` outside mise may fail to load Swift Testing macros.
- Run `mise run mac:format` before `mise run mac:check`.
- Swift 6 language mode, strict concurrency, macOS 15+. Apple frameworks only, except Sparkle 2 in the `FutoBackups`
  target. `BackupsCore` has no dependencies.
- Tests: Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), never XCTest. Parameterised tests via
  `@Test(arguments:)` for tables.

## Layout

```
Package.swift
Sources/BackupsCore/        library, all logic, fully unit-tested
  Models.swift              shared value types (Throttle, BackupStatus)
  Api/                      yucca-api client
  Restic/                   restic + restic-proxy
  State/                    config, secrets, keys, schedule
  DiskSnapshot/             APFS disk snapshots, data volume paths, Full Disk Access
  Engine/                   backup orchestration
Sources/FutoBackups/        SwiftUI app (thin; logic stays in BackupsCore)
Tests/BackupsCoreTests/     one test file per source file, named <Source>Tests.swift
scripts/                    bundling
```

## Rules

- Inject time, sleep, transports, process launchers and file locations; tests never hit the network or real
  Keychain (except tests explicitly gated on an env var).
- Touch only the files your brief allows.
- Commits: one-line conventional commit (`feat(macos-app): …`), no body, no co-author.
