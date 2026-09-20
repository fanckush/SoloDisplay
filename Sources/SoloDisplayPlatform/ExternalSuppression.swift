import Foundation
import SoloDisplayCore
import Synchronization

/// The monitors this run has turned off, on disk beside the panel's record and never mixed with
/// it. The panel's record answers one question, "is the laptop screen off and whose doing is
/// that", and its single-record exclusivity is what makes that answer trustworthy. Monitors are
/// plural by nature, and a monitor being off is never a reason to refuse to turn the panel off,
/// so they are owned separately and cannot inhibit anything the panel's record governs.
public struct ExternalSuppressionRecord: Codable, Equatable, Sendable {
  public static let currentSchema = 1

  public var schemaVersion = ExternalSuppressionRecord.currentSchema
  /// The controller run that turned these monitors off.
  public var session: String
  public var targets: [PanelTarget]
  public var createdAt: Date

  public init(session: String, targets: [PanelTarget], createdAt: Date = Date()) {
    self.session = session
    self.targets = targets
    self.createdAt = createdAt
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchema, !session.isEmpty, session.count <= 64,
          targets.count <= 8, targets.allSatisfy({ target in
            target.kind == .external && target.displayID != 0 && !target.displayUUID.isEmpty
              && !target.bootID.isEmpty && !(target.controller ?? "").isEmpty
          }),
          Set(targets.map(\.displayUUID)).count == targets.count
    else { throw JournalError.invalidTarget }
  }
}

/// Reads and writes that record. Writes are whole: the set of suppressed monitors is replaced,
/// never edited in place, so a crash can only leave the set as it was before or as it is after.
public final class ExternalSuppressionStore: Sendable {
  private let file: URL
  private let pending: URL
  private let gate = Mutex(0)

  public init(directory: URL) throws {
    file = directory.appendingPathComponent("suppressed-monitors.json", isDirectory: false)
    pending = directory.appendingPathComponent(
      "suppressed-monitors.json.new", isDirectory: false
    )
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
  }

  public convenience init() throws {
    try self.init(directory: ProductionJournalStore.defaultDirectory())
  }

  public var url: URL {
    file
  }

  /// Every monitor this run has turned off, or nothing at all when the record cannot be read.
  /// An unreadable record here never inhibits anything: the worst it can cost is a monitor left
  /// on, which is where every monitor starts.
  public func load() -> ExternalSuppressionRecord? {
    gate.withLock { _ in
      guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 65536,
            let record = try? JSONDecoder().decode(ExternalSuppressionRecord.self, from: data),
            (try? record.validate()) != nil
      else { return nil }
      return record
    }
  }

  public func save(_ record: ExternalSuppressionRecord) throws {
    try record.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try gate.withLock { _ in
      try? FileManager.default.removeItem(at: pending)
      let descriptor = open(
        pending.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else { throw JournalError.writeFailed }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        // Ownership must survive a power loss between this call and the display request.
        try handle.synchronize()
        try handle.close()
        guard rename(pending.path, file.path) == 0 else { throw JournalError.writeFailed }
      } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: pending)
        throw JournalError.writeFailed
      }
      syncDirectory()
    }
  }

  /// Only once every monitor it named is back on.
  public func clear() throws {
    try gate.withLock { _ in
      guard FileManager.default.fileExists(atPath: file.path) else { return }
      do { try FileManager.default.removeItem(at: file) } catch { throw JournalError.clearFailed }
      syncDirectory()
    }
  }

  private func syncDirectory() {
    let descriptor = open(file.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    fsync(descriptor)
    close(descriptor)
  }
}
