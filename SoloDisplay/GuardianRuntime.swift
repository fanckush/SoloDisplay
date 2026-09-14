import AppKit
import Darwin
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform

/// The one message the guardian role accepts, on the first line of its standard input.
nonisolated struct GuardianRequest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version = currentVersion
  var parentPID: Int32
  var target: PanelTarget

  func validate(actualParentPID: Int32) throws {
    guard version == Self.currentVersion, parentPID > 1, parentPID == actualParentPID,
          target.displayID != 0, !target.displayUUID.isEmpty, !target.bootID.isEmpty
    else { throw DisplayWorkerError.invalidRequest }
  }
}

/// The app's side of a guardian. One line each way, the request out and "ready" back, then
/// "release" when nothing is owed. When the app dies its end of the pipe closes, which the
/// guardian reads as certainty that the app is gone.
@MainActor
final class GuardianProcess: GuardianControlling {
  private let executable: URL
  private var child: Process?
  private var commands: FileHandle?
  private var replies: FileHandle?

  init(executable: URL) {
    self.executable = executable
  }

  func spawn(
    target: PanelTarget, ready: @escaping @MainActor () -> Void,
    gone: @escaping @MainActor () -> Void
  ) {
    release()
    let signals = GuardianSignals(ready: ready, gone: gone)
    guard var payload = try? JSONEncoder().encode(
      GuardianRequest(parentPID: getpid(), target: target)
    ) else {
      signals.gone()
      return
    }
    payload.append(0x0A)
    let commandPipe = Pipe()
    let replyPipe = Pipe()
    let process = Process()
    process.executableURL = executable
    process.arguments = [ProductionLaunch.guardianArgument]
    process.standardInput = commandPipe
    process.standardOutput = replyPipe
    process.standardError = FileHandle.nullDevice
    replyPipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        Task { @MainActor in signals.gone() }
      } else if String(bytes: data, encoding: .utf8)?.contains("ready") == true {
        Task { @MainActor in signals.ready() }
      }
    }
    process.terminationHandler = { _ in
      Task { @MainActor in signals.gone() }
    }
    do {
      try process.run()
    } catch {
      replyPipe.fileHandleForReading.readabilityHandler = nil
      signals.gone()
      return
    }
    try? commandPipe.fileHandleForReading.close()
    try? replyPipe.fileHandleForWriting.close()
    child = process
    replies = replyPipe.fileHandleForReading
    // A failed write leaves the guardian without a request; it exits and reports itself gone.
    try? commandPipe.fileHandleForWriting.write(contentsOf: payload)
    commands = commandPipe.fileHandleForWriting
  }

  func release() {
    if let commands {
      try? commands.write(contentsOf: Data("release\n".utf8))
      try? commands.close()
    }
    commands = nil
    replies = nil
    child = nil
  }
}

/// Reports each guardian's readiness at most once, and its exit at most once.
@MainActor
private final class GuardianSignals {
  private var onReady: (@MainActor () -> Void)?
  private var onGone: (@MainActor () -> Void)?

  init(ready: @escaping @MainActor () -> Void, gone: @escaping @MainActor () -> Void) {
    onReady = ready
    onGone = gone
  }

  func ready() {
    let callback = onReady
    onReady = nil
    callback?()
  }

  func gone() {
    onReady = nil
    let callback = onGone
    onGone = nil
    callback?()
  }
}

/// The guardian role. It restores the laptop screen when the app is gone, or when the screen is
/// off with no usable monitor. It never stops the app, and it only exits once nothing is owed.
@MainActor
final class GuardianRuntime {
  private let executable: URL
  private let diagnostics: OperationalLogger
  private var request: GuardianRequest?
  private var lock: SessionWriterLock?
  private var appAlive = true
  private var dangerStreak = 0
  /// A reading or a restore is under way. The next check waits for it.
  private var busy = false
  private var timer: Timer?
  private var activity: (any NSObjectProtocol)?

  init(executable: URL, diagnostics: OperationalLogger) {
    self.executable = executable
    self.diagnostics = diagnostics
  }

  func start() {
    diagnostics.started()
    let input = FileHandle.standardInput
    guard let line = Self.readLine(from: input),
          let request = try? JSONDecoder().decode(GuardianRequest.self, from: line),
          (try? request.validate(actualParentPID: getppid())) != nil
    else { finish(.invalidLaunch) }
    // One guardian per login. An earlier one that is still restoring keeps this lock, so this
    // one exits and the app, seeing it gone, tries again later.
    guard let lock = try? SessionWriterLock(loginID: request.target.loginID, name: "guardian")
    else { finish(.alreadyRunning) }
    self.lock = lock
    self.request = request
    // The checks below are the whole point of this process, so they must not be deferred.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Keeping the laptop screen recoverable"
    )
    try? FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
    diagnostics.emit(.guardianReady)
    input.readabilityHandler = { handle in
      let data = handle.availableData
      let released = String(bytes: data, encoding: .utf8)?.contains("release") == true
      if data.isEmpty || released {
        handle.readabilityHandler = nil
      }
      Task { @MainActor [weak self] in
        if released {
          self?.finish(.released)
        } else if data.isEmpty {
          self?.appWentAway()
        }
      }
    }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.check() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    check()
  }

  private func appWentAway() {
    guard appAlive else { return }
    appAlive = false
    check()
  }

  private func check() {
    guard !busy, let request else { return }
    if getppid() != request.parentPID {
      appAlive = false
    }
    busy = true
    let target = request.target
    Task.detached { [weak self] in
      let reading = DisplayObserver.read()
      let environment = ControllerObservation.environment(
        reading, power: .awake, owned: .init(target: target, disableReturned: true)
      )
      await self?.decide(environment)
    }
  }

  private func decide(_ environment: Environment) {
    guard let request else { return }
    switch GuardianPolicy.decide(environment, appAlive: appAlive, dangerStreak: &dangerStreak) {
    case .wait:
      busy = false
    case .finish:
      // Clear the record only while it still names this panel. Nothing else is this one's.
      if let store = try? ProductionJournalStore(),
         (try? store.load())?.target == request.target {
        try? store.clear()
      }
      finish(.nothingOwed)
    case .restore:
      diagnostics.emit(.guardianRestoring, reason: appAlive ? .noUsableExternal : .appGone)
      let writer = WorkerDisplayWriter(executable: executable)
      let target = request.target
      let diagnostics = diagnostics
      Task.detached { [weak self] in
        let outcome = writer.setEnabled(true, target: target)
        diagnostics.emit(.workerFinished, succeeded: outcome == .done) {
          $0.workerAction = .enable
          $0.workerOutcome = outcome
        }
        await self?.restoreFinished()
      }
    }
  }

  private func restoreFinished() {
    busy = false
  }

  private func finish(_ reason: OperationalEvent.Reason) -> Never {
    diagnostics.emit(.exitRequested, reason: reason)
    exit(0)
  }

  /// Reads the request line byte by byte, so nothing after it is consumed before the handler.
  private nonisolated static func readLine(from input: FileHandle) -> Data? {
    var line = Data()
    while line.count <= 16384 {
      guard let byte = input.readData(ofLength: 1).first else { return nil }
      if byte == 0x0A {
        return line
      }
      line.append(byte)
    }
    return nil
  }
}
