import Darwin
import Foundation
import LidlessCore
import LidlessPlatform

/// A real-process exercise of the production protection protocol, journal, and takeover ordering.
/// It performs no display configuration at all: every write is recorded as an intention so the
/// pairing, expiry, loss, stall, and journal paths can be tested automatically on any machine.

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func fail(_ reason: String) -> Never {
  FileHandle.standardError.write(Data("probe: \(reason)\n".utf8))
  exit(64)
}

guard let role = arguments.first, let scenario = option("--scenario"),
  let workspace = option("--workspace")
else { fail("usage: (helper|controller) --scenario <name> --workspace <dir>") }

let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
let target = PanelTarget(
  displayID: 1, displayUUID: "probe-panel", bootID: "probe-boot", loginID: 4242)
let ownership = Ownership(target: target, operationID: 1)

var timing = ProtectionTiming()
timing.heartbeat = 100
timing.leaseDuration = 500
timing.stallGrace = 100

func now() -> Instant { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }

func emit(_ event: String, _ detail: String? = nil) {
  var line = #"{"event":"\#(event)""#
  if let detail { line += #","detail":"\#(detail)""# }
  line += "}\n"
  FileHandle.standardOutput.write(Data(line.utf8))
}

func emitToStderr(_ event: String, _ detail: String? = nil) {
  var line = #"{"event":"\#(event)""#
  if let detail { line += #","detail":"\#(detail)""# }
  line += "}\n"
  FileHandle.standardError.write(Data(line.utf8))
}

signal(SIGPIPE, SIG_IGN)
let store = try? ProductionJournalStore(directory: workspaceURL)
guard let store else { fail("cannot open the probe journal store") }
let deadline = now() + 15_000

// The controller speaks over inherited stdin/stdout, so its own events go to stderr.
if role == "controller" {
  let link = ProtectionLink(input: .standardInput, output: .standardOutput)
  var protection = ControllerProtection(session: "probe-session", at: now(), timing: timing)
  let writerLock = try? SessionWriterLock(loginID: target.loginID, directory: workspaceURL)
  var suppressed = false
  var beats = 0
  var restored = false
  if writerLock == nil { emitToStderr("controller-writer-lock-unavailable") }

  @MainActor func apply(_ outputs: [ControllerProtection.Output]) {
    for output in outputs {
      switch output {
      case .send(let message): try? link.send(message)
      case .protectionEstablished:
        // Ownership is durable and protected. A production controller would disable here.
        suppressed = true
        emitToStderr("controller-suppressed")
      case .protectionLost:
        emitToStderr("controller-protection-lost")
        if suppressed && !restored {
          restored = true
          emitToStderr("controller-restored-without-helper-write")
          try? store.clear()
          emitToStderr("controller-cleared-journal")
        }
      }
    }
  }

  apply(protection.receive(.start, at: now()))
  while now() < deadline {
    do {
      while let message = try link.poll() {
        apply(protection.receive(.received(message), at: now()))
      }
    } catch {
      apply(protection.receive(.peerFailed(.disconnected), at: now()))
    }
    if protection.phase == .paired {
      do {
        // Exclusive writer ownership comes before durable ownership, which comes before arming.
        guard writerLock != nil else { throw JournalError.writeFailed }
        let record = ProductionRecord(
          session: "probe-session", operationID: ownership.operationID, target: target,
          scope: "app", controllerPID: getpid(), helperPID: getppid(), topology: [])
        try store.prepare(record)
        emitToStderr("controller-journal-durable")
        apply(protection.receive(.arm(ownership), at: now()))
      } catch {
        // A persistence failure is a fault, never a reason to disable anyway.
        emitToStderr("controller-journal-failed", "\(error)")
        exit(3)
      }
    }
    if protection.phase == .protected {
      beats += 1
      if scenario == "stalled-operation" {
        // The loop stays responsive while the display call is past its deadline.
        protection.note(
          progress: .init(id: 1, kind: .disable, phase: .submitted, deadline: now() - 2_000))
      }
      if scenario == "controller-loss" && beats > 3 {
        emitToStderr("controller-abandoning-suppression")
        _ = try? FileHandle.standardError.synchronize()
        kill(getpid(), SIGKILL)
      }
      if scenario == "pairing" && beats > 6 {
        emitToStderr("controller-releasing")
        apply(protection.receive(.release, at: now()))
        try? store.clear()
        emitToStderr("controller-cleared-journal")
        exit(0)
      }
    }
    if protection.phase == .lost {
      exit(restored ? 1 : 2)
    }
    apply(protection.receive(.tick, at: now()))
    Thread.sleep(forTimeInterval: 0.02)
  }
  emitToStderr("controller-deadline")
  exit(99)
}

guard role == "helper" else { fail("unknown role") }

let commands = Pipe()
let replies = Pipe()
let link = ProtectionLink(
  input: replies.fileHandleForReading, output: commands.fileHandleForWriting)
let controller = Process()
controller.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
controller.arguments = ["controller", "--scenario", scenario, "--workspace", workspace]
controller.standardInput = commands
controller.standardOutput = replies
do { try controller.run() } catch { fail("cannot start the controller child: \(error)") }
// Close the duplicate child-side handles so EOF really means the peer is gone.
try? commands.fileHandleForReading.close()
try? replies.fileHandleForWriting.close()

var protection = HelperProtection(at: now(), timing: timing)
var takeover = RecoveryTakeover()
var lock: SessionWriterLock?
var acknowledged = 0
var recovering = false
emit("helper-started")

@MainActor func drive(_ effects: [RecoveryTakeover.Effect]) {
  for effect in effects {
    switch effect {
    case .stopWriter:
      // Only the Process this helper actually launched, never a PID read from a file.
      if controller.isRunning { kill(controller.processIdentifier, SIGKILL) }
      let stopBy = now() + 3_000
      while controller.isRunning && now() < stopBy { Thread.sleep(forTimeInterval: 0.02) }
      guard !controller.isRunning else {
        emit("helper-termination-unverified")
        drive(takeover.receive(.failed))
        return
      }
      emit("helper-confirmed-controller-termination")
      drive(takeover.receive(.writerTerminationConfirmed))
    case .acquireLock:
      do {
        lock = try SessionWriterLock(loginID: target.loginID, directory: workspaceURL)
        emit("helper-acquired-writer-lock")
        drive(takeover.receive(.lockAcquired))
      } catch {
        emit("helper-lock-unavailable")
        drive(takeover.receive(.failed))
      }
    case .inspectOwnedTarget:
      let reconciliation = store.reconcile(
        bootID: target.bootID, loginID: target.loginID, displays: [])
      guard case .unresolved(let record) = reconciliation, record.target == target else {
        emit("helper-refused-unverified-target")
        drive(takeover.receive(.failed))
        return
      }
      emit("helper-authorized-owned-target")
      drive(takeover.receive(.restoreAuthorized))
    case .restore:
      // A production helper issues one enable for the recorded panel here. The probe does not.
      emit("helper-would-restore-recorded-panel")
      drive(takeover.receive(.restoreReturned))
    case .verify:
      emit("helper-verified-restoration")
      drive(takeover.receive(.restorationVerified))
    case .clearJournal:
      do {
        try store.clear()
        emit("helper-cleared-journal")
        drive(takeover.receive(.journalCleared))
      } catch {
        emit("helper-journal-clear-failed")
        drive(takeover.receive(.failed))
      }
    }
  }
}

@MainActor func apply(_ outputs: [HelperProtection.Output]) {
  for output in outputs {
    switch output {
    case .send(let message):
      if scenario == "lease-expiry", protection.phase == .protecting, message.kind == .acknowledge {
        // Stay alive and connected but stop acknowledging. Only the controller's lease expires.
        emit("helper-withholding-acknowledgement")
        continue
      }
      try? link.send(message)
      if message.kind == .acknowledge { acknowledged += 1 }
      if message.kind == .armed { emit("helper-armed") }
    case .recoveryRequired(let owned, let reason):
      guard !recovering else { continue }
      recovering = true
      emit("helper-recovery-required", reason.rawValue)
      guard owned == ownership else {
        emit("helper-refused-unknown-ownership")
        continue
      }
      drive(takeover.receive(.recoveryNeeded))
    case .standDown:
      emit("helper-stood-down")
    }
  }
}

// The helper's own independent witness, not the controller's claim.
apply(
  protection.receive(HelperProtection.Input.witnessMatches(scenario != "unwitnessed"), at: now()))

while now() < deadline {
  do {
    while let message = try link.poll() {
      apply(protection.receive(.received(message), at: now()))
    }
  } catch {
    apply(protection.receive(.peerFailed(.disconnected), at: now()))
  }
  if scenario == "helper-loss", protection.phase == .protecting, acknowledged >= 2 {
    // Contact loss with a live, responsive controller: it must restore, not this process.
    emit("helper-closing-contact")
    try? commands.fileHandleForWriting.close()
  }
  if !controller.isRunning, protection.phase != .standingDown, !recovering {
    apply(protection.receive(.controllerExited, at: now()))
  }
  apply(protection.receive(.tick, at: now()))
  if !controller.isRunning, takeover.phase == .finished || protection.phase == .standingDown {
    break
  }
  if !controller.isRunning, takeover.phase == .blocked { break }
  Thread.sleep(forTimeInterval: 0.02)
}

let stopBy = now() + 2_000
while controller.isRunning && now() < stopBy { Thread.sleep(forTimeInterval: 0.02) }
if controller.isRunning { kill(controller.processIdentifier, SIGKILL) }
lock?.release()
link.stop()
emit("helper-finished", "takeover=\(takeover.phase) protection=\(protection.phase)")
emit("controller-exit", "\(controller.terminationReason.rawValue):\(controller.terminationStatus)")
exit(0)
