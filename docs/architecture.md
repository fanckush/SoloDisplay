# Architecture

## What SoloDisplay does

SoloDisplay turns off one positively identified built-in laptop panel while a native external
monitor is connected, and turns it back on when that stops being true. It does not change
external displays, brightness, mirroring, or sleep settings.

There are two stored choices. **All Monitors** keeps the laptop screen on. **External Only** keeps
it off whenever a usable monitor is there. The choice is intent, not a reading of the hardware:
External Only stays chosen while no monitor is connected. Launch at Login defaults to off.

User-facing copy and project documentation do not use em dashes.

## Principles

The design handles uncertainty by deciding from observed state, not by timing operations.

1. **Truth comes from readings, not from calls.** A display call's return, error or hang says
   nothing about the outcome. Only a reading taken after the call ended does.
2. **Nothing that can block runs in a long-lived process.** Every private display call runs in a
   one-shot worker process. A worker that does not finish is killed, and that only means "not done
   yet": the next reading decides, and a retry follows after a backoff.
3. **Recovery acts on danger or certainty, never on lateness.** Danger is the laptop screen off
   with no usable monitor. Certainty is the app process being gone, which the kernel reports by
   closing a pipe. Nothing kills the app, and nothing quits after recovering.
4. **Level-triggered, no sticky faults.** Every event leads to the same comparison of what is
   wanted with what is observed. A problem is shown while it lasts and clears itself. Try Again
   only skips the backoff.

These replace an earlier design built on operation phases, deadlines, a heartbeat lease between
two processes, and faults that waited for Try Again. Each of its failures in September 2026 was
two timers disagreeing; see `hardware-findings.md`.

## Processes

All three roles are the same app executable. `ProductionLaunch.role` selects one from the launch
arguments, and a child role is accepted only with inherited pipes on its standard streams.

- **App** (a normal launch). The menu bar, the controller, and the platform coordinator. It holds a
  per-login `instance` lock, so a second copy exits.
- **Guardian** (`--solodisplay-guardian`). Started by the app before the laptop screen is turned off,
  and exists only while it may be off. It reads its panel identity from one request line, holds a
  per-login `guardian` lock, and replies `ready`. Once a second it takes a reading and applies
  `GuardianPolicy`: restore at once if the app is gone, restore after two readings in a row that
  show the screen off with no usable monitor, and exit once the app is gone and the screen is on.
  `release` from the app means nothing is owed and it exits. It never signals the app.
- **Display worker** (`--solodisplay-worker`). Makes exactly one change for its parent. It reads a
  request, rechecks it against a fresh reading, calls the private API with session scope so the
  change outlives it, and exits. `SoloDisplayApp.init` runs it before any AppKit setup.
- **Read-only** (`--solodisplay-unprotected`). The diagnostics window with display control
  unavailable. UI automation uses it.

Quitting does not wait for anything. If a guardian is running, it sees the app go and restores the
screen, the same path as a crash or a force quit.

A guardian from an earlier app still holds its lock while it restores. A new app's guardian cannot
start until that lock is free, so the new app keeps the screen on and retries after a backoff.

## Controller

`Controller.reduce(state, event, at:)` in `SoloDisplayCore` is synchronous and deterministic. It
cannot call macOS, read a clock, sleep, or touch storage. It returns the next state and effects.

After updating what it knows, every event runs the same two steps:

- **`desired`** says what the laptop screen should be, or nothing when no change should be made
  right now: the Mac is asleep, the lid is closed, another user is in front, the panel cannot be
  identified, or a new arrangement is still settling. External Only wants the screen off only when
  a usable native monitor is present in a supported arrangement. A screen that is off is never kept
  off without a guardian.
- **`act`** requests only the next missing step. Turning off needs the record written, then a
  guardian ready, then a disable worker, each once the step before it has landed. Turning on needs
  only an enable worker. When the screen is on and staying on, the guardian is released and the
  record is cleared.

A finished worker is judged only by a reading sampled after it finished. If the screen did not
reach the wanted state, `failures` counts up and the next attempt waits 0.5, 1, 2, 5, 10, then 30
seconds. Three misses in a row are shown in the menu; attempts continue regardless.

**Settling.** Turning off needs two readings at least 500 ms apart that agree, and a settled
arrangement. When macOS reported a display reconfiguration that explains the arrangement, it is
settled once a reading taken 500 ms after the last report still agrees, or after 5 seconds if
reports keep coming. Any other change, such as the lid or session, waits the full 2 seconds. The
controller asks for a reading at exactly the moment settling could complete. Turning back on never
waits to settle.

**Sleep.** `willSleep` and `waking` hold everything until a fresh reading shows the Mac awake. No
worker starts in between. A worker already running is left alone, and the next reading decides.

**The record.** `ProductionJournalStore` keeps one record naming the panel that may be off, with its
boot and login identity. It is written before a guardian or worker is started, and cleared once the
screen is observed on. While a record exists, a missing panel reads as SoloDisplay's own
suppression. Writing the same panel again succeeds. A record from another boot or login is replaced.
At launch, a record from this session is taken over, and any other leftover is cleared once the
built-in panel is visibly on; otherwise turning off waits until the person makes the panel
identifiable and chooses Try Again.

`Controller.presentation` projects state for the menu: what was chosen, whether the screen is off,
whether a change is under way, any lasting trouble, and why the screen cannot be off right now.

## Platform

- `DisplayObserver` performs read-only CoreGraphics, IOKit and GUI-session queries.
  `ControllerObservation` normalizes a reading. It never guesses that a display it cannot see is off
  unless the record names it.
- `DisplayTransportClassifier` counts an external as native only when it correlates to a display
  service on the SoC display pipeline. An internal panel following one present external mirror
  source is supported; an internal mirror source is not.
- `ProductionCoordinator` runs the reducer on the main actor, one event at a time. Readings,
  storage, and workers each have their own serial lane, so a slow one delays only itself.
  `DisplayEventMonitor` delivers CoreGraphics reconfiguration callbacks immediately, and a timer
  drains them as a fallback.
- `PrivateDisplayAPI` is the only caller of the private SkyLight call, inside a CoreGraphics
  display transaction. Only the display worker uses it.
- `RecoveryIdentity` decides whether an enable may address a target: a positively different
  identity blocks it, and an absent panel is addressable only by the process that turned it off.

## Diagnostics

Operational events are typed, identity-free JSON written to the unified log under subsystem
`dev.solodisplay.SoloDisplay`. Export Diagnostics saves up to a day of that history, with run and
session identifiers replaced by export-local aliases, together with a snapshot of the current
controller state that carries no display, boot or session identity. Nothing is uploaded.

The diagnostics window is a read-only view of readings and callbacks.

## Tests

Controller behavior is tested as event sequences in `Tests/SoloDisplayCoreTests`, including
settling, backoff, sleep, and guardian rules. `ProductionCoordinatorTests` runs the real coordinator
against fake readings, storage, guardian and worker. App tests cover the menu wording, launch roles,
and the worker's request checks and kill. Hardware behavior is established separately, by the
passes recorded in `status.md`.
