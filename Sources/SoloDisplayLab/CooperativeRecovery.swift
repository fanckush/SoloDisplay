import CoreGraphics
import Darwin
import Foundation
import SoloDisplayPlatform

/// Lab experiment only. The original writer stays alive, but releases its writer lock
/// before spawning the child. It never writes until the child exits and the lock is reacquired.
func cooperativeRecovery(
  journal: RecoveryJournal, journalURL: URL, writerLock: SessionWriterLock,
  monitor: DisplayEventMonitor
) throws {
  try recordObservation("owner-before-handoff", monitor: monitor)
  writerLock.release()
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  child.arguments = ["restore-child", "--journal", journalURL.path]
  var childError: (any Error)?
  do {
    try child.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while child.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    if child.isRunning {
      // This is the exact child this experiment spawned, never a process selected by name.
      kill(child.processIdentifier, SIGKILL)
      let reapDeadline = ProcessInfo.processInfo.systemUptime + 2
      while child.isRunning, ProcessInfo.processInfo.systemUptime < reapDeadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
      }
      guard !child.isRunning else {
        throw LabError.message(
          "Recovery child termination is unverified. Do not start another writer. Journal retained."
        )
      }
      childError = LabError.message(
        "Recovery child timed out. It was stopped before parent recovery."
      )
    } else if child.terminationStatus != 0 {
      childError = LabError.message("Recovery child failed with status \(child.terminationStatus).")
    }
  } catch {
    guard !child.isRunning else { throw error }
    childError = error
  }

  let recoveredLock = try SessionWriterLock(loginID: journal.target.loginID)
  defer { recoveredLock.release() }
  try recordObservation("owner-after-child-exit", monitor: monitor)
  let current = DisplayObserver.read()
  try journal.validate(bootID: current.bootID, loginID: current.loginID)
  try RecoveryIdentity.checkCurrentDisplays(current.displays, target: journal.target)
  if childError == nil {
    do {
      try verifyRestored(journal.target.displayID)
      try recordObservation("owner-verified-child-restoration", monitor: monitor)
    } catch {
      try recordObservation("owner-cannot-confirm-child-restoration", monitor: monitor)
      throw LabError.message(
        "Child reported restoration but parent could not verify it after processing callbacks. No duplicate enable was sent. This experiment is inconclusive."
      )
    }
  } else if !current.displays.contains(where: {
    $0.id == journal.target.displayID && $0.builtIn && $0.active
  }) {
    print(
      "Child did not establish active state. Original writer is explicitly restoring the recorded panel."
    )
    try PrivateDisplayAPI().setEnabled(
      true, displayID: journal.target.displayID, scope: .forAppOnly
    )
    try verifyRestored(journal.target.displayID)
  }
  if let childError {
    throw childError
  }
  print(
    "Cooperative child recovery completed and the parent independently observed the internal display active."
  )
}

func restoreChild(_ flags: [String: String]) throws {
  let monitor = DisplayEventMonitor()
  guard monitor.registrationError == nil else {
    throw LabError.message("Child display callback registration failed.")
  }
  guard Set(flags.keys) == ["--journal"] else {
    throw LabError.message("restore-child accepts only --journal.")
  }
  let journal = try RecoveryJournal.load(
    from: URL(fileURLWithPath: required("--journal", from: flags))
  )
  let current = DisplayObserver.read()
  try RecoveryIdentity.authorizeHandoff(
    journal: journal, bootID: current.bootID, loginID: current.loginID,
    parentPID: getppid(), displays: current.displays
  )
  guard current.foregroundSession == .yes else {
    throw LabError.message("Cooperative restoration requires the foreground GUI session.")
  }
  let lock = try SessionWriterLock(loginID: journal.target.loginID)
  defer { lock.release() }
  print("Recovery child PID \(getpid()) received exclusive ownership from parent \(getppid()).")
  try PrivateDisplayAPI().setEnabled(true, displayID: journal.target.displayID, scope: .forSession)
  try verifyRestored(journal.target.displayID)
  try recordObservation("child-after-restoration", monitor: monitor)
  print("Recovery child observed the internal panel active.")
}
