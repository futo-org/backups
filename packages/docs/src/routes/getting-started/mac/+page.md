---
title: Set up on a Mac
description: Install the FUTO Backups Mac app and back up the folders on your Mac
order: 4
---

The Mac app backs up folders on your Mac, on a schedule, from the menu bar. It needs macOS 26 or later.

> [!NOTE]
> The Mac app is in alpha, earlier than the rest of the beta. Keep another copy of anything you cannot afford to lose.

Before you begin, make sure you have [joined the beta](/getting-started/beta) and can sign in at [backups.futo.cloud](https://backups.futo.cloud).

## Install it

With [Homebrew](https://brew.sh):

```bash
brew trust --cask futo-org/tap/futo-backups
brew install --cask futo-org/tap/futo-backups
```

The first command is needed once: Homebrew does not load casks from a tap it has not been told to trust.

Or download `FUTO-Backups-<version>.zip` from the newest [FUTO Backups for macOS release](https://github.com/futo-org/backups/releases?q=macos-v&expanded=true), unzip it and move **FUTO Backups** into **Applications**.

The app keeps itself up to date either way. You can turn that off, or check by hand, under **Settings** → **Updates**.

## Setup

Open the app and it walks you through setup:

1. **Telemetry.** To continue setup during the closed beta, you must agree to share FUTO Backups diagnostics. Telemetry does not collect your files or recovery key.
2. **Sign in.** Select **Sign In**. Your browser opens on the FUTO sign-in page with a code. Check that it matches the one in the app and approve. The app carries on by itself.
3. **Save your recovery key.** Use **Save to File**, **Copy** or **Print**, tick "I saved my recovery key somewhere safe", then type the key back in to confirm your copy is correct. Read [your recovery key](/guides/recovery-key) before you go further.
4. **Full Disk Access.** macOS keeps folders such as Mail, Messages and Safari from apps without this permission. Select **Open System Settings**, turn on **FUTO Backups** in the list and come back. You can skip it and grant it later from **Folders**.
5. **Choose what to back up.** Pick a preset, **Essentials** (Documents and Desktop), **Essentials + Media** (adds Pictures, Movies and Music) or **Everything** (your whole home folder), or choose folders yourself. The app adds up their sizes as it goes.
6. **Ready to back up.** Check the schedule and how long snapshots are kept, then select **Back Up Now**.

If you already back up another Mac or the [standalone container](/getting-started/standalone), select **I Already Have a Recovery Key** at step 3 instead. The app lists the backups on your account: pick the one this Mac should continue, or start a new one, and enter its recovery key.

Caches, the Trash, cloud-synced folders and container disk images are skipped automatically. Change what is backed up and excluded later under **Folders**.

## Day to day

Closing the window leaves the app running in the menu bar, where it shows progress and has **Back Up Now**. Keep **Open at login** on, under **Settings** → **General**, so scheduled backups run after a restart.

- **Schedule.** On **Overview**, choose **Manual**, **Hourly**, **Daily** or **Weekly**. The default is every day at 12:00. A backup that comes due while the Mac is asleep or the app is not running runs the next time it can.
- **Keep snapshots.** Under **Settings** → **Snapshots**, choose 15, 30, 60 or 90 days, the latest two backups, everything, or your own rules. The default keeps 60 days.
- **Upload limit.** Under **Settings** → **Bandwidth**, cap the upload speed and, if you want, lift the cap overnight with **Full speed at night**.
- **Disk snapshots.** Under **Settings**, **Back up from a disk snapshot** reads folders on your Mac's internal disk from a frozen copy, so files that change during a backup stay consistent. It needs Full Disk Access.

Turn on **Notify me if a scheduled backup fails**, under **Settings** → **General**, to hear about it when scheduled backups stop working.

## Restoring

Open **History** and pick a snapshot:

- **Browse Files** lets you tick individual files and folders to restore.
- **Restore All** restores everything in the snapshot.

Either way you choose a folder to restore into. Nothing already in that folder is overwritten: when a name is taken, the restored copy gets a number, for example `Report 2.pdf`.

## Your recovery key

**Settings** → **Security** → **Show Recovery Key** shows the key after you confirm with Touch ID or your password. **Change Recovery Key** replaces it with a new one.

## Next

- [Your recovery key](/guides/recovery-key), which is the one thing you must not lose.
- [Restoring files](/guides/restore), worth reading once before you need it.
