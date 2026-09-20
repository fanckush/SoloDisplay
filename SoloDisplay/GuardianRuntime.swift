import AppKit
import Darwin
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform
import Synchronization

/// Frames the app's messages. A pipe carries bytes, not messages: one read can hold half a line
/// or several at once, so lines are assembled here rather than looked for inside a chunk.
final nonisolated class GuardianLineReader: Sendable {
  /// A line longer than this is not a message this process understands, so it is dropped rather
  /// than buffered without end.
  static let limit = 16384
  private let buffer = Mutex(Data())

  func lines(_ chunk: Data) -> [Data] {
    buffer.withLock { buffer in
      buffer.append(chunk)
      var lines: [Data] = []
      while let end = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex ..< end]
        buffer = buffer[buffer.index(after: end)...]
        if line.count <= Self.limit {
          lines.append(Data(line))
        }
      }
      if buffer.count > Self.limit {
        buffer = Data()
      }
      return lines
    }
  }
}

/// The first message the guardian role accepts, on the first line of its standard input. It
/// names everything owed at the moment the guardian starts.
nonisolated struct GuardianRequest: Codable, Equatable, Sendable {
  static let currentVersion = 2

  var version = currentVersion
  var parentPID: Int32
  var targets: [PanelTarget]

  /// The laptop panel, when it is one of the things owed.
  var panel: PanelTarget? {
    targets.first { $0.kind == .builtIn }
  }

  var monitors: [PanelTarget] {
    targets.filter { $0.kind == .external }
  }

  func validate(actualParentPID: Int32) throws {
    guard version == Self.currentVersion, parentPID > 1, parentPID == actualParentPID,
          !targets.isEmpty, targets.count <= 9,
          targets.allSatisfy({
            $0.displayID != 0 && !$0.displayUUID.isEmpty && !$0.bootID.isEmpty
          }),
          targets.filter({ $0.kind == .builtIn }).count <= 1,
          Set(targets.map(\.loginID)).count == 1
    else { throw DisplayWorkerError.invalidRequest }
  }
}

/// Every later message: everything owed now, never a change to it. A whole set is idempotent and
/// cannot be applied twice or out of order, which a pipe cannot promise. The laptop panel travels
/// in it too: a guardian started for a monitor must learn about the panel before it goes off.
nonisolated struct GuardianUpdate: Codable, Equatable, Sendable {
  static let currentVersion = 2

  var version = currentVersion
  var targets: [PanelTarget]

  var panel: PanelTarget? {
    targets.first { $0.kind == .builtIn }
  }

  var monitors: [PanelTarget] {
    targets.filter { $0.kind == .external }
  }

  func validate() throws {
    guard version == Self.currentVersion, targets.count <= 9,
          targets.allSatisfy({ $0.displayID != 0 && !$0.displayUUID.isEmpty }),
          targets.filter({ $0.kind == .builtIn }).count <= 1
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
    targets: [PanelTarget], ready: @escaping @MainActor () -> Void,
    gone: @escaping @MainActor () -> Void
  ) {
    release()
    let signals = GuardianSignals(ready: ready, gone: gone)
    guard var payload = try? JSONEncoder().encode(
      GuardianRequest(parentPID: getpid(), targets: targets)
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

  /// Everything owed now, as a whole set. A guardian that is not running is told nothing: it is
  /// given the set when it starts.
  func update(targets: [PanelTarget]) {
    guard let commands, var payload = try? JSONEncoder().encode(
      GuardianUpdate(targets: targets)
    ) else { return }
    payload.append(0x0A)
    try? commands.write(contentsOf: payload)
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
  /// Everything owed right now, replaced whole whenever the app says so. It starts as what the
  /// request named and grows when the app turns something else off.
  private var monitors: [PanelTarget] = []
  private var panel: PanelTarget?
  /// Monitors this process has already asked to be turned back on, so each is asked for once.
  private var discharged: Set<UInt32> = []
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
    guard let loginID = request.targets.first?.loginID,
          let lock = try? SessionWriterLock(loginID: loginID, name: "guardian")
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
    monitors = request.monitors
    panel = request.panel
    let reader = GuardianLineReader()
    input.readabilityHandler = { handle in
      let data = handle.availableData
      var released = false
      var owed: [PanelTarget]?
      for line in reader.lines(data) {
        if String(bytes: line, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
          == "release" {
          released = true
        } else if let update = try? JSONDecoder().decode(GuardianUpdate.self, from: line),
                  (try? update.validate()) != nil {
          // The whole set, so only the last one in this chunk matters.
          owed = update.targets
        }
      }
      if data.isEmpty || released {
        handle.readabilityHandler = nil
      }
      Task { @MainActor [weak self] in
        if let owed {
          self?.owe(owed)
        }
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

  /// What the app says is owed now. Anything no longer owed is forgotten, including whether this
  /// process had already asked for it back.
  private func owe(_ owed: [PanelTarget]) {
    monitors = owed.filter { $0.kind == .external }
    // The laptop panel is never dropped by an update that does not name it: this process may be
    // the only thing left that knows the screen is off.
    if let named = owed.first(where: { $0.kind == .builtIn }) {
      panel = named
    }
    discharged = discharged.intersection(Set(monitors.map(\.displayID)))
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
    let panel = panel
    Task.detached { [weak self] in
      let reading = DisplayObserver.read()
      let environment = ControllerObservation.environment(
        reading, power: .awake,
        owned: panel.map { .init(target: $0, disableReturned: true) }
      )
      await self?.decide(environment)
    }
  }

  private func decide(_ environment: Environment) {
    guard let request else { return }
    // A guardian holding monitors and no laptop panel has nothing to say about `panelState`. It
    // waits while the app is alive, exactly as it would for a panel that is on, and only once
    // the app is gone is there nothing left for it to do.
    let panelAction: GuardianAction = if panel == nil {
      appAlive ? .wait : .finish
    } else {
      GuardianPolicy.decide(environment, appAlive: appAlive, dangerStreak: &dangerStreak)
    }
    // The laptop screen comes first: nobody can act on a monitor they cannot see.
    if case .restore = panelAction, let panel {
      restore(panel, reason: appAlive ? .noUsableExternal : .appGone)
      return
    }
    let owed = GuardianPolicy.monitorsToRestore(
      monitors, appAlive: appAlive, discharged: discharged
    )
    if let monitor = owed.first {
      // Asked for once each. There is no evidence left to wait for: a monitor that is off is not
      // in the display list at all, and this process never asks a monitor anything.
      discharged.insert(monitor.displayID)
      restore(monitor, reason: .appGone)
      return
    }
    switch panelAction {
    case .wait:
      busy = false
    case .finish:
      // Nothing is owed only once the monitors are accounted for as well.
      guard owed.isEmpty else {
        busy = false
        return
      }
      clearOwnership(request)
      finish(.nothingOwed)
    case .restore:
      busy = false
    }
  }

  private func clearOwnership(_ request: GuardianRequest) {
    // Clear a record only while it still names what this guardian was given. Nothing else is
    // this one's to release.
    if let panel, let store = try? ProductionJournalStore(),
       (try? store.load())?.target == panel {
      try? store.clear()
    }
    if !request.monitors.isEmpty || !monitors.isEmpty,
       let store = try? ExternalSuppressionStore(), store.load() != nil {
      try? store.clear()
    }
  }

  private func restore(_ target: PanelTarget, reason: OperationalEvent.Reason) {
    diagnostics.emit(.guardianRestoring, reason: reason)
    let writer = WorkerDisplayWriter(executable: executable)
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
