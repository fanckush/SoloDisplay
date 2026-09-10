# SoloDisplay: a small display controller built around explicit uncertainty

## 1. Product and boundaries

Build a native Swift menu-bar app that disables a MacBook’s internal panel while eligible external displays are available.

Agreed behavior:

- **Manual mode:** explicitly turn the internal panel off. Sleep, lid closure, loss of eligible displays, or recovery clears that request.
- **Automatic mode:** disable after confirming suitable conditions; restore when those conditions no longer hold.
- **Keep Internal On:** pauses automatic mode until explicitly resumed, including across restarts.
- Conservative restoration may briefly illuminate the panel or move windows.
- No confirmation countdowns during normal operation.
- Native wired displays only, including multiple monitors and native-output docks. Mirroring, DisplayLink, wireless, and virtual-display configurations initially make disabling unavailable.
- Runtime capability checks determine availability. No macOS-version allowlist.
- Machines without a positively identified laptop panel remain untouched.
- Preserve normal macOS sleep and closed-lid behavior.

Defaults: manual mode, launch at login off, working name **SoloDisplay**. Initially target Apple Silicon and macOS 26 or later; newer releases may operate through capability checks but are not described as tested without evidence.

First delivery is a local build with guided hardware validation. Public signing, notarization, Homebrew packaging, and an updater follow separately.

## 2. Establish the platform contract before building automatic control

Implement a developer harness with read-only observation as its default. Separate commands exercise display changes during guided tests.

Maintain an **assumption ledger** recording each dependency, its evidence, how failure is detected, the response to failure, and its regression tests.

Resolve these questions experimentally:

- Can the internal panel be identified before disabling and addressed afterward?
- Which observations distinguish native external displays, disabled panels, sleeping displays, and missing information?
- Does `CGCompleteDisplayConfiguration(..., .forAppOnly)` undo the private disabling operation after normal exit, a crash, and forced termination? Apple documents application-lifetime rollback, but its behavior with this private operation is unverified. [Apple documentation](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)
- What happens when an API call stalls or the entire controller process stops responding?
- How do lid closure, sleep, wake, screen sleep, and session changes affect recovery?
- Does a successful enable request produce a verifiable restored panel when the lid is open and the system is awake?

Use `SLSConfigureDisplayEnabled`, falling back to `CGSConfigureDisplayEnabled`, behind one adapter. Never infer compatibility merely from finding the symbol.

**Backend selection is evidence-driven:**

1. Prefer application-lifetime configuration if disabling, explicit restoration, and exit rollback pass.
2. Add the recovery helper described below if crashes or hangs remain unrecovered.
3. Allow session-lifetime configuration only if application-lifetime configuration fails and the helper’s restoration path passes the same tests.
4. If neither configuration has a demonstrated recovery path, deliver the observer, simulator, and findings; keep product disabling unavailable. Do not substitute dimming or accumulate speculative recovery calls.

These are implementation gates, not permission to treat untested behavior as working.

## 3. Controller architecture and recovery

Use a Swift package for the platform-independent core, with a native AppKit application and a narrow macOS integration layer. Avoid third-party runtime dependencies initially.

The core exposes one synchronous transition function:

```swift
reduce(state: ControllerState, event: Event)
    -> Transition // next state plus requested effects
```

Its inputs explicitly separate:

- **Intent:** selected mode, automatic pause, temporary manual request.
- **Evidence:** display topology, panel identity, lid/power/session state, observation time and revision.
- **Operation:** target, identifier, originating revision, deadline, and outcome.
- **Ownership:** whether SoloDisplay may have disabled this particular panel.
- **Recovery:** unresolved restoration or a latched fault.

Evidence supports known, unknown, and conflicting values. Missing properties and failed queries never silently become “false.” Keep these dimensions separate to avoid creating a state for every hardware combination.

A serialized coordinator feeds the reducer events and executes effects through injected interfaces for observation, display operations, time, persistence, and diagnostics. The reducer contains no asynchronous work, timers, platform calls, or global state.

**Decision rules**

- Disabling requires explicit intent, a confirmed internal target, an open lid, an eligible foreground session, and fresh evidence of an active native external.
- Require two consistent observations at least 500 ms apart and two seconds without a relevant topology change before disabling; perform a final check immediately before issuing it.
- Monitor relevant events and refresh every two seconds while the panel is suppressed. Evidence older than five seconds cannot authorize continued suppression.
- Restore owned suppression promptly when its prerequisites fail. Do not impose the disabling delay on restoration.
- Only one display operation may be outstanding. Callbacks enqueue events; they never change displays directly.
- Cancel obsolete scheduled decisions. A stale operation completion still represents a possible physical change and must trigger reconciliation.
- Account for expected notifications and the panel’s disappearance during SoloDisplay’s own operation; do not mistake these for an unrelated failure and create a toggle loop.
- Verify outcomes separately from API return codes. Restoration may remain pending during sleep or lid closure without demanding a lit screen.
- Suspend automatic disabling after an operation fault. Require an explicit Retry/Resume action; ordinary wake recovery can resume automatic mode after fresh observation.
- If another controller changes the panel against SoloDisplay’s intent, release ownership and pause rather than repeatedly overriding it.

Use three seconds as the initial operation-verification deadline. Retry completed, failed restoration calls at most three times, with 500 ms then two-second delays. Never retry concurrently with an unresolved call. These are testable controller deadlines, not promises about OS response time.

**Ownership and persistence**

Persist preferences and a small recovery journal before issuing a disabling request. The journal includes operation identity and boot/session-scoped target evidence. If journaling fails, do not disable.

Do not persist “internal is off” as hardware truth. Do not reuse an old numeric display ID across boots or reset the entire display configuration. On relaunch, reconcile unresolved ownership before considering any new disable request.

**Conditional recovery helper**

If required by the failure tests, bundle a second user-session process:

- Arm it and receive acknowledgement before disabling.
- Exchange progress messages every second, including outstanding-operation deadlines; five seconds without progress triggers recovery.
- On controller failure, stop the paired writer and establish that it has exited before verifying rollback or restoring the journaled panel.
- The helper can restore only that recorded panel; it cannot disable displays.
- Loss of helper contact causes a responsive controller to restore and suspend disabling.
- Sleep/wake invalidates outstanding permissions and requires fresh observation; delayed messages cannot renew old permission.
- Exercise helper failure as well as controller failure. Simultaneous process failure and an unresponsive OS remain explicit limits.

## 4. Integration, interface, and diagnostics

Use CoreGraphics for display observations and transactions, IOKit for lid and power events, and session notifications for console ownership. Treat `NSScreen` as presentation information rather than the sole source of display truth.

Keep sleep acknowledgement bounded: attempt to release suppression before sleep, acknowledge the power transition without an indefinite wait, and reconcile again after wake. Lid closure transfers control back to macOS.

Keep UI limited to:

- Current status and a concise explanation when disabling is unavailable.
- Manual/Automatic selection.
- Turn Internal Off/On in manual mode.
- Keep Internal On/Resume in automatic mode.
- Launch at Login.
- Retry Recovery when applicable.
- Export Diagnostics.
- Quit, which requests restoration before exit.

Do not report successful restoration when it remains unverified. Surface the recovery state, preserving the journal for a subsequent attempt.

Diagnostics use macOS logging plus a bounded local event history: maximum 10,000 events and 5 MB. Exports include normalized evidence, intentions, effects, results, timing, and software versions. Remove usernames, paths, serial numbers, and raw device identifiers; preserve relationships using export-local pseudonyms.

No automatic uploads. Diagnostic traces must replay through the same reducer using a virtual clock.

## 5. Verification and delivery gates

**Core verification**

Use deterministic tests plus seeded generation of event sequences. Check after every transition that:

- Every disable effect has current authorization and target evidence.
- At most one operation is outstanding.
- Unknown evidence cannot authorize disabling.
- Ownership survives ambiguous outcomes.
- Stale decisions cannot execute, and stale completions cannot hide side effects.
- Faults prevent new disabling.
- Manual interruption and persistent automatic pause follow the agreed semantics.
- Recovery converges when the simulated environment eventually becomes stable and accepts restoration.

Include missing, duplicated, reordered, and delayed events; identity changes; storage errors; API success without the expected result; reentrant callbacks; clock advancement; and competing changes.

**Guided hardware validation**

Record the actual Mac, macOS build, monitor, cable, and dock used. Test:

- Direct connection, docking, rapid reconnects, and removal of one versus the last external.
- Sleep docked/wake undocked and the reverse.
- Lid-close/unplug/open sequences, including closed-lid operation.
- Screen sleep, lock/unlock, logout, and fast user switching.
- Normal quit, crash, forced termination, frozen controller, stalled operation, and helper failure if present.
- Relaunch with an unresolved journal.
- Unsupported or unclassifiable configurations remaining untouched.

A human confirms screen visibility; software observations alone do not establish it. Missing equipment remains explicitly untested.

**Delivery sequence**

1. Assumption ledger, observer, and controlled experiments.
2. Pure controller, simulator, replay, and invariant tests.
3. Passing display backend and any justified recovery helper.
4. Minimal menu-bar app and local build instructions.
5. Guided validation report and documented compatibility limits.

The release criterion is demonstrated recovery from the supported failure scenarios, with no unresolved blackout in those tests. The architecture’s guarantees cover the controller’s decisions; physical recovery remains conditional on macOS and the display hardware responding.
