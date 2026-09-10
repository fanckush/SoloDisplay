import Foundation
import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

private func workspace() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("solodisplay-preferences-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

struct PreferencesStoreTests {
  @Test func defaultsAreManualWithNothingEnabled() throws {
    let store = try PreferencesStore(directory: workspace())
    let preferences = store.load()
    #expect(preferences.mode == .manual)
    #expect(!preferences.launchAtLogin)
    #expect(!preferences.manualPathValidated)
  }

  @Test func aPausedAutomaticChoiceSurvivesARestart() throws {
    let directory = try workspace()
    let store = try PreferencesStore(directory: directory)
    try store.save(
      {
        var value = Preferences()
        value.mode = .automaticPaused
        return value
      }()
    )
    // A separate store instance is what a relaunch actually sees.
    let reopened = try PreferencesStore(directory: directory)
    #expect(reopened.load().mode == .automaticPaused)
    let state = ControllerState(mode: reopened.load().mode)
    #expect(!state.wantsOff)
  }

  @Test func savingTheModeDoesNotClobberOtherChoices() throws {
    let store = try PreferencesStore(directory: workspace())
    try store.update {
      $0.launchAtLogin = true
      $0.manualPathValidated = true
    }
    // The coordinator persists the mode alone through this path.
    try store.save(mode: .automatic)
    let after = store.load()
    #expect(after.mode == .automatic)
    #expect(after.launchAtLogin)
    #expect(after.manualPathValidated)
  }

  @Test func anUnreadableOrUnsupportedFileFallsBackToSafeDefaults() throws {
    let directory = try workspace()
    let store = try PreferencesStore(directory: directory)
    try Data("not preferences".utf8).write(to: store.url)
    #expect(store.load().mode == .manual)

    var future = Preferences()
    future.schemaVersion = Preferences.currentSchema + 1
    future.mode = .automatic
    try JSONEncoder().encode(future).write(to: store.url)
    // An unsupported schema must not be read as an instruction to run automatically.
    #expect(store.load().mode == .manual)
  }

  @Test func preferencesAreStoredPrivately() throws {
    let store = try PreferencesStore(directory: workspace())
    try store.save(Preferences())
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
  }
}
