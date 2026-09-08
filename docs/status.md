# Implementation and validation status

Updated 2026-09-08. This is the current checklist; `validation.md` is the chronological evidence record. Historical statements in that record describe the state at the time of each experiment.

## Implemented

- Pure controller with explicit evidence, ownership, single-operation semantics, bounded retries, and replay tests.
- Read-only native menu-bar app with callbacks, lifecycle notifications, and periodic observations.
- Conservative platform normalization and shadow controller integration. No ordinary app display effects execute.
- Deterministic recovery lease and takeover models. Expired replies cannot revive protection; takeover requires confirmed writer death, a lock, and fresh authorization.
- Debug-only native experiments with a live pre-armed supervisor and durable journal. The bounded writer uses the lease model, and supervisor writes pass through the takeover ordering guard.

## Still required before normal display controls

- Production process transport and helper lifecycle, including authenticated renewal messages, startup reconciliation, and durable journal clearing.
- Production effect executor and ownership-aware observations while the internal panel is absent. Shadow normalization deliberately does not infer that absence means disabled.
- Native external transport classification. Raw active flags and user attestation in a lab are not an automatic runtime classifier.
- Validated sleep, wake, lid, and session policy. Shadow power evidence remains conservative; wake notifications do not establish a physically usable external display.
- A guarded manual menu control, followed later by automatic mode and optional launch at login.
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
| Sleep while internal is off, wake docked or undocked | **Not tested** |
| Mirrored baseline through off/on and recovery | **Not tested**; detection only |
| Multiple externals, dock changes, lid closure, user switching | **Not tested** |

The dedicated bounded external-loss harness passed its second physical run, recorded in `work/external-unplug-02.log`. The supervisor detected removal and revoked protection; the responsive writer restored without a supervisor enable request. Reconnection happened after writer exit and did not reapply suppression. This validates this bounded experiment, not a production automatic-mode lifecycle or other hardware topologies. The first run expired without removal and remains inconclusive.

Automated checks last passed: 50 package tests and 23 native app tests. Debug passed with the unplug harness; Release last passed before that harness was added. UI automation remains unvalidated because the earlier runner timed out enabling automation. Real panel visibility is separate from macOS reporting a display active; normal external-monitor wake latency is not itself a defect.
