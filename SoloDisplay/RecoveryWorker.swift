import CoreGraphics
import Darwin
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform

/// The only production message accepted by the recovery-worker role. It can request an enable,
/// never a disable, and carries the durable record the helper already validated.
nonisolated struct RecoveryWorkerRequest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version = currentVersion
  var parentPID: Int32
  var record: ProductionRecord

  func validate(actualParentPID: Int32) throws {
    guard version == Self.currentVersion, parentPID > 1, parentPID == actualParentPID else {
      throw RecoveryWorkerError.invalidRequest
    }
    try record.validate()
  }
}

nonisolated enum RecoveryWorkerError: Int, Error, CustomNSError, Sendable {
  case invalidRequest = 1
  case missingWriterLock = 2
  case launchFailed = 3
  case timedOut = 4
  case terminationUnverified = 5
  case workerFailed = 6

  static var errorDomain: String {
    "dev.solodisplay.recovery-worker"
  }

  var errorCode: Int {
    rawValue
  }

  var errorUserInfo: [String: Any] {
    [:]
  }
}

/// Runs a recovery display call outside every long-lived app process. A wedged private API can
/// strand this worker only; the helper owns the exact child, bounds it, and owns its termination.
final nonisolated class RecoveryProcessDisplayWriter: DisplayWriting, @unchecked Sendable {
  private let executable: URL
  private let record: ProductionRecord
  private let writerLock: SessionWriterLock
  private let timeout: Double

  init(
    executable: URL, record: ProductionRecord, writerLock: SessionWriterLock,
    timeout: Double = 3
  ) {
    self.executable = executable
    self.record = record
    self.writerLock = writerLock
    self.timeout = timeout
  }

  func setEnabled(_ enabled: Bool, displayID: UInt32, scope: DisplayScope) throws {
    guard enabled, scope == .session, displayID == record.target.displayID else {
      throw RecoveryWorkerError.invalidRequest
    }

    let request = RecoveryWorkerRequest(parentPID: getpid(), record: record)
    let payload = try JSONEncoder().encode(request)
    guard payload.count <= 16384 else { throw RecoveryWorkerError.invalidRequest }

    let commands = Pipe()
    let replies = Pipe()
    let inheritedLock = try writerLock.fileHandleForInheritance()
    let child = Process()
    child.executableURL = executable
    child.arguments = [ProductionLaunch.recoveryWorkerArgument]
    child.standardInput = commands
    child.standardOutput = replies
    // The duplicate shares the helper's locked open-file description. If the helper itself dies,
    // the worker still excludes every other writer until it returns or is terminated.
    child.standardError = inheritedLock

    do {
      try child.run()
    } catch {
      try? inheritedLock.close()
      throw RecoveryWorkerError.launchFailed
    }
    try? inheritedLock.close()
    try? commands.fileHandleForReading.close()
    try? replies.fileHandleForWriting.close()
    do {
      try commands.fileHandleForWriting.write(contentsOf: payload)
      try commands.fileHandleForWriting.close()
    } catch {
      guard terminate(child) else { throw RecoveryWorkerError.terminationUnverified }
      throw RecoveryWorkerError.invalidRequest
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      usleep(50000)
    }
    if child.isRunning {
      guard terminate(child) else { throw RecoveryWorkerError.terminationUnverified }
      throw RecoveryWorkerError.timedOut
    }
    _ = replies.fileHandleForReading.readDataToEndOfFile()
    guard child.terminationReason == .exit, child.terminationStatus == 0 else {
      throw RecoveryWorkerError.workerFailed
    }
  }

  private func terminate(_ child: Process) -> Bool {
    if child.isRunning {
      _ = kill(child.processIdentifier, SIGKILL)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      usleep(50000)
    }
    return !child.isRunning
  }
}

/// Runs only in the paired, pipe-backed recovery-worker role. Validation is repeated here so
/// malformed input, the wrong parent, or a missing inherited writer lock cannot reach SkyLight.
nonisolated enum RecoveryWorker {
  static func run(
    input: FileHandle = .standardInput, output: FileHandle = .standardOutput
  ) -> Int32 {
    let data = input.readData(ofLength: 16385)
    guard !data.isEmpty, data.count <= 16384,
          let request = try? JSONDecoder().decode(RecoveryWorkerRequest.self, from: data)
    else { return Int32(RecoveryWorkerError.invalidRequest.rawValue) }
    do {
      try request.validate(actualParentPID: getppid())
      guard SessionWriterLock.inheritedDescriptorHoldsLock(
        STDERR_FILENO, loginID: request.record.target.loginID
      )
      else { throw RecoveryWorkerError.missingWriterLock }
      let reading = DisplayObserver.read()
      try RecoveryIdentity.authorizeRestore(
        reading, target: request.record.target,
        liveOwnership: .init(
          target: request.record.target, operationID: request.record.operationID
        )
      )
      try PrivateDisplayAPI().setEnabled(
        true, displayID: request.record.target.displayID, scope: .forSession
      )
      try? output.write(contentsOf: Data("ok\n".utf8))
      return 0
    } catch let error as RecoveryWorkerError {
      return Int32(error.rawValue)
    } catch {
      return Int32(RecoveryWorkerError.workerFailed.rawValue)
    }
  }
}
