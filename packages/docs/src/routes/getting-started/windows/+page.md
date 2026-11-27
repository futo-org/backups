---
title: Set up on Windows
description: Install the FUTO Backups Windows app and back up the folders on your PC
order: 5
---

The Windows app backs up folders on your PC on a schedule. It runs from the system tray and needs Windows 10 version 2004 or later, or Windows 11.

> [!WARNING]
> Keep a second copy of each file that you cannot lose. The Windows app is in alpha, which is earlier than the rest of the beta.

Before you start, [join the beta](/getting-started/beta) and make sure that you can sign in at [backups.futo.cloud](https://backups.futo.cloud).

## Install the app

1. Open the newest [FUTO Backups for Windows release](https://github.com/futo-org/backups/releases?q=windows-v&expanded=true).
2. Download the installer for your PC. Most PCs need `FUTOBackups-win-x64-Setup.exe`. For a PC with an Arm processor, download `FUTOBackups-win-arm64-Setup.exe`.
3. Open the installer. It installs FUTO Backups for your user account and opens it.

If Windows shows "Windows protected your PC", select **More info**, then **Run anyway**.

The app installs its own updates. To stop this, or to look for an update now, go to **Settings** → **Updates**.

## Set up the app

Open the app. It shows the setup steps in this order:

1. Telemetry. To continue during the closed beta, select **Continue** to share diagnostic data with FUTO. This data does not include your files or your recovery key.
2. Sign in. Select **Sign In**. Your browser opens the FUTO sign-in page with a code. Make sure that this code is the same as the code in the app, then approve. The app then continues.
3. Save your recovery key. Select **Save to File**, **Copy** or **Print**. Then select "I saved my recovery key somewhere safe" and type the key again. This makes sure that your copy is correct. Read [your recovery key](/guides/recovery-key) before you continue.
4. Choose what to back up. Select a preset or choose the folders yourself. The app shows the total size of the folders that you select.
5. Ready to back up. A snapshot is the copy of your folders that one backup makes. Make sure that the schedule and the time to keep snapshots are correct, keep **Open FUTO Backups at login** on, then select **Back Up Now**.

There are three presets:

- **Essentials**: Documents and Desktop.
- **Essentials + Media**: Documents, Desktop, Pictures, Videos and Music.
- **Everything**: your full user folder.

If you already back up another PC, a Mac or the [standalone container](/getting-started/standalone), select **I Already Have a Recovery Key** at step 3. The app shows the backups on your account. Select the backup that this PC continues, or start a new one. Then type the recovery key of that backup.

The app does not back up caches, the Recycle Bin, files kept only in the cloud or container disk images. OneDrive, Dropbox and Google Drive files that are not on your PC are skipped until you make them available offline. To change what the app backs up or excludes, go to **Folders**.

## Use the app

When you close the window, the app continues to run in the system tray. Select the FUTO Backups icon in the tray to see the progress of a backup and to select **Back Up Now**. Keep **Open at login** on, under **Settings** → **General**. If this setting is off, scheduled backups stop when you restart your PC.

You can change these settings:

- Schedule: on **Overview**, select **Manual**, **Hourly**, **Daily**, **Weekly** or **Custom**. The default is one time each day, around midday. If your PC was asleep at that time, the backup starts when your PC wakes.
- Keep awake: under **Settings** → **Scheduled backups**, **Keep this PC awake** stops your PC from going to sleep on its own during a backup. This setting is on by default.
- Backup conditions: under **Settings** → **Scheduled backups**, a scheduled backup can wait until your PC is on power, on Ethernet, connected to an external display or attached to a USB device such as your dock. If the conditions stay unmet, the backup runs anyway after 3 days. You can change this time or select **Never**. **Back Up Now** does not wait for the conditions.
- Snapshots to keep: under **Settings** → **Snapshots**, select 15, 30, 60 or 90 days, the latest two backups, all backups, or your own rules. The default is 60 days.
- Upload limit: under **Settings** → **Bandwidth**, set the maximum upload speed. To remove the limit at night, turn on **Full speed at night**.
- Failure notifications: under **Settings** → **General**, turn on **Notify me if a scheduled backup fails**. The app then tells you when scheduled backups stop.

To see your recovery key, go to **Settings** → **Security** and select **Show Recovery Key**. The app asks for Windows Hello or your Windows password first. To replace the key with a new key, select **Change Recovery Key**.

## Restore files

Open **History** and select a snapshot. To restore some files and folders, select **Browse Files** and select each item. To restore all of the snapshot, select **Restore All**. Then choose a folder for the restored files.

The restore does not overwrite files in that folder. If a name is already in use, the app adds a number to the restored copy, for example `Report 2.pdf`.

## Support mode

If FUTO support asks for detailed logs, go to **Settings** → **Diagnostics** → **Support mode** and select how many backups to record. Restores that you start while support mode is on are recorded too. Support mode turns itself off after those backups.

- To let support read the logs directly, turn on **Send logs to FUTO**. Each recorded run then shows a support code in **History**. Give this code to support.
- To keep the logs on your PC, leave **Send logs to FUTO** off. Select **Save Support Log** on the run in **History**, then attach the file to your support ticket.

File names in the logs are replaced by placeholders, unless you turn on **Include file names**. The logs never contain your files or your recovery key.

## Next

- [Your recovery key](/guides/recovery-key), which is the one thing you must not lose.
- [Restoring files](/guides/restore), worth reading once before you need it.
- [Getting help](/help/support), if something goes wrong.
