# Validation record

## Mirrored external-source round trip: physically confirmed

- Added a separate Debug-only mirror baseline and experiment; ordinary extended-mode guards still reject mirroring. Baseline requires exactly one external source and the identified internal follower. Verification compares the original observed display identities, mirror source, flags, and logical geometry, not just the active flag. Refresh rate, HDR, and scaling preferences are not captured.
- Four new native tests passed, bringing the native suite to 31 tests. The no-write rehearsal passed with `work/mirror-rehearsal.recovery.json` and `work/mirror-rehearsal.log`.
- Real evidence: `work/mirror-roundtrip.recovery.json`, `work/mirror-roundtrip.log`. The internal disappeared from inventory during the approximately five-second hold, the external remained reported usable, and writer restoration completed without a supervisor enable request. Result label: `mirror-roundtrip-layout-preserved-no-supervisor-enable`, exit status 0.
- A fresh native check at uptime 280190904 ms confirmed the original external source (ID 5), internal follower (ID 1, mirror source 5), both with logical geometry 2560 x 1440 at (0, 0). The mirrored internal is reported inactive, as it was before the experiment; this is not evidence that it is physically off.
- The user confirmed the physical off/on and restored mirrored image with "It's all good" in response to the explicit visibility question. No mirroring configuration, brightness, or external-display setting was explicitly changed. This does not validate mirrored sleep, unplug, crashes, or the opposite mirror-source arrangement.

## Sleep while suppressed, wake undocked: confirmed

- The first attempt, `work/sleep-undocked.log`, completed a connected sleep/wake cycle. The user explicitly said they forgot to unplug; it is not evidence of waking undocked.
- The retry used `work/sleep-undocked-02.recovery.json` and `work/sleep-undocked-02.log`, supervisor PID 8157 and writer PID 8159. The second USB-C monitor was connected at the baseline, the internal panel was suppressed, and the user was instructed to sleep, unplug once the external went dark, then wake with the cable still out. The lid remained open and the laptop was on battery.
- The supervisor recorded system sleep and wake notifications, then `sleep-wake-writer-recovered-no-supervisor-enable`. The experiment exited with status 0. A fresh independent native check at uptime 279768103 ms reported only the built-in display, active, awake, unmirrored, 1512 x 982 at (0, 0).
- The user confirmed that the internal screen visibly returned and was usable with USB-C still disconnected. This establishes physical recovery for this guided scenario on this setup, without a supervisor enable request. It does not distinguish a writer enable from macOS restoring before the writer's check, or validate production automatic mode, lid closure, or other topologies.
- Result: wake-undocked passed. No additional display changes were made after confirmation.

## Sleep while suppressed, wake with USB-C connected: confirmed

- Different external monitor from the earlier home setup: direct USB-C, no laptop charging, 2560 x 1440 at (1512, 0). Internal baseline: 1512 x 982 at (0, 0). Both unmirrored, lid open, battery 57% and discharging before the test. The external UUID differed even though macOS reused runtime ID 5.
- The no-write rehearsal passed using `work/sleep-rehearsal-away.recovery.json` and `work/sleep-rehearsal-away.log`. Its protocol trigger was synthetic, not real sleep. A previous rehearsal attempt with the external disconnected was correctly refused before mutation.
- Real evidence: `work/sleep-away.recovery.json`, `work/sleep-away.log`; supervisor PID 7664, writer PID 7670. Suppression was observed before `sleep-now-window-open`. The user chose system sleep, waited, and woke the Mac with the cable connected.
- The supervisor recorded both `system-sleep-notification-observed` and `system-wake-notification-observed`. The writer invalidated suppression on sleep and completed its recovery path after wake. The supervisor reported `sleep-wake-writer-recovered-no-supervisor-enable`; the experiment exited with status 0. This does not distinguish an owner enable from macOS already restoring before the owner's check, and is not an automatic-rollback proof.
- A fresh native observation at uptime 279482685 ms showed both displays active and unmirrored in their original arrangement. The user confirmed both were visibly on after wake and explicitly confirmed that the internal had been off before sleep.
- Result: physical docked sleep/wake recovery passed on this second monitor while on battery. Suppression was not reapplied. Waking undocked, lid closure, mirrored suppression, and production automatic-mode behavior remain unvalidated.
- Four new native tests cover sleep/wake ordering, duplicates, another sleep invalidating wake readiness, and explicit command/rehearsal parsing. All 27 native tests passed. The harness waits through recorded system sleep rather than claiming a timer can run while macOS suspends its processes; missed wake notifications remain an unvalidated failure case.

## Latest external-loss harness run

The dedicated `--lab-unplug` mode was added with a 40-second removal window and an independent 45-second writer lease. Native tests passed all 23 cases. The no-write `--lab-unplug-rehearsal` completed its synthetic-loss and writer-exit path successfully; evidence is retained in `work/unplug-rehearsal.log` and its recovery journal.

The first real run used `work/external-unplug.recovery.json`. It established suppression and reported `unplug-now-window-open`, but no removal was recorded during the window. It exited with status 1 after `exit-supervisor-aborted-test-recovery`. This validates neither physical unplug recovery nor reconnection. The expired-window run is inconclusive, and the journal is retained rather than reused.

For the current implementation and outstanding hardware matrix, see `status.md`. Sections below are chronological, not a cumulative claim that every listed scenario is now validated.

### Second unplug run: physical recovery and reconnection confirmed

- Fresh journal `work/external-unplug-02.recovery.json`, log `work/external-unplug-02.log`, supervisor PID 98663, writer PID 98665.
- After suppression was established, the user removed the direct USB-C cable during the window. The supervisor recorded `external-removal-observed` and closed the command pipe to revoke protection. The responsive writer restored and exited through its expected disconnected path. The supervisor independently verified the panel and recorded `external-loss-writer-restored-without-supervisor-enable`; the experiment exited with status 0.
- A fresh native check while disconnected reported only the built-in display, active and awake. The user confirmed that the internal display turned on.
- The user then reconnected and confirmed both screens worked. A fresh native check at uptime 266949983 ms reported both active and unmirrored, with the pre-test logical arrangement: internal 1512 x 982 at (0, 0), external 1920 x 1080 at (-194, -1080).
- Result: user-confirmed unplug recovery and post-recovery reconnection passed on this setup. No supervisor fallback enable was needed. Reconnection occurred after writer exit, so it does not validate automatic-mode reconnect policy. Sleep while suppressed, mirrored suppression, and multiple-external scenarios remain untested.

## 2026-09-08: foundation

- Scaffold: `swift package init --type library --enable-swift-testing --disable-xctest --name SoloDisplayCore`.
- Toolchain: Swift 6.3.3, installed Xcode, macOS 26.6.2 (25G83), arm64.
- GPU report: Apple M5 Pro. Exact Mac model and monitor model have not been recorded.
- User reports a USB-C connection to the external monitor, which also supplies power.
- Initial automated run: 24 Swift Testing tests passed, including 80 seeded traces of 250 events each.
- Initial sandboxed observer: empty display inventory, unknown GUI foreground state, open lid, private symbol found.
- Observer with GUI access: built-in display ID 1 and external ID 5, both reported as members of a mirror set. External active; built-in not active. These IDs are observations for this session, not constants.
- No display settings were changed during these checks.

## Outstanding gates

- Addressing the internal panel while suppressed.
- Application-lifetime rollback after exit and crash.
- Frozen-process and stalled-call recovery.
- Native wired transport classifier and lifecycle coordinator.
- Additional hardware and multiple-monitor tests.

Application-lifetime rollback is unverified. The read-only menu-bar shell now exists, but display control and any recovery helper remain gated on platform contract tests.

## First explicit application-scope round trip

- User switched to extended mode, raised internal brightness, and confirmed readiness.
- Read-only baseline: both displays active, neither mirrored, lid open, foreground GUI session. Internal logical size 1512 x 982; external 1920 x 1080.
- Command: `solodisplay-lab probe --external 5 --scope app --journal work/first.recovery.json --native-wired-attested`.
- The private disable call returned successfully. The online list then contained only the active external display.
- The probe waited up to ten seconds, explicitly enabled the recorded internal target, and verified it active. Process exited with code 0.
- The user confirmed the built-in screen visibly turned off and returned normally, with the external remaining usable.
- This validates the explicit API round trip at the software-observation level. It does not validate automatic rollback after exit, crash, or a hung process.
- The user clarified that mirroring plus dimming is an important real-world starting configuration. Mirrored restoration is now an explicit product investigation gate.

The expanded suite passed 31 tests, including trace eviction, byte limits, identity sanitization, exclusive writer locking, mirrored-topology inhibition, and expired-evidence timer behavior.

## Exit experiment stopped at an identity gate

- The user confirmed readiness for a separate exit-recovery test.
- Command used application scope with `--ending exit` and a new journal.
- Disabling succeeded and left the external active.
- While suppressed, converting the saved internal display UUID back to a runtime ID did not recover the recorded ID.
- The guard cancelled the planned exit, explicitly restored the internal panel using the recorded runtime ID, and verified it active.
- This is not an application-exit rollback result. No process was deliberately exited with suppression outstanding.
- Cross-process addressability requires further investigation. Numeric identity proven before suppression, boot/session ownership, live contradictory evidence, and UUID resolution must be treated as separate facts.

## Cooperative handoff: addressability demonstrated, observations inconsistent

- After the user requested resumption, the parent disabled the internal display under application scope and retained a recovery fallback.
- The saved UUID resolved to ID 0 while suppressed, rather than the recorded ID 1. It resolved to ID 1 again after restoration.
- Parent released its session writer lock. Its actual child acquired the lock and enabled the cached internal target using session scope.
- The child observed the internal panel active and exited.
- The parent then observed a state that did not establish active restoration. Its additional enable request failed at completion with code 1001.
- An independent observer immediately afterward found both displays active with the original extended geometry.
- Result: the child could address the recorded panel, but this is not a clean recovery pass. No conclusion is drawn about automatic exit rollback.
- Hypotheses include per-process stale information or reconfiguration timing. The next version adds explicit callback subscriptions and process-labeled timelines. It does not send another enable when a successful child result conflicts with parent observations.
- Further screen-changing tests are paused pending review of the instrumentation. A production helper is not selected on this evidence.

## Instrumented repeat

- Both processes registered CoreGraphics display callbacks successfully.
- Parent recorded begin/end callbacks for its own disable operation. Child recorded begin/end callbacks for its enable operation.
- Parent received no callbacks for the child's restoration, and continued reporting the suppressed view during the bounded verification interval.
- No duplicate enable request was sent. The experiment returned inconclusive.
- A fresh observer afterward reported both displays active. The external's latest reported origin was (-194, -1080); earlier baseline was (1512, 0). Whether the user changed the arrangement during testing is not established, so layout preservation is not marked passed.
- This narrows the observation question to CLI event-loop servicing, application-scope semantics, or related process-specific behavior. It does not establish an OS defect.
- Next step: integrate the backend into a scaffolded native app with a normal AppKit lifecycle before extending display-changing experiments. Xcode template creation has been requested from the user.

## Automated foundation checks

- 34 Swift Testing tests passed after adding the cooperative handoff identity checks and callback instrumentation.
- The generated synthetic CLI trace replayed through eight transitions and ended with the internal panel enabled and no outstanding operation, ownership, or fault.
- Source and documentation contain no em dashes.

## Native Xcode integration

- The user created a macOS App project in `/Users/imad/Work/personal/SoloDisplay` using Xcode's template, SwiftUI, Swift Testing, and XCTest UI tests.
- The core, platform adapter, lab executable, tests, and docs were copied into this repository. Original source files and hardware recovery journals remain intact in the earlier workspace. No recovery journals or build caches were copied.
- Xcode resolves `SoloDisplayKit` as a local package through a repository-relative reference. The app links `SoloDisplayCore` and `SoloDisplayPlatform`.
- Corrected a misspelling in the template's bundle identifier at the user's request. The existing signing team is unchanged.
- Added an AppKit menu-bar delegate and a read-only diagnostic window. Display callbacks, AppKit screen-change notifications, workspace lifecycle events, and periodic inventory reads feed a bounded in-memory timeline. No display writer is connected to the app.
- Swift 6 and macOS 26.0 are consistent across the app and package. App Sandbox is disabled; Hardened Runtime remains configured for eventual signed distribution.
- Debug app and both test targets built successfully. The optimized Release app also built successfully.
- Local builds used ad-hoc signing with an empty team override. No certificate creation, account registration, notarization, or publishing was performed. Xcode disables Hardened Runtime for these ad-hoc builds, so this does not validate release signing or its runtime constraints.
- All 34 package tests and five native app unit tests passed.
- The UI test runner timed out while enabling macOS automation mode, before executing the smoke test. UI behavior is not marked passed. No system permissions were changed to bypass this.
- The template's placeholder screenshot/launch-performance tests were replaced with one focused read-only diagnostic UI test. The removed template file is recoverable from the initial Git commit.
- No display configuration, brightness, mirroring, sleep setting, or login item was changed during integration. Cross-process callback delivery and rollback behavior remain unverified.

## Native observer: manual checks and independent private-API round trip

- The user's screenshot confirmed that the native app rendered both active displays, the open lid, foreground GUI session, and registered callback subscription. The user confirmed that Refresh added a Manual refresh entry.
- With the app running, the user switched from extended mode to mirroring in System Settings. The screenshot showed CoreGraphics begin/end callbacks and AppKit screen-change notifications, followed by mirrored readings. The external reported active and the built-in inactive. Inactivity in a mirror set is not proof of physical suppression.
- The user switched back to extended mode. Another screenshot showed both callback sources and both displays active with mirroring false. This validates delivery for these System Settings transitions on this setup, not all private-API or recovery transitions.
- The user then authorized a separate explicit off/on experiment while the native app remained open as a read-only independent observer (PID 89561).
- Command: `solodisplay-lab probe --external 5 --scope app --journal work/native-observer-roundtrip.recovery.json --native-wired-attested --ending restore`.
- The probe (PID 90066) disabled the built-in panel, observed only the active external display, waited approximately ten seconds, explicitly enabled the recorded panel, and exited with code 0. No exit, crash, or handoff experiment was performed.
- Reverse UUID lookup again returned ID 0 while suppressed. The original numeric target was used for explicit restoration in the same live owning process.
- The probe's immediate post-restore callback batch was empty, although its inventory showed both panels active. Do not treat that immediate batch as proof that no later notifications were delivered.
- A fresh independent CLI observation after probe exit confirmed both displays active, mirroring false, and the pre-test logical geometry restored: internal 1512 x 982 at (0, 0), external 1920 x 1080 at (-194, -1080).
- The user confirmed that both screens worked again and supplied the native app's timeline screenshots. Disable generated CoreGraphics begin/end callbacks at uptime 262721456 through 262721522 ms, followed by AppKit notifications at 262721523 and 262721590 ms showing only the active external display.
- Restoration generated CoreGraphics begin callbacks at 262731739 ms and end callbacks at 262731768 and 262731769 ms. AppKit notifications at 262731771 and 262731878 ms showed both displays active and mirroring false. This independently establishes notification delivery and updated native-app observations for both private-API transitions in this experiment, not merely eventual polling.
- Result: the explicit application-scope round trip passed with user-confirmed recovery and independent native-app observation on this setup. This is not a cross-process recovery takeover test, does not establish the cause of the earlier parent/child discrepancy, and does not validate automatic rollback, crash recovery, hangs, or mirrored off/on behavior.

## Native owner and child: cooperative restoration

- Added debug-only `--lab-check`, `--lab-handoff`, and internal `--lab-restore-child` entry points. They use the existing Xcode app lifecycle and never appear in the ordinary menu. Release builds reject lab arguments with status 64.
- Added eight unit tests for explicit command selection, operator attestation, malformed arguments, fallback decisions, baseline prerequisites, and recovery identity contradictions. All 34 package tests and 13 app unit tests passed. Debug and Release builds succeeded; a read-only native entry-point check reported both displays active.
- The user explicitly confirmed readiness for guided tests. The operator was asked to keep the cable connected and lid open for this experiment; sleep and unplug tests were not requested or performed.
- Command: `DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay --lab-handoff --external 5 --journal /Users/imad/Work/personal/SoloDisplay/work/native-app-handoff.recovery.json --native-wired-attested`.
- Native owner PID 90823 journaled the target, disabled under application scope, and observed only the active external for approximately ten seconds while yielding to AppKit.
- Owner released its writer lock and launched its actual child, PID 90833, from the same app executable. The child acquired the lock, checked live-parent and boot/session identity, enabled the cached internal target under session scope, and independently verified both displays active.
- The owner received the child's restoration callbacks at uptime 263355481 through 263355491 ms. After child exit, it reacquired the writer lock and observed both displays active at 263355690 ms, then verified again at 263355801 ms.
- The experiment exited with code 0. The owner did not issue a fallback or duplicate enable. No child timeout or forced termination occurred.
- A fresh CLI observation after both processes exited confirmed both displays active, mirroring false, and the original geometry: internal 1512 x 982 at (0, 0), external 1920 x 1080 at (-194, -1080).
- Result: cooperative restoration and native owner observation passed at the software level. Physical recovery confirmation is pending the user's report. The earlier CLI disagreement did not recur; this supports the native-lifecycle approach without proving the exact cause of that earlier result.
- This is not automatic rollback or crash/hang recovery. The owner stayed alive until the child restored, and ordinary after-crash UUID guards are unchanged. No sleep, cable-disconnect, or mirrored off/on experiment has been run.

The user subsequently confirmed that the built-in screen returned normally and the external remained usable, completing the physical check for cooperative handoff.

## Pre-armed supervisor: normal exit required explicit recovery

- Added a bounded two-pipe protocol between a native supervisor and its actual native writer child. The supervisor witnesses the active target before spawning; the writer journals and waits for an explicit arm signal before disabling. Journal target, boot/login, actual child PID, and fresh baseline must agree.
- A no-display-write rehearsal exercised the real processes, journal handshake, readiness and exit messages, and writer-lock reacquisition. It exited with code 0 and both displays active. Journal: `work/native-exit-rehearsal.recovery.json`.
- Six additional tests cover bounded protocol input, split/coalesced messages, EOF, invalid input, witness/child identity, and distinct rehearsal versus real-test parsing. All 19 app tests and 34 package tests passed. Debug and Release builds passed.
- User authorized proceeding with the supervised normal-exit test. No cable, lid, sleep, or mirroring change was requested during it.
- Command: `DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay --lab-exit-supervised --external 5 --journal /Users/imad/Work/personal/SoloDisplay/work/native-normal-exit.recovery.json --native-wired-attested`.
- Supervisor PID 93146 validated writer PID 93148's journal against its own live target witness before sending arm. It observed only the active external after disabling and for approximately five seconds.
- The writer completed a normal exit with status 0 without sending an enable request. At uptime 264189753 ms the supervisor still saw only the external. It continued observing for three seconds without seeing the internal panel active.
- The supervisor then sent one explicit session-scope enable using its live pre-disable witness after acquiring the writer lock. Restoration callbacks arrived at 264192992 through 264192996 ms; both displays were verified active at 264193073 ms.
- The experiment exited with code 0 and result `normal-exit-required-supervisor-restore`. This is a fallback-recovery result, not an automatic rollback pass. No forced termination or crash occurred.
- A fresh CLI observation confirmed both displays active afterward, mirroring false, and original logical geometry: internal 1512 x 982 at (0, 0), external 1920 x 1080 at (-194, -1080).
- Physical visibility confirmation for this test is pending. Failure to observe rollback in three seconds does not establish that macOS would never restore later, but it rules out assuming prompt automatic exit recovery for this configuration.
- Ordinary cold-start UUID recovery guards are unchanged. The supervisor's authority came from its live pre-disable observation and actual child handshake, not merely from loading a journal after process death. Crash, frozen-writer, supervisor-failure, sleep, and unplug hardware cases remain untested.

The user subsequently confirmed both displays worked in the final state of the normal-exit experiment, but did not watch the intermediate states. Uninterrupted external visibility is therefore not marked verified.

## Forced termination and frozen writer

- The user asked to proceed without repeated readiness pauses. The operator was told to keep the cable connected and lid open; no sleep or unplug steps were performed.
- Added explicit SIGKILL and SIGSTOP-then-SIGKILL modes to the existing pre-armed supervisor. Signal status must match the selected experiment; normal exit and signal termination are not interchangeable successes.
- Two more app tests cover termination classification and explicit failure-mode parsing. All 21 app tests passed; the unchanged package suite last passed all 34 tests in the preceding supervised-exit work.
- A no-display-write freeze rehearsal passed. `waitid` confirmed the child's SIGSTOP state, the supervisor remained responsive for three seconds, and the child was then terminated and its lock reacquired. This validates the process-control mechanism without assuming that successful signal delivery proves a stopped state.
- Forced-termination command used `--lab-exit-kill`, external ID 5, and `work/native-forced-exit.recovery.json`. Supervisor PID 95969 observed suppression, killed its actual writer, confirmed SIGKILL termination, and acquired the writer lock. No active internal panel appeared within three seconds. It explicitly enabled the panel; verification at uptime 264732663 ms showed both displays active. Exit code 0, result `forced-termination-required-supervisor-restore`.
- A fresh observer confirmed restoration and original geometry before the next experiment.
- Frozen-writer command used `--lab-exit-freeze`, external ID 5, and `work/native-frozen-writer.recovery.json`. Supervisor PID 96015 confirmed the writer stopped at uptime 264789105 ms while only the external was active. It remained responsive for three seconds, killed the stopped child, confirmed termination, and acquired the lock. No active internal appeared in the next three seconds, so it explicitly restored the panel. Verification at 264795536 ms showed both displays active. Exit code 0, result `frozen-writer-required-supervisor-restore`.
- A fresh CLI observation confirmed both displays active, mirroring false, and original geometry after the second test. Only the original read-only diagnostic instance remained; no lab writer was left stopped or running.
- These tests validate supervised restoration at the software level after SIGKILL and after a verified user-space stop followed by termination. They do not validate uninterruptible OS/driver stalls, simultaneous supervisor failure, or physical continuity during transitions. No new physical confirmation was requested between tests, per the user's preference to continue.

## Sleep/wake baseline with both panels enabled

- The user followed the guided sleep/wake baseline and supplied the read-only app's timeline. No writer or suppression was active for this test.
- System will sleep arrived at uptime 264950433 ms and Screens slept at 264950447 ms. Those immediate snapshots still reported both displays active. A later periodic snapshot at 264952697 ms reported both inactive. Notification names and simultaneous display flags are not interchangeable facts.
- Screens woke arrived at 264957470 ms, before System woke at 264957713 ms. At both points the inventory contained only the active internal display.
- CoreGraphics callbacks and AppKit screen-change notifications then reported both panels active and unmirrored at 264958426 and 264958590 ms. The first shown restored external inventory was 713 ms after System woke.
- This validates delivery and eventual display enumeration for this baseline. It does not validate sleep while suppressed, lid-closed recovery, or physical continuity during wake.
- Added a normalized controller regression based on this sequence, with external delays of 713 ms, 5 seconds, and 30 seconds. It requires fresh external evidence, its own full stability interval, and journal acknowledgement before disabling. The test deliberately assumes a validated synthetic transport adapter rather than treating the raw screenshot as native-transport proof.

## USB-C disconnect/reconnect baseline

- With both displays enabled and no writer running, the user unplugged and reconnected the direct USB-C monitor and supplied the native app's timeline without a manual refresh.
- Removal generated CoreGraphics begin callbacks at uptime 265157579 and 265157580 ms, then end callbacks at 265157644 ms. AppKit notifications at 265157645 and 265157718 ms showed only the active internal panel.
- Reconnection generated begin callbacks at 265163081 and 265163082 ms, then end callbacks at 265163094 and 265163095 ms. AppKit observations at 265163095 and 265163252 ms showed both panels active and unmirrored.
- The same external runtime ID appeared in this run. This does not establish identity stability across reconnection generally. The timeline does not establish exact physical cable-insertion latency or uninterrupted image visibility.
- This passes the read-only notification/inventory baseline, not external-loss restoration while the internal panel is suppressed.
- Added a normalized disconnect/reconnect regression: loss immediately requests restoration; verified restoration releases ownership; reconnect starts a new stability window and journal operation; a stale acknowledgement from the previous ownership cannot disable the panel.

The user clarified that the external monitor physically woke more slowly than the internal. That is not classified as a defect. These scenario tests guard future controller behavior; timestamps and `active` flags do not measure when the physical image becomes visible.

## Recovery protocol and live shadow integration

- Added deterministic `RecoveryLease` and `RecoveryTakeover` models, including challenge-bound renewal deadlines, irreversible loss of protection, termination-before-lock ordering, at-most-once takeover writes, and verification before journal clearing. The bounded native writer now uses the lease model; supervisor enable calls use the takeover ordering guard.
- Added conservative `ControllerObservation` normalization and `ShadowController`. The ordinary native app feeds live snapshots and lifecycle events to the reducer but executes no display or persistence effects. Missing panels remain unknown, and backend/transport/topology authorization remains inhibited. This is not a completed production coordinator or helper.
- Fifty package tests and 22 native app tests passed. Generated takeover tests exercise 20,000 additional event steps. Debug and Release builds passed, as did formatter lint and diff whitespace checks. No UI automation success is claimed.
- Native no-write rehearsals for command-pipe disconnection and open-but-silent supervisor contact passed, using `work/contact-loss-rehearsal.recovery.json` and `work/lease-expiry-rehearsal.recovery.json`. The writer took the expected disconnected/deadline failure paths and no display writes were sent.
- Real pipe-loss experiment: supervisor PID 97968, writer PID 97970, journal `work/contact-loss.recovery.json`, log `work/contact-loss.log`. After approximately five seconds of suppression the supervisor closed its command pipe. The responsive writer restored and exited with status 1, as expected for protection loss. The supervisor independently verified restoration and reported `contact-loss-writer-restored-without-supervisor-enable`, exiting with status 0.
- Real silent-supervisor experiment: supervisor PID 98001, writer PID 98003, journal `work/lease-expiry.recovery.json`, log `work/lease-expiry.log`. The supervisor left its pipe open without sending an exit command. The writer's ten-second lease expired; it restored and exited with status 1. The supervisor independently verified restoration and reported `lease-expiry-writer-restored-without-supervisor-enable`, exiting with status 0.
- Fresh native observations after each experiment reported both displays active, unmirrored, and the original logical geometry: internal 1512 x 982 at (0, 0), external 1920 x 1080 at (-194, -1080). No lab writer remained running. The existing read-only diagnostic instance was left running.
- These are software-level passes. Physical image continuity was not separately confirmed. The supervisor stayed alive in both tests; neither test killed the supervisor process or exercised simultaneous failure, cable removal, sleep, lid closure, or mirrored suppression. Those cases remain explicitly open in `status.md`.

## Milestone A: production process ownership, protection protocol, and journal

- Preserved the supplied product plan unchanged as `docs/original-plan.md` and saved the remaining-work plan as `PLAN.md`, as that plan's own first instruction requires. Neither existed before this session.
- Added a versioned protection protocol in the pure core: bounded newline-framed JSON messages carrying session identity, sequence and challenge numbers, ownership identity, and outstanding-operation progress. Each role validates the peer's stream through its own inbox. A stale, duplicated, wrong-session, wrong-sender, unsupported-version, or malformed frame latches that inbox closed rather than being skipped, because on a private inherited pipe it is evidence of a broken peer.
- Controller-side protection wraps the existing `RecoveryLease`, so an unacknowledged challenge lets the lease run out instead of receiving a grace renewal. Helper-side protection emits at most one recovery request and delegates stop-then-confirm ordering to the existing `RecoveryTakeover` rather than duplicating that guard.
- Operation deadlines travel separately from heartbeats. A controller whose loop is responsive but whose display call is past its deadline is detected as stalled by the helper. This is covered both deterministically and with real processes.
- Added a production journal in the app's Application Support directory: exclusive creation with 0600 permissions inside a 0700 directory, synchronized to disk, carrying schema version, run and operation identity, boot and login identity, target, configuration scope, and the observed topology. It is separate from the retained lab journals.
- Launch reconciliation classifies a leftover record as unresolved for this boot and login, from a prior boot or login, or retained. Every non-empty classification inhibits disabling and carries a user-facing explanation. A record contradicted by live built-in display evidence is retained rather than acted on. Clearing happens only after verified restoration.
- Production process ownership: a normal launch becomes the supervising helper and launches its controller child over inherited private pipes. Both are the same app executable with real AppKit event loops. The controller role is refused unless the standard descriptors really are pipes, so a command-line claim alone cannot authorize it.
- Added `solodisplay-probe`, a package executable that runs both roles as real paired processes and performs no display configuration at all. Eight automated tests drive it through pairing and release, a missing helper witness, journal-preparation failure, a silent but connected helper, lost helper contact, a killed controller, a stalled operation, and writer-lock ordering. What they establish is the protocol, journal, and ordering behavior; they establish nothing about physical recovery.
- Observed on this machine, bounded and cleaned up afterwards: launching the built Debug app produced helper PID 11217 with controller child PID 11219 running `--solodisplay-controller`. A second launch was refused by the instance lock with "SoloDisplay is already running in this login session." Killing the controller made the helper find nothing owned and exit without any display write. No recovery record was created, because nothing in this milestone can disable a display.
- Release rejects lab commands, an unpaired controller claim, and unknown arguments, each with exit code 64.
- Automated checks: 79 package tests and 36 native app tests passed; Debug and Release builds passed; `swift-format` lint is clean. One earlier full run failed `onlyOneWriterCanOwnAGUISession` with a lock already held. The cause was not reproduced in four subsequent runs, and the test now uses its own private directory rather than only a random synthetic session ID, which removes that collision class. The one-off failure is recorded rather than explained away.
- Not validated by this milestone: any production display change, the coordinator, transport classification, lifecycle policy, and every hardware scenario in the production process pair. Normal app launches still cannot disable a display.

## Milestone B: production coordinator and platform evidence

- Extended the pure reducer with the interfaces the production path needs: an operation-bound protection lease between durable journaling and the display write, explicit protection availability and loss, a persistence completion event for journal clearing, and a read-only presentation projection that names the first blocking reason.
- Disabling now walks journal, then lease, then call, then separate verification. A refused lease or an unanswered lease request clears the record without touching the display, which is sound because no request is issued before that phase completes. Losing the helper while owning a panel restores it and stops disabling.
- Ownership is released only by a confirmed journal clear. A failed clear keeps ownership, faults, and is retried explicitly rather than being reported as released.
- Added `ProductionCoordinator`. Decisions run one event at a time on the main actor; every synchronous platform call runs on one injected serial lane, so a stalled display call cannot block the event loop and callbacks only ever schedule work. The executor repeats the full eligibility check on that lane immediately before writing.
- Added an explicit refusal event. A pre-call refusal positively establishes that nothing was sent, so the record is cleared and no restore is issued. A returned error keeps ownership and is followed by restoration, because an error is not proof that nothing changed. Conflating the two would have produced a needless enable on a panel that was never turned off.
- Corrected an evidence gap the coordinator tests exposed: an empty display inventory is normally unusable evidence, but it is coherent when this process turned the only internal panel off and no external remains. Without that, unplugging the last external while suppressed left the controller with no target to restore. This is the scenario that passed on hardware in the earlier lab harness.
- A panel this process turned off has no live entry to read an identity from, so ownership supplies the target, and only after absence is already established as our own suppression by a returned disable plus matching boot and login identity.
- Implemented native transport classification from IOKit provenance rather than names or flags. `IODisplayConnect` does not exist on this hardware; `IOMobileFramebufferShim` publishes display identity instead. Captured fixtures on this Mac: the Dell U3223QE correlates by vendor 4268, model 17020 and serial 808923980 through `dispext0`, and the internal panel through `disp0`. Both classify as native. Those fixtures are now regression tests.
- Implemented mirror topology classification. An internal follower of one present external source is supported; an internal mirror source, a follower of an absent source, and unresolvable sets are not. An inactive mirrored follower is read as presence, never as suppression or as failed restoration.
- Added an independent power and session reconciliation path. A missed wake notification cannot strand the coordinator believing the machine is asleep: two seconds of usable observations outrank a sleep notification that was never followed by a wake. A wake notification alone still establishes nothing.
- Read-only check on the live mirrored setup, with no display changed: transport `native` for both displays, `nativeExternalAvailable: yes`, `supportedTopology: yes`, `panelState: enabled`, panel identified, and `backendValidated: unknown`. That last value is the single remaining gate, and it is the intended one.
- Added `BackendValidation`, which records the OS build, hardware model, and symbol a verified off/on round trip was observed on. Nothing writes one yet, so production disabling stays unavailable. A resolved symbol never sets it.
- Automated checks: 110 package tests and 36 native app tests passed; Debug and Release built; `swift-format` lint is clean. Seventeen new coordinator tests cover storage errors, refused and lost leases, stale completions, write errors, conflicting changes, clock advancement, missed notifications, replay fidelity, and convergence once the modeled platform accepts restoration.
- Not validated by this milestone: any production display change, the menu controls, and every hardware scenario through the production path.

## Milestone C: usable controls and diagnostics

- Connected the production coordinator to the menu shell. The controller process now owns the coordinator, the protection link, exclusive writer ownership for the whole run, display callbacks, and workspace lifecycle notifications. Notifications and callbacks only ever queue work; none of them configures a display.
- `MenuModel` is a pure mapping from controller state to menu items, so every refusal's wording is testable without launching an app or touching a display. Every `Unavailability` and every `Fault` has a specific sentence, and a fault is shown ahead of the generic unavailable reason because it is the thing a person can act on.
- Implemented the agreed controls: status and reason, manual and automatic selection, turn off and on, keep on and resume, retry recovery, launch at login through `SMAppService` with the real registration state recorded rather than the requested one, sanitized diagnostics export, and quit.
- Automatic mode is locked until this installation has turned the panel off in manual mode and seen it verified back on. That matches the plan's staging and means automatic is never offered on a path nothing has exercised here.
- Quit requests restoration first and returns `terminateLater` until nothing is unresolved. If the controller dies anyway, the helper still holds recovery responsibility.
- Preferences live beside the journal in Application Support at 0600: mode, launch at login, and whether the manual path has been validated. A paused automatic choice survives a restart. An unreadable or unsupported file falls back to manual with nothing enabled, so a corrupt file can never be read as an instruction to run automatically. The coordinator persists the mode through its own effect, and every other write is read-modify-write so nothing clobbers another field.
- Diagnostics export uses the existing bounded replay recorder: at most 10,000 events and 5 MB, sanitized to export-local pseudonyms, written only where the user chooses, with no upload. No raw lab log is offered as an export.
- Fixed a real gap found by running the pair: killing the helper left an orphaned controller alive, holding the writer lock and blocking a fresh pair from ever becoming able to disable. A controller that loses helper contact now finishes anything it owes and then exits. Re-ran on this Mac: killing the helper took the controller with it, and a fresh pair started cleanly afterwards. Nothing was owned, so no display was changed.
- Also corrected the protection machines. Release ended the pairing terminally, so a controller could only ever arm once. Release now ends one suppression cycle and leaves the pairing intact, with a separate shutdown input for ending the run. Without this, a second off/on cycle in one session would have been impossible.
- Automated checks: 119 package tests and 47 native app tests passed; Debug and Release built; `swift-format` lint is clean; Release still rejects lab commands with exit code 64.
- Not validated by this milestone: any production display change. The menu correctly reports that turning the internal display off is unavailable, because no backend validation has been recorded on this Mac. Every hardware scenario through the product path remains untested.

## Milestone D: product path on hardware

Guided run on the tested Mac (Mac17,9, macOS 26.6.2 build 25G83) with the Dell U3223QE on USB-C in the user's normal mirrored arrangement: external as mirror source, internal panel as its follower.

- Guided backend validation passed. One off and on round trip, panel observed absent, mirror relationship and geometry restored, user confirmed seeing the laptop screen go off and come back. `BackendValidation` recorded for this Mac, this macOS build, and `SLSConfigureDisplayEnabled`. Nothing else writes that record, and a resolved symbol never sets it.
- Mirrored manual off and on through the actual menu passed, repeated for three full cycles plus a fourth off, each visually confirmed. The journal is written before the write and cleared only after verified restoration, and the mirror source and geometry come back unchanged.
- Relaunch with unresolved ownership passed. A leftover record from an earlier failure was reconciled at launch before any controller ran: writer lock taken, identity checked, enable issued, restoration verified through the mirror relationship, record cleared.
- Forced controller termination passed. With the panel off, the controller was SIGKILLed. The helper detected contact loss, confirmed termination, acquired the writer lock, restored with user-confirmed visibility, cleared the record, and exited without starting another disabling controller.

Seven faults were found by running the product path, none of which the automated suite had caught:

- The journal scope raw value was `"application"` while the record validator accepted only `"app"`, so every production journal write was rejected. The coordinator test had hedged on this exact value because the fake store did not validate; it now validates like the real one.
- The controller and helper each generated their own session identifier, so the helper rejected every opening frame as wrong-session and pairing never completed. The probe had used one shared literal session, which hid it. The helper now adopts the session from the controller's first frame on the private inherited pipe.
- The helper never formed its own witness of the claimed panel, so it refused every arm request. It now re-observes the internal panel each second and compares that to the claim, with a staleness bound.
- Timers ran in the default run loop mode. Holding the menu open runs AppKit's modal tracking loop, which stops those timers, so heartbeats stopped and the helper killed the controller and took over after five seconds. Every timer now runs in common mode.
- Observations captured the ownership context at dispatch and interpreted it on arrival, so a reading taken just before a disable returned was read as a missing panel and triggered an immediate restore. The reading now happens off the loop and is interpreted on the loop with the context that is current then.
- The helper's restoration check required an active panel, which a mirrored follower never is, so a correct restoration looked like a failure and kept the record.
- Launch reconciliation never drove the takeover ordering, so its guard refused the write. Acquiring the exclusive writer lock is the termination evidence when no controller child exists yet, and the sequence now says so explicitly.
- A lease reply that arrived after its cycle ended was treated as a broken peer, so the app quit after a successful manual off and on. Stale replies are now ignored rather than failing the pairing.

Application-scoped suppression is not visible to other processes, so a separate observer still reports the panel present. Verification of these runs came from the controller's own state and from the user watching the screen, not from an outside reading.

### Product path results

All of the following ran through the actual menu on Mac17,9, macOS 26.6.2 build 25G83, with one Dell U3223QE on direct USB-C. Every visibility claim is the user's own observation of the laptop panel.

Passed: mirrored off and on with the mirror relationship and geometry preserved; extended off and on with exact geometry preserved; automatic mode disabling on its own; Keep Internal On and its persistence across a restart; resume automatic; last-external unplug while suppressed, and reconnect; sleep while suppressed waking connected; sleep while suppressed with the cable pulled before waking, and reconnect afterwards; lid close and open; screen lock, display sleep and unlock; normal quit while suppressed; forced controller termination; frozen controller; helper termination; relaunch with unresolved ownership. Fourteen operations in one session with zero faults.

Release was verified separately: it builds, rejects lab commands with exit code 64, runs the real helper and controller pair from the built app, performs a manual off and on, and writes nothing to stderr.

Two further faults were found during these runs, on top of the eight recorded above:

- The controller died by SIGPIPE while writing a heartbeat to a helper that had gone away, which killed it mid-restoration and left an unresolved record. Production now ignores SIGPIPE, and the same test then restored, cleared its own record, and stopped cleanly.
- Neither process discounted system sleep from its deadlines. Sleeping while suppressed made the controller call its own restore stalled and the helper agree, so waking killed the pair and left SoloDisplay not running. Both now learn about suspension from the OS rather than inferring it from elapsed time, and a submitted call no longer times out while the machine is not awake.

One observation worth recording rather than changing: sleep, lid closure and losing the external all invalidate a prerequisite, so SoloDisplay conservatively restores and then disables again, which shows as a brief flash of the internal panel. Screen lock and display sleep invalidate nothing, so the suppression is simply held and no flash occurs. Display sleep is now an explicit non-reason to restore rather than an incidental one.

### Not tested

Multiple external displays and docks, because no second external or dock is available. Fast user switching and logout, because that needs a second account. The internal panel acting as the mirror source, which the topology classifier refuses, so it stays unavailable. DisplayLink, wireless, and virtual displays, which the transport classifier refuses for want of hardware to confirm against. Other Macs and other macOS builds. UI automation remains unvalidated.
