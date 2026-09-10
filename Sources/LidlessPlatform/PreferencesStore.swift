import Foundation
import LidlessCore
import Synchronization

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
  private let gate = PreferenceGate()

  public init(directory: URL) throws {
    file = directory.appendingPathComponent("preferences.json", isDirectory: false)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
  }

  public init() throws {
    try self.init(directory: ProductionJournalStore.defaultDirectory())
  }

  public var url: URL {
    file
  }

  /// An unreadable or unsupported file falls back to defaults. Preferences are a convenience,
  /// and the safe default is manual mode with nothing enabled.
  public func load() -> Preferences {
    gate.value.withLock { _ in readUnlocked() }
  }

  private func readUnlocked() -> Preferences {
    guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count < 16384,
          let stored = try? JSONDecoder().decode(Preferences.self, from: data),
          stored.schemaVersion == Preferences.currentSchema
    else { return .init() }
    return stored
  }

  public func save(_ preferences: Preferences) throws {
    try gate.value.withLock { _ in try writeUnlocked(preferences) }
  }

  private func writeUnlocked(_ preferences: Preferences) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(preferences).write(to: file, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// Read, change, write. The caller never has to hold a stale copy across a change.
  @discardableResult public func update(_ change: (inout Preferences) -> Void) throws
    -> Preferences {
    try gate.value.withLock { _ in
      var preferences = readUnlocked()
      change(&preferences)
      try writeUnlocked(preferences)
      return preferences
    }
  }
}

private final class PreferenceGate: Sendable {
  let value = Mutex(0)
}
