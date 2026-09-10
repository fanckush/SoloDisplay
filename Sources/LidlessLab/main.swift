import ColorSync
import CoreGraphics
import Darwin
import Foundation
import LidlessCore
import LidlessPlatform

enum LabError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(message): message
    }
  }
}

func utf8String(_ data: Data) throws -> String {
  guard let text = String(bytes: data, encoding: .utf8) else {
    throw LabError.message("Failed to encode UTF-8 output")
  }
  return text
}

func emit(_ value: some Encodable) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  try print(utf8String(encoder.encode(value)))
}

struct ProbeObservation: Encodable {
  var label: String
  var processID: Int32
  var callbackRegistrationError: Int32?
  var callbacks: [DisplayChangeEvent]
  var droppedCallbacks: Int
  var reading: PlatformReading
}

func recordObservation(_ label: String, monitor: DisplayEventMonitor) throws {
  let reading = DisplayObserver.read()
  let events = monitor.drain()
  try emit(
    ProbeObservation(
      label: label, processID: getpid(), callbackRegistrationError: monitor.registrationError,
      callbacks: events.events, droppedCallbacks: events.dropped, reading: reading
    )
  )
  fflush(stdout)
}

let usage = """
lidless-lab observe
    Read-only display and capability report. This is the default command.

lidless-lab replay <trace.json>
    Replay a normalized controller trace without changing displays.

lidless-lab example-trace
    Print a sanitized synthetic trace for replay experiments. Does not access displays.

lidless-lab probe --external <id> --scope app|session --journal <new-path> --native-wired-attested [--ending restore|exit|handoff]
    GUIDED LAB ONLY. Disable the current internal panel for up to 10 seconds,
    then request restoration. The operator must confirm the named external is
    a visible native wired display. This is not production capability detection.
    Run observe first. Keep the lid open for the initial experiment.
    Default ending: restore. The separate guided exit experiment requires app
    scope and deliberately exits without enabling. Have the restore command ready.
    The handoff experiment retains the original owner while a child restores the
    panel under an exclusive writer lock. It does not establish crash recovery.

lidless-lab restore --journal <path>
    Request restoration of the journaled panel in the same boot and GUI session.
    Do not run while the probe process is alive. An accepted request is not proof
    that the physical panel recovered. Journals are retained for inspection.
"""

func options(_ args: ArraySlice<String>) throws -> [String: String] {
  var result: [String: String] = [:]
  var iterator = args.makeIterator()
  while let key = iterator.next() {
    guard result[key] == nil else { throw LabError.message("Duplicate option: \(key)") }
    if key == "--native-wired-attested" {
      result[key] = "true"
    } else {
      guard ["--external", "--scope", "--journal", "--ending"].contains(key),
            let value = iterator.next()
      else {
        throw LabError.message("Unknown or incomplete option: \(key)")
      }
      result[key] = value
    }
  }
  return result
}

func required(_ key: String, from options: [String: String]) throws -> String {
  guard let value = options[key] else { throw LabError.message("Required option: \(key)") }
  return value
}

func probe(_ flags: [String: String]) throws {
  let monitor = DisplayEventMonitor()
  guard monitor.registrationError == nil else {
    throw LabError.message("Display callback registration failed. No change made.")
  }
  guard flags["--native-wired-attested"] == "true",
        let external = try UInt32(required("--external", from: flags))
  else {
    throw LabError.message("A confirmed native wired external display ID is required.")
  }
  let scope = try required("--scope", from: flags)
  guard scope == "app" || scope == "session" else {
    throw LabError.message("Scope must be app or session.")
  }
  let ending = flags["--ending"] ?? "restore"
  guard ending == "restore" || (["exit", "handoff"].contains(ending) && scope == "app") else {
    throw LabError.message(
      "Ending must be restore, exit, or handoff. Exit and handoff experiments require app scope."
    )
  }
  let journalURL = try URL(fileURLWithPath: required("--journal", from: flags))
  let first = DisplayObserver.read()
  guard first.enumerationError == nil, first.lid == .open, first.foregroundSession == .yes,
        let target = first.internalTarget,
        first.displays.contains(where: { $0.id == target.displayID && $0.active }),
        first.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }),
        !first.displays.contains(where: \.mirrored)
  else {
    throw LabError.message(
      "Probe prerequisites unavailable. Run observe from a local GUI Terminal with the lid open and an active external display."
    )
  }
  let api = PrivateDisplayAPI()
  guard api.symbolName != nil else { throw DisplayAPIError.unavailable }
  let writerLock = try SessionWriterLock(loginID: target.loginID)
  defer { writerLock.release() }
  let journal = RecoveryJournal(target: target, scope: scope, ownerPID: getpid())
  try journal.save(to: journalURL)
  let second = DisplayObserver.read()
  guard second.internalTarget == target, second.foregroundSession == .yes, second.lid == .open,
        second.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }),
        !second.displays.contains(where: \.mirrored)
  else {
    throw LabError.message(
      "Environment changed before the probe. No disable request was sent. Journal retained."
    )
  }
  print("Probe PID: \(getpid()). Recovery journal: \(journalURL.path)")
  print(
    "Requesting internal display disable with \(scope) scope. Planned ending in 10 seconds: \(ending). A blocked process cannot meet that deadline."
  )
  fflush(stdout)
  let configScope: CGConfigureOption = scope == "app" ? .forAppOnly : .forSession
  var failure: (any Error)?
  var interrupted = false
  do {
    try api.setEnabled(false, displayID: target.displayID, scope: configScope)
    try recordObservation("owner-after-disable", monitor: monitor)
    let uuid = CFUUIDCreateFromString(nil, target.displayUUID as CFString)
    let resolvedID = uuid.map { CGDisplayGetDisplayIDFromUUID($0) }
    print(
      "Owned UUID resolves during suppression: \(resolvedID == target.displayID) (resolved ID: \(resolvedID.map(String.init) ?? "unavailable"), recorded ID: \(target.displayID))"
    )
    if ending == "exit", resolvedID != target.displayID {
      throw LabError.message(
        "Cross-process recovery identity is not resolvable. Restoring explicitly instead of testing exit."
      )
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
      let current = DisplayObserver.read()
      if current.lid != .open || current.foregroundSession != .yes
        || !current.displays.contains(where: { $0.id == external && $0.usableExternalCandidate }) {
        interrupted = true
        break
      }
    }
  } catch {
    failure = error
    print("Probe returned an error: \(error). Attempting restoration of the owned target.")
  }
  if ending == "exit", failure == nil, !interrupted {
    print(
      "Exiting without explicit restoration. Observe OS rollback, then use the recorded journal if needed."
    )
    fflush(stdout)
    exit(0)
  }
  if ending == "handoff", failure == nil, !interrupted {
    try cooperativeRecovery(
      journal: journal, journalURL: journalURL, writerLock: writerLock, monitor: monitor
    )
    return
  }
  try api.setEnabled(true, displayID: target.displayID, scope: configScope)
  try verifyRestored(target.displayID)
  try recordObservation("owner-after-explicit-restore", monitor: monitor)
  print(
    "Internal display reported active. Confirm visibility yourself. Journal retained as experiment evidence."
  )
  if let failure {
    throw failure
  }
}

func verifyRestored(_ displayID: UInt32) throws {
  let deadline = ProcessInfo.processInfo.systemUptime + 3
  repeat {
    if CGDisplayIsBuiltin(displayID) != 0, CGDisplayIsActive(displayID) != 0 {
      return
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
  } while ProcessInfo.processInfo.systemUptime < deadline
  throw LabError.message(
    "Restoration request returned, but the internal display was not verified active. Keep the journal. A closed lid or sleeping system cannot prove visibility."
  )
}

func restore(_ flags: [String: String]) throws {
  guard Set(flags.keys) == ["--journal"] else {
    throw LabError.message("restore accepts only --journal.")
  }
  let journal = try RecoveryJournal.load(
    from: URL(fileURLWithPath: required("--journal", from: flags))
  )
  let reading = DisplayObserver.read()
  try journal.validate(bootID: reading.bootID, loginID: reading.loginID)
  let writerLock = try SessionWriterLock(loginID: journal.target.loginID)
  defer { writerLock.release() }
  guard reading.foregroundSession == .yes else {
    throw LabError.message("Restoration requires the foreground GUI session.")
  }
  try RecoveryIdentity.checkCurrentDisplays(reading.displays, target: journal.target)
  // A reused PID causes a conservative refusal rather than risking two writers.
  errno = 0
  guard journal.ownerPID > 1, kill(journal.ownerPID, 0) == -1, errno == ESRCH else {
    throw LabError.message(
      "The recorded writer may still be alive. Establish that it has exited before recovery."
    )
  }
  if let current = reading.displays.first(where: { $0.id == journal.target.displayID }) {
    guard current.builtIn, current.uuid == journal.target.displayUUID else {
      throw LabError.message("The target now identifies a different display. No change was made.")
    }
    if current.active {
      print("Internal display already reports active. No change made.")
      return
    }
  }
  guard let uuid = CFUUIDCreateFromString(nil, journal.target.displayUUID as CFString),
        CGDisplayGetDisplayIDFromUUID(uuid) == journal.target.displayID
  else {
    throw LabError.message("The recorded display UUID cannot be resolved to the owned target.")
  }
  let api = PrivateDisplayAPI()
  // A recovery process must not undo its enable request on its own exit.
  try api.setEnabled(true, displayID: journal.target.displayID, scope: .forSession)
  try verifyRestored(journal.target.displayID)
  print("Internal display reported active. Confirm visibility yourself. Journal retained.")
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first ?? "observe" {
  case "observe":
    guard args.count <= 1 else { throw LabError.message("observe takes no options.") }
    try emit(DisplayObserver.read())
  case "replay":
    guard args.count == 2 else { throw LabError.message("replay requires one trace path.") }
    let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    guard data.count <= 5_000_000 else { throw LabError.message("Trace exceeds 5 MB.") }
    let trace = try JSONDecoder().decode(ReplayTrace.self, from: data)
    guard trace.events.count <= 10000 else {
      throw LabError.message("Trace exceeds 10,000 events.")
    }
    try emit(trace.replay())
  case "example-trace":
    guard args.count == 1 else { throw LabError.message("example-trace takes no options.") }
    var recorder = TraceRecorder(initial: .init(mode: .automatic))
    let target = PanelTarget(
      displayID: 17, displayUUID: "synthetic-panel", bootID: "synthetic-boot", loginID: 29
    )
    var environment = Environment(
      panel: target, panelState: .enabled, power: .awake, lid: .open,
      foregroundSession: .yes, nativeExternalAvailable: .yes,
      supportedTopology: .yes, backendValidated: .yes
    )
    try recorder.append(
      .init(at: 0, event: .observed(.init(sequence: 1, sampledAt: 0, environment: environment)))
    )
    try recorder.append(
      .init(
        at: 2000, event: .observed(.init(sequence: 2, sampledAt: 2000, environment: environment))
      )
    )
    try recorder.append(.init(at: 2001, event: .journalSaved(operationID: 1, succeeded: true)))
    try recorder.append(
      .init(at: 2010, event: .operationReturned(operationID: 1, succeeded: true))
    )
    environment.panelState = .disabled
    try recorder.append(
      .init(
        at: 2020, event: .observed(.init(sequence: 3, sampledAt: 2020, environment: environment))
      )
    )
    environment.nativeExternalAvailable = .no
    try recorder.append(
      .init(
        at: 3000, event: .observed(.init(sequence: 4, sampledAt: 3000, environment: environment))
      )
    )
    try recorder.append(
      .init(at: 3010, event: .operationReturned(operationID: 2, succeeded: true))
    )
    environment.panelState = .enabled
    try recorder.append(
      .init(
        at: 3020, event: .observed(.init(sequence: 5, sampledAt: 3020, environment: environment))
      )
    )
    try print(utf8String(recorder.exportSanitized()))
  case "probe": try probe(options(args.dropFirst()))
  case "restore": try restore(options(args.dropFirst()))
  case "restore-child": try restoreChild(options(args.dropFirst()))
  case "help", "--help", "-h": print(usage)
  default: throw LabError.message(usage)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
