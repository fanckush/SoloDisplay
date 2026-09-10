# Sleep-transition recovery incident

## What happened

On 2026-09-10, Lidless had successfully disabled the internal panel. At 00:16:32,
macOS delivered `willSleep` and the controller immediately started a restore. The
private display call never returned. At 00:16:34, normal timer callbacks were
mistaken for sufficient wake evidence by the liveness fallback. At 00:16:36, the
helper classified the controller operation as stalled, terminated the controller,
confirmed its exit, acquired the writer lock, and then called the same private API
inside the helper. That call also never returned.

The resulting process state was internally consistent but operationally broken:
the controller and its menu were gone, the helper was alive and held the per-login
instance lock, the ownership journal remained, and a new launch exited because an
instance already existed. The internal panel remained suppressed.

## Violated invariants

The split-process design was intentional so the supervisor could outlive a failed
controller. Three missing invariants made that split unsafe:

- Executing a timer callback proves only that user-space code ran. It does not prove
  that sleep ended or that the display stack accepts writes.
- The supervisor cannot be the recovery boundary if it enters the same potentially
  blocking API as the process it supervises.
- A live supervisor with no controller and unresolved ownership must be visible and
  actionable. Holding the instance lock invisibly is not an acceptable state.

## Replacement design

`willSleep` closes a generation-based write gate. Waking leaves it closed until an
explicit wake signal is followed by a fresh usable display observation. A closure
queued under an earlier generation stays invalid even after the gate reopens.
Ownership and the durable record survive the transition. Automatic intent cannot
disable again until restoration has been observed, verified, and cleared.

The helper performs recovery through a one-shot worker process. The request is
versioned, bounded, tied to the actual parent PID, restricted to enabling the exact
journaled panel, and revalidated by the worker. The worker inherits a duplicate of
the helper's exact locked file description, so there is no competing-writer window.
After three seconds the helper sends `SIGKILL` to the exact worker and confirms its
exit. If the OS cannot terminate it immediately, the worker's inherited lock still
excludes every other writer. A timed-out or failed worker leaves the journal intact
and the helper alive.

Whenever the controller is absent and recovery is unresolved, the helper changes
from normally hidden to a warning status item. It shows recovery state, diagnostics,
and an explicit retry action. Only clean ownership permits the helper to hide itself
and launch a new controller.

## Guarantee boundary

No user-space architecture can guarantee that a private OS or driver call will
succeed. This design instead guarantees that such a call does not run inside the
only long-lived recovery process. If the platform refuses every recovery attempt,
the panel can remain unavailable, but Lidless retains its evidence and a responsive,
visible control plane rather than silently wedging.
