# Validation record

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

- Scaffold: `swift package init --type library --enable-swift-testing --disable-xctest --name LidlessCore`.
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
- Command: `lidless-lab probe --external 5 --scope app --journal work/first.recovery.json --native-wired-attested`.
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

- The user created a macOS App project in `/Users/imad/Work/personal/Lidless` using Xcode's template, SwiftUI, Swift Testing, and XCTest UI tests.
- The core, platform adapter, lab executable, tests, and docs were copied into this repository. Original source files and hardware recovery journals remain intact in the earlier workspace. No recovery journals or build caches were copied.
- Xcode resolves `LidlessKit` as a local package through a repository-relative reference. The app links `LidlessCore` and `LidlessPlatform`.
- Corrected the template's `dev.ledless` spelling to `dev.lidless` at the user's request. The existing signing team is unchanged.
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
- Command: `lidless-lab probe --external 5 --scope app --journal work/native-observer-roundtrip.recovery.json --native-wired-attested --ending restore`.
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
- Command: `DerivedData/Build/Products/Debug/Lidless.app/Contents/MacOS/Lidless --lab-handoff --external 5 --journal /Users/imad/Work/personal/Lidless/work/native-app-handoff.recovery.json --native-wired-attested`.
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
- Command: `DerivedData/Build/Products/Debug/Lidless.app/Contents/MacOS/Lidless --lab-exit-supervised --external 5 --journal /Users/imad/Work/personal/Lidless/work/native-normal-exit.recovery.json --native-wired-attested`.
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
