import Foundation
import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

@Test func aRecoveryWorkerCanInheritTheExactHeldWriterLock() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let lock = try SessionWriterLock(loginID: 42, directory: directory)
  let inherited = try lock.fileHandleForInheritance()
  #expect(
    SessionWriterLock.inheritedDescriptorHoldsLock(
      inherited.fileDescriptor, loginID: 42, directory: directory
    )
  )
  #expect(
    !SessionWriterLock.inheritedDescriptorHoldsLock(
      inherited.fileDescriptor, loginID: 43, directory: directory
    )
  )
  try inherited.close()
  lock.release()
}

/// The lock file name is a cross-version contract, not a product name. A build that picks a
/// different name cannot see an older build's lock, so both would believe they are the only
/// display writer in this GUI session.
@Test func theWriterLockKeepsItsPreRenameFileName() {
  let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
  let url = SessionWriterLock.lockURL(in: directory, name: "writer", loginID: 42)
  #expect(url.lastPathComponent == "lidless-writer-\(getuid())-42.lock")
  let instance = SessionWriterLock.lockURL(in: directory, name: "instance", loginID: 42)
  #expect(instance.lastPathComponent == "lidless-instance-\(getuid())-42.lock")
}

@Test func journalRejectsDifferentBootOrLogin() {
  let target = PanelTarget(displayID: 1, displayUUID: "uuid", bootID: "boot", loginID: 42)
  let journal = RecoveryJournal(target: target, scope: "app", ownerPID: 123)
  #expect(throws: (any Error).self) { try journal.validate(bootID: "other", loginID: 42) }
  #expect(throws: (any Error).self) { try journal.validate(bootID: "boot", loginID: 43) }
  #expect(throws: (any Error).self) { try journal.validate(bootID: nil, loginID: 42) }
  #expect(throws: Never.self) { try journal.validate(bootID: "boot", loginID: 42) }
}

@Test func journalIsRoundTrippableAndCannotOverwriteExistingEvidence() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("recovery.json")
  let target = PanelTarget(displayID: 1, displayUUID: "uuid", bootID: "boot", loginID: 42)
  let journal = RecoveryJournal(target: target, scope: "app", ownerPID: 123)
  try journal.save(to: path)
  #expect(try RecoveryJournal.load(from: path) == journal)
  #expect(throws: (any Error).self) { try journal.save(to: path) }
  #expect(try RecoveryJournal.load(from: path) == journal)
}

@Test func onlyOneWriterCanOwnAGUISession() throws {
  // A private directory, not just a synthetic ID, isolates this from live and past sessions.
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let session = UInt32.random(in: 2_000_000_000 ..< 3_000_000_000)
  let first = try SessionWriterLock(loginID: session, directory: directory)
  defer { first.release() }
  #expect(throws: (any Error).self) {
    _ = try SessionWriterLock(loginID: session, directory: directory)
  }
  first.release()
  let second = try SessionWriterLock(loginID: session, directory: directory)
  second.release()
}
