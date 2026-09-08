import AppKit
import Darwin
import Foundation
import LidlessCore
import LidlessPlatform

/// Why display control is unavailable, in the words the menu shows. Availability is proven,
/// never assumed: every path that cannot establish protection lands here.
nonisolated enum ProductionAvailability: Equatable {
  case unavailable(String)
  case protectedIdle

  var explanation: String? {
    switch self {
    case .unavailable(let reason): reason
    case .protectedIdle: nil
    }
  }
}

/// The supervising process. It owns no user interface, never disables a display, and can only
/// restore the one panel a durable record says this installation turned off.
@MainActor
final class HelperRuntime {
  private let store: ProductionJournalStore
  private let executable: URL
  private var instanceLock: SessionWriterLock?
  private var controller: Process?
  private var link: ProtectionLink?
  private var protection: HelperProtection
  private var takeover = RecoveryTakeover()
  private var timer: Timer?
  private var recovering = false
  private var witnessedAt: Instant = 0

  init(executable: URL, store: ProductionJournalStore) {
    self.executable = executable
    self.store = store
    protection = .init(at: Self.now())
  }

  static func now() -> Instant { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }

  func start() async {
    let reading = DisplayObserver.read()
    guard let loginID = reading.loginID else {
      report("Lidless cannot identify this login session, so it will not change any display.")
      NSApp.terminate(nil)
      return
    }
    do {
      instanceLock = try SessionWriterLock(loginID: loginID, name: "instance")
    } catch {
      // Another Lidless pair already owns this GUI session. Two supervisors is worse than one.
      report("Lidless is already running in this login session.")
      NSApp.terminate(nil)
      return
    }
    await reconcileAtLaunch(reading)
    launchController()
    let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pump() }
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  /// Unresolved ownership is resolved before any controller runs, so a new run can never
  /// start while an earlier one may still have the internal panel turned off.
  private func reconcileAtLaunch(_ reading: PlatformReading) async {
    let reconciliation = store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays)
    switch reconciliation {
    case .clean:
      return
    case .retained(let reason):
      report(reason)
    case .priorSession(let record):
      // A restart or new login already restored the panel. Confirm that before forgetting it.
      guard reading.displays.contains(where: { $0.builtIn && $0.active }) else {
        report(
          "Lidless kept an unresolved record from a previous startup because it cannot see an active internal display."
        )
        return
      }
      try? store.clear()
      report("Lidless cleared an unresolved record from a previous startup. Nothing was changed.")
      _ = record
    case .unresolved(let record):
      await restore(record, reason: "unresolved ownership from an earlier run")
    }
  }

  private func launchController() {
    let commands = Pipe()
    let replies = Pipe()
    link = ProtectionLink(
      input: replies.fileHandleForReading, output: commands.fileHandleForWriting)
    let child = Process()
    child.executableURL = executable
    child.arguments = [ProductionLaunch.controllerArgument]
    child.standardInput = commands
    child.standardOutput = replies
    do { try child.run() } catch {
      report("Lidless could not start its controller process: \(error)")
      NSApp.terminate(nil)
      return
    }
    // Close the duplicate child-side handles so EOF really means the peer is gone.
    try? commands.fileHandleForReading.close()
    try? replies.fileHandleForWriting.close()
    controller = child
  }

  private func pump() {
    guard let link else { return }
    let now = Self.now()
    // The helper's own view of the panel, taken independently of anything the controller says.
    if now - witnessedAt >= 1_000 {
      witnessedAt = now
      let reading = DisplayObserver.read()
      apply(protection.receive(.witness(reading.internalTarget), at: now))
    }
    do {
      while let message = try link.poll() {
        apply(protection.receive(.received(message), at: now))
      }
    } catch {
      apply(protection.receive(.peerFailed(.disconnected), at: now))
    }
    if controller?.isRunning == false, !recovering {
      apply(protection.receive(.controllerExited, at: now))
    }
    apply(protection.receive(.tick, at: now))
    if controller?.isRunning == false, !recovering {
      // Nothing is owned and nothing is running. The supervising process has no work left.
      timer?.invalidate()
      NSApp.terminate(nil)
    }
  }

  private func apply(_ outputs: [HelperProtection.Output]) {
    for output in outputs {
      switch output {
      case .send(let message): try? link?.send(message)
      case .standDown: break
      case .recoveryRequired(let ownership, let reason):
        guard !recovering else { continue }
        recovering = true
        Task { @MainActor in await self.takeOver(ownership, reason: reason.rawValue) }
      }
    }
  }

  /// Stop the actual controller child, prove it is gone, take the writer lock, and only then
  /// consider a restore. Message content alone never reaches the display API.
  private func takeOver(_ ownership: Ownership, reason: String) async {
    guard let child = controller else { return }
    takeover.receive(.recoveryNeeded)
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    guard await awaitExit(child, seconds: 3) else {
      takeover.receive(.failed)
      report("Lidless could not confirm its controller stopped, so it changed no display.")
      return
    }
    takeover.receive(.writerTerminationConfirmed)
    guard case .unresolved(let record) = currentReconciliation(), record.target == ownership.target
    else {
      // The responsive controller already restored and cleared its own ownership.
      takeover.receive(.failed)
      report("Lidless found nothing left to restore after \(reason).")
      timer?.invalidate()
      NSApp.terminate(nil)
      return
    }
    await restore(record, reason: reason)
    timer?.invalidate()
    NSApp.terminate(nil)
  }

  private func currentReconciliation() -> JournalReconciliation {
    let reading = DisplayObserver.read()
    return store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays)
  }

  private func restore(_ record: ProductionRecord, reason: String) async {
    let lock: SessionWriterLock
    do {
      // Acquiring the writer lock is the evidence that no live writer owns this session.
      lock = try SessionWriterLock(loginID: record.target.loginID)
    } catch {
      takeover.receive(.failed)
      report("Another display writer holds this session, so Lidless changed no display.")
      return
    }
    defer { lock.release() }
    if takeover.phase == .watching {
      // Launch reconciliation: no controller child exists yet, and holding the exclusive writer
      // lock is what establishes that no live writer owns this session. Takeover from a running
      // controller reaches here already past this step, with a confirmed termination behind it.
      takeover.receive(.writerTerminationConfirmed)
    }
    takeover.receive(.lockAcquired)
    let reading = DisplayObserver.read()
    guard
      (try? RecoveryIdentity.checkCurrentDisplays(reading.displays, target: record.target))
        != nil, reading.bootID == record.target.bootID, reading.loginID == record.target.loginID
    else {
      takeover.receive(.failed)
      report("Live display evidence contradicts Lidless's record, so it changed no display.")
      return
    }
    guard takeover.receive(.restoreAuthorized) == [.restore] else {
      takeover.receive(.failed)
      report("Lidless refused an out-of-order recovery write.")
      return
    }
    // Session scope: this process did not make the change it is undoing.
    do {
      try PrivateDisplayAPI().setEnabled(
        true, displayID: record.target.displayID, scope: .forSession)
    } catch {
      report("Lidless requested restoration and will verify it: \(error)")
    }
    takeover.receive(.restoreReturned)
    guard await verifyRestored(record.target) else {
      // An unverified restoration keeps the record. It is not reported as a success.
      takeover.receive(.failed)
      report("Lidless could not confirm the internal display came back on after \(reason).")
      return
    }
    takeover.receive(.restorationVerified)
    do {
      try store.clear()
      takeover.receive(.journalCleared)
      report("Lidless restored the internal display after \(reason).")
    } catch {
      takeover.receive(.failed)
      report("Lidless restored the internal display but could not clear its record: \(error)")
    }
  }

  private func verifyRestored(_ target: PanelTarget) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    repeat {
      try? await Task.sleep(for: .milliseconds(100))
      let reading = DisplayObserver.read()
      // A mirrored follower is never reported active, so requiring that would make a correct
      // restoration look like a failure and keep the record forever.
      if reading.displays.contains(where: {
        $0.id == target.displayID && $0.builtIn && $0.uuid == target.displayUUID && $0.online
          && !$0.asleep && ($0.active || $0.mirrorSourceID != nil)
      }) {
        return true
      }
    } while ProcessInfo.processInfo.systemUptime < deadline
    return false
  }

  private func awaitExit(_ child: Process, seconds: Double) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return !child.isRunning
  }

  private func report(_ message: String) {
    FileHandle.standardError.write(Data("Lidless helper: \(message)\n".utf8))
  }
}
