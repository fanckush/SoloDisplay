import Foundation
import LidlessCore
import Testing
@testable import LidlessPlatform

/// Real paired processes over inherited private pipes. The probe never configures a display,
/// so these run anywhere: what they establish is the pairing, expiry, loss, stall, takeover
/// ordering, and journal handling, not any physical recovery.
private struct ProbeRun {
  let events: [(name: String, detail: String?)]
  let terminationReason: Process.TerminationReason
  let terminationStatus: Int32
  let workspace: URL

  var names: [String] {
    events.map(\.name)
  }

  var operational: [OperationalEvent] {
    events.compactMap {
      guard $0.name == "operational", let detail = $0.detail else { return nil }
      return try? JSONDecoder().decode(OperationalEvent.self, from: Data(detail.utf8))
    }
  }

  func detail(of name: String) -> String? {
    events.first { $0.name == name }?.detail
  }

  func contains(_ name: String) -> Bool {
    names.contains(name)
  }

  var journalRemains: Bool {
    FileManager.default.fileExists(atPath: workspace.appendingPathComponent("recovery.json").path)
  }
}

private func probeExecutable() throws -> URL {
  var candidates: [URL] = []
  if let bundle = ProcessInfo.processInfo.environment["XCTestBundlePath"] {
    candidates.append(URL(fileURLWithPath: bundle).deletingLastPathComponent())
  }
  candidates.append(Bundle.main.bundleURL)
  candidates.append(Bundle.main.bundleURL.deletingLastPathComponent())
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  for configuration in ["debug", "release"] {
    candidates.append(root.appendingPathComponent(".build/\(configuration)", isDirectory: true))
  }
  for directory in candidates {
    let candidate = directory.appendingPathComponent("lidless-probe")
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  throw ProbeError.notBuilt
}

private enum ProbeError: Error { case notBuilt }

/// Runs the helper, which spawns its own controller child. Returns the helper's event stream.
private func run(_ scenario: String, seeding: ProductionRecord? = nil) throws -> ProbeRun {
  let workspace = FileManager.default.temporaryDirectory
    .appendingPathComponent("lidless-probe-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  if let seeding {
    try ProductionJournalStore(directory: workspace).prepare(seeding)
  }
  let process = Process()
  process.executableURL = try probeExecutable()
  process.arguments = [
    "helper", "--scenario", scenario, "--workspace", workspace.path
  ]
  let output = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = try #require(String(bytes: data, encoding: .utf8))
  let events = text.split(separator: "\n").compactMap { line -> (String, String?)? in
    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
          let name = json["event"]
    else { return nil }
    return (name, json["detail"])
  }
  return .init(
    events: events, terminationReason: process.terminationReason,
    terminationStatus: process.terminationStatus, workspace: workspace
  )
}

private let probeTarget = PanelTarget(
  displayID: 1, displayUUID: "probe-panel", bootID: "probe-boot", loginID: 4242
)

struct ProtectionProcessTests {
  @Test func pairedProcessesArmProtectAndReleaseWithoutLeavingOwnership() throws {
    let outcome = try run("pairing")
    #expect(outcome.contains("helper-armed"))
    #expect(outcome.contains("helper-stood-down"))
    // A released panel leaves the helper nothing to restore and nothing to recover from.
    #expect(!outcome.contains("helper-recovery-required"))
    #expect(!outcome.contains("helper-would-restore-recorded-panel"))
    #expect(!outcome.journalRemains)
    #expect(outcome.detail(of: "controller-exit") == "1:0")
    #expect(outcome.operational.filter { $0.code == .childExited }.count == 1)
    #expect(outcome.operational.last?.reason == .exited)
    #expect(outcome.operational.last?.exitStatus == 0)
  }

  @Test func aControllerWithNoHelperWitnessNeverGetsProtection() throws {
    let outcome = try run("unwitnessed")
    #expect(!outcome.contains("helper-armed"))
    #expect(outcome.contains("helper-stood-down"))
    #expect(!outcome.contains("helper-would-restore-recorded-panel"))
    // The controller's lease expired instead of assuming protection; exit 2 is "never suppressed".
    #expect(outcome.detail(of: "controller-exit") == "1:2")
  }

  @Test func aJournalFailureStopsTheRunBeforeAnythingIsArmed() throws {
    let seeded = ProductionRecord(
      session: "earlier-run", operationID: 9, target: probeTarget, scope: "app",
      controllerPID: 1, helperPID: 1, topology: []
    )
    let outcome = try run("pairing", seeding: seeded)
    #expect(!outcome.contains("helper-armed"))
    #expect(outcome.contains("helper-stood-down"))
    // Unresolved ownership is retained for reconciliation, not overwritten by the new run.
    #expect(outcome.journalRemains)
    #expect(outcome.detail(of: "controller-exit") == "1:3")
  }

  @Test func aSilentHelperMakesTheResponsiveControllerRestoreAndTheHelperNotWrite() throws {
    let outcome = try run("lease-expiry")
    #expect(outcome.contains("helper-withholding-acknowledgement"))
    // The controller restored its own panel and cleared ownership, so the helper found nothing.
    #expect(outcome.contains("helper-refused-unverified-target"))
    #expect(!outcome.contains("helper-would-restore-recorded-panel"))
    #expect(!outcome.journalRemains)
    #expect(outcome.detail(of: "controller-exit") == "1:1")
  }

  @Test func lostHelperContactAlsoLeavesRecoveryToTheResponsiveController() throws {
    let outcome = try run("helper-loss")
    #expect(outcome.contains("helper-closing-contact"))
    #expect(outcome.contains("helper-refused-unverified-target"))
    #expect(!outcome.contains("helper-would-restore-recorded-panel"))
    #expect(!outcome.journalRemains)
    #expect(outcome.detail(of: "controller-exit") == "1:1")
  }

  @Test func aKilledControllerIsRecoveredInTakeoverOrder() throws {
    let outcome = try run("controller-loss")
    let ordered = outcome.names.filter {
      [
        "helper-recovery-required", "helper-confirmed-controller-termination",
        "helper-acquired-writer-lock", "helper-authorized-owned-target",
        "helper-would-restore-recorded-panel", "helper-verified-restoration",
        "helper-cleared-journal"
      ].contains($0)
    }
    // Termination and the writer lock come before any write, and clearing comes after verifying.
    #expect(
      ordered == [
        "helper-recovery-required", "helper-confirmed-controller-termination",
        "helper-acquired-writer-lock", "helper-authorized-owned-target",
        "helper-would-restore-recorded-panel", "helper-verified-restoration",
        "helper-cleared-journal"
      ]
    )
    #expect(outcome.detail(of: "helper-recovery-required") == "contactLost")
    #expect(outcome.detail(of: "helper-finished") == "takeover=finished protection=revoked")
    #expect(!outcome.journalRemains)
    // The controller died by signal without restoring anything itself.
    #expect(outcome.detail(of: "controller-exit") == "2:9")
  }

  @Test func aResponsiveControllerWithAStalledCallIsStoppedThenRecovered() throws {
    let outcome = try run("stalled-operation")
    #expect(outcome.detail(of: "helper-recovery-required") == "operationStalled")
    // The heartbeat loop was healthy, so only the operation deadline could reveal this.
    #expect(outcome.contains("helper-confirmed-controller-termination"))
    #expect(outcome.contains("helper-would-restore-recorded-panel"))
    #expect(outcome.contains("helper-cleared-journal"))
    #expect(!outcome.journalRemains)
    #expect(outcome.detail(of: "controller-exit") == "2:9")
    let records = outcome.operational
    #expect(
      records.map(\.code) == [
        .recoveryRequested, .childTerminationRequested,
        .childExited, .writerLockAcquired, .journalCleared
      ]
    )
    #expect(records.first?.helperLoss == .operationStalled)
    #expect(records.first?.operation?.phase == .submitted)
    #expect(records.first?.progressAgeMS != nil)
    #expect(records.filter { $0.code == .childExited }.count == 1)
  }

  @Test func theHelperTakesTheWriterLockOnlyAfterItsControllerIsGone() throws {
    let outcome = try run("controller-loss")
    let terminated = try #require(
      outcome.names.firstIndex(of: "helper-confirmed-controller-termination")
    )
    let locked = try #require(outcome.names.firstIndex(of: "helper-acquired-writer-lock"))
    #expect(terminated < locked)
    // No lock is left behind holding out a future run.
    #expect(throws: Never.self) {
      let lock = try SessionWriterLock(loginID: probeTarget.loginID, directory: outcome.workspace)
      lock.release()
    }
  }
}
