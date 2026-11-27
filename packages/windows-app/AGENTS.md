# AGENTS.md — packages/windows-app

Native Windows client for FUTO Backups (alpha): a WinUI 3 app that signs in with the device flow and backs up chosen
folders with the bundled FUTO restic through the bundled restic-proxy, on a schedule. It mirrors `packages/macos-app`.

## Zero comments

Never write code comments or doc comments. Names carry the meaning. The only exception is a non-obvious *why* a
reader would otherwise miss; these are rare. Re-read your diff and delete every comment before committing.

## Tooling

- Run everything from `packages/windows-app` through mise: `mise run win:build`, `mise run win:test`,
  `mise run win:check`, `mise run win:mock`, `mise run win:helpers`. mise pins the .NET SDK.
- The .NET analyzers run at the Recommended level with warnings as errors, and formatting follows the .NET
  defaults in `.editorconfig`, so the build fails on either. `mise run win:format` fixes what it can. A rule is turned
  off only in `.editorconfig`, with the reason beside it.
- .NET 11, WinUI 3 (Windows App SDK), unpackaged and self-contained, for win-arm64 and win-x64.
- Tests: xUnit v3 on Microsoft.Testing.Platform (`global.json`). `ResticIntegrationTests` run against the real
  restic.exe from `build/helpers` and skip when it has not been built.

## Layout

```
src/FutoBackups.Core/       library, all logic, fully unit-tested, no UI
  Api/                      yucca-api client, discovery, device login
  Restic/                   restic commands, output parsing, restic-proxy over a named pipe
  State/                    config, secrets (Credential Manager), keys, schedule, retention, exclusions, run history
  Engine/                   backup, restore, key rotation, deletion and reset orchestration
  Status/                   the status summary every surface shows
  Models/                   AppModel: app state and flows, the port of the macOS AppModel
src/FutoBackups/            WinUI app (thin; logic stays in Core)
  ViewModels/               one view model per page, built on AppModel
  Pages/, Controls/         XAML views
  Platform/                 notifications, start at login, Windows Hello and password checks, pickers
  Mock/                     simulated engine and account for --mock
tests/FutoBackups.Core.Tests/
scripts/build-helpers.sh    builds restic.exe and restic-proxy.exe for both architectures
```

## Rules

- Interface text matches the macOS app word for word, with only platform nouns changed (Mac to PC, Finder to File
  Explorer, menu bar to system tray) and British spelling.
- Inject time, sleep, transports, process launchers and file locations; tests never hit the network or the real
  Credential Manager.
- Keyboard access everywhere, with accessible names on every control. No emoji or text glyphs as icons.
