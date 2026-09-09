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
  private var timer: Timer?
  private var recovering = false
  private var witnessedAt: Instant = 0
  private var powerSubscriptions: [NSObjectProtocol] = []
  private let recoveryObserver: any PlatformObserving
  private let recoveryWriter: any DisplayWriting
  private let recoveryClock: any CoordinatorClock
  private let recoveryPause: @Sendable () async -> Void
  private let recoveryLockDirectory: URL

  init(
    executable: URL, store: ProductionJournalStore,
    recoveryObserver: any PlatformObserving = LivePlatformObserver(validation: nil),
    recoveryWriter: any DisplayWriting = LiveDisplayWriter(),
    recoveryClock: any CoordinatorClock = MonotonicClock(),
    recoveryLockDirectory: URL = FileManager.default.temporaryDirectory,
    recoveryPause: @escaping @Sendable () async -> Void = {
      try? await Task.sleep(for: .milliseconds(500))
    }
  ) {
    self.executable = executable
    self.store = store
    protection = .init(at: Self.now())
    self.recoveryObserver = recoveryObserver
    self.recoveryWriter = recoveryWriter
    self.recoveryClock = recoveryClock
    self.recoveryLockDirectory = recoveryLockDirectory
    self.recoveryPause = recoveryPause
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
    guard currentReconciliation() == .clean else {
      report("Recovery remains unresolved. No disabling controller was started.")
      return
    }
    // The helper watches the same power transitions, so its lease does not expire across sleep.
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, suspended) in [
      (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
    ] {
      let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.apply(
            self.protection.receive(suspended ? .suspended : .resumed, at: Self.now()))
        }
      }
      powerSubscriptions.append(token)
    }
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
      _ = await restore(record, reason: "unresolved ownership from an earlier run")
    }
  }

  private func launchController() {
    let commands = Pipe()
    let replies = Pipe()
    link = ProtectionLink(
      input: replies.fileHandleForReading, output: commands.fileHandleForWriting)
    let child = Process()
    child.executableURL = executable
    // Pass through the flags that belong to the interface, which the child owns.
    child.arguments =
      [ProductionLaunch.controllerArgument]
      + ProcessInfo.processInfo.arguments.filter { $0 == "--diagnostics" }
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
        if message.kind == .arm {
          guard let record = try store.load(), let claimed = message.ownership,
            record.session == message.session, record.operationID == claimed.operationID,
            record.target == claimed.target,
            (try? record.validate()) != nil
          else {
            apply(protection.receive(.peerFailed(.malformed), at: now))
            break
          }
        }
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
    var takeover = RecoveryTakeover()
    takeover.receive(.recoveryNeeded)
    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    guard await awaitExit(child, seconds: 3) else {
      takeover.receive(.failed)
      report("Lidless could not confirm its controller stopped, so it changed no display.")
      return
    }
    takeover.receive(.writerTerminationConfirmed)
    let record: ProductionRecord
    do {
      guard let retained = try store.load() else {
        timer?.invalidate()
        NSApp.terminate(nil)
        return
      }
      try retained.validate()
      guard retained.target == ownership.target, retained.operationID == ownership.operationID,
        retained.session == protection.session
      else {
        report("The recovery record does not match this live ownership. It was retained.")
        return
      }
      record = retained
    } catch {
      report("The recovery record cannot be read. Recovery remains unresolved: \(error)")
      return
    }
    if await restore(record, reason: reason, liveOwnership: ownership, transaction: takeover) {
      timer?.invalidate()
      NSApp.terminate(nil)
    }
  }

  private func currentReconciliation() -> JournalReconciliation {
    let reading = DisplayObserver.read()
    return store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays)
  }

  func restore(
    _ record: ProductionRecord, reason: String,
    liveOwnership: Ownership? = nil, transaction: RecoveryTakeover = .init()
  ) async -> Bool {
    // A transaction is scoped to this recovery attempt, never reused by a future child.
    var takeover = transaction
    let lock: SessionWriterLock
    do {
      // Acquiring the writer lock is the evidence that no live writer owns this session.
      lock = try SessionWriterLock(loginID: record.target.loginID, directory: recoveryLockDirectory)
    } catch {
      takeover.receive(.failed)
      report("Another display writer holds this session, so Lidless changed no display.")
      return false
    }
    defer { lock.release() }
    if takeover.phase == .watching {
      // Launch reconciliation: no controller child exists yet, and holding the exclusive writer
      // lock is what establishes that no live writer owns this session. Takeover from a running
      // controller reaches here already past this step, with a confirmed termination behind it.
      takeover.receive(.writerTerminationConfirmed)
    }
    takeover.receive(.lockAcquired)
    guard takeover.receive(.restoreAuthorized) == [.restore] else {
      report("Recovery refused: writer termination and lock ordering were not established.")
      return false
    }
    var continuation = RecoveryContinuation()
    var reportedWaiting = false
    let observer = recoveryObserver
    let writer = recoveryWriter
    while continuation.phase != .finished && continuation.phase != .blocked {
      let reading = observer.read()
      let readiness = RecoveryIdentity.readiness(
        reading, target: record.target,
        liveOwnership: liveOwnership)
      if readiness == .waiting && !reportedWaiting {
        report("Waiting for recovery evidence. Ownership and the writer lock are retained.")
        reportedWaiting = true
      }
      switch continuation.observe(
        readiness: readiness,
        restored: RestorationVerification.matches(record, reading: reading), at: recoveryClock.now()
      ) {
      case .none: break
      case .restore:
        // Recheck on the actual execution lane. A wait before a call is not a failed call.
        let outcome = await Task.detached { () -> RecoveryReadiness in
          let fresh = RecoveryIdentity.readiness(
            observer.read(), target: record.target,
            liveOwnership: liveOwnership)
          guard fresh == .ready else { return fresh }
          // Only this quiescent recovery owns the writer lock. A platform error still needs
          // verification, since it may have changed the panel before returning an error.
          try? writer.setEnabled(true, displayID: record.target.displayID, scope: .session)
          return .ready
        }.value
        if outcome == .waiting {
          continuation.writeDeferred()
        } else if outcome == .blocked {
          continuation.block()
        } else {
          continuation.writeReturned()
        }
      case .clear:
        do {
          try store.clear()
          continuation.journalCleared(succeeded: true)
        } catch {
          continuation.journalCleared(succeeded: false)
        }
      }
      if continuation.phase != .finished && continuation.phase != .blocked {
        await recoveryPause()
      }
    }
    let finished = continuation.phase == .finished
    report(
      finished
        ? "Lidless restored the internal display after \(reason)."
        : "Recovery could not be verified. The record was retained; no new controller will start.")
    return finished
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
