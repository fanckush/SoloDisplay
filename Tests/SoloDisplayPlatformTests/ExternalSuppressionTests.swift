import Foundation
import SoloDisplayCore
import Testing
@testable import SoloDisplayPlatform

private func workspace() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("solodisplay-monitors-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func monitor(
  id: UInt32 = 4, uuid: String = "dell", controller: String = "dispext0"
) -> PanelTarget {
  .init(
    displayID: id, displayUUID: uuid, bootID: "boot", loginID: 42,
    kind: .external, controller: controller
  )
}

struct ExternalSuppressionTests {
  @Test func whatWasTurnedOffSurvivesARelaunch() throws {
    let directory = try workspace()
    let store = try ExternalSuppressionStore(directory: directory)
    #expect(store.load() == nil)

    try store.save(.init(session: "run-1", targets: [monitor()]))
    // A separate instance is what a relaunch actually sees.
    let reopened = try ExternalSuppressionStore(directory: directory)
    #expect(reopened.load()?.targets == [monitor()])

    try reopened.clear()
    #expect(reopened.load() == nil)
  }

  @Test func theWholeSetIsReplacedRatherThanEdited() throws {
    let store = try ExternalSuppressionStore(directory: workspace())
    try store.save(.init(session: "run-1", targets: [monitor(), monitor(
      id: 5, uuid: "benq", controller: "dispext1"
    )]))
    try store.save(.init(session: "run-1", targets: [monitor()]))
    #expect(store.load()?.targets == [monitor()])
  }

  /// A monitor being off is never a reason to refuse to turn the laptop screen off, so an
  /// unreadable record here reports nothing rather than inhibiting anything.
  @Test func anUnreadableRecordNamesNoMonitorsAndBlocksNothing() throws {
    let directory = try workspace()
    let store = try ExternalSuppressionStore(directory: directory)
    try Data("not a record".utf8).write(to: store.url)
    #expect(store.load() == nil)
    // And it is replaced by the next write rather than held.
    try store.save(.init(session: "run-1", targets: [monitor()]))
    #expect(store.load()?.targets == [monitor()])
  }

  @Test func onlyExternalsWithAnEndpointAreEverRecorded() throws {
    let store = try ExternalSuppressionStore(directory: workspace())
    let panel = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 42)
    #expect(throws: (any Error).self) {
      try store.save(.init(session: "run-1", targets: [panel]))
    }
    var portless = monitor()
    portless.controller = nil
    #expect(throws: (any Error).self) {
      try store.save(.init(session: "run-1", targets: [portless]))
    }
    // One monitor cannot be recorded twice, which would let one be forgotten while it is off.
    #expect(throws: (any Error).self) {
      try store.save(.init(session: "run-1", targets: [monitor(), monitor(id: 9)]))
    }
  }

  @Test func aRecordWrittenBeforeMonitorsWereNamedStillReads() throws {
    // PanelTarget gained its kind after the first records were written. An older one names the
    // laptop panel, and failing to read it would be worse than reading it.
    let json = #"""
    {"displayID":1,"displayUUID":"panel","bootID":"boot","loginID":42}
    """#
    let target = try JSONDecoder().decode(PanelTarget.self, from: Data(json.utf8))
    #expect(target.kind == .builtIn)
    #expect(target.controller == nil)
  }
}
