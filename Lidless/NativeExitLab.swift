#if DEBUG
  import CoreGraphics
  import Darwin
  import Foundation
  import LidlessCore
  import LidlessPlatform
  import Synchronization

  // Private, fixed-size pipe protocol. No filenames, shell commands, or display IDs cross these pipes.
  nonisolated enum NativeExitSignal: UInt8, Sendable {
    case ready = 1
    case arm = 2
    case suppressed = 3
    case exitNow = 4
    case failed = 5
  }

  nonisolated struct NativeExitBuffer: Sendable {
    private(set) var signals: [NativeExitSignal] = []
    private(set) var failed = false
    private(set) var closed = false
    private var received = 0

    mutating func receive(_ data: Data) {
      guard !failed, !closed else { return }
      if data.isEmpty {
        closed = true
        return
      }
      guard data.count <= 8 - received else {
        failed = true
        return
      }
      received += data.count
      for byte in data {
        guard let signal = NativeExitSignal(rawValue: byte) else {
          failed = true
          return
        }
        signals.append(signal)
      }
    }

    mutating func pop() throws -> NativeExitSignal? {
      guard !failed else { throw NativeExitProtocolError.invalidData }
      if !signals.isEmpty { return signals.removeFirst() }
      guard !closed else { throw NativeExitProtocolError.disconnected }
      return nil
    }
  }

  nonisolated enum NativeExitProtocolError: Error {
    case invalidData, disconnected, unexpectedSignal, deadline
  }

  nonisolated final class NativeExitInbox: Sendable {
    private let state = Mutex(NativeExitBuffer())
    private let handle: FileHandle

    init(_ handle: FileHandle) {
      self.handle = handle
      handle.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        self?.state.withLock { $0.receive(data) }
        if data.isEmpty { handle.readabilityHandler = nil }
      }
    }

    func pop() throws -> NativeExitSignal? { try state.withLock { try $0.pop() } }
    func stop() { handle.readabilityHandler = nil }
    deinit { handle.readabilityHandler = nil }
  }

  enum NativeExitAuthorization {
    static func expectedTermination(
      reason: Process.TerminationReason, status: Int32,
      ending: NativeExitEnding
    ) -> Bool {
      switch ending {
      case .normal: reason == .exit && status == 0
      case .kill, .freeze: reason == .uncaughtSignal && status == SIGKILL
      case .disconnect, .silence, .unplug, .sleep: reason == .exit && status == 1
      }
    }
    static func validate(journal: RecoveryJournal, witnessed: PanelTarget, childPID: Int32) throws {
      try journal.validate(bootID: witnessed.bootID, loginID: witnessed.loginID)
      guard journal.scope == "app", journal.target == witnessed,
        childPID > 1, journal.ownerPID == childPID
      else {
        throw NativeLabError.refused("Writer journal does not match the supervisor's live witness.")
      }
    }
  }

  enum NativeExitEnding: String, Equatable {
    case normal = "normal-exit"
    case kill = "forced-termination"
    case freeze = "frozen-writer"
    case disconnect = "contact-loss"
    case silence = "lease-expiry"
    case unplug = "external-unplug"
    case sleep = "system-sleep"
  }

  extension NativeRecoveryLab {
    private func send(_ signal: NativeExitSignal, to handle: FileHandle) throws {
      try handle.write(contentsOf: Data([signal.rawValue]))
    }

    private func waitFor(_ expected: NativeExitSignal, inbox: NativeExitInbox, seconds: Double)
      async throws
    {
      let deadline = ProcessInfo.processInfo.systemUptime + seconds
      repeat {
        if let signal = try inbox.pop() {
          guard signal == expected else { throw NativeExitProtocolError.unexpectedSignal }
          return
        }
        try await Task.sleep(for: .milliseconds(50))
      } while ProcessInfo.processInfo.systemUptime < deadline
      throw NativeExitProtocolError.deadline
    }

    private func awaitExit(_ child: Process, seconds: Double) async -> Bool {
      let deadline = ProcessInfo.processInfo.systemUptime + seconds
      while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
      }
      return !child.isRunning
    }

    private func stopAndReap(_ child: Process) async throws {
      if child.isRunning { kill(child.processIdentifier, SIGKILL) }
      guard await awaitExit(child, seconds: 2) else {
        throw NativeLabError.refused("Writer termination is unverified. Supervisor must not write.")
      }
    }

    private func verifyStopped(_ writer: Process) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 1
      repeat {
        var info = siginfo_t()
        guard
          waitid(P_PID, id_t(writer.processIdentifier), &info, WSTOPPED | WNOWAIT | WNOHANG) == 0
        else {
          throw NativeLabError.refused(
            "Cannot establish that the writer stopped. No takeover authorized.")
        }
        if info.si_pid == writer.processIdentifier && info.si_code == CLD_STOPPED
          && info.si_status == SIGSTOP
        {
          return
        }
        try await Task.sleep(for: .milliseconds(50))
      } while writer.isRunning && ProcessInfo.processInfo.systemUptime < deadline
      throw NativeLabError.refused("Writer stop was not verified.")
    }

    func supervisedExit(
      external: UInt32, path: String, rehearsal: Bool,
      ending: NativeExitEnding = .normal
    ) async throws {
      signal(SIGPIPE, SIG_IGN)
      let sleepMonitor = ending == .sleep ? NativeSleepMonitor() : nil
      defer { sleepMonitor?.stop() }
      guard let executable = Bundle.main.executableURL,
        !FileManager.default.fileExists(atPath: path)
      else { throw NativeLabError.refused("A new journal and the native executable are required.") }
      let witnessed = try NativeLabSafety.baseline(DisplayObserver.read(), external: external)
      if ending == .unplug {
        guard DisplayObserver.read().displays.filter({ !$0.builtIn }).count == 1 else {
          throw NativeLabError.refused(
            "The last-external experiment requires exactly one external.")
        }
      }
      guard PrivateDisplayAPI().symbolName != nil else { throw DisplayAPIError.unavailable }
      try report("exit-supervisor-live-baseline")

      let commands = Pipe()
      let replies = Pipe()
      let inbox = NativeExitInbox(replies.fileHandleForReading)
      defer {
        inbox.stop()
        try? commands.fileHandleForWriting.close()
        try? replies.fileHandleForReading.close()
      }
      let writer = Process()
      writer.executableURL = executable
      let writerVerb: String
      if ending == .sleep {
        writerVerb = rehearsal ? "--lab-sleep-writer-rehearsal" : "--lab-sleep-writer"
      } else if ending == .unplug {
        writerVerb = rehearsal ? "--lab-unplug-writer-rehearsal" : "--lab-unplug-writer"
      } else {
        writerVerb = rehearsal ? "--lab-exit-writer-rehearsal" : "--lab-exit-writer"
      }
      writer.arguments = [
        writerVerb, "--external",
        String(external), "--journal", path, "--native-wired-attested",
      ]
      writer.standardInput = commands
      writer.standardOutput = replies
      try writer.run()
      // Close the supervisor's duplicate child-side handles so EOF really means peer loss.
      try? commands.fileHandleForReading.close()
      try? replies.fileHandleForWriting.close()

      var armedJournal: RecoveryJournal?
      var supervisorEnableAttempted = false
      var takeover = RecoveryTakeover()
      do {
        try await waitFor(.ready, inbox: inbox, seconds: 3)
        let journal = try RecoveryJournal.load(from: URL(fileURLWithPath: path))
        try NativeExitAuthorization.validate(
          journal: journal, witnessed: witnessed, childPID: writer.processIdentifier)
        guard writer.isRunning,
          try NativeLabSafety.baseline(DisplayObserver.read(), external: external) == witnessed
        else { throw NativeLabError.refused("Baseline changed before arming the writer.") }
        // Set recovery responsibility before sending any permission to mutate.
        armedJournal = rehearsal ? nil : journal
        try report(rehearsal ? "exit-rehearsal-handshake-ready" : "exit-supervisor-armed")
        try send(.arm, to: commands.fileHandleForWriting)
        try await waitFor(.suppressed, inbox: inbox, seconds: 3)
        try report(
          rehearsal ? "exit-rehearsal-simulated-suppression" : "exit-supervisor-after-disable")
        if ending == .unplug || ending == .sleep {
          if let sleepMonitor {
            try await awaitSleepCycle(
              external: external, journal: journal, writer: writer,
              monitor: sleepMonitor, rehearsal: rehearsal)
          } else {
            try await awaitExternalRemoval(
              external: external, journal: journal,
              writer: writer, rehearsal: rehearsal)
          }
          // Revoke protection promptly on external loss. The responsive writer owns restoration.
          try commands.fileHandleForWriting.close()
          guard await awaitExit(writer, seconds: 5), writer.terminationReason == .exit,
            writer.terminationStatus == 1
          else {
            throw NativeLabError.refused("Lifecycle writer recovery did not complete in time.")
          }
          takeover.receive(.writerTerminationConfirmed)
          try await waitFor(.failed, inbox: inbox, seconds: 1)
          let lock = try SessionWriterLock(loginID: witnessed.loginID)
          defer { lock.release() }
          takeover.receive(.lockAcquired)
          try await verifyRestored(journal)
          try report(
            ending == .sleep
              ? (rehearsal
                ? "sleep-rehearsal-complete-no-display-writes"
                : "sleep-wake-writer-recovered-no-supervisor-enable")
              : rehearsal
                ? "unplug-rehearsal-complete-no-display-writes"
                : "external-loss-writer-restored-without-supervisor-enable")
          return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        repeat {
          try await Task.sleep(for: .milliseconds(100))
          let current = DisplayObserver.read()
          try NativeLabSafety.ownedContext(current, journal: journal)
          guard writer.isRunning, !current.mirroringDetected,
            rehearsal
              || !current.displays.contains(where: { $0.id == witnessed.displayID && $0.active }),
            current.displays.contains(where: { $0.id == external && $0.usableExternalCandidate })
          else { throw NativeLabError.refused("The supervised suppression conditions changed.") }
        } while ProcessInfo.processInfo.systemUptime < deadline
        if ending == .freeze {
          guard kill(writer.processIdentifier, SIGSTOP) == 0 else {
            throw NativeLabError.refused("Cannot stop the actual writer child.")
          }
          try await verifyStopped(writer)
          try report(rehearsal ? "freeze-rehearsal-writer-stopped" : "frozen-writer-stop-verified")
          // The supervisor remains responsive while the writer cannot run its own lease timer.
          let frozenDeadline = ProcessInfo.processInfo.systemUptime + 3
          repeat {
            try await Task.sleep(for: .milliseconds(100))
            try NativeLabSafety.ownedContext(DisplayObserver.read(), journal: journal)
            guard writer.isRunning else {
              throw NativeLabError.refused("Stopped writer exited unexpectedly.")
            }
          } while ProcessInfo.processInfo.systemUptime < frozenDeadline
        }
        if ending == .disconnect {
          try commands.fileHandleForWriting.close()
        } else if ending == .silence {
          // Leave the authenticated pipe open but send nothing. Only the writer's lease can expire.
        } else if ending == .normal {
          try send(.exitNow, to: commands.fileHandleForWriting)
        } else {
          guard kill(writer.processIdentifier, SIGKILL) == 0 else {
            throw NativeLabError.refused("Cannot terminate the actual writer child.")
          }
        }
        guard await awaitExit(writer, seconds: ending == .silence ? 8 : 5) else {
          throw NativeExitProtocolError.deadline
        }
        takeover.receive(.writerTerminationConfirmed)
        guard
          NativeExitAuthorization.expectedTermination(
            reason: writer.terminationReason,
            status: writer.terminationStatus, ending: ending)
        else {
          throw NativeLabError.refused("Writer termination did not match the selected experiment.")
        }
        if ending == .disconnect || ending == .silence {
          try await waitFor(.failed, inbox: inbox, seconds: 1)
        }
        let lock = try SessionWriterLock(loginID: witnessed.loginID)
        defer { lock.release() }
        takeover.receive(.lockAcquired)
        if rehearsal {
          guard
            try NativeLabSafety.baseline(DisplayObserver.read(), external: external) == witnessed
          else {
            throw NativeLabError.refused(
              "Rehearsal baseline changed. No display requests were sent.")
          }
          try report("exit-rehearsal-complete-no-display-writes")
          return
        }
        try report("exit-supervisor-writer-exited")
        if ending == .disconnect || ending == .silence {
          // This scenario requires responsive-writer restoration, not supervisor recovery.
          try await verifyRestored(journal)
          try report("\(ending.rawValue)-writer-restored-without-supervisor-enable")
          print(
            "RESULT (\(ending.rawValue)): writer recovered after lost protection; supervisor sent no enable request."
          )
          return
        }
        // Observe before fallback so an explicit enable cannot be mistaken for automatic rollback.
        let rollbackDeadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
          try await Task.sleep(for: .milliseconds(100))
          let current = DisplayObserver.read()
          try NativeLabSafety.ownedContext(current, journal: journal)
          if current.displays.contains(where: { $0.id == witnessed.displayID && $0.active }) {
            try report("\(ending.rawValue)-rollback-observed-without-enable")
            print(
              "RESULT (\(ending.rawValue)): internal panel active after writer termination; supervisor sent no enable request."
            )
            return
          }
        } while ProcessInfo.processInfo.systemUptime < rollbackDeadline
        guard takeover.receive(.restoreAuthorized) == [.restore] else {
          throw NativeLabError.refused("Recovery ordering did not authorize a supervisor write.")
        }
        supervisorEnableAttempted = true
        try PrivateDisplayAPI().setEnabled(true, displayID: witnessed.displayID, scope: .forSession)
        try await verifyRestored(journal)
        try report("\(ending.rawValue)-required-supervisor-restore")
        print(
          "RESULT (\(ending.rawValue)): automatic rollback was not observed within three seconds; supervisor explicitly restored the panel."
        )
      } catch {
        // Preserve responsibility through system sleep; never run takeover writes during it.
        try await sleepMonitor?.awaitWakeIfSleeping()
        // Reap our actual writer and acquire its lock before any supervisor recovery attempt.
        takeover.receive(.recoveryNeeded)
        try await stopAndReap(writer)
        takeover.receive(.writerTerminationConfirmed)
        if let journal = armedJournal {
          let lock = try SessionWriterLock(loginID: witnessed.loginID)
          defer { lock.release() }
          takeover.receive(.lockAcquired)
          let current = DisplayObserver.read()
          try NativeLabSafety.ownedContext(current, journal: journal)
          if !supervisorEnableAttempted,
            !current.displays.contains(where: { $0.id == witnessed.displayID && $0.active })
          {
            guard takeover.receive(.restoreAuthorized) == [.restore] else {
              throw NativeLabError.refused(
                "Recovery ordering rejected a competing or repeated write.")
            }
            supervisorEnableAttempted = true
            try PrivateDisplayAPI().setEnabled(
              true, displayID: witnessed.displayID, scope: .forSession)
            try await verifyRestored(journal)
          }
          try report("exit-supervisor-aborted-test-recovery")
        }
        throw error
      }
    }

    func exitWriter(
      external: UInt32, path: String, rehearsal: Bool, unplug: Bool = false,
      sleep: Bool = false
    ) async
      -> Int32
    {
      // A disconnected pipe must produce an error, not terminate the writer before local restoration.
      signal(SIGPIPE, SIG_IGN)
      let sleepMonitor = sleep ? NativeSleepMonitor() : nil
      defer { sleepMonitor?.stop() }
      let inbox = NativeExitInbox(.standardInput)
      defer { inbox.stop() }
      var ownedJournal: RecoveryJournal?
      var writerLock: SessionWriterLock?
      defer { writerLock?.release() }
      do {
        guard getppid() > 1 else { throw NativeLabError.refused("A live supervisor is required.") }
        let supervisorPID = getppid()
        let target = try NativeLabSafety.baseline(DisplayObserver.read(), external: external)
        let api = PrivateDisplayAPI()
        guard api.symbolName != nil else { throw DisplayAPIError.unavailable }
        writerLock = try SessionWriterLock(loginID: target.loginID)
        let journal = RecoveryJournal(target: target, scope: "app", ownerPID: getpid())
        try journal.save(to: URL(fileURLWithPath: path))
        try send(.ready, to: .standardOutput)
        try await waitFor(.arm, inbox: inbox, seconds: 3)
        guard getppid() == supervisorPID,
          sleepMonitor?.snapshot.sleepCount ?? 0 == 0,
          try NativeLabSafety.baseline(DisplayObserver.read(), external: external) == target
        else {
          throw NativeLabError.refused("Writer baseline or supervisor changed before disabling.")
        }
        // The already authenticated pipe acknowledgement protects one bounded experiment.
        // The session is local to this Process handshake and is never loaded from a journal.
        let leaseSession = UUID().uuidString
        var lease = RecoveryLease(
          session: leaseSession, at: labNow(), duration: unplug || sleep ? 45_000 : 10_000)
        lease.receive(.acknowledged(session: leaseSession, challenge: 1), at: labNow())
        guard lease.protects(at: labNow()) else { throw NativeExitProtocolError.deadline }
        if !rehearsal {
          ownedJournal = journal
          try api.setEnabled(false, displayID: target.displayID, scope: .forAppOnly)
        }
        try send(.suppressed, to: .standardOutput)
        // A bounded lease: parent loss or silence restores locally while this writer is responsive.
        while true {
          if let sleepMonitor, sleepMonitor.snapshot.sleepCount > 0 {
            throw NativeLabError.refused(
              "System sleep invalidated suppression; recover after wake.")
          }
          guard lease.receive(.tick, at: labNow()).isEmpty, lease.protects(at: labNow()) else {
            throw NativeExitProtocolError.deadline
          }
          guard getppid() == supervisorPID else {
            lease.receive(.contactLost, at: labNow())
            throw NativeExitProtocolError.disconnected
          }
          if let next = try inbox.pop() {
            guard next == .exitNow else { throw NativeExitProtocolError.unexpectedSignal }
            break
          }
          try await Task.sleep(for: .milliseconds(50))
        }
        let current = DisplayObserver.read()
        try NativeLabSafety.ownedContext(current, journal: journal)
        guard getppid() == supervisorPID,
          !current.mirroringDetected,
          rehearsal
            || !current.displays.contains(where: { $0.id == target.displayID && $0.active }),
          current.displays.contains(where: { $0.id == external && $0.usableExternalCandidate })
        else {
          throw NativeLabError.refused("Supervisor or external unavailable at the exit boundary.")
        }
        // Deliberately no enable. The waiting supervisor remains alive with its pre-disable witness.
        return 0
      } catch {
        // A sleep interruption clears suppression intent, but a lit panel is not required asleep.
        // The live owner retains its journal and lock until it can recover after wake.
        do { try await sleepMonitor?.awaitWakeIfSleeping() } catch { return 1 }
        if let journal = ownedJournal {
          do {
            let current = DisplayObserver.read()
            try NativeLabSafety.ownedContext(current, journal: journal)
            if !current.displays.contains(where: { $0.id == journal.target.displayID && $0.active })
            {
              try PrivateDisplayAPI().setEnabled(
                true, displayID: journal.target.displayID, scope: .forAppOnly)
            }
            try await verifyRestored(journal)
          } catch {
            try? FileHandle.standardError.write(
              contentsOf: Data("Writer fallback unverified: \(error)\n".utf8))
          }
        }
        try? send(.failed, to: .standardOutput)
        try? FileHandle.standardError.write(
          contentsOf: Data("Exit writer aborted: \(error)\n".utf8))
        return 1
      }
    }

    private func labNow() -> Instant {
      Int64(ProcessInfo.processInfo.systemUptime * 1_000)
    }

    private func awaitSleepCycle(
      external: UInt32, journal: RecoveryJournal,
      writer: Process, monitor: NativeSleepMonitor, rehearsal: Bool
    ) async throws {
      guard monitor.snapshot.sleepCount == 0 else {
        throw NativeLabError.refused("Sleep occurred before the experiment was ready.")
      }
      let initial = DisplayObserver.read()
      try NativeLabSafety.ownedContext(initial, journal: journal)
      guard initial.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }),
        rehearsal
          || !initial.displays.contains(where: { $0.id == journal.target.displayID && $0.active })
      else { throw NativeLabError.refused("Suppression was not established before sleep testing.") }
      try report(rehearsal ? "sleep-rehearsal-ready" : "sleep-now-window-open")
      let started = labNow()
      var reportedSleep = false
      while true {
        let cycle = monitor.snapshot
        if cycle.sleepCount > 0 && !reportedSleep {
          try report("system-sleep-notification-observed")
          reportedSleep = true
        }
        if cycle.completed {
          try report("system-wake-notification-observed")
          return
        }
        if cycle.sleepCount == 0 {
          guard writer.isRunning else {
            throw NativeLabError.refused("Writer exited before sleep.")
          }
          if rehearsal && labNow() - started >= 1_000 {
            try report("sleep-rehearsal-protocol-trigger-not-real-sleep")
            return
          }
          guard labNow() - started < 40_000 else {
            throw NativeLabError.refused(
              "No system sleep within test window; recovering without a pass.")
          }
          let current = DisplayObserver.read()
          try NativeLabSafety.ownedContext(current, journal: journal)
          guard !current.mirroringDetected,
            current.displays.contains(where: { $0.id == external && $0.usableExternalCandidate })
          else { throw NativeLabError.refused("Docked baseline changed before system sleep.") }
        }
        // Once asleep, both processes may be suspended. Recovery resumes on didWake, not a timer.
        try await Task.sleep(for: .milliseconds(100))
      }
    }

    private func awaitExternalRemoval(
      external: UInt32, journal: RecoveryJournal,
      writer: Process, rehearsal: Bool
    ) async throws {
      let initial = DisplayObserver.read()
      try NativeLabSafety.ownedContext(initial, journal: journal)
      guard initial.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }),
        rehearsal
          || !initial.displays.contains(where: { $0.id == journal.target.displayID && $0.active })
      else {
        throw NativeLabError.refused("Suppression was not established before unplug testing.")
      }
      try report(rehearsal ? "unplug-rehearsal-ready" : "unplug-now-window-open")
      fflush(stdout)
      let started = labNow()
      while labNow() - started < 40_000 {
        try await Task.sleep(for: .milliseconds(100))
        guard writer.isRunning else {
          throw NativeLabError.refused("Writer exited before cable removal.")
        }
        let current = DisplayObserver.read()
        try NativeLabSafety.ownedContext(current, journal: journal)
        guard !current.mirroringDetected else {
          throw NativeLabError.refused("Mirroring changed during unplug test.")
        }
        // Absence is distinct from an asleep or temporarily inactive external.
        if !current.displays.contains(where: { $0.id == external })
          || (rehearsal && labNow() - started >= 1_000)
        {
          try report(rehearsal ? "unplug-rehearsal-synthetic-loss" : "external-removal-observed")
          return
        }
      }
      throw NativeLabError.refused(
        "No cable removal within the bounded test window; restoring without a pass.")
    }
  }
#endif
