# Implementation and validation status

Updated 2026-09-08. This is the current checklist; `validation.md` is the chronological evidence record. Historical statements in that record describe the state at the time of each experiment.

`PLAN.md` holds the remaining implementation and delivery plan. `original-plan.md` is the unchanged product plan it continues.

## Milestone tracking

Statuses are not interchangeable. **Implemented** means the code exists. **Automatically verified** means tests exercise it without a person present. **Hardware verified** means a guided physical test passed with user-confirmed visibility.

| Milestone | Status |
| --- | --- |
| A. Production recovery and persistence | Implemented and automatically verified, including real paired processes. Not hardware verified. |
| B. Live coordinator and platform evidence | Not started. |
| C. Usable controls and diagnostics | Not started. |
| D. Product-path validation and delivery | Not started. Depends on B and C. |

## Implemented

- Pure controller with explicit evidence, ownership, single-operation semantics, bounded retries, and replay tests.
- Deterministic recovery lease and takeover models. Expired replies cannot revive protection; takeover requires confirmed writer death, a lock, and fresh authorization.
- Versioned production protection protocol. Bounded newline-framed messages carry session identity, sequence and challenge numbers, ownership identity, and outstanding-operation progress. Stale, duplicated, wrong-session, wrong-sender, unsupported-version, and malformed frames latch the peer's inbox closed rather than being skipped.
- Production process ownership. A normal launch becomes the supervising helper, which launches its controller child over inherited private pipes. Both are the same app executable with real AppKit event loops. Production entry points are separate from the Debug-only lab commands and are rejected in Release only for the lab ones.
- Production journal in the app's Application Support directory, created exclusively with 0600 permissions inside a 0700 directory, synchronized to disk before use, and carrying schema version, run and operation identity, boot and login identity, target, configuration scope, and the observed topology.
- Launch reconciliation. Unresolved ownership for this boot and login is restored under the takeover ordering before any controller runs. A prior boot or login is cleared only after an active built-in panel is observed. Corrupt, unsupported, contradicted, or unidentifiable records are retained with an explanation and inhibit disabling.
- Read-only native menu-bar app with callbacks, lifecycle notifications, and periodic observations, now hosted in the controller process.
- Conservative platform normalization and shadow controller integration. No ordinary app display effects execute.
- Debug-only native experiments with a live pre-armed supervisor and durable journal. The bounded writer uses the lease model, and supervisor writes pass through the takeover ordering guard.

## Still required before normal display controls

- Milestone B: the production coordinator around the pure reducer, with a serial execution lane for synchronous private calls, protection and persistence events, and structured platform evidence.
- Native external transport classification. Raw active flags and user attestation in a lab are not an automatic runtime classifier.
- Validated sleep, wake, lid, and session policy. Shadow power evidence remains conservative; wake notifications do not establish a physically usable external display.
- Milestone C: guarded manual controls, then automatic mode, optional launch at login, production diagnostics export, and quit with restoration requested.
- Milestone D: repeating the recovery matrix through the actual menu controls with user-confirmed visibility.
- Distribution signing, notarization, and Homebrew packaging.

## Hardware matrix

| Scenario | Current evidence |
| --- | --- |
| Explicit internal off/on | Passed, including user-confirmed visibility |
| Cooperative native child restoration | Passed, including user-confirmed visibility |
| Normal writer exit | No prompt automatic rollback observed; supervisor restored |
| SIGKILL writer | Supervisor restored; software evidence |
| SIGSTOP then SIGKILL writer | Supervisor restored; software evidence, not an uninterruptible OS call |
| Writer loses supervisor pipe | Writer restored without supervisor enable; software evidence |
| Supervisor pipe stays open but silent | Writer lease expired and restored without supervisor enable; software evidence |
| Supervisor process itself killed | Not tested; pipe loss is not an actual supervisor-death test |
| Sleep/wake with both displays enabled | Read-only observation baseline passed |
| Unplug/replug with both displays enabled | Read-only observation baseline passed |
| Unplug last external while internal is off | Passed on this direct USB-C setup; writer restored, user confirmed physical visibility |
| Reconnect after that recovery | Passed; user confirmed both screens, fresh inventory confirmed original arrangement |
| Sleep while internal is off, wake with USB-C connected | Passed on second monitor, battery power; user confirmed internal off before sleep and both on after wake |
| Sleep while internal is off, disconnect external before wake | Passed on second USB-C monitor, battery power, open lid; user confirmed internal usable with cable still out |
| Mirrored external-source/internal-follower off/on | Passed on second USB-C monitor; original observed mirror relationship and geometry restored, with user-confirmed physical off/on and mirrored image |
| Mirrored sleep, unplug, crash recovery, or internal-source topology | **Not tested** |
| Multiple externals, dock changes, lid closure, user switching | **Not tested** |
| Production helper/controller pair on real hardware | **Not tested.** The pair runs and recovers in automated tests that perform no display configuration. |

The dedicated bounded external-loss harness passed its second physical run, recorded in `work/external-unplug-02.log`. The supervisor detected removal and revoked protection; the responsive writer restored without a supervisor enable request. Reconnection happened after writer exit and did not reapply suppression. This validates this bounded experiment, not a production automatic-mode lifecycle or other hardware topologies. The first run expired without removal and remains inconclusive.

Automated checks last passed: 79 package tests and 36 native app tests. Debug and Release builds passed, and `swift-format` lint is clean. Release rejects lab commands, unpaired controller claims, and unknown arguments. UI automation remains unvalidated because the earlier runner timed out enabling automation. Real panel visibility is separate from macOS reporting a display active; normal external-monitor wake latency is not itself a defect.
