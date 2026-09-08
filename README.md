# Lidless

A small macOS utility for turning off a MacBook's internal display while a native wired external display is available.

## Current status

This repository contains the first engineering milestone, not a finished menu-bar app:

- A pure Swift controller with explicit uncertainty, operation ownership, and bounded recovery.
- Deterministic tests and generated event-sequence tests.
- Bounded, sanitized diagnostic traces that replay through the same controller.
- A read-only macOS observer.
- A native menu-bar diagnostic app, created from Xcode's macOS App template.
- Live, conservative observations feeding the controller in non-mutating shadow mode.
- Recovery lease and takeover state machines exercised by bounded native experiments.
- Explicit developer commands for guided display experiments and journal-based restoration.

Automatic display control is not connected to the private API. The backend remains unvalidated until guided hardware tests establish its behavior. The observer deliberately does not label an external display as native wired based only on CoreGraphics flags.

## Build and test

Requires Xcode with Swift 6.3 and macOS 26 or later. The initial validation target is Apple Silicon. The package was scaffolded with `swift package init` and uses no external package dependencies.

```sh
swift build
swift test
swift run lidless-lab observe
```

`observe` is read-only. It reports the private symbol, GUI session, lid state, and available display information. A sandboxed or non-GUI process may receive an empty display inventory. That is unavailable evidence, not proof that the machine has no displays.

The raw lab report includes local display and session identifiers for experiments. Do not confuse it with the sanitized trace export intended for sharing.

## Native app

Open `Lidless.xcodeproj`, select the `Lidless` scheme and My Mac, then Run. A laptop icon appears in the menu bar. Choose **Display Diagnostics…** to open its read-only window. Closing that window keeps the observer running; **Quit Lidless** stops it. No login item is installed.

A normal launch starts two processes. The launched process becomes the supervising recovery helper, which has no interface, and it launches the menu-bar controller as its child over inherited private pipes. A second launch is refused while a pair already owns the login session. Killing or quitting the controller ends the helper once nothing is left to recover. Pass `--lidless-unprotected` to run the interface alone, without a helper and with display control unavailable.

The Xcode project references the Swift package in this repository using a relative path. It does not depend on the original chat workspace. The existing signing team and bundle identifiers are retained from the user's template. The app identifier is `dev.lidless.Lidless`, with the template spelling corrected at the user's request.

## Supported configurations

Turning the internal display off requires all of these, and the menu names whichever one is missing:

- A positively identified internal panel, an open lid, an awake Mac, and the foreground login session.
- At least one external display classified as native from IOKit provenance. DisplayLink, wireless, virtual, and anything uncorrelated stay unavailable.
- A supported arrangement: unmirrored, or the internal panel following one present external mirror source. An internal panel acting as the mirror source is not supported.
- A recovery helper paired to the controller.
- A recorded backend validation for this Mac and this macOS build. An OS update invalidates it, and disabling becomes unavailable until it is recorded again.

Verified on a Mac17,9 running macOS 26.6.2 (build 25G83) with one Dell U3223QE on direct USB-C, in both mirrored and extended arrangements. Not verified: multiple external displays, docks, DisplayLink, wireless and virtual displays, fast user switching, logout, and other Macs or macOS builds. See `docs/status.md` for the scenario-by-scenario record.

Known limits. Simultaneous failure of both processes, and an unresponsive OS or display driver, are outside what the recovery design can cover. Suppression is application scoped, so other processes still report the panel as present. Signing, notarization, and Homebrew packaging are not set up.

The development app uses a normal AppKit lifecycle, CoreGraphics callbacks, workspace notifications, and periodic read-only observations. Its event history is bounded and stays in memory. Neither ordinary launch nor refresh changes display settings. The app does not yet execute the controller's effects. Debug builds also contain an explicitly invoked native hardware lab described in the guided procedure; it is unavailable in Release builds and has no normal menu entry.

The app targets macOS 26.0 and Swift 6. App Sandbox is disabled for the planned outside-App-Store display utility; Hardened Runtime remains enabled in the project. Xcode disables Hardened Runtime for the ad-hoc builds below, so they do not validate the final signed runtime. No new entitlements or developer-account operations are added. Release signing and notarization are not configured yet.

For an account-independent local build and app unit tests:

```sh
xcodebuild -project Lidless.xcodeproj -scheme Lidless -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  test -only-testing:LidlessTests
```

The UI smoke test is read-only but launches and interacts with the app. Run it separately when macOS permits Xcode UI automation. Package tests remain available through `swift test`.

## Replay without touching displays

```sh
mkdir -p work
swift run lidless-lab example-trace > work/example.json
swift run lidless-lab replay work/example.json
```

The example uses synthetic observations. Replaying it does not execute its requested effects.

## Hardware experiments

Read [the guided procedure](docs/hardware-tests.md) before using `probe` or `restore`. Neither runs automatically. No display-changing experiment is part of `swift test`.

The first experiment requires an open lid, a visible built-in panel, and a confirmed native wired external display in extended mode. A USB-C monitor can provide video and charge the Mac over the same cable.

## Design and next steps

- [Architecture and product decisions](docs/architecture.md)
- [Assumption ledger](docs/assumptions.md)
- [Validation record](docs/validation.md)
- [Current implementation and hardware checklist](docs/status.md)

Native cross-process restoration is demonstrated, and tested writer-exit scenarios required explicit recovery. Next gates are production helper and effect-executor integration, native transport classification, and hardware tests for unplugging and sleeping while suppressed. Mirrored off/on remains untested. Public signing, notarization, and Homebrew distribution are later work.

This project does not promise that an unresponsive operating system or driver can always restore a visible screen. It makes its own decisions testable and keeps unverified platform behavior explicit.
