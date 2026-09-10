# Recovery lifecycle follow-up

This document records the earlier revision. Its impending-sleep write and
timer-activity fallback were superseded after the 2026-09-10 sleep-transition
incident. See `sleep-recovery-incident.md` for the replacement invariants.

## Scope

Addresses three findings in the review of `9564cfa`: exhausted retries during temporary unavailability, helper exit before deferred recovery, and indefinitely suspended heartbeat expiry after a missed wake notification. Earlier hardware results are retained in `validation.md` and `status.md`.

## Design

The controller emits `restoreDeferred` only when no display call was made. It refunds that reserved attempt, retains ownership, and waits for a newer observation before retrying. A short resampling interval prevents synchronous adapters from creating an immediate retry loop. Real API errors still consume the bounded retry budget and require verification.

`RecoveryContinuation` owns one helper recovery's waiting, writing, verification, and journal-clearing phases. The production helper enters it only after writer termination and exclusive lock ordering have been established. It holds the lock across waits and repeats identity checks on the actual writer lane. Missing evidence waits; positive identity contradictions block. Neither case creates permission to guess a target. A returned call is verified rather than repeated blindly. An unobservable verification interval does not count against its visibility deadline.

`RuntimeSuspension` separately reconciles protocol liveness. After two timer executions at least two seconds apart, a suspended role resumes heartbeat checking even if no workspace wake event arrived. This is evidence of process execution, not screen availability. The controller still requires a fresh challenge acknowledgement and separate display eligibility before disabling. A helper with no valid subsequent heartbeat expires its lease normally.

## Verification

- Package suite: 142 tests passed.
- Native suite: 49 tests passed, including the actual helper recovery routine with a fake writer and a real isolated lock.
- Debug app: built successfully.
- Release app: built successfully with local ad-hoc signing.
- No display-changing experiments were run for this revision.

Targeted physical confirmation remains: suppressed lid close/open; interrupted GUI-session recovery; takeover while restoration cannot yet be attempted; and sleep/wake recovery through the revised product path. Missing-notification behavior is tested deterministically, since an ordinary physical sleep test cannot prove how a dropped notification would behave.

## Limits

An unresponsive OS call is not cancelled by a timeout. Failure of both processes can discard live authority, so a cold journal alone still cannot authorize a write to an absent panel. A permanent identity contradiction or failed visible verification remains unresolved rather than being reported as recovery. These changes do not establish universal blackout prevention or replace the historical hardware matrix with a new one.
