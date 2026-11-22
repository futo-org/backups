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

## Releases

Publishing a `v<version>` release (release-please) runs `.github/workflows/macos-release.yml`, which builds the Mac
app only when its inputs (`packages/macos-app`, `packages/restic-proxy`, the `RESTIC_IMAGE` pin) changed since the
version in the current appcast, and publishes it as its own release `macos-v<version>` — same version number, never an
asset of the server release — with notes filtered to Mac commits. The feed is unchanged:
`https://github.com/futo-org/backups/releases/download/macos-appcast/appcast.xml`.

Release versions must be plain `MAJOR.MINOR.PATCH`: `CFBundleVersion` is `MAJOR*1000000+MINOR*1000+PATCH`, and a
published zip is never replaced.

Configure as repository secrets: `MACOS_CERTIFICATE_P12` (base64 Developer ID certificate),
`MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_NOTARY_KEY_P8` (base64 notary API key),
`APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER`, `SPARKLE_PRIVATE_KEY` (base64 Ed25519 seed); and as a repository
variable: `SPARKLE_PUBLIC_KEY` (the matching public key, baked into the bundle).

When secrets are missing or the Mac inputs are unchanged since the version in the current appcast, the gate job skips
with a notice instead of failing.

### Building a release locally

```bash
cd packages/macos-app
SPARKLE_PUBLIC_KEY=… SPARKLE_PRIVATE_KEY=… DOWNLOAD_URL_PREFIX=https://example.com/apps/ \
  mise run mac:release 1.2.3
```

Set `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` (all three) to notarize and staple, and `CODESIGN_IDENTITY` to
sign with a real identity; the zip and `appcast.xml` land in `OUT_DIR` (default `build/release`). Set
`RELEASE_NOTES_HTML_FILE` to notes HTML (`scripts/release-notes.sh html …`) to embed them in the appcast item's
`<description>`, so Sparkle's update dialog shows them.
