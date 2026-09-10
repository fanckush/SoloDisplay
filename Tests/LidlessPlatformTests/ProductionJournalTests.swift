import Foundation
import LidlessCore
import Testing
@testable import LidlessPlatform

private func workspace() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("lidless-journal-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private let target = PanelTarget(
  displayID: 4, displayUUID: "built-in", bootID: "boot-a", loginID: 501
)

private func record(
  session: String = "run-1", operationID: UInt64 = 1, target: PanelTarget = target,
  topology: [DisplayReading] = []
) -> ProductionRecord {
  .init(
    session: session, operationID: operationID, target: target, scope: "app",
    controllerPID: 100, helperPID: 99, topology: topology
  )
}

struct ProductionJournalTests {
  @Test func ownershipIsWrittenPrivatelyAndCannotBeSilentlyOverwritten() throws {
    let store = try ProductionJournalStore(directory: workspace())
    try store.prepare(record())
    #expect(try store.load()?.operationID == 1)

    // A second preparation means unresolved ownership, not a new experiment.
    #expect(throws: JournalError.self) { try store.prepare(record(operationID: 2)) }
    #expect(try store.load()?.operationID == 1)

    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    let directory = try FileManager.default.attributesOfItem(
      atPath: store.url.deletingLastPathComponent().path
    )
    #expect(directory[.posixPermissions] as? NSNumber == 0o700)
  }

  @Test func reconciliationSeparatesThisSessionFromAPriorOne() throws {
    let store = try ProductionJournalStore(directory: workspace())
    #expect(store.reconcile(bootID: "boot-a", loginID: 501, displays: []) == .clean)

    try store.prepare(record())
    guard
      case let .unresolved(unresolved) = store.reconcile(
        bootID: "boot-a", loginID: 501, displays: []
      )
    else {
      Issue.record("expected unresolved ownership for this boot and login")
      return
    }
    #expect(unresolved.target == target)

    // The same record on another boot or login is not authority to write that display ID.
    guard case .priorSession = store.reconcile(bootID: "boot-b", loginID: 501, displays: []) else {
      Issue.record("expected a prior-session classification for a different boot")
      return
    }
    guard case .priorSession = store.reconcile(bootID: "boot-a", loginID: 502, displays: []) else {
      Issue.record("expected a prior-session classification for a different login")
      return
    }
  }

  @Test func everyLeftoverRecordInhibitsANewDisableUntilItIsResolved() throws {
    let store = try ProductionJournalStore(directory: workspace())
    #expect(!store.reconcile(bootID: "boot-a", loginID: 501, displays: []).inhibitsDisabling)
    try store.prepare(record())
    for reconciliation in [
      store.reconcile(bootID: "boot-a", loginID: 501, displays: []),
      store.reconcile(bootID: "boot-b", loginID: 501, displays: []),
      store.reconcile(bootID: nil, loginID: nil, displays: [])
    ] {
      #expect(reconciliation.inhibitsDisabling)
      #expect(reconciliation.explanation != nil)
    }
  }

  @Test func liveEvidenceContradictingTheRecordIsRetainedRatherThanActedOn() throws {
    let store = try ProductionJournalStore(directory: workspace())
    try store.prepare(record())
    let impostor = DisplayReading(
      id: 9, uuid: "someone-else", uuidResolvedID: 9, builtIn: true, active: true, online: true,
      asleep: false, mirrored: false, mirrorSourceID: nil, width: 1, height: 1, originX: 0,
      originY: 0, modeAvailable: true
    )
    guard
      case let .retained(explanation) = store.reconcile(
        bootID: "boot-a", loginID: 501, displays: [impostor]
      )
    else {
      Issue.record("a contradicting built-in panel must not be treated as owned")
      return
    }
    #expect(!explanation.isEmpty)
    // Nothing was cleared: the evidence survives for the next attempt.
    #expect(try store.load() != nil)
  }

  @Test func corruptAndUnsupportedRecordsAreKeptAndExplained() throws {
    let directory = try workspace()
    let store = try ProductionJournalStore(directory: directory)
    try Data("not a journal".utf8).write(to: store.url)
    guard case .retained = store.reconcile(bootID: "boot-a", loginID: 501, displays: []) else {
      Issue.record("a corrupt record must inhibit disabling")
      return
    }

    var future = record()
    future.schemaVersion = ProductionRecord.currentSchema + 1
    try FileManager.default.removeItem(at: store.url)
    try Data(JSONEncoder().encode(future)).write(to: store.url)
    guard case .retained = store.reconcile(bootID: "boot-a", loginID: 501, displays: []) else {
      Issue.record("an unsupported schema must inhibit disabling")
      return
    }
    #expect(FileManager.default.fileExists(atPath: store.url.path))
  }

  @Test func recordsCarryTheTopologyRecoveryNeedsToVerify() throws {
    let store = try ProductionJournalStore(directory: workspace())
    let external = DisplayReading(
      id: 5, uuid: "external", uuidResolvedID: 5, builtIn: false, active: true, online: true,
      asleep: false, mirrored: true, mirrorSourceID: nil, width: 1920, height: 1080, originX: -194,
      originY: -1080, modeAvailable: true
    )
    try store.prepare(record(topology: [external]))
    let loaded = try #require(try store.load())
    #expect(loaded.topology == [external])
    #expect(loaded.scope == "app")
  }

  @Test func clearingIsIdempotentAndOnlyRemovesResolvedOwnership() throws {
    let store = try ProductionJournalStore(directory: workspace())
    try store.prepare(record())
    try store.clear()
    #expect(try store.load() == nil)
    #expect(throws: Never.self) { try store.clear() }
    // Ownership can be established again once nothing is unresolved.
    #expect(throws: Never.self) { try store.prepare(record(operationID: 2)) }
  }

  @Test func invalidRecordsAreRefusedBeforeAnythingIsWritten() throws {
    let store = try ProductionJournalStore(directory: workspace())
    var missingIdentity = record()
    missingIdentity.target.displayUUID = ""
    #expect(throws: JournalError.self) { try store.prepare(missingIdentity) }
    var unknownScope = record()
    unknownScope.scope = "everything"
    #expect(throws: JournalError.self) { try store.prepare(unknownScope) }
    #expect(try store.load() == nil)
  }
}
