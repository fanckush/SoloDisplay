import Darwin
import Foundation

/// Evidence that the private display call actually worked on this machine and OS build. A
/// resolved symbol is not this. Only a completed, verified off/on round trip writes one.
public struct BackendValidation: Codable, Equatable, Sendable {
  public static let currentSchema = 1

  public var schemaVersion = BackendValidation.currentSchema
  public var osVersion: String
  public var hardwareModel: String
  public var symbolName: String
  public var validatedAt: Date
  /// What was actually confirmed, in the words of the run that confirmed it.
  public var evidence: String

  public init(osVersion: String, hardwareModel: String, symbolName: String, evidence: String) {
    self.osVersion = osVersion
    self.hardwareModel = hardwareModel
    self.symbolName = symbolName
    self.evidence = evidence
    validatedAt = Date()
  }

  /// A validation covers exactly the configuration it was recorded on. An OS update or a
  /// different Mac invalidates it, because neither was tested.
  public func covers(osVersion: String, hardwareModel: String, symbolName: String?) -> Bool {
    schemaVersion == Self.currentSchema && self.osVersion == osVersion
      && self.hardwareModel == hardwareModel && symbolName != nil && self.symbolName == symbolName
  }

  public static func hardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
    return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

public struct BackendValidationStore: Sendable {
  private let file: URL

  public init(directory: URL) throws {
    file = directory.appendingPathComponent("backend-validation.json", isDirectory: false)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public init() throws { try self.init(directory: ProductionJournalStore.defaultDirectory()) }

  public var url: URL { file }

  public func load() -> BackendValidation? {
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 16_384
    else { return nil }
    return try? JSONDecoder().decode(BackendValidation.self, from: data)
  }

  /// Returns the record only when it covers the configuration running right now.
  public func current(symbolName: String?) -> BackendValidation? {
    guard let record = load(),
      record.covers(
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: BackendValidation.hardwareModel(), symbolName: symbolName)
    else { return nil }
    return record
  }

  public func save(_ record: BackendValidation) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(record).write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}
