# Implementation and validation status

Updated 2026-09-08. This is the current checklist; `validation.md` is the chronological evidence record. Historical statements in that record describe the state at the time of each experiment.

`PLAN.md` holds the remaining implementation and delivery plan. `original-plan.md` is the unchanged product plan it continues.

## Milestone tracking

Statuses are not interchangeable. **Implemented** means the code exists. **Automatically verified** means tests exercise it without a person present. **Hardware verified** means a guided physical test passed with user-confirmed visibility.

| Milestone | Status |
| --- | --- |
| A. Production recovery and persistence | Implemented and automatically verified, including real paired processes. Not hardware verified. |
| B. Live coordinator and platform evidence | Implemented and automatically verified. Observation and eligibility confirmed on this Mac's live mirrored setup. Not hardware verified for any display change. |
| C. Usable controls and diagnostics | Implemented and automatically verified. The pair runs with the real coordinator behind the menu. Not hardware verified: no production display change has been made. |
| D. Product-path validation and delivery | In progress. Mirrored manual off/on, relaunch reconciliation, and forced controller termination pass through the actual menu with user-confirmed visibility. Extended, unplug, sleep, lid, session, and automatic scenarios remain. |

## Implemented

- Pure controller with explicit evidence, ownership, single-operation semantics, bounded retries, and replay tests.
- Deterministic recovery lease and takeover models. Expired replies cannot revive protection; takeover requires confirmed writer death, a lock, and fresh authorization.
- Versioned production protection protocol. Bounded newline-framed messages carry session identity, sequence and challenge numbers, ownership identity, and outstanding-operation progress. Stale, duplicated, wrong-session, wrong-sender, unsupported-version, and malformed frames latch the peer's inbox closed rather than being skipped.
- Production process ownership. A normal launch becomes the supervising helper, which launches its controller child over inherited private pipes. Both are the same app executable with real AppKit event loops. Production entry points are separate from the Debug-only lab commands and are rejected in Release only for the lab ones.
- Production journal in the app's Application Support directory, created exclusively with 0600 permissions inside a 0700 directory, synchronized to disk before use, and carrying schema version, run and operation identity, boot and login identity, target, configuration scope, and the observed topology.
- Launch reconciliation. Unresolved ownership for this boot and login is restored under the takeover ordering before any controller runs. A prior boot or login is cleared only after an active built-in panel is observed. Corrupt, unsupported, contradicted, or unidentifiable records are retained with an explanation and inhibit disabling.
- Production coordinator around the pure reducer. Decisions happen one event at a time; every synchronous platform call runs on one serial lane, so a stalled display call cannot block the event loop and no callback ever configures a display. The executor repeats the full eligibility check immediately before writing, and a refusal before the call is distinguished from a call that failed.
- Native transport classification from IOKit provenance. A display counts as native only when it correlates to a display service hanging off the SoC display pipeline. Names, active flags, and operator attestation are not inputs.
- Mirror topology classification. An internal follower of one present external source is supported; an internal mirror source or an unresolvable set is not. An inactive follower is read as presence, never as suppression.
- Menu-bar controls driven by the coordinator: status with a specific reason for every refusal, manual and automatic selection, turn off and on, keep on and resume, retry recovery, launch at login, sanitized diagnostics export, and quit that requests restoration first. Automatic mode stays locked until a manual off and verified restoration has actually worked on this Mac.
- Bounded replay diagnostics fed by production events, capped at 10,000 events and 5 MB, exported with export-local pseudonyms and never uploaded. No raw lab log is offered as a user-facing export.
- A controller that loses its supervising helper finishes anything it owes and then exits, so an unsupervised process cannot hold the writer lock and block a fresh pair.
- Read-only native menu-bar app with callbacks, lifecycle notifications, and periodic observations, now hosted in the controller process.
- Conservative platform normalization and shadow controller integration. No ordinary app display effects execute.
- Debug-only native experiments with a live pre-armed supervisor and durable journal. The bounded writer uses the lease model, and supervisor writes pass through the takeover ordering guard.

## Still required before normal display controls

- A recorded backend validation. `backendValidated` is the last remaining gate on this Mac, and nothing writes that record yet, so the menu correctly reports that turning the display off is unavailable. Writing one requires a guided round trip, which is Milestone D work.
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
| Mirrored off/on through the product menu | Passed. Three full cycles plus a fourth off, user-confirmed each time. Journal written and cleared, mirror source and geometry preserved. |
| Relaunch with unresolved ownership, product path | Passed. The helper reconciled a leftover record, restored, verified through the mirror relationship, and cleared it before any controller ran. |
| Lid closure and opening, product path | Passed. Closing released the suppression without demanding a lit screen, opening restored eligibility and it disabled again. |
| Screen lock, display sleep, unlock, product path | Passed. No operation at all: none of these invalidates a prerequisite, so the suppression was simply held and the panel never flashed back on. |
| Frozen controller, product path | Passed. The helper's lease expired, it killed the stopped controller, confirmed termination, restored with user-confirmed visibility, and cleared the record. This is a stopped user-space process, not an uninterruptible driver call. |
| Sleep while suppressed, wake connected, product path | Passed. Impending sleep released the suppression and cleared the record; waking re-earned evidence and disabled again. No faults, no helper intervention. |
| Sleep while suppressed, disconnect before wake, product path | Passed. The internal panel was usable with the cable out, nothing was turned off without an external, and reconnecting disabled it again after a fresh stability window. |
| Automatic mode disabling on its own | Passed. Selecting Automatic turned the panel off within the stability window, user confirmed. |
| Unplug last external while suppressed, product path | Passed. Restoration was immediate and undebounced, user confirmed the panel came back. |
| Reconnect after that recovery, product path | Passed. A fresh stability window ran before it disabled again. |
| Keep Internal On, and its persistence | Passed. The panel came back and stayed on across unplug and replug, and the paused choice survived a full restart with no disable attempted. |
| Normal quit while suppressed, product path | Passed. Restored, cleared the record, released protection, and both processes exited. |
| Helper termination while suppressed, product path | Passed. The responsive controller restored with user-confirmed visibility, cleared its own record, and stopped. |
| Forced controller termination, product path | Passed. The helper detected contact loss, confirmed termination, took the writer lock, restored with user-confirmed visibility, cleared the record, and exited without starting another disabling controller. |
| Mirrored sleep, unplug, crash recovery, or internal-source topology | **Not tested** |
| Multiple externals, dock changes, lid closure, user switching | **Not tested** |
| Production helper/controller pair on real hardware | **Not tested.** The pair runs and recovers in automated tests that perform no display configuration. |
| Production eligibility on the live mirrored setup | Read-only pass. Transport native, topology supported, panel identified. No display was changed. |
| Helper loss with the production pair running | Observed on this Mac. The controller exited rather than lingering unsupervised, and a fresh pair started afterwards. Nothing was owned, so no display was changed. |

The dedicated bounded external-loss harness passed its second physical run, recorded in `work/external-unplug-02.log`. The supervisor detected removal and revoked protection; the responsive writer restored without a supervisor enable request. Reconnection happened after writer exit and did not reapply suppression. This validates this bounded experiment, not a production automatic-mode lifecycle or other hardware topologies. The first run expired without removal and remains inconclusive.

Automated checks last passed: 123 package tests and 48 native app tests. Debug and Release builds passed, and `swift-format` lint is clean. Release rejects lab commands, unpaired controller claims, and unknown arguments. UI automation remains unvalidated because the earlier runner timed out enabling automation. Real panel visibility is separate from macOS reporting a display active; normal external-monitor wake latency is not itself a defect.
