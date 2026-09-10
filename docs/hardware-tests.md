# Guided hardware tests

These are developer experiments. They are not routine app usage or part of the automated test suite. Run each display-changing step with a person observing the screens. Do not run crash or freeze experiments as the first test.

## 1. Read-only baseline

```sh
swift run solodisplay-lab observe
```

Record the OS build, Mac family, monitor, connection path, power source, and visible layout in the validation record. Avoid publishing raw boot, session, and display UUIDs.

For the first experiment:

1. Use a direct native wired external display.
2. Use Extended Display rather than mirroring.
3. Open the lid and raise the built-in brightness enough to see the panel.
4. Confirm both displays are working.
5. Use the external display ID from this observation, not a copied example.

The observer must report an open lid, foreground session, built-in target identity, and a usable external candidate. Missing information is a stop condition. USB-C power delivery does not by itself establish the display's transport.

## 2. Initial explicit off/on round trip

Create `work/` for local experiment artifacts. Run the command with the actual external ID:

```sh
swift run solodisplay-lab probe --external EXTERNAL_ID --scope app --journal work/first.recovery.json --native-wired-attested
```

The attestation means the operator checked the connection and can see the external display. It is a lab-only substitute for the production transport classifier, which is not implemented yet.

The probe records ownership first, obtains exclusive writer access, checks prerequisites again, then requests disabling. If the call returns, it requests restoration within ten seconds or earlier when the observed conditions deteriorate. A blocked OS call can prevent that timer from running. This experiment has no independent recovery helper yet.

Observe the actual panel, external image, and desktop layout. An active flag is recorded separately from visible recovery. A successful explicit round trip does not establish automatic rollback on exit.

The journal remains even after success. Use a different filename for a later experiment rather than overwriting it.

## 3. Recovery after the writer exits

Prepare a second Terminal on the external display before any exit experiment:

```sh
.build/debug/solodisplay-lab restore --journal work/first.recovery.json
```

Only run restoration after the original probe exits. The command refuses a writer that may still be alive, a boot/login mismatch, or a contradictory target. It acquires the same writer lock. It leaves the journal intact.

After the explicit round trip succeeds, design the next experiment around one failure at a time: normal exit without an explicit enable, abnormal exit, and forced termination. Observe whether macOS restores the panel without the restore command. Run fallback restoration if needed. Do not mark application-lifetime rollback as passed based on the initial probe, which explicitly enables before exit.

Once the operator is ready for the separate exit test:

```sh
swift run solodisplay-lab probe --external EXTERNAL_ID --scope app --journal work/exit.recovery.json --native-wired-attested --ending exit
```

The exit mode first checks that the journaled UUID still resolves while the panel is suppressed. If that check fails or the environment changes, it restores explicitly instead of deliberately exiting with suppression outstanding. Otherwise it exits after ten seconds without an enable call. Observe the result independently, then use `restore --journal work/exit.recovery.json` if required.

If reverse UUID resolution is unavailable while suppressed, do not remove that guard from ordinary crash recovery. First investigate addressability with a cooperative child while the original owner remains alive:

```sh
swift run solodisplay-lab probe --external EXTERNAL_ID --scope app --journal work/handoff.recovery.json --native-wired-attested --ending handoff
```

The parent releases its writer lock and starts its own recovery child. The child verifies the boot/session, actual parent PID, and absence of contradictory live target identity before using the target recorded by the live parent. It acquires the same writer lock. The parent may take over only after the child exits and the parent reacquires the lock. A child timeout is handled with bounded termination; failure to establish termination forbids a second writer.

Both processes subscribe to display reconfiguration callbacks, record process-specific observations, and keep callbacks free of display mutations. When the child reports successful restoration but the parent's observations disagree, the parent processes callbacks for a bounded verification interval. Continued disagreement is inconclusive; it does not trigger a duplicate enable request.

This proves neither after-crash identity nor automatic exit rollback. The current probe has no automatic crash/freeze mode. Those are separate experiments after the relevant recovery gates pass.

## 4. Native-owner cooperative handoff

The independent native observer received private-API off/on callbacks, but the earlier CLI owner disagreed with its recovery child. To isolate the owner event-loop question, Debug app builds now contain an explicit native-owner lab mode. Ordinary launches remain read-only. Release builds reject all native lab arguments.

First build the Debug app, then run this read-only entry-point check:

```sh
DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay --lab-check
```

This enters the normal app lifecycle, yields to AppKit, reports inventory, and exits without creating a journal or changing a display.

Only with the operator ready, both panels visible, an open lid, and a confirmed native wired external in extended mode:

```sh
DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay \
  --lab-handoff --external EXTERNAL_ID \
  --journal /ABSOLUTE/NEW/PATH/native-handoff.recovery.json \
  --native-wired-attested
```

Keep the read-only diagnostic instance open as a third observer. Do not unplug, close the lid, change mirroring, or sleep during this test.

The native owner journals ownership, disables under application scope, and yields to AppKit during the approximately ten-second interval. It then releases its writer lock and launches its own app executable as a child. The child validates the journal against its actual live parent, boot/session, and current target evidence before obtaining restoration through a session-scoped enable. Both processes have native app lifecycles and callback subscriptions.

The owner waits up to five seconds for the child. A timeout stops only that exact child and allows up to two seconds to establish termination. Owner fallback is forbidden until termination is established and the writer lock is reacquired. A child success followed by conflicting owner evidence allows verification only, not another enable. A failed child can trigger owner fallback; that outcome is not recorded as a successful handoff.

This mode does not deliberately exit or freeze the owner while suppression is outstanding. It is not an armed crash-recovery helper. Stalled OS calls can still exceed lab deadlines; unresolved errors remain failures, not visibility guarantees. Do not use it to test sleep or cable removal. The stricter ordinary after-crash UUID guard is unchanged.

## 5. Supervised normal-exit rollback

The earlier unsupervised exit command remains guarded by reverse UUID lookup. Do not remove that guard. The new Debug-only supervisor instead captures the target while active and stays alive throughout its actual writer child's lifetime.

Rehearse the IPC and journal handshake without display writes first:

```sh
DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay \
  --lab-exit-rehearsal --external EXTERNAL_ID \
  --journal /ABSOLUTE/NEW/PATH/exit-rehearsal.recovery.json \
  --native-wired-attested
```

Then, with the operator ready and the same open-lid, extended, native wired baseline:

```sh
DerivedData/Build/Products/Debug/SoloDisplay.app/Contents/MacOS/SoloDisplay \
  --lab-exit-supervised --external EXTERNAL_ID \
  --journal /ABSOLUTE/NEW/PATH/normal-exit.recovery.json \
  --native-wired-attested
```

The writer cannot disable before the supervisor acknowledges its journal against a fresh live baseline. After approximately five seconds of independently observed suppression, the supervisor authorizes normal writer exit without an enable. It then acquires the writer lock and watches for an active internal display for up to three seconds. If absent, it explicitly enables the previously witnessed panel and verifies the result. The output distinguishes rollback observed without enable from explicit supervisor restoration.

The supervisor allows at most one enable attempt. On coordination failure, it must establish writer termination before acquiring the lock and recovering. A responsive writer restores on lost contact or lease expiry. This is a bounded lab safeguard, not a validated persistent service, and OS stalls can exceed its deadlines. Do not unplug or sleep during this test.

The first run required explicit supervisor restoration. Do not label exit code 0 as an automatic rollback pass: it means the experiment completed, and its result label identifies the recovery path. Physical visibility and post-exit geometry still require separate checks.

## 6. Forced termination and stopped writer

The same supervisor supports separate Debug-only failure modes. Each requires the same explicit external ID, new absolute journal path, native-wired attestation, and operator presence as the normal-exit command.

- `--lab-exit-kill`: after five seconds of suppression, send SIGKILL only to the actual writer child. Require signal-termination status before lock acquisition and recovery.
- `--lab-exit-freeze`: after five seconds of suppression, send SIGSTOP to the actual writer. Verify the stopped event with `waitid` using `WSTOPPED | WNOWAIT | WNOHANG`, leaving termination reaping to Foundation. Keep the supervisor running for three seconds, then send SIGKILL and establish termination before recovery.
- `--lab-freeze-rehearsal`: exercise the stopped-process and termination path with all display writes disabled. Run this before the real freeze test.

The first real runs required explicit supervisor restoration after the three-second rollback-observation window. Both ended with active displays and the original logical arrangement. These are software-level recovery results, not proof of uninterrupted physical visibility or recovery from an uninterruptible OS call. SIGSTOP is not equivalent to every possible API stall.

Do not kill processes by name or reuse journal PIDs as signal targets. The lab signals only the `Process` instance it created during the current run.

## 7. Lost protection experiments

The Debug-only `--lab-contact-loss` and `--lab-lease-expiry` modes use the same required options as the supervised exit experiment. Their `-rehearsal` variants exercise processes and protocol with display writes disabled. Always use a new absolute journal path.

Contact loss closes the supervisor's command pipe after five seconds. Lease expiry leaves the pipe open but silent until the writer's ten-second lease expires. In both cases the responsive writer must restore locally, exit through its failure path, and the supervisor must independently verify restoration without enabling the panel itself. Supervisor fallback makes an unsuccessful experiment safer but is not a pass for these scenarios.

These modes keep the supervisor alive. They do not establish behavior when that process is killed, when both processes fail, or when the external is unplugged. Keep the external connected, the lid open, and the session awake throughout.

## 8. Last external unplugged while suppressed

`--lab-unplug-rehearsal` runs a synthetic external-loss trigger with display writes disabled. `--lab-unplug` runs the physical test. Both require the usual external ID, fresh absolute journal path, native-wired attestation, open lid, awake foreground session, and an extended baseline with exactly one external display.

After suppression is observed, `unplug-now-window-open` marks a 40-second window for the operator to remove the USB-C cable. Keep the lid open and do not sleep or change mirroring. External absence revokes the writer's protection by closing its command pipe. The writer restores locally; the supervisor waits up to five seconds for exit and independently verifies the internal panel. Failure takes the existing confirmed-termination and lock-protected fallback path. No cable removal before the deadline is an aborted experiment, not a pass. The writer also has an independent 45-second lease.

The operator should report physical internal-screen recovery before reconnecting. If the internal remains dark for several seconds, reconnect the external cable rather than waiting without a visible screen. A successful software report does not prove physical visibility. Reconnection is observed separately, after the writer has exited; this harness never automatically suppresses again.

## 9. Later matrix

| Scenario | Required observation |
| --- | --- |
| Start mirrored with the internal dimmed | Recognize the incoming state. In a dedicated experiment, verify mirror source, resolution, and layout survive off/on and recovery. Do not automatically rewrite the arrangement. |
| One external disconnects while another remains | No unnecessary suppression toggle if fresh eligible evidence remains. |
| Last external disappears | Restore the owned panel without a disabling debounce. |
| Sleep docked, wake undocked | Open internal panel becomes usable; manual request stays cleared. |
| Sleep undocked, wake docked | Automatic mode waits for fresh stable evidence. |
| Lid closes before the cable is removed | Preserve normal sleep; recover when opened elsewhere. |
| Screen sleep, lock/unlock, logout, user switching | Do not fight OS ownership or demand a lit sleeping panel. |
| Controller freezes or API stalls | Demonstrate takeover without concurrent writers, potentially using a helper. |
| Helper fails | Responsive controller restores and suspends disabling. |
| Other app changes the panel | Pause instead of repeatedly overriding it. |
| Missing internal panel, virtual or mirrored topology | No disable request. |
| Journal is stale, truncated, or unwritable | Refuse a new disable request or invalid recovery target. |

## Passing a gate

Record the software commit, exact experiment, observed behavior, API results, and whether recovery required intervention. Keep untested configurations explicit. A failure changes the assumption ledger and gets a replay fixture or adapter contract test before adding a workaround.
