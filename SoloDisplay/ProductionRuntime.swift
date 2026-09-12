import AppKit
import Darwin
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform

enum HelperInterfaceState: Equatable {
  case hidden
  case recovering(String)
  case blocked(String)

  /// Retry is only offered on a blocked state. A recovery that cannot progress therefore has to
  /// stop reporting progress, or it leaves a person with nothing to act on and no way out.
  static let waitingForEvidence = Self.blocked(
    "SoloDisplay cannot identify the internal display yet, so it is holding its record and "
      + "changing nothing. Try again, or restart this Mac if the screen stays off."
  )

  static let restoringPanel = Self.recovering("Restoring the internal display…")
}

/// Why display control is unavailable, in the words the menu shows. Availability is proven,
/// never assumed: every path that cannot establish protection lands here.
nonisolated enum ProductionAvailability: Equatable {
  case unavailable(String)
  case protectedIdle

  var explanation: String? {
    switch self {
    case let .unavailable(reason): reason
    case .protectedIdle: nil
    }
  }
}

/// The supervising process. It never disables a display. It is normally invisible, but owns a
/// recovery-only status item whenever the controller is absent and ownership remains unresolved.
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
  private let recoveryWriter: (any DisplayWriting)?
  private let recoveryClock: any CoordinatorClock
  private let recoveryPause: @Sendable () async -> Void
  private let recoveryLockDirectory: URL
  private let diagnostics: OperationalLogger
  private let recoveryWriteAvailability = WriteAvailability(awake: true)
  private var childExit = ChildExitDiagnostics()
  private var activityResumeCount: UInt64 = 0
  private var loggedPairing = false
  private var loggedLoss: HelperProtection.Reason?
  private var recoveryOwnership: Ownership?
  /// Scoped to one recovery attempt, and reset by each. Tracked apart from the diagnostics
  /// one-shot because the interface has to be able to go back to reporting progress.
  private var surfacedRecoveryWait = false

  var onInterfaceStateChanged: ((HelperInterfaceState) -> Void)?

  init(
    executable: URL, store: ProductionJournalStore,
    recoveryObserver: any PlatformObserving = LivePlatformObserver(validation: nil),
    recoveryWriter: (any DisplayWriting)? = nil,
    recoveryClock: any CoordinatorClock = MonotonicClock(),
    recoveryLockDirectory: URL = FileManager.default.temporaryDirectory,
    diagnostics: OperationalLogger = .init(role: .helper),
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
    self.diagnostics = diagnostics
  }

  static func now() -> Instant {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
  }

  func start() async {
    diagnostics.started()
    let reading = DisplayObserver.read()
    guard let loginID = reading.loginID else {
      diagnostics.emit(.exitRequested, reason: .missingSession)
      report("SoloDisplay cannot identify this login session, so it will not change any display.")
      NSApp.terminate(nil)
      return
    }
    do {
      instanceLock = try SessionWriterLock(loginID: loginID, name: "instance")
    } catch {
      // Another SoloDisplay pair already owns this GUI session. Two supervisors is worse than one.
      diagnostics.emit(.exitRequested, reason: .alreadyRunning, errorCode: (error as NSError).code)
      report("SoloDisplay is already running in this login session.")
      NSApp.terminate(nil)
      return
    }
    startObservingPower()
    await reconcileAtLaunch(reading)
    guard currentReconciliation() == .clean else {
      diagnostics.emit(.recoveryBlocked, reason: .unresolvedOwnership)
      report("Recovery remains unresolved. No disabling controller was started.")
      onInterfaceStateChanged?(
        .blocked("Internal display recovery remains unresolved. No new controller was started.")
      )
      return
    }
    onInterfaceStateChanged?(.hidden)
    launchController()
    let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pump() }
    }
    RunLoop.main.add(ticker, forMode: .common)
    timer = ticker
  }

  /// Install this before launch reconciliation. Recovery can itself span a sleep transition,
  /// and no worker may start until a subsequent wake notification reopens the write gate.
  private func startObservingPower() {
    let workspace = NSWorkspace.shared.notificationCenter
    for (name, suspended) in [
      (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
      (NSWorkspace.screensDidWakeNotification, false)
    ] {
      let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.diagnostics.emit(
            suspended ? .suspended : .resumed,
            session: self.protection.session, reason: suspended ? .workspaceSleep : .workspaceWake
          )
          self.recoveryWriteAvailability.update(awake: !suspended)
          self.apply(
            self.protection.receive(suspended ? .suspended : .resumed, at: Self.now())
          )
        }
      }
      powerSubscriptions.append(token)
    }
  }

  /// Unresolved ownership is resolved before any controller runs, so a new run can never
  /// start while an earlier one may still have the internal panel turned off.
  private func reconcileAtLaunch(_ reading: PlatformReading) async {
    let reconciliation = store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays
    )
    switch reconciliation {
    case .clean:
      return
    case let .retained(reason):
      diagnostics.emit(.recoveryBlocked, reason: .recordRetained)
      report(reason)
      onInterfaceStateChanged?(.blocked(reason))
    case let .priorSession(record):
      // A restart or new login already restored the panel. Confirm that before forgetting it.
      guard reading.displays.contains(where: { $0.builtIn && $0.active }) else {
        diagnostics.emit(.recoveryWaiting, reason: .priorSession)
        report(
          "SoloDisplay kept an unresolved record from a previous startup because it cannot see an active internal display."
        )
        onInterfaceStateChanged?(
          .blocked("Recovery is waiting for the internal display to become identifiable.")
        )
        return
      }
      diagnostics.emit(.journalClearing, reason: .priorSession)
      do {
        try store.clear()
        diagnostics.emit(.journalCleared, reason: .priorSession, succeeded: true)
        report(
          "SoloDisplay cleared an unresolved record from a previous startup. Nothing was changed."
        )
      } catch {
        diagnostics.emit(
          .journalCleared, reason: .priorSession, succeeded: false,
          errorCode: (error as NSError).code
        )
      }
      _ = record
    case let .unresolved(record):
      diagnostics.emit(.recoveryRequested, session: record.session, reason: .unresolvedOwnership)
      onInterfaceStateChanged?(.recovering("Restoring the internal display from an earlier run…"))
      let finished = await restore(record, reason: "unresolved ownership from an earlier run")
      if !finished {
        onInterfaceStateChanged?(
          .blocked("Recovery could not be completed. The recovery record is still retained.")
        )
      }
    }
  }

  private func launchController() {
    let commands = Pipe()
    let replies = Pipe()
    link = ProtectionLink(
      input: replies.fileHandleForReading, output: commands.fileHandleForWriting
    )
    let child = Process()
    child.executableURL = executable
    // Pass through the flags that belong to the interface, which the child owns.
    child.arguments =
      [ProductionLaunch.controllerArgument]
        + ProcessInfo.processInfo.arguments.filter { $0 == "--diagnostics" }
    child.standardInput = commands
    child.standardOutput = replies
    do { try child.run() } catch {
      diagnostics.emit(
        .startupFailed, reason: .controllerLaunchFailed,
        errorCode: (error as NSError).code
      )
      diagnostics.emit(.exitRequested, reason: .controllerLaunchFailed)
      report("SoloDisplay could not start its controller process: \(error)")
      NSApp.terminate(nil)
      return
    }
    // Close the duplicate child-side handles so EOF really means the peer is gone.
    try? commands.fileHandleForReading.close()
    try? replies.fileHandleForWriting.close()
    controller = child
    // The controller waits on arm replies, so answer as soon as a request arrives. The pump timer
    // still polls, which keeps witnessing and a missed notification covered.
    link?.setReceiveHandler { [weak self] in
      Task { @MainActor in self?.receiveMessages(at: Self.now()) }
    }
  }

  private func pump() {
    guard link != nil else { return }
    let now = Self.now()
    // The helper's own view of the panel, taken independently of anything the controller says.
    if now - witnessedAt >= 1000 {
      witnessedAt = now
      let reading = DisplayObserver.read()
      apply(protection.receive(.witness(reading.internalTarget), at: now))
    }
    receiveMessages(at: now)
    if controller?.isRunning == false, !recovering {
      if let controller {
        childExit.recordIfTerminated(controller, using: diagnostics, session: protection.session)
      }
      apply(protection.receive(.controllerExited, at: now))
    }
    apply(protection.receive(.tick, at: now))
    if controller?.isRunning == false, !recovering {
      // Nothing is owned and nothing is running. The supervising process has no work left.
      diagnostics.emit(.exitRequested, session: protection.session, reason: .nothingOwed)
      timer?.invalidate()
      NSApp.terminate(nil)
    }
  }

  private func apply(_ outputs: [HelperProtection.Output]) {
    if let reason = protection.reason, loggedLoss != reason {
      loggedLoss = reason
      diagnostics.emit(
        reason == .controllerExited && protection.ownership == nil
          ? .protectionEnded : .protectionLost, session: protection.session,
        operation: protection.progress
      ) {
        $0.helperLoss = reason
        $0.progressAgeMS = max(0, Self.now() - protection.lastProgressAt)
        if let progress = protection.progress {
          $0.deadlineOverdueMS = max(0, Self.now() - progress.deadline)
        }
      }
    }
    if protection.activityResumeCount != activityResumeCount {
      activityResumeCount = protection.activityResumeCount
      diagnostics.emit(.resumed, session: protection.session, reason: .activityFallback)
    }
    if !loggedPairing, protection.session != nil {
      loggedPairing = true
      diagnostics.emit(.paired, session: protection.session)
    }
    for output in outputs {
      switch output {
      case let .send(message): try? link?.send(message)
      case .standDown: break
      case let .recoveryRequired(ownership, reason):
        guard !recovering else { continue }
        diagnostics.emit(
          .recoveryRequested, session: protection.session,
          operation: protection.progress
        ) {
          $0.helperLoss = reason
          $0.progressAgeMS = max(0, Self.now() - protection.lastProgressAt)
          if let progress = protection.progress {
            $0.deadlineOverdueMS = max(0, Self.now() - progress.deadline)
          }
        }
        recovering = true
        recoveryOwnership = ownership
        onInterfaceStateChanged?(.recovering("Restoring the internal display…"))
        Task { @MainActor in await self.takeOver(ownership, reason: reason.rawValue) }
      }
    }
  }

  /// Stop the actual controller child, prove it is gone, take the writer lock, and only then
  /// consider a restore. Message content alone never reaches the display API.
  private func takeOver(_ ownership: Ownership, reason: String) async {
    guard let child = controller else {
      recovering = false
      onInterfaceStateChanged?(.blocked("The controller process could not be identified."))
      return
    }
    var takeover = RecoveryTakeover()
    takeover.receive(.recoveryNeeded)
    if child.isRunning {
      diagnostics.emit(
        .childTerminationRequested, session: protection.session,
        reason: .protectionFailure
      ) { $0.helperLoss = protection.reason }
      let result = kill(child.processIdentifier, SIGKILL)
      if result != 0 {
        diagnostics.emit(
          .childTerminationRequested, session: protection.session,
          reason: .protectionFailure, succeeded: false, errorCode: Int(errno)
        )
      }
    }
    guard await awaitExit(child, seconds: 3) else {
      diagnostics.emit(.childExitUnconfirmed, session: protection.session, succeeded: false)
      takeover.receive(.failed)
      report("SoloDisplay could not confirm its controller stopped, so it changed no display.")
      recovering = false
      onInterfaceStateChanged?(
        .blocked("The controller could not be stopped safely. No recovery write was attempted.")
      )
      return
    }
    childExit.recordIfTerminated(child, using: diagnostics, session: protection.session)
    takeover.receive(.writerTerminationConfirmed)
    let record: ProductionRecord
    do {
      guard let retained = try store.load() else {
        diagnostics.emit(.exitRequested, session: protection.session, reason: .nothingOwed)
        timer?.invalidate()
        NSApp.terminate(nil)
        return
      }
      try retained.validate()
      guard retained.target == ownership.target, retained.operationID == ownership.operationID,
            retained.session == protection.session
      else {
        diagnostics.emit(.recoveryBlocked, session: protection.session, reason: .recordMismatch)
        report("The recovery record does not match this live ownership. It was retained.")
        recovering = false
        onInterfaceStateChanged?(.blocked("The recovery record did not match the live operation."))
        return
      }
      record = retained
    } catch {
      diagnostics.emit(
        .recoveryBlocked, session: protection.session, reason: .recordUnreadable,
        errorCode: (error as NSError).code
      )
      report("The recovery record cannot be read. Recovery remains unresolved: \(error)")
      recovering = false
      onInterfaceStateChanged?(.blocked("The recovery record could not be read."))
      return
    }
    if await restore(record, reason: reason, liveOwnership: ownership, transaction: takeover) {
      diagnostics.emit(.exitRequested, session: protection.session, reason: .recoveryComplete)
      timer?.invalidate()
      NSApp.terminate(nil)
    } else {
      recovering = false
      onInterfaceStateChanged?(
        .blocked("Recovery could not be completed. The recorded panel remains protected.")
      )
    }
  }

  func retryRecovery() {
    guard !recovering else { return }
    let record: ProductionRecord
    do {
      guard let retained = try store.load() else {
        onInterfaceStateChanged?(.hidden)
        return
      }
      record = retained
    } catch {
      onInterfaceStateChanged?(.blocked("The recovery record could not be read."))
      return
    }
    recovering = true
    onInterfaceStateChanged?(.recovering("Retrying internal display recovery…"))
    Task { @MainActor in
      let finished = await self.restore(
        record, reason: "an explicit retry", liveOwnership: self.recoveryOwnership
      )
      self.recovering = false
      if finished {
        self.diagnostics.emit(
          .exitRequested, session: self.protection.session, reason: .recoveryComplete
        )
        NSApp.terminate(nil)
      } else {
        self.onInterfaceStateChanged?(
          .blocked("Recovery could not be completed. The recorded panel remains protected.")
        )
      }
    }
  }

  private func currentReconciliation() -> JournalReconciliation {
    let reading = DisplayObserver.read()
    return store.reconcile(
      bootID: reading.bootID, loginID: reading.loginID, displays: reading.displays
    )
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
      diagnostics.emit(.writerLockAcquired, session: record.session)
    } catch {
      diagnostics.emit(
        .writerLockUnavailable, session: record.session, reason: .writerBusy,
        errorCode: (error as NSError).code
      )
      takeover.receive(.failed)
      report("Another display writer holds this session, so SoloDisplay changed no display.")
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
      diagnostics.emit(.recoveryBlocked, session: record.session, reason: .orderingRefused)
      report("Recovery refused: writer termination and lock ordering were not established.")
      return false
    }
    var continuation = RecoveryContinuation()
    var reportedWaiting = false
    surfacedRecoveryWait = false
    let observer = recoveryObserver
    let writer: any DisplayWriting =
      recoveryWriter
        ?? RecoveryProcessDisplayWriter(executable: executable, record: record, writerLock: lock)
    let diagnostics = diagnostics
    let clock = recoveryClock
    let writeAvailability = recoveryWriteAvailability
    while continuation.phase != .finished, continuation.phase != .blocked {
      let reading = observer.read()
      let readiness = recoveryWriteAvailability.grant() == nil
        ? RecoveryReadiness.waiting
        : RecoveryIdentity.readiness(
          reading, target: record.target,
          liveOwnership: liveOwnership
        )
      noteRecoveryWait(
        readiness == .waiting, session: record.session, reported: &reportedWaiting
      )
      switch continuation.observe(
        readiness: readiness,
        restored: RestorationVerification.matches(record, reading: reading), at: recoveryClock.now()
      ) {
      case .none: break
      case .restore:
        guard let writeGrant = recoveryWriteAvailability.grant() else {
          diagnostics.emit(.restoreDeferred, session: record.session)
          continuation.writeDeferred()
          break
        }
        // Recheck on the actual execution lane. A wait before a call is not a failed call.
        let outcome = await Task.detached { () -> RecoveryReadiness in
          guard writeAvailability.permits(writeGrant) else { return .waiting }
          let fresh = RecoveryIdentity.readiness(
            observer.read(), target: record.target,
            liveOwnership: liveOwnership
          )
          guard fresh == .ready else { return fresh }
          guard writeAvailability.permits(writeGrant) else { return .waiting }
          // Only this quiescent recovery owns the writer lock. A platform error still needs
          // verification, since it may have changed the panel before returning an error.
          let started = clock.now()
          diagnostics.emit(.operationStarted, session: record.session) {
            $0.operationID = record.operationID
          }
          do {
            try writer.setEnabled(true, displayID: record.target.displayID, scope: .session)
            diagnostics.emit(.operationReturned, session: record.session, succeeded: true) {
              $0.operationID = record.operationID
              $0.elapsedMS = max(0, clock.now() - started)
            }
          } catch {
            diagnostics.emit(
              .operationReturned, session: record.session, succeeded: false,
              errorCode: OperationalEvent.numericErrorCode(error)
            ) {
              $0.operationID = record.operationID
              $0.elapsedMS = max(0, clock.now() - started)
            }
          }
          return .ready
        }.value
        if outcome == .waiting {
          diagnostics.emit(.restoreDeferred, session: record.session)
          continuation.writeDeferred()
        } else if outcome == .blocked {
          continuation.block()
        } else {
          continuation.writeReturned()
        }
      case .clear:
        diagnostics.emit(.operationVerified, session: record.session) {
          $0.operationID = record.operationID
        }
        diagnostics.emit(.journalClearing, session: record.session)
        do {
          try store.clear()
          diagnostics.emit(.journalCleared, session: record.session, succeeded: true)
          continuation.journalCleared(succeeded: true)
        } catch {
          diagnostics.emit(
            .journalCleared, session: record.session, succeeded: false,
            errorCode: (error as NSError).code
          )
          continuation.journalCleared(succeeded: false)
        }
      }
      if continuation.phase != .finished, continuation.phase != .blocked {
        await recoveryPause()
      }
    }
    let finished = continuation.phase == .finished
    diagnostics.emit(
      finished ? .recoveryVerified : .recoveryBlocked,
      session: record.session, reason: finished ? .recoveryComplete : .verificationFailed,
      succeeded: finished
    )
    report(
      finished
        ? "SoloDisplay restored the internal display after \(reason)."
        : "Recovery could not be verified. The record was retained; no new controller will start."
    )
    return finished
  }

  private func awaitExit(_ child: Process, seconds: Double) async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    return !child.isRunning
  }

  /// The diagnostic fires once per attempt. The interface state toggles, because a wait that
  /// ends has to take its message with it or every later recovery reads as stuck.
  private func noteRecoveryWait(_ waiting: Bool, session: String, reported: inout Bool) {
    if waiting, !reported {
      diagnostics.emit(.recoveryWaiting, session: session, reason: .evidenceUnavailable)
      report("Waiting for recovery evidence. Ownership and the writer lock are retained.")
      reported = true
    }
    guard waiting != surfacedRecoveryWait else { return }
    surfacedRecoveryWait = waiting
    onInterfaceStateChanged?(waiting ? .waitingForEvidence : .restoringPanel)
  }

  private func report(_ message: String) {
    FileHandle.standardError.write(Data("SoloDisplay helper: \(message)\n".utf8))
  }
}

extension HelperRuntime {
  /// Shared by the pump timer and the link's receive notification, so an arm request is answered
  /// as soon as it arrives. An arm is only honoured against the durable record it names.
  private func receiveMessages(at now: Instant) {
    guard let link else { return }
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
  }
}
