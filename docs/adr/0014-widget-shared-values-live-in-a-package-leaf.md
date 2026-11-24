# ADR 0014: Where app/widget-extension shared values live

- Status: Accepted (2026-11-06, with the widgets plan's recommended defaults, WLA-OD7 (a))
- Date: 2026-11-06

## Decision

The values the app and the widget extension share go in a new **dependency-free leaf target
`WidgetProtocol`** inside `WhirrCore`, mirroring `WatchProtocol` (ADR 0003). It holds:

- `WidgetSnapshot` and its parts, the file the app writes into the App Group and the extension's
  only input (WLA-OD3 (a));
- `WidgetSnapshotCodec`, which validates before encoding and after decoding, bounds the bytes,
  probes the schema version first, and emits sorted-key JSON;
- `WidgetStorageLayout`, the App Group identifier and every path under the one `Widgets` folder,
  with cover names validated so a snapshot cannot point the extension outside it;
- `SleepTimerActivityAttributes`, the sleep-timer Live Activity's values (WLA-OD5 (a)).

Same amendment as ADR 0003: **no package dependencies; system frameworks behind `#if canImport`
are permitted**. `ActivityKit` conformance is guarded by `#if canImport(ActivityKit) && os(iOS)`,
because the package also builds for macOS (where its tests run) and watchOS.

The widget extension links `WidgetProtocol` and nothing else from the package. The app links it
too, for the publisher and the Live Activity driver.

## Why not the alternative

**A synchronized source folder `App/WidgetShared`** compiled into both targets, as `App/WatchShared`
is. Smaller, with no package edge, but its tests would run only in the App suite on a simulator,
and the codec's bounds, version handling and path validation are exactly the pure logic the
package tests quickly on macOS. `App/WatchShared` holds platform adapters, which is the case it
suits; these are values.

## Consequences

- Adding a target is a dependency-graph change: `Package.swift`, the `ARCHITECTURE.md` §1 table and
  `LayeringTests` move together (decision log D49).
- No server identifier crosses into the App Group: items carry an opaque per-publication token, and
  text that looks like a URL or a path is refused on construction and on decode (WLA-OD6 (a)).
- Linking the product to the Whirr and WhirrWidgetsExtension targets is a project-bundle change
  Rhys makes in Xcode (widgets plan, H1 step 7).
- The extension must not import `AppModel`, `Persistence` or `ABSApi`; it reads only the snapshot
  and the covers. That keeps it inside the widget memory budget and away from the database and
  Keychain.

## Evidence

`widgets-and-live-activities-plan.md`, WLA-OD3,
WLA-OD5, WLA-OD6 and WLA-OD7, approved 2026-11-06.
