# Hardware findings

What this Mac has shown about the display stack, and why each finding still shapes the design.
Tested on one MacBook with a direct USB-C Dell monitor, macOS 26. `validation.md` is the full
chronological record of the earlier experiments.

## The private call

- **Turning the panel off works through `SLSConfigureDisplayEnabled` inside a CoreGraphics display
  transaction.** It is private API. Finding the symbol is not proof it does what it claims, which is
  why every change is judged by a later reading.
- **A session-scope change outlives the process that made it** (spike, 2026-09-14). A one-shot
  process turned the panel off and exited, and the panel stayed off for the full 30 seconds checked.
  A separate process then turned it back on, and the mirror arrangement came back unchanged. This is
  what lets every change run in a disposable worker.
- **Nothing restores the panel promptly when the writer exits with application scope** (earlier lab
  runs). Something has to bring the screen back if SoloDisplay dies. That is the guardian.

## Identity while the panel is off

- **An off panel disappears from the online display list entirely** (2026-09-14). A reading cannot
  tell "off" from "absent" on its own, so an absent panel counts as off only while the record names
  it, in the same boot and login.
- **The panel's UUID can stop resolving to its display ID while it is off** (earlier lab runs). The
  record therefore keeps the display ID, and an enable by that ID worked while the panel was absent
  (2026-09-14).

## Calls can block

- **During sleep** (incident, 2026-09-10). A restore started on `willSleep` never returned. No change
  starts around sleep any more, and no call runs in a long-lived process.
- **During a hotplug** (2026-09-14, 13:21). On unplug, the restore brought the panel back within
  152 ms, but the call did not return within 3 seconds. The old design killed the controller over a
  change that had already worked. Now a hung worker is killed and the next reading shows the change
  landed.
- **Display reads can stall too.** They usually take 30 to 70 ms, but once during a plug-in no reading
  completed for about 5 seconds (2026-09-12). Readings have their own lane and never gate a decision
  on a deadline.

## Timing around a plug-in

- **macOS finishes its own plug-in reconfiguration in roughly 300 to 600 ms**, and reports it through
  CoreGraphics reconfiguration callbacks (2026-09-12). After those callbacks the arrangement stayed
  quiet until SoloDisplay acted, which is why settling ends 500 ms after the last callback.
- **Callbacks can reach one process a few hundred milliseconds later than another**, so settling is
  timed from the reports this process actually received.

## Liveness

- **A process can stop running for about 5 seconds without sleep or a crash** (2026-09-14, 11:26).
  The cause is unknown. The old heartbeat lease expired and the helper killed the controller while
  the screen was off with a monitor connected, which was not dangerous. The guardian now acts only on
  a gone app or on danger, never on silence.

## Lid, sleep and mirroring

- **Closing the lid releases the suppression**, and opening it allows turning off again (product path
  pass, earlier builds).
- **An internal panel following an external mirror source reports itself inactive.** That is
  presence, not suppression. Off and on through the product preserved the mirror relationship and
  geometry (earlier product passes, and the 2026-09-14 spike).
- **Screen lock and display sleep invalidate nothing**, so a suppressed panel is simply kept off
  (earlier product path pass).
