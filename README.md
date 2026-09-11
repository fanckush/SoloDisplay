<h1 align="center">SoloDisplay</h1>

<p align="center">
  <em>Turn your MacBook's built-in display fully <strong>off</strong> without closing the lid.</em>
</p>

<p align="center">
  <a href="https://github.com/fanckush/SoloDisplay/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/fanckush/SoloDisplay/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/fanckush/SoloDisplay"><img alt="Test coverage" src="https://codecov.io/gh/fanckush/SoloDisplay/branch/main/graph/badge.svg"></a>
  <a href="https://github.com/fanckush/SoloDisplay/releases"><img alt="Release" src="https://img.shields.io/github/v/release/fanckush/SoloDisplay?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="License: GPL-3.0" src="https://img.shields.io/badge/License-GPLv3-blue.svg"></a>
  <img alt="Platform" src="https://img.shields.io/badge/macOS-Apple%20Silicon-black?logo=apple">
</p>

<p align="center">
  <img src="docs/assets/app-screenshot.webp" alt="The SoloDisplay menu bar panel, with All Monitors and External Only" width="420">
</p>

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

## Usage

There are two choices:

- **All Monitors** keeps your laptop screen on.
- **External Only** turns it off whenever a monitor is connected, and back on when
  you unplug.

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

### Development checks

Enable the repository's Git hooks once per clone:

```sh
brew install swiftformat swiftlint
scripts/setup-hooks.sh
```

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
