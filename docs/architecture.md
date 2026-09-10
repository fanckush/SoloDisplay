# Architecture

## Product decisions

SoloDisplay controls one positively identified internal laptop panel. It does not modify external display settings, brightness, mirroring, or system sleep preferences.

Manual mode is the default. A manual off request is temporary and clears on interruption. Automatic mode is explicit opt-in. Its Keep Internal On action remains paused across wake, reconnect, and relaunch until the user resumes it. Launch at Login defaults to off.

Native wired external displays, including native-output docks and multiple monitors, are the intended first supported configurations. DisplayLink, wireless, virtual, and unclassified topologies inhibit disabling initially. Unknown OS versions are evaluated using runtime capabilities, not a version allowlist. Tested compatibility is reported separately from the deployment target.

Mirroring plus a dimmed internal display is a normal incoming configuration for this product. The observer detects mirroring and records the mirror source and desktop coordinates. Until its behavior is validated, disabling is explicitly inhibited. The first guided experiment uses an extended baseline; a separate mirrored-baseline experiment must establish whether disabling and recovery preserve the original arrangement. Do not silently switch the user's mirroring settings or force that conversion as an unexplained workaround.

No normal-use confirmation countdowns. Diagnostics remain local unless explicitly exported. User-facing copy and project documentation do not use em dashes.

## Functional core

`Controller.reduce(state, event, at:)` is synchronous and deterministic. It returns the next state and requested effects. It cannot call macOS, inspect a clock, sleep, access storage, or change a display.

The model separates intent, observed environment, pending operation, possible ownership, and faults. Unknown and conflicting observations have explicit representations. A raw private symbol is not evidence that the display-control contract is validated.

Disabling requires fresh evidence, two separated observations, a stable interval, a known panel, a foreground GUI session, an open lid, a validated backend, and a supported native external display. The executor must check again immediately before sending the request.

The core requests a durable ownership journal before emitting a disable effect. Journal failure prevents disabling. An API error does not prove that no side effect occurred, so ownership survives errors.

One operation can be outstanding. A submitted call that exceeds its deadline becomes stalled. Its timeout requests supervisor intervention but never grants permission to start a competing writer. A late completion remains relevant and can trigger restoration.

An accepted operation enters verification. Only a newer observation can establish the outcome. Restoration takes precedence over verifying an obsolete disable request. The disappearance of the panel during a verified suppression must be interpreted by the validated platform adapter, not guessed by the core.

The initial timing policy is two seconds of stability, 500 ms between counted observations, five seconds of evidence freshness, three seconds for an operation or awake verification, and at most three restoration attempts with 500 ms and two-second retry delays. These deadlines bound controller decisions, not hardware response.

## Platform boundary

`DisplayObserver` performs read-only CoreGraphics, ColorSync, IOKit, and GUI-session queries. `ControllerObservation` normalizes its readings for shadow execution, but never upgrades raw flags or a private symbol into production authority. Missing or inactive panels remain unknown, not disabled. Mirroring explicitly inhibits the topology; transport and backend validation remain unknown.

`PrivateDisplayAPI` is the sole implementation of the private call. It opens SkyLight explicitly, resolves `SLSConfigureDisplayEnabled` then `CGSConfigureDisplayEnabled`, and wraps the call in a CoreGraphics transaction. This adapter is exercised only by explicit lab commands until its contract is validated.

`RecoveryJournal` records the boot, GUI login session, runtime display ID, display UUID, experiment scope, and owner process. Creating a journal is exclusive and synchronized to disk. Existing journals are never silently overwritten. Lab writers hold a kernel-backed GUI-session lock so separate invocations cannot become concurrent writers.

Journals are authority to investigate an owned target, not authority to apply an old ID on another boot. Restoration validates boot and GUI session identity, checks that the previous writer is gone, rejects a target that now describes a different display, and verifies the result separately.

The lab intentionally retains journals after successful restoration as experiment evidence. The future production executor must serialize journal writes and clears, acknowledge failures, and reconcile any leftover journal before another disable request.

Experiments established that reverse UUID lookup can become unavailable during suppression. `RecoveryIdentity` therefore distinguishes live contradictory evidence from an absent, previously owned panel. The cooperative lab child may use its actual live parent's boot/session-scoped ownership; ordinary after-exit recovery retains the stricter unresolved-identity guard. These are different authorities, not interchangeable fallback guesses.

The instrumented CLI handoff produced inconsistent parent/child observations even with callbacks registered. The parent received only callbacks for its own operation. A normal AppKit event loop must be tested before connecting these raw observations to production decisions. Callback registration by itself is not a validated observation contract.

Subsequent tests established that a native observer receives independent private-API off/on notifications, and a native owner can observe its cooperative child's restoration. The debug-only `NativeRecoveryLab` uses the same app executable for both processes and asynchronous waits that service AppKit. Normal app launches remain read-only, and Release builds reject its arguments. The earlier CLI disagreement did not recur in this native test; its exact cause is not proven. Neither cooperative handoff nor explicit off/on establishes after-crash recovery authority.

## Process and lifecycle design gates

First test application-lifetime configuration. Apple documents rollback at process termination, but its behavior with this private call is not established by those public docs.

If application-lifetime configuration does not work, investigate session-lifetime changes only with demonstrated independent recovery. A live frozen process must be tested separately from a terminated process. A recovery helper is allowed if experiments show that it closes a recovery gap.

The supervised normal-exit experiment found no active panel within three seconds of writer exit; the pre-armed supervisor explicitly restored it. Automatic rollback is therefore not an adequate recovery assumption for this tested configuration. A production independent recovery mechanism is now justified for investigation, but the lab supervisor is not that production implementation.

The debug-only exit experiment captures a live target witness before creating its writer. The writer journals and holds the session lock, then waits for a pipe acknowledgement before disabling. The supervisor validates the journal against its own witness, its actual child, and fresh baseline evidence before acknowledging. Recovery responsibility begins before that acknowledgement is sent. After normal writer exit, the supervisor acquires the lock and observes before any enable call, separating OS rollback from explicit recovery. Ordinary cold-start journal recovery retains its stricter identity requirements.

The pipe protocol accepts only bounded fixed-size signals. Lost contact or a bounded lease expiry makes the responsive writer attempt restoration; supervisor takeover requires confirmed writer termination and lock acquisition. These error paths are implemented but not all hardware-validated. Stalled OS calls, simultaneous process failure, and unavailable identity evidence can still prevent physical restoration. No universal blackout guarantee is claimed.

Any helper must be armed before disabling, observe both process progress and operation deadlines, stop the original writer before takeover, and restore only the journaled panel. A responsive controller restores when it loses helper contact. Simultaneous failure of both processes and an unresponsive OS remain outside that mechanism's guarantee.

The production coordinator serializes events without executing configuration calls inside display callbacks. Sleep is a hard write barrier: `willSleep` invalidates the current write generation, and neither sleeping nor waking permits a display call. A wake notification plus a fresh usable observation creates a new generation. Work queued before sleep cannot become valid after wake. Unresolved ownership survives the interval, and an already enabled panel satisfies the required restoration without being misclassified as a competing controller. A fault requires explicit retry.

The menu-bar shell now exists. Its AppKit delegate owns a read-only diagnostic model, a CoreGraphics callback subscription, workspace lifecycle subscriptions, and a main-run-loop timer. Callback and notification handlers defer observation; they never perform configuration writes. The bounded in-memory timeline distinguishes callbacks from snapshots. Unchanged polling updates freshness without evicting useful events.

The native diagnostic model now feeds `ShadowController`, which serially runs the real reducer, services requested timer deadlines, and counts rejected effects without executing writes or persistence. Workspace sleep/wake notifications invalidate intent and evidence. This remains an observation integration, not a production effect executor. Its power evidence deliberately does not become awake merely because an external is reported active.

`RecoveryLease` binds protection to a live handshake and numbered challenges. A pending renewal does not extend the old deadline; a matching acknowledgement grants validity only until the challenge's original deadline. Duplicate, wrong-session, and late acknowledgements cannot revive expired protection. Lost contact, interruption, or expiry emits one restoration request. The process adapter remains responsible for authenticating the peer and for restoring only an owned target.

`RecoveryTakeover` separates writer termination, lock acquisition, fresh target authorization, the restore request, verification, and journal clearing. Timeouts and successful signal delivery are not termination evidence. The native lab uses this ordering guard before supervisor writes and uses the lease model for its bounded writer. Lab journals remain retained evidence, so the lab intentionally does not execute the production journal-clear effect.

## Production process ownership and protection

A normal launch becomes the supervising helper. It never disables a display and launches its controller child from the same app executable over inherited private pipes. It is normally invisible, but that is conditional: if the controller is absent while recovery remains unresolved, the helper owns a recovery-only status item with diagnostics and explicit retry. It cannot remain as an invisible single-instance owner in that state. Both processes run real AppKit event loops. There is no daemon, no root privilege, and no background installation. A per-login instance lock refuses a second pair, and the controller holds the writer lock for its whole run, so the helper cannot acquire it while its controller lives.

`ProtectionMessage` is a versioned, bounded frame carrying session identity, a monotonic sequence number, a challenge number, ownership identity, and outstanding-operation progress. `ProtectionInbox` validates one peer's stream. A stale, duplicated, wrong-session, wrong-sender, unsupported-version, or malformed frame latches that inbox closed: on a private inherited pipe such a frame is evidence of a broken peer, not noise to skip.

`ControllerProtection` wraps `RecoveryLease`, so an unacknowledged challenge lets protection expire instead of receiving a grace renewal. Only `protects(at:)` gates a disable, and a lease is never sufficient by itself: exclusive writer ownership, durable ownership, and fresh platform prerequisites are separate requirements. `HelperProtection` grants protection only after its own independent witness agrees with the claimed target, emits at most one recovery request, and delegates stop-then-confirm ordering to `RecoveryTakeover` rather than repeating that guard. Operation deadlines travel with every heartbeat, so a responsive communication loop cannot conceal a stalled display call.

`ProductionJournalStore` writes ownership to the app's Application Support directory: exclusive creation with 0600 permissions inside a 0700 directory, synchronized to disk, and never silently overwritten. A record carries schema version, run and operation identity, boot and login identity, target, configuration scope, and the topology observed immediately before the request, so recovery can verify rather than assume. Preparation and clearing are serialized and their failures are reported, because a persistence failure must produce a fault instead of an unrecorded change.

Launch reconciliation classifies a leftover record as unresolved for this boot and login, from a prior boot or login, or retained. Every non-empty classification inhibits disabling and carries an explanation the interface can show. A record contradicted by live built-in display evidence is retained, not acted on. A prior-session record is cleared only after an active built-in panel is observed, because a restart already restored the panel. Clearing otherwise happens only after verified restoration.

Helper takeover never enters the private display API in the helper itself. It launches a one-shot recovery-worker role with a versioned, parent-bound request. The worker revalidates the durable record and fresh recovery identity, can only enable the recorded panel at session scope, and inherits a duplicate of the exact locked file description. The helper bounds the worker to three seconds, sends `SIGKILL` to that exact child on timeout, and confirms its exit before releasing responsibility. If the OS cannot yet confirm termination, the inherited lock continues to exclude every other writer. In every failure case the journal is retained and the helper remains responsive with the recovery interface. A driver that refuses every call can still prevent physical restoration; it cannot strand the only long-lived control plane inside that call.

See `status.md` for the current verification boundary instead of inferring hardware coverage from the existence of a model, a lab command, or a process role.

## Diagnostics and tests

`TraceRecorder` bounds history by both event count and encoded size. Evicting an event advances the replay baseline, so the retained suffix still replays correctly. Shared exports replace display, boot, and session identifiers with consistent local pseudonyms.

Regression tests express event sequences and invariants. Generated sequences add missing, delayed, reordered, and conflicting events. They establish properties of the controller under modeled assumptions. Guided hardware tests establish which assumptions match the operating system.

Use SDK and project scaffolding tools where available. The user created the native project with Xcode's macOS App template, including Swift Testing and XCTest UI targets. Integration edits add a repository-relative local package dependency to that generated project. No custom project generator is required.
