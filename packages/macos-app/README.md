# FUTO Backups for macOS (PoC)

Native SwiftUI client: device-flow login, pick folders, back up on a schedule with the bundled FUTO restic through
the bundled restic-proxy, list snapshots, restore, forget/prune (`--keep-within 60d`), upload throttling.

```bash
cd packages/macos-app
mise run mac:check    # lint + build + unit tests
mise run mac:bundle   # build/FUTO Backups.app with restic + restic-proxy in Contents/Helpers, ad-hoc signed
mise run mac:open     # bundle and launch
```

`mise run mac:install` builds a dev version (`0.0.0-dev.<commit>`, automatic update checks off), signs it with FUTO's
Developer ID certificate from Infisical (or `CODESIGN_IDENTITY` from your keychain), installs it in `/Applications`
and launches it; `NOTARIZE=1` also notarizes it.

Unbundled (`swift run FutoBackups`) needs `FUTO_BACKUPS_RESTIC` and `FUTO_BACKUPS_RESTIC_PROXY` pointing at the helpers.

## Smoke test against the dev stack

1. `mise k3d:up && mise tilt:up` at the repo root. The app defaults to FUTO Cloud
   (`https://meta.futo.cloud/.well-known/yucca.json`): pick Local dev on the welcome screen for k3d, or set the server to
   `http://localhost:3020/api/meta` for the compose stack.
2. `mise run mac:open`, Account → Log in, approve the code in the browser (mock-oidc).
3. Folders → add a folder, Schedule → Back up now, then Snapshots → Restore… into an empty folder.
4. The connection shows up as type `macos` in the web app's connections page.

Config lives in `~/Library/Application Support/FUTO Backups/config.json`; the session token and the master key
(the recovery key, compatible with the standalone app) live in the login Keychain under `org.futo.backups.mac`.

## Releases

Publishing a `v<version>` release (release-please) runs `.github/workflows/macos-release.yml`, which builds the Mac
app only when its inputs (`packages/macos-app`, `packages/restic-proxy`, the `RESTIC_IMAGE` pin) changed since the
version in the current appcast, and publishes it as its own release `macos-v<version>` — same version number, never an
asset of the server release — with notes filtered to Mac commits. The feed is unchanged:
`https://github.com/futo-org/backups/releases/download/macos-appcast/appcast.xml`.

Release versions must be plain `MAJOR.MINOR.PATCH`: `CFBundleVersion` is `MAJOR*1000000+MINOR*1000+PATCH`, and a
published zip is never replaced.

The build job runs in the `macos-release` environment, which only `main` and the `v*` tags can deploy to. Infisical
syncs its secrets there: `apple-signing/global/ci` holds FUTO's Developer ID Application certificate
(`APPLE_DEVELOPER_ID_APPLICATION__*`, `APPLE_TEAM_ID`) and the App Store Connect notary key (`APPLE_NOTARY_API_KEY__*`);
`yucca/global/ci` holds `MACOS_SPARKLE_PRIVATE_KEY`, the base64 Ed25519 seed that signs updates. Its public half is
pinned as `SUPublicEDKey` in `Resources/Info.plist`; the release fails if the two don't match. The job fails if a
secret is missing; the gate job skips with a notice when the Mac inputs are unchanged since the version in the current
appcast.

### Building a release locally

```bash
cd packages/macos-app
SPARKLE_PRIVATE_KEY=… DOWNLOAD_URL_PREFIX=https://example.com/apps/ \
  mise run mac:release 1.2.3
```

Set `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` (all three) to notarize and staple, and `CODESIGN_IDENTITY` (and
`EXPECTED_TEAM_ID` to check it) to sign with a real identity; the zip and `appcast.xml` land in `OUT_DIR` (default `build/release`). Set
`RELEASE_NOTES_HTML_FILE` to notes HTML (`scripts/release-notes.sh html …`) to embed them in the appcast item's
`<description>`, so Sparkle's update dialog shows them.
