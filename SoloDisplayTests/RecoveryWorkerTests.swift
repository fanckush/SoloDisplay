import Foundation
import SoloDisplayCore
import SoloDisplayPlatform
import Testing
@testable import SoloDisplay

struct RecoveryWorkerTests {
  private func record() -> ProductionRecord {
    .init(
      session: UUID().uuidString, operationID: 7,
      target: .init(
        displayID: 1, displayUUID: UUID().uuidString, bootID: UUID().uuidString, loginID: 42
      ),
      scope: "app", controllerPID: 100, helperPID: 101, topology: []
    )
  }

  @Test func requestIsBoundToItsActualParentAndValidatedRecord() throws {
    let request = RecoveryWorkerRequest(parentPID: 123, record: record())
    #expect(throws: Never.self) { try request.validate(actualParentPID: 123) }
    #expect(throws: RecoveryWorkerError.self) { try request.validate(actualParentPID: 124) }
  }

  @Test func malformedRecordCannotReachTheRecoveryWorker() {
    var invalid = record()
    invalid.operationID = 0
    let request = RecoveryWorkerRequest(parentPID: 123, record: invalid)
    #expect(throws: (any Error).self) { try request.validate(actualParentPID: 123) }
  }

  @Test func recoveryProcessBoundsAndReapsANonReturningChild() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let loginID: UInt32 = 9999
    let lock = try SessionWriterLock(loginID: loginID, directory: folder)
    var owned = record()
    owned.target.loginID = loginID
    let writer = RecoveryProcessDisplayWriter(
      executable: URL(fileURLWithPath: "/usr/bin/yes"), record: owned, writerLock: lock,
      timeout: 0.1
    )

    #expect(throws: RecoveryWorkerError.timedOut) {
      try writer.setEnabled(true, displayID: owned.target.displayID, scope: .session)
    }
    lock.release()
    let reacquired = try SessionWriterLock(loginID: loginID, directory: folder)
    reacquired.release()
  }
}
