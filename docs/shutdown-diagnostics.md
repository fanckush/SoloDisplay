# Shutdown diagnostics

Implemented 2026-09-09. This change adds evidence, not a new display-control policy.
The earlier unexplained disappearance cannot be diagnosed retrospectively from
logs that were not recorded.

## Operational events

`OperationalEventSink` accepts typed, allowlisted events. The production adapter
uses macOS Unified Logging under `dev.lidless.Lidless` with lifecycle, protection,
recovery, and diagnostics categories. Notice/error events remain enabled in
Release. The pure protection reducers expose diagnostic reasons and timing but
perform no logging or asynchronous work.

Each process has a random run identifier; the validated pairing session links
controller and helper records. These are correlation tokens, not recovery
authority. No display identifiers, boot/login identifiers, serials, paths, or
arbitrary error descriptions enter this stream. Version/build strings are bounded
and restricted to numeric version syntax. Unknown or malformed messages are not
copied into exports.

The runtime records startup, actions, changes in observed eligibility, lifecycle
notifications and fallback reconciliation, protection failures, display-call
start/return, verification, journal outcomes, and exit decisions. Repeated
observations and heartbeats are not persisted. Watchdog evidence includes the
outstanding operation and deadline, last-progress age, and controller lease
challenge details when available.

An exit request is not proof of exit. The helper separately records the actual
child's termination reason and status once termination is observed. Takeover logs
put that confirmation before writer-lock acquisition. Display-call return is
distinct from observable restoration and successful journal clearing. Failed
verification retains ownership and never emits successful recovery.

Logging does not flush or wait for durable delivery. No diagnostic result grants
display authority or changes a timeout, lease, recovery decision, or writer lock.

## Export

Export Diagnostics collects a snapshot of the current replay and best-effort
system-log history on a background task. A restrictive subsystem/category filter
selects the preceding 24 hours, newest first; the resulting export is chronological.
Iteration has a five-second cooperative budget and fixed record/byte limits.
The OS store creation/enumeration calls themselves are not cancellable; they never
run on the protection event loop. Only one export runs at a time.

The JSON keeps the original `schemaVersion`, `initial`, and `events` fields for
existing replay readers, adding a versioned `diagnostics` section with collection
time, requested interval, status, truncation, rejected-entry count, and history.
History statuses are collected, empty, unavailable, or failed. Empty never means
that no incident occurred. Timestamps use Foundation's JSON Date representation,
seconds since 2001-01-01 UTC; event uptime values are monotonic milliseconds.

History retains at most 2,000 events and 500 KB. The replay retains at most 8,000
events and 4.45 MB, leaving framing/metadata space within the combined 10,000-event,
5 MB ceiling. Evicting old replay events advances the initial state so replay
semantics survive. Both process and pairing tokens become export-local aliases.

macOS can deny system-log access. The app still saves the replay, explains missing
history, and supplies Console instructions. Encoding or file-write failures show
an error instead of silently succeeding. No shell fallback, uploads, privilege
prompts, app-owned log files, or recovery-journal changes are involved.

## Verification

- Package tests cover typed privacy filtering, distinct protection-loss reasons,
  timing evidence, history failures, export limits and replay compatibility,
  write failures, and actual normal/signal child termination with one-time reporting.
- Existing isolated process scenarios retain their safety assertions and now also
  assert structured stalled-operation evidence and termination/lock ordering.
- Native tests use the real helper recovery loop with an injected observer, fake
  writer, isolated journal and lock, and captured events. They check deferred
  recovery ordering and blocked recovery without a false success event.
- Debug and Release builds pass. A separate optimized `lidless-probe
  diagnostics-smoke` process emitted startup and intentional-exit events, then
  terminated. `diagnostics-history` retrieved both from the system store afterward
  on this Mac. This establishes this account's retrieval capability, not universal
  availability or guaranteed retention.

No display-changing tests or normal automatic-mode launch were performed for this
change. A frozen or abruptly killed process cannot reliably emit a final event.
Its surviving helper can record observations, but simultaneous process failure,
OS failure, dropped entries, and expired retention can still leave incomplete
evidence.
