# FUTO Backups for macOS (PoC)

Native SwiftUI client: device-flow login, pick folders, back up on a schedule with the bundled FUTO restic through
the bundled restic-proxy, list snapshots, restore, forget/prune (`--keep-within 60d`), upload throttling.

```bash
cd packages/macos-app
mise run mac:check    # lint + build + unit tests
mise run mac:bundle   # build/FUTO Backups.app with restic + restic-proxy in Contents/Helpers, ad-hoc signed
mise run mac:open     # bundle and launch
```

Unbundled (`swift run FutoBackups`) needs `FUTO_BACKUPS_RESTIC` and `FUTO_BACKUPS_RESTIC_PROXY` pointing at the helpers.

## Smoke test against the dev stack

1. `mise k3d:up && mise tilt:up` at the repo root (the app defaults to `http://localhost:8080/.well-known/yucca.json`;
   for the compose stack set the server to `http://localhost:3020/api/meta` in Account).
2. `mise run mac:open`, Account → Log in, approve the code in the browser (mock-oidc).
3. Folders → add a folder, Schedule → Back up now, then Snapshots → Restore… into an empty folder.
4. The connection shows up as type `macos` in the web app's connections page.

Config lives in `~/Library/Application Support/FUTO Backups/config.json`; the session token and the master key
(the recovery key, compatible with the standalone app) live in the login Keychain under `org.futo.backups.mac`.
