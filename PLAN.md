# SoloDisplay: remaining implementation and delivery plan

## 1. Objective and source of truth

Deliver a usable local menu-bar app using the existing controller and demonstrated recovery behavior. Preserve the original product decisions: manual default, opt-in automatic mode, persistent Keep Internal On, login off by default, no normal-use countdowns, and no changes to brightness or external-display configuration.

**Mirroring preservation is required for the first usable local build.** A successful mirrored round trip is evidence for that topology, not authorization to skip its remaining recovery tests.

At implementation start:

- Preserve the supplied original plan unchanged as `docs/original-plan.md`.
- Save this remaining-work plan as the repository’s `PLAN.md`.
- Reconcile `docs/status.md` with the actual code, test counts, and hardware evidence. Keep the chronological experiment records intact.
- Track each milestone as implemented, automatically verified, hardware verified, or blocked. These statuses are not interchangeable.

Continue through normal implementation decisions without repeated approval stops. Request user involvement for physical tests, missing equipment, or a material change to this plan. Record any deviation and its evidence.

## 2. Milestone A: production recovery and persistence

### Process ownership

Use two long-running native processes:

- **Controller:** owns the menu UI, reducer, observation coordinator, and normal enable/disable operations.
- **Recovery helper:** observes independently, supervises its actual controller child, and can only restore an owned internal panel.

Normal launch briefly bootstraps the helper; the helper launches the controller. Both use the existing app executable with separate internal entry points and real AppKit event loops. No daemon, root privileges, Homebrew service, or persistent background installation.

Production entry points must be separate from the Debug-only lab commands. Inherited private pipes establish the process pairing; filenames, saved PIDs, or command-line assertions alone cannot authorize recovery.

### Protection protocol

Replace the bounded lab signals with a versioned, bounded protocol carrying session identity, sequence/challenge numbers, ownership identity, and outstanding-operation progress.

- Establish exclusive writer ownership, durable journaling, a fresh helper witness, and an acknowledged protection lease before disabling.
- Exchange progress every second. Five seconds without valid progress revokes protection.
- Operation deadlines remain independent of heartbeats. A responsive communication loop must not conceal a stalled display call.
- Reject stale, duplicated, wrong-session, expired, and malformed messages.
- Lost helper contact makes a responsive controller restore and pause.
- Helper takeover requires confirmed termination of its actual controller child, followed by writer-lock acquisition and fresh recovery checks.
- After takeover, do not automatically launch another disabling controller. Retain a recovery/fault state until explicit restart or retry.
- Both-process failure, missed platform evidence, and an unresponsive OS remain explicit limits.

### Durable state

Introduce a production journal separate from retained lab journals. Store it in the app’s user Application Support directory with restrictive permissions.

Include schema version, operation/session identity, boot/login identity, target evidence, configuration scope, and the observed topology needed for verification. Serialize journal preparation and clearing; acknowledge persistence failures to the controller.

On launch:

- Reconcile unresolved ownership before allowing any new disable.
- Never use a persisted numeric ID alone as recovery authority.
- Retain ambiguous, corrupt, or unsupported records and inhibit disabling with an actionable explanation.
- Clear ownership only after verified recovery and successful journal clearing.
- Treat preferences separately from hardware truth. Never persist “screen is off” as fact.

Use the demonstrated application-scoped disable path and explicit restoration. Do not depend on automatic exit rollback. Keep helper restoration restricted to the recorded panel.

**Acceptance:** real-process automated tests demonstrate pairing, lease expiry, controller/helper loss, stalled-operation detection, takeover ordering, and journal failure handling without concurrent writers. Normal app launches still cannot disable until later gates pass.

## 3. Milestone B: live coordinator and platform evidence

Implement a serialized production coordinator around the existing pure reducer. Inject observation, clock, display writer, protection, persistence, and diagnostic interfaces.

Keep synchronous private API calls off the main event loop on one serial execution lane. Queue callbacks and lifecycle events; never configure displays inside callbacks. A timeout is not cancellation, and late operation results remain relevant.

### Required interface changes

- Explicit protection readiness/loss events and operation-bound preparation acknowledgements.
- Structured platform evidence for topology, transport eligibility, owned-panel state, and lifecycle uncertainty.
- Persistence completion/failure events, including journal clearing.
- Read-only presentation state for availability, pending recovery, and faults.
- Versioned process messages and production journal records.

Keep the reducer free of platform calls and asynchronous work. Extend existing replay and invariant tests alongside these interfaces.

### Observation and eligibility

Implement native transport classification using runtime platform evidence, with fixtures from the tested hardware. Do not classify from monitor names, active flags, or lab attestation alone. Unclassified, virtual, wireless, and DisplayLink configurations remain unavailable.

Preserve the original evidence policy:

- Two consistent samples at least 500 ms apart.
- Two seconds of relevant stability before disabling.
- A final eligibility and protection check immediately before a write.
- Refresh at least every two seconds while suppressed.
- Evidence older than five seconds cannot authorize continued suppression.

Recognize a missing panel as SoloDisplay-owned suppression only when live ownership and the validated operation context establish that interpretation. An inactive mirrored follower is neither proof of suppression nor failed restoration.

For mirroring, capture and verify source relationships and observable display configuration. Never silently switch to extended mode or repair a mismatch by rewriting external settings. Unsupported mirror arrangements remain unavailable.

### Power and sessions

Replace the lab’s wake-only handling with the original lifecycle design:

- On impending sleep, invalidate disabling permission and attempt to release suppression.
- Bound power-transition acknowledgement to one second; never hold sleep indefinitely waiting for a display call.
- Preserve unresolved ownership across sleep and reconcile after wake.
- Do not demand visible restoration while asleep, closed-lid, or outside the eligible GUI session.
- A wake notification alone cannot establish a usable external display.
- Manual intent clears on interruption. Automatic mode resumes only after fresh eligible evidence, unless paused or faulted.
- Recovery does not wait for an external monitor to reappear.
- Add an independent power/session reconciliation path so missing a workspace notification cannot leave the coordinator relying indefinitely on stale lifecycle state.

**Acceptance:** adversarial tests cover reordered notifications, missing events, lease loss, stale completions, conflicting changes, clock advancement, and storage errors. Recovery converges when the modeled platform becomes observable and accepts restoration.

## 4. Milestone C: usable controls and diagnostics

Connect the production coordinator to the existing menu shell.

Implement:

- Status and specific reasons disabling is unavailable.
- Manual/Automatic selection.
- Turn Internal Off/On.
- Keep Internal On/Resume.
- Retry Recovery.
- Optional Launch at Login, default off.
- Export Diagnostics.
- Quit with restoration requested before exit.

Enable manual controls first for validation, then automatic mode after manual-path acceptance. The completed local milestone includes both modes.

Persist automatic pause across restart. On an unverified recovery, show that state and preserve the journal rather than reporting success. Quit must not start a competing writer or silently discard unresolved ownership; the helper retains recovery responsibility if the controller exits unexpectedly.

Connect production events to the existing bounded replay diagnostics: at most 10,000 events and 5 MB, sanitized export-local identifiers, and no uploads. Normal operation must not use raw lab logs as user-facing exports.

**Acceptance:** UI-model and integration tests exercise the real coordinator, including unavailable configurations, pending actions, faults, persistent pause, restart, and quit. No production menu action calls a lab command.

## 5. Milestone D: validate the product path and deliver

Repeat the relevant tests through the actual menu controls. Earlier harness passes remain supporting evidence, not substitutes.

Required hardware acceptance:

- Extended and mirrored off/on, with arrangement preserved.
- Last-external unplug and reconnect.
- Sleep while suppressed, waking connected and disconnected.
- Mirrored unplug and sleep/wake recovery.
- Normal quit, forced controller termination, frozen controller, and actual helper termination.
- Relaunch with unresolved ownership.
- Lid closure/opening, screen sleep, lock/unlock, and session transitions.
- Automatic resume after fresh evidence and persistent Keep Internal On behavior.

Use available equipment for multiple-monitor and dock tests. Missing equipment stays explicitly untested, and unsupported configurations remain gated. Do not claim universal recovery from finite tests.

Verify Debug and Release builds, the package suite, native tests, and available UI automation. Confirm Release rejects lab commands and production child processes run correctly from the built app.

Deliver the local app, build/run instructions, supported-configuration report, and remaining limitations. Public signing, notarization, Homebrew packaging, and an updater remain a separate follow-up.

**Completion criterion:** the supported manual and automatic workflows work through the app, required recovery scenarios pass with human visibility confirmation, and no unresolved blackout remains in those tests. If a required safety or mirroring gate fails, keep the affected control unavailable and document the blocker rather than silently weakening the requirement.
