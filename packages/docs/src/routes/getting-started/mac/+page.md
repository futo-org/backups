---
title: Set up on a Mac
description: Install the FUTO Backups Mac app and back up the folders on your Mac
order: 4
---

The Mac app backs up folders on your Mac on a schedule. It runs from the menu bar and needs macOS 26 or later.

> [!WARNING]
> Keep a second copy of each file that you cannot lose. The Mac app is in alpha, which is earlier than the rest of the beta.

Before you start, [join the beta](/getting-started/beta) and make sure that you can sign in at [backups.futo.cloud](https://backups.futo.cloud).

## Install the app

You can install the app with [Homebrew](https://brew.sh) or from a download.

To install with Homebrew, run these two commands:

```bash
brew trust --cask futo-org/tap/futo-backups
brew install --cask futo-org/tap/futo-backups
```

The first command tells Homebrew to trust the FUTO tap, which is the list of FUTO packages. You run it one time only.

To install from a download, do these steps:

1. Download `FUTO-Backups-<version>.zip` from the newest [FUTO Backups for macOS release](https://github.com/futo-org/backups/releases?q=macos-v&expanded=true).
2. Open the zip file.
3. Move **FUTO Backups** into **Applications**.

The app installs its own updates. To stop this, or to look for an update now, go to **Settings** → **Updates**.

## Set up the app

Open the app. It shows the setup steps in this order:

1. Telemetry. To continue during the closed beta, select **Continue** to share diagnostic data with FUTO. This data does not include your files or your recovery key.
2. Sign in. Select **Sign In**. Your browser opens the FUTO sign-in page with a code. Make sure that this code is the same as the code in the app, then approve. The app then continues.
3. Save your recovery key. Select **Save to File**, **Copy** or **Print**. Then select "I saved my recovery key somewhere safe" and type the key again. This makes sure that your copy is correct. Read [your recovery key](/guides/recovery-key) before you continue.
4. Full Disk Access. Without this permission, macOS does not let apps read folders such as Mail, Messages and Safari. Select **Open System Settings**, turn on **FUTO Backups** in the list, then go back to the app. If you skip this step, you can turn it on later from **Folders**.
5. Choose what to back up. Select a preset or choose the folders yourself. The app shows the total size of the folders that you select.
6. Ready to back up. A snapshot is the copy of your folders that one backup makes. Make sure that the schedule and the time to keep snapshots are correct, then select **Back Up Now**.

There are three presets:

- **Essentials**: Documents and Desktop.
- **Essentials + Media**: Documents, Desktop, Pictures, Movies and Music.
- **Everything**: your full home folder.

If you already back up another Mac or the [standalone container](/getting-started/standalone), select **I Already Have a Recovery Key** at step 3. The app shows the backups on your account. Select the backup that this Mac continues, or start a new one. Then type the recovery key of that backup.

The app does not back up caches, the Trash, cloud-synced folders or container disk images. To change what the app backs up or excludes, go to **Folders**.

## Use the app

When you close the window, the app continues to run in the menu bar. The menu bar shows the progress of a backup and has **Back Up Now**. Keep **Open at login** on, under **Settings** → **General**. If this setting is off, scheduled backups stop when you restart your Mac.

You can change these settings:

- Schedule: on **Overview**, select **Manual**, **Hourly**, **Daily** or **Weekly**. The default is each day at 12:00. If your Mac was asleep at that time, the backup starts when the app can run it.
- Keep awake: under **Settings** → **Scheduled backups**, **Keep this Mac awake** stops your Mac from going to sleep on its own during a backup. This setting is on by default. Closing the lid still puts your Mac to sleep.
- Backup conditions: under **Settings** → **Scheduled backups**, a scheduled backup can wait until your Mac is on power, on Ethernet, connected to an external display or attached to a USB device such as your dock. If the conditions stay unmet, the backup runs anyway after 3 days. You can change this time or select **Never**. **Back Up Now** does not wait for the conditions.
- Snapshots to keep: under **Settings** → **Snapshots**, select 15, 30, 60 or 90 days, the latest two backups, all backups, or your own rules. The default is 60 days.
- Upload limit: under **Settings** → **Bandwidth**, set the maximum upload speed. To remove the limit at night, turn on **Full speed at night**.
- Disk snapshots: under **Settings**, **Back up from a disk snapshot** reads the internal disk of your Mac from a copy that does not change during the backup. This setting needs Full Disk Access.
- Failure notifications: under **Settings** → **General**, turn on **Notify me if a scheduled backup fails**. The app then tells you when scheduled backups stop.

To see your recovery key, go to **Settings** → **Security** and select **Show Recovery Key**. The app asks for Touch ID or your password first. To replace the key with a new key, select **Change Recovery Key**.

## Restore files

Open **History** and select a snapshot. To restore some files and folders, select **Browse Files** and select each item. To restore all of the snapshot, select **Restore All**. Then choose a folder for the restored files.

The restore does not overwrite files in that folder. If a name is already in use, the app adds a number to the restored copy, for example `Report 2.pdf`.

## Next

- [Your recovery key](/guides/recovery-key), which is the one thing you must not lose.
- [Restoring files](/guides/restore), worth reading once before you need it.
