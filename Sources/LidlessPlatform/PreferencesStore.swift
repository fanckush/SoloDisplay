import Foundation
import LidlessCore

/// User intent that must survive a restart. This is never hardware truth: it says what the
/// user asked for, not what any display is currently doing.
public struct Preferences: Codable, Equatable, Sendable {
  public static let currentSchema = 1

  public var schemaVersion = Preferences.currentSchema
  public var mode: Mode = .manual
  public var launchAtLogin = false
  /// Automatic mode stays unavailable until a manual off and verified restoration has worked
  /// on this Mac. Offering it before that would be asking the user to trust an untested path.
  public var manualPathValidated = false

  public init() {}
}

public struct PreferencesStore: Sendable {
  private let file: URL

  public init(directory: URL) throws {
    file = directory.appendingPathComponent("preferences.json", isDirectory: false)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public init() throws { try self.init(directory: ProductionJournalStore.defaultDirectory()) }

  public var url: URL { file }

  /// An unreadable or unsupported file falls back to defaults. Preferences are a convenience,
  /// and the safe default is manual mode with nothing enabled.
  public func load() -> Preferences {
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 16_384,
      let stored = try? JSONDecoder().decode(Preferences.self, from: data),
      stored.schemaVersion == Preferences.currentSchema
    else { return .init() }
    return stored
  }

  public func save(_ preferences: Preferences) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preferences).write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// Read, change, write. The caller never has to hold a stale copy across a change.
  @discardableResult public func update(_ change: (inout Preferences) -> Void) throws -> Preferences
  {
    var preferences = load()
    change(&preferences)
    try save(preferences)
    return preferences
  }
}
