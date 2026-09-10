import Foundation
import SoloDisplayCore

public struct RecoveryJournal: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var target: PanelTarget
  public var scope: String
  public var ownerPID: Int32
  public var createdAt: Date

  public init(target: PanelTarget, scope: String, ownerPID: Int32) {
    self.target = target
    self.scope = scope
    self.ownerPID = ownerPID
    createdAt = Date()
  }

  public func validate(bootID: String?, loginID: UInt32?) throws {
    guard schemaVersion == 1 else { throw JournalError.unsupportedSchema }
    guard let bootID, let loginID, bootID == target.bootID, loginID == target.loginID else {
      throw JournalError.identityMismatch
    }
    guard scope == "app" || scope == "session", target.displayID != 0,
          !target.displayUUID.isEmpty, !target.bootID.isEmpty
    else { throw JournalError.invalidTarget }
  }

  public func save(to url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw JournalError.alreadyExists
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // Never overwrite unresolved recovery evidence. Foundation's exclusive option also closes the
    // race.
    try encoder.encode(self).write(to: url, options: [.withoutOverwriting])
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
  }

  public static func load(from url: URL) throws -> Self {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    guard data.count < 16384 else { throw JournalError.invalidTarget }
    return try JSONDecoder().decode(Self.self, from: data)
  }
}

public enum JournalError: Error, CustomStringConvertible {
  case unsupportedSchema, identityMismatch, invalidTarget, alreadyExists
  case writeFailed, clearFailed
  public var description: String {
    switch self {
    case .unsupportedSchema: "Unsupported recovery journal schema."
    case .identityMismatch:
      "Recovery journal does not match this boot and GUI login session. No display was changed."
    case .invalidTarget: "Invalid recovery target. No display was changed."
    case .alreadyExists: "Recovery journal already exists. Resolve it before another experiment."
    case .writeFailed:
      "Ownership could not be recorded durably, so no display was changed."
    case .clearFailed:
      "Ownership could not be cleared. SoloDisplay keeps the record and retries rather than forgetting it."
    }
  }
}
