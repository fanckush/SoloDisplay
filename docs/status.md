# Implementation and validation status

Updated 2026-09-14. `architecture.md` describes the current design and `hardware-findings.md` the
hardware behavior it depends on. `validation.md` is the chronological evidence record of earlier
experiments.

Statuses are not interchangeable. **Implemented** means the code exists. **Automatically
verified** means tests exercise it without a person present. **Hardware verified** means a guided
physical test passed with user-confirmed visibility.

## State-driven control (current)

Implemented and automatically verified on 2026-09-14. It replaces the helper, heartbeat lease,
operation phases and sticky faults, after two unexpected quits on 2026-09-14 and a save timeout on
2026-09-12, each caused by timers disagreeing.

- One app process decides from readings. A guardian child exists only while the laptop screen may
  be off, and every display change runs in a one-shot worker that can be killed.
- The guardian restores the screen when the app is gone or when the screen is off with no usable
  monitor. It never stops the app. Nothing quits after recovering.
- Failures back off and clear themselves. Three misses in a row are shown in the menu.
- Settling ends 500 ms after macOS stops reporting a reconfiguration, capped at 5 seconds, and
  otherwise waits 2 seconds.
- The experiment labs, probe, replay trace and shadow controller were removed. `solodisplay-lab`
  keeps only the read-only `observe` command.

Size: about 4,400 lines of app code (core 541, platform 1,908, app 1,948), down from about 8,400.
Tests: about 1,900 lines, down from about 4,500.

**Automated verification:** 75 package tests and 28 app tests pass, and lint is clean. The Debug app
builds.

**Hardware verified:** only the Step 0 spike. A session-scope turn-off from a one-shot process stayed
off for 30 seconds after that process exited, and a separate process turned the panel back on with
the mirror arrangement preserved. No product-path hardware pass has been run on this design yet.

**Hardware pass still needed:** plug in and unplug several times; unplug for minutes while off;
sleep while off, both waking connected and unplugging before wake; close and open the lid; quit while
off; force quit the app while off; kill the guardian while off; relaunch with a leftover record;
mirrored setup. Success means the app never quits on its own and the screen is never left off
without a monitor.

## Documents about the earlier design

`sleep-recovery-incident.md`, `recovery-followup.md`, `shutdown-diagnostics.md`, `original-plan.md`
and `PLAN.md` describe the helper and lease design and its lab experiments. They are kept as history.
Their findings that still apply are summarized in `hardware-findings.md`.

## Earlier hardware matrix (previous design)

Evidence for the builds it was recorded against, not for the current design.

| Scenario | Evidence |
| --- | --- |
| Explicit internal off/on | Passed, including user-confirmed visibility |
| Normal writer exit | No prompt automatic rollback observed; supervisor restored |
| Unplug last external while internal is off | Passed on a direct USB-C setup; user confirmed physical visibility |
| Reconnect after that recovery | Passed; user confirmed both screens and the original arrangement |
| Sleep while internal is off, wake with USB-C connected | Passed; user confirmed internal off before sleep and both on after wake |
| Sleep while internal is off, disconnect external before wake | Passed; user confirmed internal usable with cable still out |
| Mirrored external-source and internal-follower off/on | Passed; mirror relationship and geometry restored |
| Extended off/on through the product menu | Passed; exact geometry preserved |
| Lid closure and opening, product path | Passed; closing released the suppression, opening allowed it again |
| Screen lock, display sleep, unlock, product path | Passed; nothing invalidated, the panel never flashed back on |
| Normal quit while suppressed, product path | Passed; restored and exited |
| Internal panel as the mirror source | **Not tested.** The topology classifier refuses it |
| Multiple externals and dock changes | **Not tested.** No second external or dock available |
| Fast user switching and logout | **Not tested.** Needs a second account |
