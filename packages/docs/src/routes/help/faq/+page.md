---
title: Frequently asked questions
description: Short answers to the questions people ask most about FUTO Backups during the beta
order: 1
---

These are the questions that came up most often during the beta. Where a guide covers a topic in more depth, the answer links to it.

## The beta

### Does it cost anything?

No. FUTO Backups is free for the whole closed beta. Beta accounts have no billing details attached, so nothing can be charged.

Pricing for after the beta has not been announced. So far we have only said that it will be competitive with Backblaze B2, and that you will pay for the storage you actually use rather than buying a fixed amount up front. See [what it costs](/guides/account#what-it-costs).

### Is there a storage limit?

No. There is no cap during the closed beta, so back up as much as you like. Large libraries are exactly what we want to test.

### Will my backups be kept after the beta?

That has not been decided yet. We may need to wipe all beta data at the end of the beta for technical reasons. If beta data ever has to be deleted, we will announce it in the FUTO Backups Discord channels before it happens, although in an emergency that notice could be short.

The beta comes with no durability or availability guarantees, so do not make FUTO Backups the only copy of anything you care about.

## Setting up

### Which version of Immich do I need?

Immich v3.4.0 or later. Earlier releases do not include backups, so on them the `/link?target=backups` address just takes you to your photos. See [update Immich](/getting-started/immich#1-update-immich).

If your installation has not picked up v3.4.0 yet, for example the Unraid all-in-one image, you can join the beta with the [standalone container](/getting-started/standalone) in the meantime.

### Can I back up more than my Immich library?

Yes. The [standalone container](/getting-started/standalone) runs the same backup software outside Immich and backs up any folders you mount into it, so you can use it for a whole home server or NAS. One account can have Immich and standalone machines connected at the same time.

### Does it back up my external libraries?

Yes. The recommended settings for your first backup in Immich include external libraries. Under **Backup Contents** you can choose to include all of them, none, or specific ones. See [choose what gets backed up](/getting-started/immich#4-choose-what-gets-backed-up).

### Can I choose what is backed up before the first backup starts?

In Immich, setup ends by starting a first backup with recommended settings. You can change **Backup Contents** at any time, and the change applies from the next run. If you would rather not upload anything yet, cancel the backup once it starts, adjust your settings, and run it later.

### I skipped two-factor authentication. How do I set it up now?

Sign in to your FUTO account at [auth.futo.cloud](https://auth.futo.cloud) and open its security settings, where you can add a second factor.

## Backups

### Are backups incremental?

Yes. The first backup uploads everything. After that, each run only sends what changed, so later backups are much faster.

Data is also deduplicated within a backup, so the same photo uploaded twice to one Immich server is only stored once. Separate backups do not share data with each other, so a second Immich server, or a backup set up from scratch, uploads everything again.

### Why does the first backup take so long, and why does the time remaining jump around?

The first backup has to upload your whole library, which can take days on a slow connection. The time remaining is worked out from how fast data has gone so far, so it moves a lot early on, and again whenever the backup moves between large and small files.

Your backups are stored in Germany. If you are far away, for example in South America, uploads can be slower than your connection suggests.

### Can I limit how much bandwidth backups use?

In Immich, yes. Open **Configure** on the backups page, then **Bandwidth**, and set an **Upload speed** in Mbps. You can also turn on **Full speed during quiet hours** so the limit is lifted overnight. The limit only applies to uploads, not to restores.

The standalone app does not have a bandwidth setting yet.

### Later backups of my large library still take a long time. Why?

Every run checks every file for changes, even when very little has changed. On a library with millions of files, and especially on a network share, that check is most of the work. [Folders on a network share](/getting-started/standalone#folders-on-a-network-share) explains how to tune it.

Some changes make the next backup read every file again in full, such as switching a share between SMB and NFS or anything else that changes the file metadata the system reports. Nothing new is uploaded, because the data is already stored, but that one run takes much longer than usual.

On SMB mounts, the `nouser_xattr` mount option can make these checks a lot faster, because it skips reading extended attributes for every file. The trade-off is that those extended attributes are then not included in your backups.

### Should I turn off the database backups built into Immich?

You can. FUTO Backups makes its own fresh database backup at the start of every run, so it matches the files in that backup closely. If Immich's scheduled database backups are still on, the backups page suggests **Use FUTO Backups only**, which is the right choice for most people. Keeping both is fine if you want the extra copies.

### Can I back up Immich with the standalone container instead?

We recommend the Immich integration, because it takes care of the database for you. Copying the folder of a running Postgres database does not give you a usable backup.

If you do use the standalone container, turn on Immich's automatic database backups in its admin settings. They are written to the `backups` folder inside your Immich upload location, so include that folder in your backup. Be aware that those database backups are taken on their own schedule, so they may not match your files exactly.

### Can I exclude folders or file types?

Not yet. In the standalone app a backup covers everything under the paths you choose, so pick paths that only contain what you want. In Immich you choose categories under **Backup Contents** rather than individual folders, users or file types.

### Will I be told when a backup fails?

Not yet. Failure notifications are not built. Until they are, check the backups page in Immich or the app, or your dashboard at [backups.futo.cloud](https://backups.futo.cloud), from time to time.

### If backups are incremental, how can old snapshots be deleted?

Your data is stored in packs that each snapshot refers to. When an old snapshot is removed, any packs that no other snapshot uses are deleted. Packs that are only partly used are repacked: the data still needed is moved into a new pack and the old one is deleted, freeing the space. Newer snapshots keep everything they need. See [how long snapshots are kept](/guides/schedules#how-long-snapshots-are-kept).

## Restoring and your recovery key

### What happens if I lose my recovery key?

Your backups cannot be decrypted without it, and FUTO does not have a copy, so nobody can recover them for you. If the machine still works, you can [view the key again](/guides/recovery-key#seeing-it-again-later) and save it properly this time.

Keep it somewhere that survives losing the machine you back up: a password manager, a printed copy, or a file on another machine. If your password manager is self-hosted on that same server, it is not a separate copy.

### Is the recovery key the same as the encryption key?

Yes. Both names mean the same 64-character key you were shown during setup. See [your recovery key](/guides/recovery-key).

### I reinstalled Immich and imported my key, but it started a new first backup. What went wrong?

Restoring onto a new Immich server has to start from the **Welcome to Immich** page, before you create an admin account: choose **Restore From Backup**, then **FUTO Backups**, and import your key there. Importing the key in the normal backups setup connects the server as a new one instead. Start again from a fresh install and follow [rebuilding a machine](/guides/restore#immich).

### Can FUTO see my files, or can I download them from the website?

No to both. Your files are encrypted on your machine before they are uploaded, with a key that never leaves you, so neither FUTO nor the website can read them. To get files back, restore them from the app on your machine. You can pick individual files with **Select files instead**. See [restoring files](/guides/restore).

### Can I import backups I made with another tool?

Not at the moment. Backups made with other software or another provider cannot be brought into FUTO Backups, so your first backup uploads everything.

## Storage and updates

### Where is my data stored?

On FUTO's own hardware in Falkenstein, Germany. There is no region to choose. See [where your data is stored](/guides/account#where-your-data-is-stored).

### Can I store backups somewhere other than FUTO storage?

In the standalone app you can add **Local Storage**, a disk mounted into the container, alongside or instead of FUTO's storage. See [where backups are stored](/guides/backups#where-backups-are-stored). Immich currently stores backups on FUTO's storage only. Other destinations, such as your own S3 bucket, are not supported today.

### How do I update the standalone container?

It does not update itself. Pull the new image and recreate the container, as shown in [updating](/getting-started/standalone#updating). Release notes for each version are on the [releases page](https://github.com/futo-org/backups/releases) of the repository.
