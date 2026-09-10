import Darwin
import Foundation

/// A kernel-held, per-user GUI-session lock. Process exit releases it without deleting evidence.
public final class SessionWriterLock {
  private var descriptor: Int32
  private let url: URL

  /// `directory` exists so automated real-process tests can hold their own lock without
  /// competing with a live GUI session's writer. Production always uses the default.
  /// `name` separates unrelated exclusions; only "writer" gates display configuration.
  public init(
    loginID: UInt32, name: String = "writer",
    directory: URL = FileManager.default.temporaryDirectory
  ) throws {
    url = directory.appendingPathComponent("lidless-\(name)-\(getuid())-\(loginID).lock")
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

  /// A recovery worker inherits a duplicate of the exact locked file description. The helper
  /// keeps its own descriptor too, so either process dying cannot create a concurrent-writer gap.
  public func fileHandleForInheritance() throws -> FileHandle {
    guard descriptor >= 0 else { throw WriterLockError.unavailable }
    let inherited = dup(descriptor)
    guard inherited >= 0 else { throw WriterLockError.unavailable }
    return FileHandle(fileDescriptor: inherited, closeOnDealloc: true)
  }

  /// The worker independently proves that its inherited descriptor names the expected lock file
  /// and participates in that lock before it enters the private display API.
  public static func inheritedDescriptorHoldsLock(
    _ inherited: Int32, loginID: UInt32,
    directory: URL = FileManager.default.temporaryDirectory
  ) -> Bool {
    let expectedURL = directory.appendingPathComponent(
      "lidless-writer-\(getuid())-\(loginID).lock"
    )
    var inheritedStatus = stat()
    var expectedStatus = stat()
    guard fstat(inherited, &inheritedStatus) == 0,
          stat(expectedURL.path, &expectedStatus) == 0,
          inheritedStatus.st_dev == expectedStatus.st_dev,
          inheritedStatus.st_ino == expectedStatus.st_ino
    else { return false }
    return flock(inherited, LOCK_EX | LOCK_NB) == 0
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
