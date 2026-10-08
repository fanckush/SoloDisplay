# HiDPI implementation research

Research date: 2026-10-08. Scope: implementation for SoloDisplay's Apple Silicon,
macOS 15+ target, with particular attention to 2560×1440 external monitors.
This began as a design proposal. Subsequent live trials verified two native HiDPI
modes on the user's Y27h-30 without an override or a virtual display. Temporary
mode and mirroring changes were restored. Production code was not changed.

**Recommendation**

Build public and private mode discovery and switching first. The live experiment
below demonstrates that the public catalog can hide useful, working native modes.
Only consider native display-model overrides when both paths are insufficient.
Keep virtual-display mirroring as a separate later feature. The first hardware
milestone, native 1920×1080 and 2048×1152 HiDPI at 165 Hz, passed OS readback.

BetterDisplay documents both native overrides and virtual screens. Its current
flexible-scaling documentation describes generating many discrete scaled resolutions,
not a continuously variable backing scale. Its public landing repository is not
the native implementation inspected for this research. The proposed override
encoding below comes from separate open-source prior art, not a claim to reproduce
BetterDisplay's internal implementation exactly.
[BetterDisplay flexible scaling](https://betterdisplay.pro/guide/technical-reference/flexible-scaling/),
[repository](https://github.com/waydabber/BetterDisplay).

**What the feature actually changes**

Keep logical desktop size, rendering dimensions, physical panel pixels, and cable
signal timing as separate properties. Assuming a 2560×1440 panel and native output:

| Logical desktop | Rendering dimensions | Output/panel | Interface size versus native 1× |
| --- | --- | --- | --- |
| 2560×1440 LoDPI | 2560×1440 | 2560×1440 | 100% |
| 2048×1152 HiDPI | 4096×2304 | 2560×1440 | 125% |
| 1920×1080 HiDPI | 3840×2160 | 2560×1440 | About 133% |
| 1280×720 HiDPI | 2560×1440 | 2560×1440 | 200% |
| 2560×1440 HiDPI, if available | 5120×2880 | 2560×1440 | 100%, supersampled |

macOS renders HiDPI at 2× in each axis and resizes the result where necessary.
Intermediate sizes can improve text at a comfortable interface size. Keeping the
native logical size instead produces supersampling: some prefer its smoother edges,
others find it softer. It cannot add physical panel detail. A 5K rendering surface
does not require a 5K signal over the cable. At equal logical size, a same-format
image buffer has four times the pixels; this does not imply four times total GPU
cost or application memory.
[BetterDisplay rendering explanation](https://betterdisplay.pro/guide/faq/scaling/macos-scaling-hidpi-lodpi/).

**1. Discover and select modes already exposed by macOS**

Use `CGDisplayCopyAllDisplayModes` with
`kCGDisplayShowDuplicateLowResolutionModes: true`. For every result record:

- `width`, `height`: logical points.
- `pixelWidth`, `pixelHeight`: rendering pixels, not a reliable physical-panel size.
- `refreshRate`, `ioFlags`, `ioDisplayModeID`, `isUsableForDesktopGUI()`.
- Display identity and the inventory generation in which the mode was found.

For ordinary modes, both pixel dimensions being twice their logical dimensions
identifies 2× HiDPI. Equal logical dimensions do not make two modes interchangeable:
preserve backing scale and refresh rate when grouping candidates. A refresh rate
of zero must not be interpreted as a measured zero-Hz output.

Illustrative enumeration, not production code:

```swift
let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] ?? []
let hiDPI = modes.filter {
  $0.width > 0 && $0.height > 0 &&
  $0.pixelWidth == 2 * $0.width && $0.pixelHeight == 2 * $0.height
}
```

Switch using `CGBeginDisplayConfiguration`,
`CGConfigureDisplayWithDisplayMode`, and `CGCompleteDisplayConfiguration`.
Cancel on a configure-stage error and inspect every return value. Then enumerate
again and compare the observed current mode with the request. API success alone
does not establish that the intended configuration persisted.

Use `.forSession` for a short-lived worker's initial trial. `.forAppOnly` is tied
to the worker's lifetime. Apple documents `.permanently` as updating the current
and persistent configuration, with some unsupported permanent configurations
lasting only for the session. Decide persistence separately from the initial trial;
do not persist an accidental arrangement with the laptop panel suppressed.

The declarations and scope semantics were checked in the installed Xcode SDK's
`CGDirectDisplay.h` and `CGDisplayConfiguration.h`.
[Apple mode enumeration API](https://developer.apple.com/documentation/coregraphics/cgdisplaycopyalldisplaymodes(_:_:)).

Public enumeration is the first path to test, not a promise to match every mode
shown by BetterDisplay. Hammerspoon demonstrates the private alternatives:
`CGSGetNumberOfDisplayModes`, `CGSGetDisplayModeDescriptionOfLength`,
`CGSGetCurrentDisplayMode`, and `CGSConfigureDisplayMode`. These enumerate/select
existing modes; they do not create arbitrary modes. Its private mode structure
contains undocumented padding, so any fallback needs runtime symbol detection,
ABI validation and isolation. Add it only if a hardware comparison establishes a
useful mode missing from the public catalog.
[Hammerspoon implementation](https://github.com/Hammerspoon/hammerspoon/blob/master/extensions/screen/libscreen.m).

**2. Add missing modes through a native model override**

The established override location is:

```text
/Library/Displays/Contents/Resources/Overrides/
  DisplayVendorID-<vendor in hex>/DisplayProductID-<product in hex>
```

The file is a plist containing integer `DisplayVendorID`, `DisplayProductID`, and
a `scale-resolutions` array of `Data`. This is a model override; it need not replace
the EDID or rewrite monitor firmware.

The `one-key-hidpi` source encodes doubled width and height as two big-endian
32-bit values and supplies variants with additional flag bytes. Its custom-size
path produces 12-byte and 16-byte entries. For logical 1920×1080 these decode to:

```text
00 00 0f 00  00 00 08 70  00 00 00 01
00 00 0f 00  00 00 08 70  00 00 00 01  00 20 00 00
```

I decoded these locally from the script's base64 construction. The dimensions
are 3840×2160. The flag semantics are undocumented; these are candidate encodings
to validate, not an Apple-supported schema. Generate bytes directly in Swift and
let `PropertyListSerialization` encode `Data`, avoiding string-spliced base64.
The script also writes `target-default-ppmm` and `DisplayResolutionEnabled`.
Establish whether either is needed on supported macOS versions before adopting
those broader changes.
[one-key-hidpi source](https://github.com/xzhih/one-key-hidpi/blob/master/hidpi.sh).

Installing the file needs administrator authorization. Current BetterDisplay
documentation distinguishes installation from activation and states that model
edits affect matching vendor/product identities, including other connected units.
Some external Apple Silicon displays support activation without reboot; built-in
displays still require reboot. The exact live activation mechanism is not established
by this research. Use reboot as the first implementation's activation contract.
[Model configuration](https://betterdisplay.pro/guide/interface-reference/settings/displays/display/system-configuration/),
[activation](https://betterdisplay.pro/guide/interface-reference/settings/#activation-after-applying).

Proposed installer requirements:

- A narrowly scoped privileged helper with authenticated IPC and fixed destinations;
  evaluate `SMAppService` for the macOS 15+ baseline. The existing display worker is
  not an administrator helper. Ordinary mode switching stays in the user's session.
- Read and preserve an existing override, including unrelated properties and modes.
  Track the exact original file, installed content hash, and owned additions.
- Atomic installation, explicit ownership/permissions, symlink/path checks, and
  conflict detection if another tool edits the same model file.
- Restore only owned changes. Never remove a whole vendor directory to disable a
  single monitor's configuration. Two identical monitors share this installation;
  runtime mode preferences can still be per physical display.
- Treat installed, activated, enumerated, usable, selected, and verified as distinct
  states. A valid plist or listed mode does not prove successful operation.

These are SoloDisplay design recommendations. DPIManager provides another Swift
reference for the path and plist fields, but its writer/removal logic should not be
copied wholesale: it overwrites the file and removes the vendor directory on disable.
[DPIManager source](https://github.com/HasBrain/MacOS-DPIManager/blob/main/DPIManager/DisplayManager.swift).

**3. Virtual-display fallback**

An alternative uses private Objective-C classes `CGVirtualDisplayDescriptor`,
`CGVirtualDisplayMode`, `CGVirtualDisplaySettings`, and `CGVirtualDisplay`.
Create a sufficiently large virtual mode, enable `settings.hiDPI`, retain the
virtual display object, then make the physical display follow the virtual source
using `CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)`.
Check the resulting mirror direction and mode after configuration.

An open-source example supplies doubled mode dimensions and retains the virtual
object for its lifetime. This requires a long-lived host, unlike SoloDisplay's
one-shot mutation workers. Teardown, reconnection, main-display selection, and
restoring the previous physical arrangement become additional responsibilities.
[hidpi-mirror implementation](https://github.com/pasky/hidpi-mirror/blob/main/hidpi-mirror.m).

This can help when the native pipeline cannot expose a requested size, including
some driver-managed displays. It has different performance and lifecycle behavior.
Rendering limits depend on hardware, port, arrangement, and OS; do not promote
old M1/M2 6K/8K limits into universal constants for all Apple Silicon.
[BetterDisplay resolution limits](https://betterdisplay.pro/guide/faq/scaling/hidpi-resolution-limits/).

**Integration with this repository**

The following conclusions come from local code inspection:

- `DisplayObserver.swift` records whether a mode exists but not a full mode catalog
  or both logical and rendering dimensions. Add a dedicated mode catalog adapter.
- `DisplayTransport.swift` already correlates native outputs with IOKit and carries
  vendor/model/serial evidence. Reuse that work for targeting; do not derive native
  dimensions from the currently selected scaled mode.
- `SoloDisplay/DisplayWorker.swift` and `PrivateDisplayAPI.swift` establish isolated
  mutations, fresh identity checks, and session-scoped transactions. Extend the
  pattern for mode changes, resolving a requested mode from a fresh catalog inside
  the worker. Persist semantic preferences, not a mode ID as a durable identity.
- `ControllerObservation.nativeExternal` requires native externals and rejects
  non-native ones. Its topology checks reject several virtual-source mirror
  arrangements. Virtual mirroring therefore needs an explicit redesign of visibility
  and recovery evidence; simply creating a dummy would conflict with current policy.
- Coordinate mode changes with the existing production coordinator and input
  detection so display mutations cannot race. For initial trials, restore and
  observe the built-in panel first, hold suppression, switch and verify, then allow
  normal External Only reconciliation after settling.
- The guardian currently restores the laptop panel; it does not restore a previous
  external mode or undo a persistent override. Mode trial rollback needs its own
  recovery responsibility. An observed active mode also cannot prove that a person
  sees a usable image, so the trial needs a confirmation/rollback signal even if
  the final UX is deferred.

Suggested new responsibilities: `DisplayModeCatalog`, `DisplayModeRequest`,
`DisplayModeWorker`, `HiDPIOverridePlan`, and a narrowly scoped installer service.
Keep override installation separate from mode selection and from suppression intent.

**Implementation sequence and evidence required**

1. Add a read-only lab command to export the current mode and full public catalog,
   including backing pixels, rate and usability. Compare a clean configuration
   against the same hardware after a known working override. Existing BetterDisplay
   overrides must be accounted for so they do not masquerade as native OS support.
2. Add session-scoped mode trials with identity validation, readback and rollback.
   First demonstrate switching between existing LoDPI and HiDPI variants.
3. Generate a small override containing 1920×1080 and 2048×1152 candidates for a
   1440p panel. Validate serialization and install/restore behavior before activation.
4. Validate after reboot. Record actual availability and output timing. Test exact
   native-sized HiDPI separately; do not guarantee that 2560×1440 HiDPI is accepted
   just because an intermediate mode works. Test near-native alternatives if needed.
5. Integrate mode preference restoration after reconnect only once settling and
   user/manual changes can be distinguished. Avoid a callback-induced switch loop
   or repeatedly overriding a change made in System Settings.
6. Consider finer resolution steps, live activation and virtual mirroring only
   after the native path is established.

Hardware coverage should include supported macOS versions, representative Apple
Silicon generations, HDMI versus DisplayPort/USB-C, docks/KVMs, duplicate monitor
models, rotation, high refresh rate, HDR/VRR where applicable, sleep/wake, unplugging
during a trial, worker/app failure, and interaction with External Only and input
detection. Verify native cable timing with monitor information or an independent
output-timing query; `pixelWidth` alone is not that measurement.

Unit tests should cover mode matching, stale display IDs, aspect-ratio/range checks,
byte encoding and plist round-trips, override merge/restore conflicts, and reducer
sequences for trial interruption and rollback. Actual mode availability, text
quality, refresh/HDR behavior, and activation require hardware evidence.

The research does not establish the minimal override keys on every supported OS,
BetterDisplay's exact private activation mechanism, or exact-native HiDPI availability.
The subsequent experiment below establishes this monitor's ability to accept two
intermediate native HiDPI modes, without installing an override.

**Read-only hardware baseline, 2026-10-08**

A temporary Swift probe enumerated the live display session using the public APIs
above. It made no configuration calls. The sandbox initially returned an empty
display list; the same probe outside the sandbox successfully read the GUI session.

- Host reports macOS 27.0.1, build 26A434.
- One online display: Y27h-30, active and unmirrored.
- Current mode: logical 2560×1440, rendering 2560×1440, 165 Hz, LoDPI.
- Default catalog: 115 entries. Expanded catalog: 210 entries.
- Largest exposed HiDPI logical width: 1280, with 1280×720 rendering at 2560×1440.
  This size is marked desktop-usable at 60, 100, 120, 144 and 165 Hz.
- Logical 1920×1080 and 2048×1152 are present, but only as LoDPI variants.
  No HiDPI entry wider than 1280 exists in the expanded public catalog, including
  entries not marked desktop-usable.
- The standard `/Library/Displays/Contents/Resources/Overrides` directory is absent.
  This rules out a currently installed override there, not every possible prior
  third-party or cached configuration.

This baseline establishes that public mode selection alone cannot provide the
desired intermediate HiDPI sizes in the observed connection. It does not test
private enumeration, installation/activation of an override, or actual mode
switching. The user confirms direct USB-C to the monitor with power delivery,
and reports no known BetterDisplay use on this Mac.

**Native switching experiment, 2026-10-08: both modes passed**

The private catalog exposed 270 modes, including 1920×1080 and 2048×1152 at 2×
and 165 Hz, even when the initial public expanded catalog exposed only 210 modes.
This changed the next step: no override was generated or installed.

SoloDisplay was temporarily stopped to restore the laptop panel. The recovered
arrangement had the laptop following the external display. The user correctly
pointed out that mirroring could confound the result. The trial therefore explicitly
separated the laptop into an independent display, in the same app-scoped transaction
that selected the external mode with `CGSConfigureDisplayMode`.

| Physical display | Requested desktop | Independently observed rendering | Observed rate | Mirroring |
| --- | --- | --- | --- | --- |
| Y27h-30 | 1920×1080 | 3840×2160 | 165 Hz | Off |
| Y27h-30 | 2048×1152 | 4096×2304 | 165 Hz | Off |

Both `CGCompleteDisplayConfiguration` calls returned success. A separate probe
process confirmed the modes through `CGDisplayCopyDisplayMode` while each trial
was active. Exactly two online physical displays were present: the Y27h-30 and the
built-in Retina panel, which independently ran at logical 1512×982, rendering
3024×1964, 120 Hz. Both had null mirror sources. The trial also required that the
external display was not in a mirror set before declaring success.

Each mode was held for 20 seconds, then explicitly restored to 2560×1440 LoDPI at
165 Hz. Changes used `kCGConfigureForAppOnly`, with an external 40-second process
watchdog. Process exit reverted the temporary topology. No virtual-display API,
system override, administrator installation, activation or reboot was needed.

The original C prototype and Swift probe have since been replaced by
`solodisplay-lab modes` (read-only report) and `solodisplay-lab modes try`
(plain, then 2x, then restore, app-only). Compact observations from these runs
are recorded in `experiments/hidpi-native-results.json`.

Correction to the initial inference: absence from the public catalog does not
prove that an override is necessary. These modes were selectable through the
private API and subsequently visible as the current mode through the public API.
The public expanded catalog during either independent-desktop trial contained
211 entries, including the selected mode, rather than exposing all private modes.

The 1920×1080 trial was repeated for 60 seconds with an 85-second process watchdog.
The user confirmed that the external monitor displayed correctly with larger,
clear text. A separate probe again confirmed unmirrored 1920×1080 logical,
3840×2160 rendering at 165 Hz during that longer trial.

This proves native mode acceptance, 2× rendering, and a user-confirmed usable image
on this particular Mac, OS, monitor and connection. It does not yet prove persistence
across sleep/reconnect, other macOS versions, HDR/VRR behavior or physical cable timing.

Final cleanup was verified: SoloDisplay and its guardian were running again, only
the external display was online, and its mode was back to logical/rendering
2560×1440 at 165 Hz. The standard override directory remained absent.

**Sharp Text findings, 2026-10-08**

Measured on the same Y27h-30 over USB-C at 165 Hz, macOS 27.0.1.

- Switching 1920×1080 from 1× to 2× is seamless: no blackout, and macOS reports
  only a set-mode event, with no desktop shape change. The logical desktop is
  unchanged, so no window moves.
- The cable stays at native timing throughout. With 2048×1152 at 2× active, the
  framebuffer reports `DPTimingModeId` 89, which is 2560×1440 at 165 Hz. The monitor
  offers no 2048×1152 or 1920×1080-scaled signal of its own; every scaled mode is
  scaled inside the Mac.
- Switching 2048×1152 between 1× and 2× does blank the monitor briefly, in both
  directions. The cause is not established: the cable timing is the same, and the
  4096-pixel-wide source is well under the pipe's reported 6720-pixel limit.
- A hidden 2× mode can be recognised from the current mode alone. The 2× modes
  System Settings never lists carry IOKit's `kDisplayModeValidForMirroringFlag`
  (`0x200000`) and no native flag, for example 1920×1080 at 2× with `0x200003`. The
  2× mode macOS does list, 1280×720, carries the native flag instead (`0x2000003`).
  Sharp Text relies on this to undo its own switches without recording them.
- Once a hidden mode is active, the public catalog lists it (211 entries instead of
  210), but only that one. Listing alone therefore cannot tell hidden from offered
  modes; the flags can.
- The two variants macOS lists for each size and rate (for example #103 and #104)
  are identical in the private record apart from the mode number.
