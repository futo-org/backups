# FUTO Backups for Windows

Native Windows client for FUTO Backups (alpha). It backs up chosen folders to FUTO Cloud on a schedule, encrypted on
the PC with a recovery key that never leaves it.

## Run it

```sh
mise run win:build
mise run win:mock      # the app against simulated services, no account needed
mise run win:test
```

Debug builds show a server picker on the welcome screen. Choose Local Dev to use a local stack on
`http://localhost:3020/api/meta`. With the mock OIDC provider, approve a device code with
`http://localhost:8092/api/form/device?user_code=<code>&sub=<name>`.

To point a build at other helper binaries, set `FUTO_BACKUPS_RESTIC` and `FUTO_BACKUPS_RESTIC_PROXY`.

## Where it keeps things

| What | Where |
|---|---|
| Settings | `%APPDATA%\FUTO Backups\config.json` |
| Sign-in and recovery key | Credential Manager, `FUTO Backups/…` |
| restic cache | `%LOCALAPPDATA%\FUTO Backups\Cache` |

Unlink This PC in Settings removes all three.

## Updates

Releases are [Velopack](https://velopack.io) packages. `Setup.exe` installs into `%LOCALAPPDATA%\FUTOBackups`, and the
installed app checks once a day for a newer version, after the user agrees during setup (Settings can turn it off).
The app reads `releases.win-<arch>.json` from the rolling `windows-feed` release, then downloads the package from
`windows-v<version>`, whose SHA-256 the feed pins. A downloaded update installs the next time the app starts, or
straight away from Check Now when no backup is running.

Feeds are unsigned until the update key exists. Create it once with `mise run win:update-key <path>`: commit
`packaging/update-public-key.pem` and store the private key as `WINDOWS_UPDATE_PRIVATE_KEY` in the `windows-release`
environment. From then on releases sign their feeds (ECDSA P-256), and apps built with the public key refuse a feed
whose `.sig` does not verify.
