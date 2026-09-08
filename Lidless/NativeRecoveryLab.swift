#if DEBUG
  import AppKit
  import CoreGraphics
  import Darwin
  import Foundation
  import LidlessCore
  import LidlessPlatform

  enum NativeLabError: Error, CustomStringConvertible {
    case refused(String)
    var description: String {
      switch self {
      case .refused(let reason): reason
      }
    }
  }

  /// Explicit launch arguments only. No normal menu action enters this lab.
  enum NativeLabCommand: Equatable {
    case check
    case handoff(external: UInt32, journal: String)
    case restoreChild(journal: String)
    case supervisedExit(external: UInt32, journal: String, rehearsal: Bool)
    case exitWriter(external: UInt32, journal: String, rehearsal: Bool)
    case unplugWriter(external: UInt32, journal: String, rehearsal: Bool)
    case sleepWriter(external: UInt32, journal: String, rehearsal: Bool)
    case mirrorWriter(external: UInt32, journal: String, rehearsal: Bool)
    case failure(external: UInt32, journal: String, ending: NativeExitEnding, rehearsal: Bool)

    static func parse(_ arguments: [String]) throws -> Self? {
      guard arguments.contains(where: { $0.hasPrefix("--lab-") }) else { return nil }
      if arguments == ["--lab-check"] { return .check }
      guard let verb = arguments.first,
        [
          "--lab-handoff", "--lab-restore-child", "--lab-exit-supervised", "--lab-exit-writer",
          "--lab-exit-rehearsal", "--lab-exit-writer-rehearsal",
          "--lab-exit-kill", "--lab-exit-freeze", "--lab-freeze-rehearsal",
          "--lab-contact-loss", "--lab-contact-loss-rehearsal",
          "--lab-lease-expiry", "--lab-lease-expiry-rehearsal",
          "--lab-unplug", "--lab-unplug-rehearsal", "--lab-unplug-writer",
          "--lab-unplug-writer-rehearsal",
          "--lab-sleep", "--lab-sleep-rehearsal", "--lab-sleep-writer",
          "--lab-sleep-writer-rehearsal",
          "--lab-mirror", "--lab-mirror-rehearsal", "--lab-mirror-writer",
          "--lab-mirror-writer-rehearsal",
        ].contains(verb)
      else { throw NativeLabError.refused("Unknown native lab command.") }
      var values: [String: String] = [:]
      var iterator = arguments.dropFirst().makeIterator()
      while let key = iterator.next() {
        guard values[key] == nil else { throw NativeLabError.refused("Duplicate option: \(key)") }
        if key == "--native-wired-attested" {
          values[key] = "true"
        } else {
          guard ["--external", "--journal"].contains(key), let value = iterator.next(),
            !value.hasPrefix("--")
          else { throw NativeLabError.refused("Unknown or incomplete option: \(key)") }
          values[key] = value
        }
      }
      guard let journal = values["--journal"], (journal as NSString).isAbsolutePath else {
        throw NativeLabError.refused("An absolute recovery journal path is required.")
      }
      if verb == "--lab-restore-child" {
        guard Set(values.keys) == ["--journal"] else {
          throw NativeLabError.refused("The recovery child accepts only --journal.")
        }
        return .restoreChild(journal: journal)
      }
      guard Set(values.keys) == ["--journal", "--external", "--native-wired-attested"],
        let external = values["--external"].flatMap(UInt32.init), external != 0
      else {
        throw NativeLabError.refused(
          "A visible, native wired external must be explicitly attested.")
      }
      switch verb {
      case "--lab-mirror", "--lab-mirror-rehearsal":
        return .failure(
          external: external, journal: journal, ending: .mirror,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-mirror-writer", "--lab-mirror-writer-rehearsal":
        return .mirrorWriter(
          external: external, journal: journal,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-sleep", "--lab-sleep-rehearsal":
        return .failure(
          external: external, journal: journal, ending: .sleep,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-sleep-writer", "--lab-sleep-writer-rehearsal":
        return .sleepWriter(
          external: external, journal: journal,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-unplug", "--lab-unplug-rehearsal":
        return .failure(
          external: external, journal: journal, ending: .unplug,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-unplug-writer", "--lab-unplug-writer-rehearsal":
        return .unplugWriter(
          external: external, journal: journal,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-contact-loss", "--lab-contact-loss-rehearsal",
        "--lab-lease-expiry", "--lab-lease-expiry-rehearsal":
        return .failure(
          external: external, journal: journal,
          ending: verb.hasPrefix("--lab-contact-loss") ? .disconnect : .silence,
          rehearsal: verb.hasSuffix("-rehearsal"))
      case "--lab-exit-kill", "--lab-exit-freeze", "--lab-freeze-rehearsal":
        return .failure(
          external: external, journal: journal,
          ending: verb == "--lab-exit-kill" ? .kill : .freeze,
          rehearsal: verb == "--lab-freeze-rehearsal")
      case "--lab-exit-supervised", "--lab-exit-rehearsal":
        return .supervisedExit(
          external: external, journal: journal, rehearsal: verb == "--lab-exit-rehearsal")
      case "--lab-exit-writer", "--lab-exit-writer-rehearsal":
        return .exitWriter(
          external: external, journal: journal, rehearsal: verb == "--lab-exit-writer-rehearsal")
      default: return .handoff(external: external, journal: journal)
      }
    }
  }

  enum NativeLabChildOutcome: Equatable {
    case exited(Int32)
    case notStarted
    case terminationUnverified
  }

  enum NativeLabHandoffDecision: Equatable {
    case verifyOnly, restoreInOwner, reportChildFailure, forbidSecondWriter

    static func decide(child: NativeLabChildOutcome, panelActive: Bool) -> Self {
      switch child {
      case .terminationUnverified: .forbidSecondWriter
      case .exited(0): .verifyOnly
      case .exited, .notStarted: panelActive ? .reportChildFailure : .restoreInOwner
      }
    }
  }

  enum NativeLabSafety {
    static func baseline(_ reading: PlatformReading, external: UInt32) throws -> PanelTarget {
      guard reading.enumerationError == nil, reading.lid == .open,
        reading.foregroundSession == .yes, !reading.mirroringDetected,
        let target = reading.internalTarget,
        reading.displays.contains(where: { $0.id == target.displayID && $0.active }),
        reading.displays.contains(where: { $0.id == external && $0.usableExternalCandidate })
      else {
        throw NativeLabError.refused("Open-lid extended-display prerequisites are not established.")
      }
      return target
    }

    static func ownedContext(_ reading: PlatformReading, journal: RecoveryJournal) throws {
      try journal.validate(bootID: reading.bootID, loginID: reading.loginID)
      guard reading.enumerationError == nil, reading.foregroundSession == .yes, reading.lid == .open
      else {
        throw NativeLabError.refused(
          "Recovery requires reliable inventory, the foreground session, and an open lid.")
      }
      try RecoveryIdentity.checkCurrentDisplays(reading.displays, target: journal.target)
    }
  }

  /// A bounded developer experiment using the app's real main event loop, not a CLI RunLoop shim.
  /// This is not the production coordinator or an independently armed crash-recovery helper.
  @MainActor
  final class NativeRecoveryLab {
    private let monitor = DisplayEventMonitor()

    private struct Report: Encodable {
      let label: String
      let processID: Int32
      let parentPID: Int32
      let callbacks: [DisplayChangeEvent]
      let droppedCallbacks: Int
      let reading: PlatformReading
      /// What the production normalization makes of this reading, with no ownership context.
      let environment: Environment
    }

    func run(_ command: NativeLabCommand) async -> Int32 {
      do {
        guard monitor.registrationError == nil else {
          throw NativeLabError.refused("Native callback registration failed. No change made.")
        }
        // Yield to AppKit before the first sample, including for the read-only smoke check.
        try await Task.sleep(for: .milliseconds(100))
        switch command {
        case .check: try report("native-read-only-check")
        case .handoff(let external, let journal):
          try await handoff(external: external, path: journal)
        case .restoreChild(let journal): try await restoreChild(path: journal)
        case .supervisedExit(let external, let journal, let rehearsal):
          try await supervisedExit(external: external, path: journal, rehearsal: rehearsal)
        case .exitWriter(let external, let journal, let rehearsal):
          return await exitWriter(external: external, path: journal, rehearsal: rehearsal)
        case .unplugWriter(let external, let journal, let rehearsal):
          return await exitWriter(
            external: external, path: journal, rehearsal: rehearsal, unplug: true)
        case .sleepWriter(let external, let journal, let rehearsal):
          return await exitWriter(
            external: external, path: journal, rehearsal: rehearsal, sleep: true)
        case .mirrorWriter(let external, let journal, let rehearsal):
          return await exitWriter(
            external: external, path: journal, rehearsal: rehearsal, mirror: true)
        case .failure(let external, let journal, let ending, let rehearsal):
          try await supervisedExit(
            external: external, path: journal, rehearsal: rehearsal, ending: ending)
        }
        return 0
      } catch {
        print(
          "Native lab failed or was inconclusive: \(error). Preserve the journal and check the screens."
        )
        fflush(stdout)
        return 1
      }
    }

    func report(_ label: String) throws {
      let reading = DisplayObserver.read()
      let batch = monitor.drain()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(
        Report(
          label: label, processID: getpid(), parentPID: getppid(),
          callbacks: batch.events, droppedCallbacks: batch.dropped, reading: reading,
          environment: ControllerObservation.environment(reading, power: .awake)))
      print(String(decoding: data, as: UTF8.self))
      fflush(stdout)
    }

    private func handoff(external: UInt32, path: String) async throws {
      guard let executable = Bundle.main.executableURL else {
        throw NativeLabError.refused("Cannot resolve this app's executable. No change made.")
      }
      let target = try NativeLabSafety.baseline(DisplayObserver.read(), external: external)
      let api = PrivateDisplayAPI()
      guard api.symbolName != nil else { throw DisplayAPIError.unavailable }
      let ownerLock = try SessionWriterLock(loginID: target.loginID)
      defer { ownerLock.release() }
      let journal = RecoveryJournal(target: target, scope: "app", ownerPID: getpid())
      try journal.save(to: URL(fileURLWithPath: path))
      guard try NativeLabSafety.baseline(DisplayObserver.read(), external: external) == target
      else {
        throw NativeLabError.refused("Target changed before disabling. No change made.")
      }
      try report("native-owner-before-disable")
      print(
        "Native owner \(getpid()) will disable for approximately ten seconds, then hand restoration to its actual child. A stalled OS call can exceed that interval."
      )
      fflush(stdout)
      do {
        try api.setEnabled(false, displayID: target.displayID, scope: .forAppOnly)
        try report("native-owner-after-disable")
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
          try await Task.sleep(for: .milliseconds(100))
          let current = DisplayObserver.read()
          try NativeLabSafety.ownedContext(current, journal: journal)
          guard !current.mirroringDetected,
            current.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }),
            !current.displays.contains(where: { $0.id == target.displayID && $0.active })
          else {
            throw NativeLabError.refused(
              "The suppression or external-display prerequisites changed.")
          }
        }
        try report("native-owner-before-handoff")
      } catch {
        // No child exists yet. Errors do not establish that disabling had no side effect.
        try NativeLabSafety.ownedContext(DisplayObserver.read(), journal: journal)
        try api.setEnabled(true, displayID: target.displayID, scope: .forAppOnly)
        try await verifyRestored(journal)
        try report("native-owner-restored-before-handoff")
        throw error
      }

      ownerLock.release()
      let child = Process()
      child.executableURL = executable
      child.arguments = ["--lab-restore-child", "--journal", path]
      let outcome = await runChild(child)
      guard outcome != .terminationUnverified else {
        throw NativeLabError.refused(
          "Child termination is unverified. No second writer is allowed.")
      }
      let reacquiredLock = try SessionWriterLock(loginID: target.loginID)
      defer { reacquiredLock.release() }
      try report("native-owner-after-child-exit")
      let current = DisplayObserver.read()
      try NativeLabSafety.ownedContext(current, journal: journal)
      let decision = NativeLabHandoffDecision.decide(
        child: outcome,
        panelActive: current.displays.contains(where: { $0.id == target.displayID && $0.active }))
      switch decision {
      case .verifyOnly:
        // A successful child result plus stale owner evidence must not cause a duplicate write.
        try await verifyRestored(journal)
        try report("native-owner-verified-child-restoration")
        print(
          "Native cooperative recovery verified by child and owner. Confirm physical visibility independently."
        )
      case .restoreInOwner:
        try api.setEnabled(true, displayID: target.displayID, scope: .forAppOnly)
        try await verifyRestored(journal)
        try report("native-owner-fallback-restored")
        throw NativeLabError.refused(
          "Child recovery failed; owner fallback restored. This is not a handoff pass.")
      case .reportChildFailure:
        throw NativeLabError.refused(
          "Child failed although the panel reports active. This is not a handoff pass.")
      case .forbidSecondWriter:
        throw NativeLabError.refused(
          "Child termination is unverified. No second writer is allowed.")
      }
    }

    private func runChild(_ child: Process) async -> NativeLabChildOutcome {
      do { try child.run() } catch {
        print("Recovery child could not start: \(error)")
        return .notStarted
      }
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
      }
      if child.isRunning {
        // Only the Process instance we launched, never a process found by name or journal PID.
        kill(child.processIdentifier, SIGKILL)
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 2
        while child.isRunning && ProcessInfo.processInfo.systemUptime < reapDeadline {
          do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
      }
      guard !child.isRunning else { return .terminationUnverified }
      // A signal termination is never interpreted as successful recovery.
      return .exited(child.terminationReason == .exit ? child.terminationStatus : -1)
    }

    private func restoreChild(path: String) async throws {
      let journal = try RecoveryJournal.load(from: URL(fileURLWithPath: path))
      let lock = try SessionWriterLock(loginID: journal.target.loginID)
      defer { lock.release() }
      let current = DisplayObserver.read()
      guard journal.scope == "app" else {
        throw NativeLabError.refused("Native handoff requires application scope.")
      }
      try RecoveryIdentity.authorizeHandoff(
        journal: journal, bootID: current.bootID,
        loginID: current.loginID, parentPID: getppid(), displays: current.displays)
      try NativeLabSafety.ownedContext(current, journal: journal)
      try report("native-child-before-restoration")
      // The live actual parent provides ownership. This does not relax ordinary after-crash identity checks.
      try PrivateDisplayAPI().setEnabled(
        true, displayID: journal.target.displayID, scope: .forSession)
      try await verifyRestored(journal)
      try report("native-child-verified-restoration")
    }

    func verifyRestored(_ journal: RecoveryJournal) async throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      repeat {
        // Always service AppKit at least once before accepting restoration evidence.
        try await Task.sleep(for: .milliseconds(100))
        let reading = DisplayObserver.read()
        try NativeLabSafety.ownedContext(reading, journal: journal)
        if reading.displays.contains(where: {
          $0.id == journal.target.displayID && $0.builtIn && $0.uuid == journal.target.displayUUID
            && $0.active
        }) {
          return
        }
      } while ProcessInfo.processInfo.systemUptime < deadline
      try report("native-restoration-not-verified")
      throw NativeLabError.refused(
        "Restoration is unverified after servicing AppKit. No duplicate enable was sent.")
    }
  }
#endif
