# Whirr — Privacy Policy

**Last updated:** 20 November 2026

Whirr is an iOS client for [Audiobookshelf](https://www.audiobookshelf.org), a self-hosted media
server. This policy describes what Whirr does with your information.

## The short version

**Whirr collects no data about you.** There is no Whirr server, no account with the developer, no
analytics, no telemetry, and no third-party crash reporting or advertising code in the app. Nothing
you do in Whirr is transmitted to the developer. Optional RSS subscriptions, where enabled, contact
the feed and media/artwork hosts selected by that subscription; those services receive ordinary
network metadata and are governed by their own policies.

If you turn on iCloud Sync for podcasts, Whirr keeps your podcast subscriptions and listening state in your own private iCloud database, which Apple runs. The developer cannot read it. See iCloud Sync for podcasts below.

You do not have to take that on trust. The source code of every released version is published at
<https://github.com/whirr-app/Whirr>, so the absence of analytics, telemetry, and tracking code can
be checked directly.

## There is no developer-operated service

Whirr does not have a backend. When you set up the app you enter the address of **your own**
Audiobookshelf server. Signing in, browsing your server library, streaming, server-hosted downloads,
artwork, and listening-progress sync go to that server. In a build where you enable native RSS
subscriptions, Whirr also contacts the subscribed feed and the allowed enclosure/artwork hosts needed
to provide that subscription. It never sends your Audiobookshelf credentials to those RSS origins.

The developer has no access to that server, its contents, or any traffic between it and your
device. Your relationship with that server is governed by whoever runs it, which in the ordinary
case is you.

## iCloud Sync for podcasts

iCloud Sync for podcasts is off by default. Nothing is sent to iCloud until you turn on Podcast Data › iCloud Sync in Whirr's podcast settings on that device. When it is on, Whirr uses Apple's CloudKit to keep the following in the private database of your iCloud account:

- the RSS podcasts you follow, including their feed addresses, titles and authors, and your show order;
- your podcast settings, overall and for each show;
- each episode's playback position, played and dismissed state, title and feed identifiers;
- Saved for Later and the last episode you played; and
- a random identifier for this installation of Whirr, used to order changes between devices.

This data is stored in your iCloud storage and counts toward your quota; Apple's privacy policy governs it. There is still no Whirr server, and the developer has no access to it. Every value except a version number is stored as a CloudKit encrypted field, and becomes end-to-end encrypted if you turn on Advanced Data Protection for iCloud. Record names that are derived from your data are keyed hashes, so they do not reveal which podcasts you follow.

Your Audiobookshelf server address, account, library and progress, passwords, tokens, feed passwords, downloaded audio, artwork and diagnostics are never synced.

Turning sync off stops syncing and keeps your data on the device and in iCloud. Delete Podcast Data from iCloud removes the iCloud copy without changing what is on your devices.

## Podcast backup files

Create Backup writes a file only when you ask for one, and you choose where it goes. The file is plain, unencrypted JSON containing the feed addresses of the podcasts you follow, your podcast settings and your listening state. It never contains passwords, feed passwords, tokens, Audiobookshelf data or audio. Some private feed addresses include an access key, so treat backup files as private. Whirr never uploads a backup anywhere on its own.

## What is stored on your device

| Data | Where it is kept | Notes |
|---|---|---|
| Server address and account identity | App container | Never leaves the device except to reach that server |
| Access and refresh tokens | iOS Keychain | Device-only; explicitly excluded from iCloud and desktop backups |
| Your account password | **Not stored** | Used once to sign in, then discarded |
| Library metadata and listening progress | Local database in the app container | Protected with iOS file protection |
| Downloaded audiobooks, server-hosted podcasts, and books | App container | Excluded from iCloud backup; removed on sign-out |
| Native RSS subscriptions and downloads, when enabled | App container | Device-owned; retained on sign-out and removable through the subscription controls |
| Podcast episodes you send to your Apple Watch, when enabled | The Watch app's own container | Copied to the Watch; not backed up; removed when played or removed, and deleted when you sign out of Whirr on the Watch |
| Cover artwork cache | App container | Account-owned server artwork clears on sign-out; device-owned RSS cache follows its subscription |
| App-wide display preferences | iCloud key-value storage | A fixed allowlist of non-sensitive settings only — never server addresses, account identity, credentials, tokens, library contents, or media |
| Podcast subscriptions and listening state, when iCloud Sync is on | Your private iCloud database | Encrypted CloudKit fields; see iCloud Sync for podcasts |

Podcast episodes you send to your Apple Watch are copied to the Watch and stay on it until they are
played or removed. They are not backed up, and they are deleted if you sign out of Whirr on the
Watch.

## Diagnostics

Whirr uses Apple's MetricKit to record local performance, crash, and responsiveness information.
It stays on your device and is **never uploaded** — not to the developer, not to anyone.

Settings › About › Report a Problem can build a diagnostics file from that information and from
Whirr's own recent activity record. The file is only ever shared by you, through the system share
sheet, to a destination you choose; the app never sends it anywhere on its own. You can read the
whole file in the app before sharing it. Logging out deletes it.

That file, and every log or error message Whirr writes, never contains your server address, account
name, passwords, tokens, authorization headers, or the titles of anything in your library.

## Tracking and advertising

Whirr does not track you. It contains no advertising identifier (IDFA), no App Tracking Transparency
prompt, no advertising or attribution SDK, and no analytics SDK of any kind. No data is shared with
data brokers or advertising networks, and no user profile is built for any purpose.

## Links out of the app

An EPUB you read may contain external links. Whirr opens one only after you confirm it, only for
`http`, `https`, `mailto`, and `tel` addresses, and only by handing it to the appropriate system
app. Once a link opens elsewhere, that destination's own privacy policy applies. All other link
types are refused.

## Siri and App Shortcuts

Whirr's voice actions carry no title, author, account, server, or library information. They accept
only a playback direction or a sleep-timer duration.

## Children

Whirr is a client for a library you supply. It contains no first-party catalogue and shows no
advertising. It collects no data from anyone, including children.

## Deleting your data

Signing out of Whirr deletes your stored credentials, the local database for that account,
server-hosted downloads, account-owned artwork cache, and any exported diagnostics from the device.
Device-owned native RSS subscriptions and downloads, when enabled, remain until you remove them in
the app. Deleting the app removes everything in its container. Signing out does not turn off iCloud Sync for podcasts or remove its iCloud copy, and neither does deleting the app; use Delete Podcast Data from iCloud for that. Backup files you created stay wherever you saved them.

Because the developer holds no data about you, there is nothing to request, correct, export, or
delete from the developer. Requests about your Audiobookshelf library should go to its operator;
requests about an RSS feed or media host should go to that service's operator.

## Your rights

Whirr processes no personal data on the developer's behalf, so there is no controller-held data
subject to access, rectification, erasure, portability, or objection requests under the UK GDPR,
the EU GDPR, or the CCPA/CPRA. Whirr sells no personal information and shares none.

## Changes

If this policy changes, the updated version will be posted at this address with a new "last
updated" date. Material changes affecting how the app handles your information will also be noted
in the app's release notes.

## Contact

Questions about this policy: <support@whirrapp.uk>
