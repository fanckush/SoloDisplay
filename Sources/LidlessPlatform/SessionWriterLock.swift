import Darwin
import Foundation

/// A kernel-held, per-user GUI-session lock. Process exit releases it without deleting evidence.
public final class SessionWriterLock {
  private var descriptor: Int32

  /// `directory` exists so automated real-process tests can hold their own lock without
  /// competing with a live GUI session's writer. Production always uses the default.
  /// `name` separates unrelated exclusions; only "writer" gates display configuration.
  public init(
    loginID: UInt32, name: String = "writer",
    directory: URL = FileManager.default.temporaryDirectory
  ) throws {
    let url = directory.appendingPathComponent("lidless-\(name)-\(getuid())-\(loginID).lock")
    descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw WriterLockError.unavailable }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      descriptor = -1
      throw WriterLockError.alreadyHeld
    }
  }

  public func release() {
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }
  deinit { release() }
}

public enum WriterLockError: Error, CustomStringConvertible {
  case unavailable, alreadyHeld
  public var description: String {
    switch self {
    case .unavailable: "Cannot establish exclusive display-writer ownership. No change made."
    case .alreadyHeld: "Another Lidless lab writer is running in this GUI session. No change made."
    }
  }
}
