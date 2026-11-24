# Whirr

Whirr is a native SwiftUI client for a self-hosted [Audiobookshelf](https://www.audiobookshelf.org)
server, for iPhone and iPad on iOS 26. It plays audiobooks and podcasts, reads EPUB ebooks, keeps
the local library usable offline, and syncs listening progress back to your server. It also
supports podcast subscriptions by RSS that do not need a server at all.

The signed release is on the App Store. This repository is the source it is built from.

## Why the source is published

Whirr has no backend, no analytics, and no account with the developer. The
[privacy policy](docs/legal/privacy-policy.md) says so, and publishing the code lets anyone check
that claim rather than take it on trust. The [security contract](docs/SECURITY.md) describes how
credentials and local data are handled.

## Licence

Whirr is free software under the [GNU General Public License, version 3](LICENSE)
(GPL-3.0-only). You may use, study, modify and share it, including builds of it, provided anything
you distribute is also under GPL-3.0 with its source available.

The licence covers the code, not the name. A modified or redistributed build must not be called
Whirr or use the Whirr icon; see [NOTICE](NOTICE). Third-party packages keep their own licences.

## Building

You need Xcode 26.6 or later. Swift packages resolve on first open. The Core package builds and
tests without a simulator:

```sh
swift test --package-path Packages/Core
Scripts/check-format.sh
```

The app itself:

```sh
xcodebuild \
  -project App/Whirr.xcodeproj \
  -scheme Whirr \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

That build is unsigned and runs only in the Simulator.

### Installing on your own iPhone

You are welcome to build Whirr for your own devices. It is not a supported path, so please
report bugs only from the App Store build. The project is set up to sign as the App Store
build, and that signing uses capabilities a personal account cannot get. In Xcode:

1. **Signing.** For each of the Whirr, WhirrWidgetsExtension and WhirrWatch Watch App targets,
   open Signing & Capabilities and choose your own team.
2. **Bundle identifiers.** Replace `com.remoteconcern.whirr` with a prefix you own, keeping the
   suffixes: the app is `<prefix>`, the widget `<prefix>.WhirrWidgets`, the Watch app
   `<prefix>.watchkitapp`. Then set the Watch target's `WKCompanionAppBundleIdentifier` build
   setting to `<prefix>`.
3. **CarPlay.** Delete the CarPlay Audio entitlement from the Whirr target. Apple grants it per
   developer on request, so signing fails while it is there.
4. **iCloud and push.** On a free Apple ID, also delete the iCloud and Push Notifications
   capabilities from the Whirr target; a paid account can keep them only with an iCloud container of
   its own, which also means changing the container identifier in
   `App/Whirr/PodcastCloudSyncComposition.swift`. Without them, leave **iCloud Sync** (Settings,
   under Podcast Data) off: it needs CloudKit and will not work in your build.
5. **App group.** Either rename `group.com.remoteconcern.whirr` to a group you own, in the Whirr
   and WhirrWidgetsExtension capabilities and in
   `Packages/Core/Sources/WidgetProtocol/WidgetStorageLayout.swift`, or delete the App Groups
   capability from both targets. Without it the app works, but the widgets show nothing.

Then choose your device as the run destination and press Run. Builds signed with a free Apple ID
expire after seven days; run again from Xcode to renew. Everything else (playback, downloads,
offline use, EPUB, podcasts by RSS, the Watch app) needs no special capability.

## Issues and support

Bug reports and feature requests go through
[GitHub Issues](https://github.com/whirr-app/Whirr/issues). Please use the templates; they ask for the app, iOS, and
Audiobookshelf server versions, which are needed for almost every report.

This repository does not accept pull requests. Each release is published here as one commit, so
there is no development history to work against.

## Repository map

| Path | Purpose |
|---|---|
| `App/Whirr/` | SwiftUI screens, app composition, and iOS-only adapters |
| `Packages/Core/` | Domain, persistence, sync, model, and design-system targets |
| `App/WhirrTests/` | App composition and presentation tests |
| `docs/` | Architecture, API, sync, security, and testing contracts, plus decision records |
| `docs/legal/` | Privacy policy |
| `site/` | Support and privacy pages, published at <https://whirr-app.github.io/Whirr/> |

[codemap.md](codemap.md) routes from a feature to the file that owns it.
