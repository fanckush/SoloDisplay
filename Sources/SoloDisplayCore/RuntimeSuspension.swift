/// Sleep notifications suspend failure detection, but cannot disable it indefinitely. Two
/// seconds of executing timer callbacks are independent evidence that the process can run.
/// This resumes only protocol liveness, never display eligibility or user intent.
struct RuntimeSuspension: Equatable, Sendable {
  private(set) var suspended = false
  private var firstActivity: Instant?
  mutating func suspend() {
    guard !suspended else { return }
    suspended = true
    firstActivity = nil
  }

  @discardableResult mutating func resume() -> Bool {
    let changed = suspended
    suspended = false
    firstActivity = nil
    return changed
  }

  mutating func observesActivity(at now: Instant) -> Bool {
    guard suspended else { return false }
    guard let firstActivity else {
      firstActivity = now
      return false
    }
    // A single delayed callback is not a wake. Require another execution after the interval.
    return now >= firstActivity && now - firstActivity >= 2000
  }
}
