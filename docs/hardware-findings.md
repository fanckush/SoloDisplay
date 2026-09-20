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

## External brightness

- **DDC/CI brightness works on the Dell U3223QE over direct USB-C** (spike, 2026-09-17). The
  private `IOAVServiceWriteI2C` and `IOAVServiceReadI2C` calls reached it through the one
  `DCPAVServiceProxy` with `Location = External`. `solodisplay-lab ddc get` read 68 out of 100.
  `ddc set 60` took effect, a later read agreed, and setting 68 restored it. Requests used the
  standard checksum that includes the 0x51 source address. Docks, HDMI, and other monitors are
  untested.

## What the monitor is showing

- **A monitor switched to another machine keeps its link to this Mac up** (2026-09-19). The Dell
  U3223QE showing a PC over DisplayPort still enumerated in CoreGraphics, still charged over
  USB-C, and still answered DDC. Nothing in a display reading distinguishes it from a monitor
  showing this Mac, which is why the app used to turn the laptop screen off and leave nothing
  visible anywhere.
- **VCP 0x60 answers the question, on this monitor.** Replies captured while switching inputs:

  | Showing | Reply | `current` |
  |---|---|---|
  | This Mac, USB-C | `6E 88 02 00 60 00 1B 1B 1B 1B D4` | `0x1B1B` |
  | The PC, DisplayPort 1 | same with `SL = 0x0F` | `0x1B0F` |
  | HDMI 1 | same with `SL = 0x11` | `0x1B11` |

  The low byte is the input on screen. The high byte stayed `0x1B`, the input this Mac is wired
  to, through all three. Comparing the two bytes answers it with no calibration.
- **The high byte is not in the standard.** MCCS defines only the low byte and leaves the high
  byte reserved, so `0x00` there is what a monitor following the standard returns. It is read as
  unknown, never as disagreement. The risk accepted knowingly: a monitor that fills the high byte
  with some other constant that never equals its selected input would be refused for ever. That is
  visible in the menu and All Monitors still works, so it is not the silent failure it replaces.
- **Not every monitor does DDC at all** (2026-09-19). A second monitor, with DDC/CI enabled in its
  own menu, acknowledged the bus and returned a null message (`6E 80 ...`) to every request,
  brightness included. It never reaches a verdict and is left exactly as it was before.
- **The selected input is reported even with no cable on it.** Choosing an empty DisplayPort still
  answered `0x0F`, which is right: an empty selected input is still not this Mac.
- **One exchange failed during a switch** and the next succeeded, so a single silence is never
  acted on.
- **A monitor can still be asked while its display is disabled** (2026-09-19, probe). With the
  external turned off through `SLSConfigureDisplayEnabled`, CoreGraphics stopped listing it
  entirely, but its `DCPAVServiceProxy` remained and both a fresh and an already open connection
  read `0x1B1B`. So turning an invisible external off would not cost the evidence needed to turn
  it back on, provided the monitors are enumerated through IOKit. `answerableControllers` goes
  through `CGGetOnlineDisplayList` and did go blind, so it is the wrong enumeration for that.
  The controller-to-display correlation also has to be remembered from before the display was
  disabled, since transport classification needs a CoreGraphics display to correlate.
- **Turning off a monitor other screens mirror collapses the mirror rather than blanking them**
  (2026-09-20, probe). With the laptop panel following the Dell, disabling the Dell left the
  panel `active`, `main`, and out of the mirror set within 1.5s, and it stayed that way. Turning
  the Dell back on restored the mirror exactly as it was, the panel following it again. So a
  follower counts as a screen that will still be there afterwards, and the rule worth enforcing
  is that something visible remains rather than that nothing may follow. Measured on one Mac with
  one monitor: a follower that is itself an external is untested.
