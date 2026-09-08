# Assumption ledger

Status distinguishes documented behavior, direct observations, and unresolved experiments. An API name alone does not validate its physical effect.

| ID | Assumption or dependency | Evidence and status | Failure response / required test |
| --- | --- | --- | --- |
| A01 | The controller runs in a foreground GUI session. | CoreGraphics and Security session APIs exist. The sandboxed observer returned unknown; GUI-capable execution returned foreground. | Unknown or background sessions cannot authorize disabling. Test lock and user switching separately. |
| A02 | A built-in laptop panel can be identified before changing it. | CoreGraphics built-in flag plus IOKit lid state observed on the local Mac. | No confirmed panel or no laptop lid capability means no disabling. Test no-panel and unavailable-query cases. |
| A03 | Native wired external displays can be distinguished from virtual displays. | Unresolved. CoreGraphics activity and naming alone are insufficient. | Production topology remains unclassified. Lab-only operator attestation does not satisfy production detection. |
| A04 | The private enable/disable ABI matches the reference implementation. | Explicit application-scope off/on succeeded on local macOS 26.6.2 and was visually confirmed by the user. | More configurations remain untested. Missing symbol leaves disabling unavailable. |
| A05 | Application-lifetime scope also restores this private change when the owner exits. | In the supervised normal-exit test, no active internal panel was observed during the three seconds after normal writer exit. The pre-armed supervisor explicitly restored it. | Do not rely on automatic exit rollback for this tested configuration. This bounded observation does not prove it would never restore later. Crash and forced-termination cases remain untested. |
| A06 | A live but frozen writer can be rescued. | The native supervisor verified a SIGSTOP-stopped writer, kept running for three seconds, then confirmed SIGKILL termination and restored the panel. Software observations passed; physical visibility for this run is unconfirmed. | This tests a stopped user-space process, not an uninterruptible kernel/driver call. The supervisor must establish termination and acquire the writer lock before takeover. |
| A07 | The owned panel remains addressable after suppression. | Same-process restoration and visually confirmed native cooperative handoff succeeded. Reverse UUID lookup failed while suppressed. A supervisor that witnessed the target before disabling later restored it after its writer exited, using the cached identity and fresh contradiction checks. | A live pre-armed witness is different from a journal loaded after a restart. Ordinary after-crash UUID checks remain unchanged. Do not carry raw IDs across boots. |
| A08 | A returned API call establishes the physical result. | Explicitly rejected. The core requires subsequent observation. | Simulate success without state change; visually confirm on hardware. |
| A09 | Every notification arrives once and in order. | Explicitly rejected. CoreGraphics callbacks can occur within configuration calls. | Enqueue observations, serialize effects, and test duplicates and late completions. |
| A10 | Before-sleep restoration can always finish. | Explicitly rejected. IOKit provides bounded acknowledgement and then proceeds with sleep. | Preserve unresolved ownership, acknowledge promptly, and reconcile after wake. |
| A11 | A restored panel must immediately be active. | False while the lid is closed, the display sleeps, or the GUI session is unavailable. | Defer visibility verification until awake and open; test ordinary closed-lid behavior. |
| A12 | An active external means the person can see an image. | Explicitly rejected. Software activity is not physical visibility. | Guided human observation. No physical-visibility guarantee in product claims. |
| A13 | A persisted display ID always denotes the same target. | Public documentation limits the useful lifetime. | Require matching boot/login identity and reject contradictory live identity. |
| A14 | Another display controller cannot change the same panel. | Explicitly rejected. | Unexpected restoration pauses automation instead of competing. Test with an independent configuration change. |
| A15 | Storage failures and process restarts are harmless. | Explicitly rejected. | Journal before mutation, refuse overwrite, retain ownership on error, replay unresolved work conservatively. |
| A16 | A newly released macOS version is compatible if a symbol exists. | Explicitly rejected. | Runtime prerequisite checks plus explicit tested-configuration reporting. No OS-version lockout was requested. |
| A17 | Users normally begin with an extended desktop. | Explicitly rejected by the user's existing setup: mirror the external and dim the internal to avoid losing the pointer. | Recognize mirroring as a first-class incoming state. Separately test off/on, exit rollback, and preservation of mirror source, resolution, and arrangement. No silent conversion. |
| A18 | Callback registration alone gives every process a current display view. | Rejected by the CLI handoff discrepancy. A native observer received independent off/on notifications, and native owner/child handoff produced matching observations. | Use a real app lifecycle and verify post-operation evidence. The earlier CLI result's exact cause remains unproven; event-loop and timing differences are hypotheses, not a universal OS contract. |

## Primary references

- [CoreGraphics configuration scope](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)
- [Display identifiers](https://developer.apple.com/documentation/coregraphics/cgdirectdisplayid)
- [Apple power-management definitions](https://github.com/apple/darwin-xnu/blob/main/iokit/IOKit/pwr_mgt/IOPM.h)
- [GUI sessions and user switching](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html)
- [Reference private-call implementation](https://github.com/RonaldPark89/InternalDisplayOff/blob/main/Sources/DisplayManager.swift)

The installed SDK headers also document CoreGraphics callback reentrancy, `IORegisterForSystemPower` acknowledgement, and early-wake restrictions. The implementation was written independently; the reference repository is used to investigate behavior.
