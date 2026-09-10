<h1 align="center">SoloDisplay</h1>

<p align="center">
  <em>Turn your MacBook's built-in display fully <strong>off</strong> without closing the lid.</em>
</p>

<p align="center">
  <a href="https://github.com/fanckush/SoloDisplay/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/fanckush/SoloDisplay/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/fanckush/SoloDisplay/releases"><img alt="Release" src="https://img.shields.io/github/v/release/fanckush/SoloDisplay?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/License-GPLv3-blue.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple">
</p>

<!-- TODO: drop a menu-bar screenshot / GIF at docs/assets/demo.gif -->
<p align="center"><img src="docs/assets/demo.gif" alt="SoloDisplay in the menu bar" width="520"></p>

## Why

When a MacBook is connected to an external monitor with the lid open, macOS keeps
the built-in panel on, and there is no built-in way to disable it. The common
workaround is dimming to zero and turning on mirroring, which is not great.

SoloDisplay actually turns the internal panel off, and it treats getting your screen
back as the main thing to get right. The paid, closed-source
[BetterDisplay](https://github.com/waydabber/BetterDisplay) can do this among many
other features. SoloDisplay does just this one thing, for free and in the open.

## Install

```sh
brew install --cask fanckush/solodisplay/solodisplay
```

Builds are signed with a Developer ID and notarized by Apple, so Gatekeeper opens
them without warnings.

### Upgrading from Lidless

This app was called Lidless up to v0.1.0. The name collided with three unrelated
apps that all keep a Mac awake with the lid *closed*, which is close to the
opposite of what this does, so v0.2.0 renamed it.

`brew upgrade` moves you across on its own and removes the old app. If you
installed by hand, turn **Launch at Login** off in Lidless first, then quit it
and delete `Lidless.app`. That login item is registered against the old bundle
identifier, so SoloDisplay cannot remove it and macOS keeps launching the old
app at every login until you do.

Your recovery record and preferences move to
`~/Library/Application Support/SoloDisplay` the first time SoloDisplay starts,
so an internal display left off by Lidless is still restored.

## Usage

Launch SoloDisplay and look for the laptop icon in the menu bar. The menu adapts to
your setup:

- Manual mode: **Turn Internal Display Off** and **Turn Internal Display On**.
- Automatic mode: SoloDisplay turns the internal panel off on its own when a supported
  external display is present, and back on when it is not. **Keep Internal Display
  On** pauses that.
- If a requirement is missing, the menu names it (for example a closed lid, no
  native external display, or a Mac that is asleep) instead of acting.
- **Launch at Login** and **Export Diagnostics…** are in the menu too.

## How it works

SoloDisplay disables the internal screen through an undocumented display interface
that the public CoreGraphics API does not expose. The approach is the one used by
the open-source
[RonaldPark89/InternalDisplayOff](https://github.com/RonaldPark89/InternalDisplayOff).
BetterDisplay produces the same effect but is closed-source, so its method is not
public.

Because the technique is private and the failure mode is a black screen, the app
is built defensively. A normal launch starts two processes: a normally hidden
recovery supervisor, and the menu-bar controller it launches as its child over
private pipes. A durable ownership record is written before any display change
and cleared only after a verified restoration. If controller recovery is unresolved,
the supervisor takes over the menu-bar interface instead of remaining invisible.
The potentially blocking recovery call runs only in a bounded one-shot worker. See
[docs/architecture.md](docs/architecture.md) for the design and
[docs/status.md](docs/status.md) for what has been tested.

## Supported configurations

Turning the internal display off requires all of these, and the menu names
whichever one is missing:

- A positively identified internal panel, an open lid, an awake Mac, and the
  foreground login session.
- At least one external display classified as native from IOKit provenance.
  DisplayLink, wireless, virtual, and anything uncorrelated stay unavailable.
- A supported arrangement: unmirrored, or the internal panel following one present
  external mirror source. An internal panel acting as the mirror source is not
  supported.
- A recorded backend validation for this Mac and this macOS build. An OS update
  invalidates it until it is recorded again.

Verified on a Mac17,9 running macOS 26.6.2 (build 25G83) with one Dell U3223QE on
direct USB-C, in both mirrored and extended arrangements. Not verified: multiple
external displays, docks, DisplayLink, wireless and virtual displays, fast user
switching, logout, and other Macs or macOS builds. See
[docs/status.md](docs/status.md) for the scenario-by-scenario record.

Known limits: an unresponsive OS or display driver can still prevent physical
restoration, and simultaneous loss of the controller and supervisor can discard
live recovery authority. A stuck recovery call cannot consume the supervisor or
its recovery interface. Suppression is application scoped, so other processes
still report the panel as present.

## Build from source

Requires Xcode (Swift 6.3) and macOS 26+ on Apple Silicon. No external
dependencies.

```sh
swift build
swift test
swift run solodisplay-lab observe   # read-only; reports displays/session/lid state

open SoloDisplay.xcodeproj           # Scheme "SoloDisplay" then Run
```

Account-independent app tests (ad-hoc signed):

```sh
xcodebuild -project SoloDisplay.xcodeproj -scheme SoloDisplay -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:SoloDisplayTests
```

No display-changing experiment runs as part of `swift test`. The guided hardware
procedure ([docs/hardware-tests.md](docs/hardware-tests.md)) must be invoked
explicitly.

### Development checks

Enable the repository's Git hooks once per clone:

```sh
brew install swiftformat swiftlint
scripts/setup-hooks.sh
```

The pre-commit hook checks staged Swift files with SwiftFormat and SwiftLint. The
commit-message hook accepts `feat:`, `fix:`, `docs:`, `chore:`, and `perf:`
subjects, including optional scopes and `!`. The pre-push hook runs the Swift
package tests and unsigned app unit tests. Run the same checks manually with
`scripts/lint.sh` and `scripts/test.sh`.

## Design and docs

- [Architecture and product decisions](docs/architecture.md)
- [Assumption ledger](docs/assumptions.md)
- [Validation record](docs/validation.md)
- [Implementation and hardware checklist](docs/status.md)
- [Guided hardware procedure](docs/hardware-tests.md)

## Credits

- [RonaldPark89/InternalDisplayOff](https://github.com/RonaldPark89/InternalDisplayOff),
  reference for the disable technique.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay), prior art that
  proved the feature is possible.

## License

[GPL-3.0-or-later](LICENSE). SoloDisplay is free and open. If you distribute a
modified version, it has to stay free and open too.
