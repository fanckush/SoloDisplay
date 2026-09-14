import CoreGraphics
import Darwin
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform

/// One display change for the worker role. It names the whole panel identity, so the worker can
/// check that identity itself immediately before it calls into SkyLight.
nonisolated struct DisplayWorkerRequest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version = currentVersion
  var parentPID: Int32
  var enabled: Bool
  var target: PanelTarget

  func validate(actualParentPID: Int32) throws {
    guard version == Self.currentVersion, parentPID > 1, parentPID == actualParentPID,
          target.displayID != 0, !target.displayUUID.isEmpty, !target.bootID.isEmpty
    else { throw DisplayWorkerError.invalidRequest }
  }
}

nonisolated enum DisplayWorkerError: Int, Error, CustomNSError, Sendable {
  case invalidRequest = 1
  case launchFailed = 3
  case timedOut = 4
  case terminationUnverified = 5
  case workerFailed = 6
  /// The worker's own check found the request no longer applies. Nothing was sent.
  case refused = 7

  static var errorDomain: String {
    "dev.solodisplay.display-worker"
  }

  var errorCode: Int {
    rawValue
  }

  var errorUserInfo: [String: Any] {
    [:]
  }
}

/// Runs every display change in its own short-lived worker process. The private call can block,
/// during sleep or a hotplug, so no long-lived SoloDisplay process ever makes it. A worker that
/// does not finish is killed. That says nothing about the display: the next reading decides.
final nonisolated class WorkerDisplayWriter: DisplayWriting, @unchecked Sendable {
  private let executable: URL
  private let timeout: Double

  init(executable: URL, timeout: Double = 10) {
    self.executable = executable
    self.timeout = timeout
  }

  func setEnabled(_ enabled: Bool, target: PanelTarget) -> WorkerOutcome {
    let request = DisplayWorkerRequest(parentPID: getpid(), enabled: enabled, target: target)
    guard let payload = try? JSONEncoder().encode(request), payload.count <= 16384 else {
      return .failed
    }

    let commands = Pipe()
    let replies = Pipe()
    let child = Process()
    child.executableURL = executable
    child.arguments = [ProductionLaunch.workerArgument]
    child.standardInput = commands
    child.standardOutput = replies
    do {
      try child.run()
    } catch {
      return .failed
    }
    try? commands.fileHandleForReading.close()
    try? replies.fileHandleForWriting.close()
    do {
      try commands.fileHandleForWriting.write(contentsOf: payload)
      try commands.fileHandleForWriting.close()
    } catch {
      terminate(child)
      return .failed
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      usleep(20000)
    }
    if child.isRunning {
      terminate(child)
      return .killed
    }
    _ = replies.fileHandleForReading.readDataToEndOfFile()
    guard child.terminationReason == .exit else { return .failed }
    switch child.terminationStatus {
    case 0: return .done
    case Int32(DisplayWorkerError.refused.rawValue): return .refused
    default: return .failed
    }
  }

  /// Kills the child. If the OS cannot reap it at once, it still makes no further decision:
  /// the next reading does.
  private func terminate(_ child: Process) {
    if child.isRunning {
      _ = kill(child.processIdentifier, SIGKILL)
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      usleep(20000)
    }
  }
}

/// The worker role: read one request from the parent's pipe, check it against a fresh reading,
/// make the call with session scope so it outlives this process, and exit.
nonisolated enum DisplayWorker {
  static func run(
    input: FileHandle = .standardInput, output: FileHandle = .standardOutput
  ) -> Int32 {
    let data = input.readData(ofLength: 16385)
    guard !data.isEmpty, data.count <= 16384,
          let request = try? JSONDecoder().decode(DisplayWorkerRequest.self, from: data)
    else { return Int32(DisplayWorkerError.invalidRequest.rawValue) }
    do {
      try request.validate(actualParentPID: getppid())
      try check(request, against: DisplayObserver.read())
      try PrivateDisplayAPI().setEnabled(
        request.enabled, displayID: request.target.displayID, scope: .forSession
      )
      try? output.write(contentsOf: Data("ok\n".utf8))
      return 0
    } catch let error as DisplayWorkerError {
      return Int32(error.rawValue)
    } catch {
      return Int32(DisplayWorkerError.workerFailed.rawValue)
    }
  }

  /// Checked here rather than trusted from the parent, because the parent's view is already
  /// history by the time this process runs.
  static func check(_ request: DisplayWorkerRequest, against reading: PlatformReading) throws {
    if request.enabled {
      // The parent is the live process that turned this panel off, so an absent panel is its
      // own suppression rather than a guess about a display it cannot see.
      guard (try? RecoveryIdentity.authorizeRestore(
        reading, target: request.target, ownedTarget: request.target
      )) != nil
      else { throw DisplayWorkerError.refused }
    } else {
      guard reading.enumerationError == nil, reading.internalTarget == request.target,
            reading.lid == .open, reading.foregroundSession == .yes
      else { throw DisplayWorkerError.refused }
    }
  }
}
