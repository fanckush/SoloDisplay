import Darwin
import Foundation
import SoloDisplayCore
import Synchronization

/// Durable ownership evidence written before a production disable request. It is separate from
/// the retained lab journals: this record exists only while a panel may still be suppressed.
public struct ProductionRecord: Codable, Equatable, Sendable {
  public static let currentSchema = 1

  public var schemaVersion = ProductionRecord.currentSchema
  /// Identity of the controller run that created it, not a reusable installation identifier.
  public var session: String
  public var operationID: UInt64
  public var target: PanelTarget
  /// Configuration scope actually used for the write. Recovery must match it.
  public var scope: String
  public var controllerPID: Int32
  public var helperPID: Int32
  public var createdAt: Date
  /// The topology observed immediately before the request, so recovery can verify rather
  /// than assume what the arrangement should look like afterwards.
  public var topology: [DisplayReading]

  public init(
    session: String, operationID: UInt64, target: PanelTarget, scope: String,
    controllerPID: Int32, helperPID: Int32, topology: [DisplayReading]
  ) {
    self.session = session
    self.operationID = operationID
    self.target = target
    self.scope = scope
    self.controllerPID = controllerPID
    self.helperPID = helperPID
    self.topology = topology
    createdAt = Date()
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchema else { throw JournalError.unsupportedSchema }
    guard scope == "app" || scope == "session", operationID > 0, !session.isEmpty,
          session.count <= 64, target.displayID != 0, !target.displayUUID.isEmpty,
          !target.bootID.isEmpty, topology.count <= 32
    else { throw JournalError.invalidTarget }
  }
}

/// What a leftover record means for this launch. Only `unresolved` authorizes a restore attempt,
/// and none of these cases authorizes a new disable before the record is cleared.
public enum JournalReconciliation: Equatable, Sendable {
  /// No record. Ordinary prerequisites still apply before disabling.
  case clean
  /// This boot and GUI login session. The recorded panel may still be suppressed.
  case unresolved(ProductionRecord)
  /// A different boot or login session. A reboot or new session restores the panel, so this is
  /// clearable, but only after observing an active built-in panel. The stored ID is not authority.
  case priorSession(ProductionRecord)
  /// Corrupt, unsupported, or contradicted by live evidence. Retained, and disabling is inhibited.
  case retained(String)

  public var inhibitsDisabling: Bool {
    self != .clean
  }

  public var explanation: String? {
    switch self {
    case .clean: nil
    case .unresolved:
      "SoloDisplay may still have the internal display turned off from an earlier run. It is restoring that display before anything else."
    case .priorSession:
      "SoloDisplay found unfinished recovery from a previous startup. It is confirming the internal display before allowing it to be turned off again."
    case let .retained(reason): reason
    }
  }
}

/// Serialized preparation and clearing. Every result is reported back so the controller can
/// fault on a persistence failure instead of proceeding without durable ownership.
public final class ProductionJournalStore: Sendable {
  private let directory: URL
  private let file: URL
  private let gate = Mutex(0)

  public static func defaultDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("SoloDisplay", isDirectory: true)
  }

  /// Where the support directory lived before the rename to SoloDisplay.
  public static func legacyDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Lidless", isDirectory: true)
  }

  static let migratedFiles = ["recovery.json", "preferences.json", "backend-validation.json"]

  /// An upgrade must not strand a durable ownership record where the new build cannot see it,
  /// because an unresolved record is the only evidence that a panel is still turned off.
  ///
  /// Run this once in the supervisor before any process opens a store. It is idempotent: the
  /// whole-directory move is a single `rename`, so a concurrent launch either wins or finds the
  /// source already gone, and both are the intended end state. An existing destination is
  /// authoritative and is never overwritten; only files missing from it are taken across.
  public static func migrateLegacyDirectory(from legacy: URL, to current: URL) throws {
    guard legacy != current else { return }
    let manager = FileManager.default
    var legacyIsDirectory: ObjCBool = false
    guard manager.fileExists(atPath: legacy.path, isDirectory: &legacyIsDirectory),
          legacyIsDirectory.boolValue
    else { return }

    if !manager.fileExists(atPath: current.path),
       (try? manager.moveItem(at: legacy, to: current)) != nil {
      return
    }

    try manager.createDirectory(
      at: current, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    for name in migratedFiles {
      let source = legacy.appendingPathComponent(name, isDirectory: false)
      let destination = current.appendingPathComponent(name, isDirectory: false)
      guard manager.fileExists(atPath: source.path),
            !manager.fileExists(atPath: destination.path)
      else { continue }
      try manager.moveItem(at: source, to: destination)
    }

    // Anything left behind is unrecognized, so it stays where it is rather than being deleted.
    if let remaining = try? manager.contentsOfDirectory(atPath: legacy.path), remaining.isEmpty {
      try? manager.removeItem(at: legacy)
    }
  }

  public init(directory: URL) throws {
    self.directory = directory
    file = directory.appendingPathComponent("recovery.json", isDirectory: false)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  public convenience init() throws {
    try self.init(directory: Self.defaultDirectory())
  }

  public var url: URL {
    file
  }

  /// Exclusive create. An existing record is unresolved ownership and is never overwritten.
  public func prepare(_ record: ProductionRecord) throws {
    try record.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(record)
    try gate.withLock { _ in
      let descriptor = open(
        file.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else {
        throw errno == EEXIST ? JournalError.alreadyExists : JournalError.writeFailed
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      do {
        try handle.write(contentsOf: data)
        // Ownership must survive a power loss between this call and the display request.
        try handle.synchronize()
        try handle.close()
      } catch {
        try? handle.close()
        try? FileManager.default.removeItem(at: file)
        throw JournalError.writeFailed
      }
      syncDirectory()
    }
  }

  public func load() throws -> ProductionRecord? {
    try gate.withLock { _ in
      guard FileManager.default.fileExists(atPath: file.path) else { return nil }
      let data = try Data(contentsOf: file, options: .mappedIfSafe)
      guard data.count < 65536 else { throw JournalError.invalidTarget }
      return try JSONDecoder().decode(ProductionRecord.self, from: data)
    }
  }

  /// Only after verified restoration. A failure here keeps ownership, it does not release it.
  public func clear() throws {
    try gate.withLock { _ in
      guard FileManager.default.fileExists(atPath: file.path) else { return }
      do { try FileManager.default.removeItem(at: file) } catch { throw JournalError.clearFailed }
      syncDirectory()
    }
  }

  private func syncDirectory() {
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    fsync(descriptor)
    close(descriptor)
  }

  public func reconcile(bootID: String?, loginID: UInt32?, displays: [DisplayReading])
    -> JournalReconciliation {
    let record: ProductionRecord?
    do { record = try load() } catch {
      return .retained(
        "SoloDisplay found an unreadable recovery record and will not turn the internal display off until it is resolved. Export diagnostics or remove the file it names."
      )
    }
    guard let record else { return .clean }
    do { try record.validate() } catch {
      return .retained(
        "SoloDisplay found a recovery record it does not understand and will not turn the internal display off until it is resolved."
      )
    }
    guard let bootID, let loginID else {
      return .retained(
        "SoloDisplay cannot read this Mac's startup or login session identity, so it cannot resolve the recovery record it found."
      )
    }
    guard record.target.bootID == bootID, record.target.loginID == loginID else {
      return .priorSession(record)
    }
    // Live contradiction outranks the record. A different built-in panel means do not act on it.
    do { try RecoveryIdentity.checkCurrentDisplays(displays, target: record.target) } catch {
      return .retained(
        "Live display evidence contradicts SoloDisplay's recovery record, so no display was changed. Turning the internal display off stays unavailable."
      )
    }
    return .unresolved(record)
  }
}
