# Claude Code instructions for Cassette

## Build / test / lint

- `make build` — iOS simulator build. Use this to verify changes; it auto-detects the simulator.
- `make build-mac` — macOS build. Run it too: the app ships on both platforms and iOS-only
  code has broken the Mac target before.
- `make test` — the `CassetteTests` scheme on the simulator. Swift Testing (`@Test` / `#expect`).
- `make lint` — SwiftLint `--strict`. Same gate CI runs. It is clean today; keep it that way.
- `make device` — build, install and launch on a connected iPhone. Needs `DEVICE_NAME`.

Don't hardcode a simulator UDID. The Makefile derives one.

CI (`.github/workflows/ci.yml`) runs lint, both builds, and the tests on every push and PR.

## Signing and identifiers

Team ID, display name, bundle ID and App Group all come from `Config/Cassette.xcconfig`,
which every target inherits through the project-level base configuration. A checkout
overrides them in `Config/Local.xcconfig` (gitignored, created by `make setup`).

**Never hardcode any of those four values in `project.pbxproj`, an entitlements file, or
an Info.plist.** Reference `$(CASSETTE_DEVELOPMENT_TEAM)`, `$(CASSETTE_DISPLAY_NAME)`,
`$(CASSETTE_BUNDLE_ID)` or `$(CASSETTE_APP_GROUP_ID)` instead. `SharedStorage.appGroupID`
reads the group back out of the Info.plist for the same reason — the app and the widget
extension must agree on it whoever is signing.

`TEST_HOST` hardcodes `Cassette.app`, so `PRODUCT_NAME` must stay `$(TARGET_NAME)`.
Change `CASSETTE_DISPLAY_NAME` to rename a dev build, not the product name.

## Project conventions

- **Deployment targets are iOS 18 and macOS 15.** Swift language mode 5 with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a plain `struct` or `class` is
  MainActor-isolated unless you write `nonisolated`. Model and DTO types are `nonisolated`.
- **Services are actors**, reached through protocol existentials on `AppContainer`. They
  never import SwiftUI or UIKit. Views hold no business logic.
- **`PlayerService` is the only thing that talks to the audio engine.** It owns one
  long-lived `AudioStreaming.AudioPlayer` for the whole session. Don't add a second.
- **All playback URLs come from `MediaResolver`** (downloaded → cached → stream). Never
  call SwiftSonic for a stream URL from anywhere else. The one exception is Chromecast,
  which must bypass local files because the receiver fetches the audio itself.
- **Never bypass SwiftSonic** for Subsonic API calls. If you are writing more than ~10
  lines of networking, you are in the wrong place. See CONTRIBUTING.md.
- **New files are picked up automatically** — the targets use Xcode's synchronized folder
  groups, so adding a `.swift` file under `Cassette/` needs no `project.pbxproj` edit.
- **Every new Swift file needs the MPL-2.0 header.** Copy it from a neighbour.
- **Use the design system.** No magic-number spacing, hardcoded colors, or one-off fonts
  in views. See `Cassette/DesignSystem/README.md`.

## Chromecast

- **iOS only.** The Cast SDK ships no macOS slice, so `CastManager`, `CastMediaItem` and
  `CastButton` are wrapped in `#if os(iOS)`, and the package is linked with an iOS
  platform filter. Keep it that way or the Mac build breaks.
- **Cassette owns the queue, not the receiver.** Only the current track is ever loaded on
  the Chromecast; `castMediaDidFinish` walks `PlayerService` to the next one. That keeps
  shuffle, repeat, auto-extend and scrobbling working unchanged. Don't push the whole
  queue to the receiver.
- **`PlayerService` treats Cast as an alternative transport.** `isCasting` gates every
  chokepoint (start, pause, resume, seek, stop, volume, progress). Add new transport calls
  to both branches.
- **Cast always streams,** even for downloaded tracks — the file lives on the phone and
  the TV cannot reach it. Subsonic stream URLs self-authenticate through query parameters,
  which is what makes this work at all.
- **Servers needing custom request headers cannot be cast.** The Cast SDK has nowhere to
  put them. `castItem(for:)` detects this and shows a toast instead of failing silently.
- Uses the Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`) — no custom
  receiver, no Google registration fee.
- **Testing it.** The receiver→player mapping is a pure `CastManager.event(for:…)`, so
  the transitions that matter are unit-tested rather than left to hardware. Add cases
  there instead of reaching for a live speaker. `make check-cast` answers the separate
  question of whether there is anything on the network to cast to; it is outside
  `make test` because an empty room is not a defect. What stays unautomated: the SDK's
  own session lifecycle, `GCKUICastButton` rendering, and whether audio actually comes
  out of the speaker.
- Expect `Upload Symbols Failed … no dSYM for GoogleCast.framework` when exporting an
  archive. The SDK is a prebuilt binary without dSYMs. Harmless.

## Tests

- **Swift Testing, not XCTest** (`CassetteUITests` is the only XCTest holdout).
- `@Suite("Name")` on a struct, a private `make…()` factory returning the subject under
  test, and hand-rolled `Mock…` classes in the same file. No mocking framework.
- Use `ModelContainer.cassette(inMemory: true)` per test — suites run in parallel.
- Actor-heavy logic is tested through `nonisolated static` helpers rather than the actor.
  See `CrossfadePreloadTests` and `CastMediaItemTests` for the shape.

## Linting

`.swiftlint.yml` is tuned so `--strict` passes on the tree as it stands. Rules the
existing code breaks in bulk are disabled with a reason, not mass-fixed: reformatting
~1,400 sites would bury real diffs and conflict with every open branch. SwiftFormat is
deliberately **not** wired up for the same reason — it wants to rewrite 305 of 371 files.

If you re-enable a rule, fix its call sites in a dedicated commit.

Two disabled rules are SwiftLint being wrong rather than a style choice:
`redundant_nil_coalescing` misreads `[String: URL?]` subscripts, where `?? nil` flattens
a double optional and is load-bearing, and `static_over_final_class` fires on
`override class` members, which cannot be `static`. Don't "fix" those.

## When making changes

- Keep commits atomic, one concern each. Conventional commit prefixes are used here.
- Don't include Claude Code attribution in commit messages.
- Don't push or merge without explicit instruction.
