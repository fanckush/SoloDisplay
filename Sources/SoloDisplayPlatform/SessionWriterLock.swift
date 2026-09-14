import Darwin
import Foundation

/// A kernel-held, per-user GUI-session lock. Process exit releases it without deleting evidence.
public final class SessionWriterLock {
  private var descriptor: Int32
  private let url: URL

  static func lockURL(in directory: URL, name: String, loginID: UInt32) -> URL {
    directory.appendingPathComponent("solodisplay-\(name)-\(getuid())-\(loginID).lock")
  }

  /// `directory` exists so automated tests can hold their own lock without competing with a live
  /// GUI session. Production always uses the default. `name` separates unrelated exclusions:
  /// "instance" is one app per login, "guardian" is one guardian per login.
  public init(
    loginID: UInt32, name: String,
    directory: URL = FileManager.default.temporaryDirectory
  ) throws {
    url = Self.lockURL(in: directory, name: name, loginID: loginID)
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
    case .unavailable: "Cannot open the SoloDisplay session lock. No change made."
    case .alreadyHeld: "Another SoloDisplay process holds this lock in this GUI session."
    }
  }
}
