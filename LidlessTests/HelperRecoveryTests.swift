import Foundation
import LidlessCore
import LidlessPlatform
import Synchronization
import Testing

@testable import Lidless

private final class RecoveryObserver: PlatformObserving {
  let value: Mutex<PlatformReading>
  init(_ reading: PlatformReading) { value = Mutex(reading) }
  func read() -> PlatformReading { value.withLock { $0 } }
  func set(_ reading: PlatformReading) { value.withLock { $0 = reading } }
}

private final class RecoveryWriter: DisplayWriting {
  let calls = Mutex<[Bool]>([])
  func setEnabled(_ enabled: Bool, displayID: UInt32, scope: DisplayScope) throws {
    calls.withLock { $0.append(enabled) }
  }
}

/// Tests advance the production loop at its suspension points, without wall-clock sleeps.
private actor RecoveryGate {
  private var paused: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  func pause() async {
    await withCheckedContinuation { continuation in
      paused = continuation
      observer?.resume()
      observer = nil
    }
  }
  func untilPaused() async {
    if paused != nil { return }
    await withCheckedContinuation { observer = $0 }
  }
  func advance() {
    let next = paused
    paused = nil
    next?.resume()
  }
}

@MainActor struct HelperRecoveryTests {
  @Test func liveRecoveryRetainsItsLockAcrossClosedLidAndVerificationWaits() async throws {
    let baseline = try fixture()
    let target = try #require(baseline.internalTarget)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try ProductionJournalStore(directory: folder)
    let record = ProductionRecord(
      session: "test", operationID: 1, target: target, scope: "app",
      controllerPID: 123, helperPID: 456, topology: baseline.displays)
    try store.prepare(record)
    var absent = baseline
    absent.displays.removeFirst()
    absent.lid = .closed
    let observer = RecoveryObserver(absent)
    let writer = RecoveryWriter()
    let gate = RecoveryGate()
    let helper = HelperRuntime(
      executable: folder.appendingPathComponent("never-launched"),
      store: store, recoveryObserver: observer, recoveryWriter: writer,
      recoveryLockDirectory: folder, recoveryPause: { await gate.pause() })
    let recovery = Task {
      await helper.restore(
        record, reason: "test", liveOwnership: .init(target: target, operationID: 1))
    }
    await gate.untilPaused()
    #expect(writer.calls.withLock { $0 }.isEmpty)
    #expect(try store.load() == record)
    #expect(throws: WriterLockError.alreadyHeld) {
      try SessionWriterLock(loginID: target.loginID, directory: folder)
    }
    absent.lid = .open
    observer.set(absent)
    await gate.advance()
    await gate.untilPaused()
    #expect(writer.calls.withLock { $0 } == [true])
    // Lose the eligible session while the accepted write still needs visibility verification.
    absent.foregroundSession = .no
    observer.set(absent)
    await gate.advance()
    await gate.untilPaused()
    #expect(try store.load() == record)
    #expect(writer.calls.withLock { $0 } == [true])
    observer.set(baseline)
    await gate.advance()
    #expect(await recovery.value)
    #expect(try store.load() == nil)
    let released = try SessionWriterLock(loginID: target.loginID, directory: folder)
    released.release()
  }

  private func fixture() throws -> PlatformReading {
    try JSONDecoder().decode(
      PlatformReading.self,
      from: Data(
        #"""
        {"schemaVersion":1,"osVersion":"synthetic","monotonicMilliseconds":100,
         "lid":"open","bootID":"synthetic-boot","loginID":42,"foregroundSession":"yes",
         "backendValidated":false,"limitations":[],"transportEvidence":[],"displays":[
          {"id":1,"uuid":"synthetic-panel","uuidResolvedID":1,"builtIn":true,"active":true,
           "online":true,"asleep":false,"mirrored":false,"width":1512,"height":982,
           "originX":0,"originY":0,"modeAvailable":true,"transport":"unclassified"},
          {"id":5,"uuid":"synthetic-external","uuidResolvedID":5,"builtIn":false,"active":true,
           "online":true,"asleep":false,"mirrored":false,"width":1920,"height":1080,
           "originX":1512,"originY":0,"modeAvailable":true,"transport":"unclassified"}
         ]}
        """#.utf8))
  }
}
