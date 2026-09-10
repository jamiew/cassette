# Claude Code instructions for Cassette

## Build / test / lint

- `make build` — iOS simulator build. Use this to verify changes; it auto-detects the simulator.
- `make build-mac` — macOS build. Run it too: the app ships on both platforms and iOS-only
  code has broken the Mac target before.
- `make test` — the `CassetteTests` scheme on the simulator. Swift Testing (`@Test` / `#expect`).
- `make lint` — SwiftLint `--strict`. Same gate CI runs. It is clean today; keep it that way.
- `make device` — build, install and launch on a connected iPhone. Needs `DEVICE_NAME`.
  A locked phone refuses the launch but the install has already succeeded; that prints a
  note rather than failing.
- `make ci` — the whole gate in CI's order. Run this before proposing a change is done.

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
  call SwiftSonic for a stream URL from anywhere else. Chromecast is the exception: a
  direct cast needs a stream URL because the receiver cannot reach a file on the phone,
  while a relayed cast prefers exactly that file. See the Chromecast section.
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
- **There are two ways to deliver a track, and `castItem(for:)` chooses.** Direct, where
  the receiver fetches the Subsonic stream URL itself — fewer hops, and it keeps playing
  when the app is suspended. Or relayed through `CastProxyServer`, where the phone serves
  the audio over the LAN and the receiver collects from `http://<phone>/media/<token>`.
- **Direct is preferred and used whenever it can work.** Subsonic stream URLs
  self-authenticate through query parameters, which is what makes it possible at all.
- **The relay is for what direct cannot do:** a server needing request headers the Cast
  SDK has nowhere to put, an address only the phone can resolve, a certificate only the
  phone trusts, and downloaded files. It is chosen up front for the cases we can detect,
  and fallen back to for the rest when the receiver reports it could not fetch. After one
  such failure the session stays relayed — the next track would fail identically.
- **A relayed cast prefers a local copy.** If the track is downloaded or cached the phone
  already holds the bytes, so the relay drops back to a single hop.
- **The relay only lives as long as the app.** A suspended app serves nothing, so a
  relayed cast stops when the app is. Direct casts are unaffected. Worth fixing; see
  `CastProxyServer`'s note.
- **The receiver must be able to reach the server on its own.** It fetches the audio with
  its own DNS and its own network, so a server that only answers on the phone is invisible
  to it: a Tailscale `ts.net` name, a Bonjour `.local` name, loopback, or a certificate the
  phone trusts and the speaker does not. This is the single most common reason casting
  "connects but does nothing". `CastMediaItem.isLikelyUnreachableByReceiver(host:)` only
  shapes the error message — never block a cast on it, because the same `ts.net` name
  published through Tailscale Funnel is public and works.
- **A receiver that fails says so once, quietly.** It goes idle with `idleReason == .error`
  and nothing else. Map that to `CastStatusEvent.failed` and surface it; treating it as a
  state to ignore is what makes a broken cast look like a dead play button.
- Uses the Default Media Receiver (`kGCKDefaultMediaReceiverApplicationID`) — no custom
  receiver, no Google registration fee.
- **Testing the relay needs no Chromecast.** `CastProxyServerTests` runs the real server
  over a socket and collects from it the way a receiver would, so ranges, HEAD and token
  handling are covered headlessly in `make test`. `CastProxyHTTPTests` covers the parsing.
- **Testing the session.** The receiver→player mapping is a pure `CastManager.event(for:…)`, so
  the transitions that matter are unit-tested rather than left to hardware. Add cases
  there instead of reaching for a live speaker. `make check-cast` answers the separate
  question of whether there is anything on the network to cast to; it is outside
  `make test` because an empty room is not a defect. What stays unautomated: the SDK's
  own session lifecycle, `GCKUICastButton` rendering, and whether audio actually comes
  out of the speaker.
- **The simulator cannot cast.** The SDK's discovery needs real multicast, so the device
  picker there always reads "No devices available". `CassetteUITests/CastFlowUITests`
  drives the whole flow up to that point and is deliberately outside `make test`; finishing
  the session needs hardware. To see what a real receiver was told, join it as a second
  sender from the Mac (`pychromecast`, or `catt`) and read its media status — that is how
  you tell "the app never sent a load" apart from "the speaker refused it".
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
