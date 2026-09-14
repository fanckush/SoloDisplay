import Darwin
import Foundation
import SoloDisplayCore
import Synchronization
import Testing
@testable import SoloDisplayPlatform

final class CapturedOperationalEvents: OperationalEventSink {
  private let storage = Mutex<[OperationalEvent]>([])
  var events: [OperationalEvent] {
    storage.withLock { $0 }
  }

  func record(_ event: OperationalEvent) {
    storage.withLock { $0.append(event) }
  }
}

private struct HistoryStub: OperationalHistoryReading {
  var history: OperationalHistory
  func read(from _: Date, through _: Date) -> OperationalHistory {
    history
  }
}

private struct FailingDiagnosticsWriter: DiagnosticsFileWriting {
  func write(_: Data, to _: URL) throws {
    throw CocoaError(.fileWriteNoPermission)
  }
}

struct OperationalDiagnosticsTests {
  @Test func typedSinkRejectsUnsafeIdentifiersAndBuildStrings() {
    let sink = CapturedOperationalEvents()
    let logger = OperationalLogger(role: .guardian, sink: sink)
    logger.emit(.started) { $0.appVersion = "/Users/sensitive/secret" }
    logger.emit(.guardianReady) { $0.run = "display-serial-number" }
    logger.emit(.guardianReady, session: "boot-or-login-identifier")
    #expect(sink.events.count == 1)
    #expect(sink.events[0].session == nil)
    #expect(OperationalEvent.safeVersion("1.2.3"))
    #expect(
      OperationalEvent.numericErrorCode(DisplayAPIError.call("untrusted-stage", 1001)) == 1001
    )
    #expect(!OperationalEvent.safeVersion(String(repeating: "1", count: 33)))
  }

  @Test func maximalOperationalRecordFitsUnifiedLogPayload() throws {
    let sink = CapturedOperationalEvents()
    let logger = OperationalLogger(role: .app, sink: sink)
    let environment = Environment(
      panel: nil, panelState: .disabled, power: .awake, lid: .open, foregroundSession: .yes,
      nativeExternalAvailable: .conflicting, supportedTopology: .unknown
    )
    logger.emit(
      .stateChanged, session: UUID().uuidString, reason: .workspaceSessionInactive,
      succeeded: false, errorCode: 5
    ) {
      $0.workerAction = .disable
      $0.workerOutcome = .killed
      $0.elapsedMS = 1_000_000
      $0.exitStatus = 255
      $0.action = .selectExternalOnly
      $0.trouble = .recordUnresolved
      $0.unavailability = .sessionNotForeground
      $0.mode = .automaticPaused
      $0.environment = OperationalEnvironment(environment)
      $0.panelOff = true
      $0.working = true
      $0.failures = 1000
      $0.appVersion = "12345.12345.12345"
      $0.build = "202612312359"
    }
    #expect(try JSONEncoder().encode(sink.events[0]).count <= 1000)
  }

  @Test(arguments: [OperationalHistory.Status.unavailable, .failed, .empty, .collected])
  func historyFailuresStillExportTheCurrentState(_ status: OperationalHistory.Status) throws {
    let exporter = DiagnosticsExporter(reader: HistoryStub(history: .init(status: status)))
    let snapshot = DiagnosticsSnapshot(ControllerState(mode: .automatic), at: 0)
    let data = try exporter.collect(snapshot: snapshot)
    let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
    #expect(document.snapshot == snapshot)
    #expect(
      document.diagnostics.requestedThrough.timeIntervalSince(document.diagnostics.requestedFrom)
        == 86400
    )
    #expect(document.diagnostics.history.entries.isEmpty)
    #expect(document.diagnostics.explanation.contains("Console"))
    if status == .empty {
      #expect(document.diagnostics.explanation.contains("does not prove nothing happened"))
    }
  }

  @Test func aSnapshotCarriesNoDisplayBootOrSessionIdentity() throws {
    let target = PanelTarget(
      displayID: 1, displayUUID: "PRIVATE-panel", bootID: "PRIVATE-boot", loginID: 424_242
    )
    var state = ControllerState(mode: .automatic, record: target)
    state.observation = .init(
      sequence: 1, sampledAt: 0,
      environment: .init(
        panel: target, panelState: .disabled, power: .awake, lid: .open, foregroundSession: .yes,
        nativeExternalAvailable: .yes, supportedTopology: .yes
      )
    )
    let text = try #require(
      String(bytes: JSONEncoder().encode(DiagnosticsSnapshot(state, at: 0)), encoding: .utf8)
    )
    #expect(!text.contains("PRIVATE"))
    #expect(!text.contains("424242"))
  }

  @Test func exportsFilterRawTextAndPreserveExportLocalPairing() throws {
    let now = Date()
    let guardian = UUID()
    let app = UUID()
    let session = UUID()
    var guardianEvent = OperationalEvent(
      code: .guardianReady, role: .guardian, run: guardian, uptimeMS: 1
    )
    var appEvent = OperationalEvent(code: .guardianReady, role: .app, run: app, uptimeMS: 2)
    guardianEvent.session = session.uuidString
    appEvent.session = session.uuidString
    var raw = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(guardianEvent)) as? [String: Any]
    )
    raw["secret"] = "PRIVATE-display-serial"
    guardianEvent = try JSONDecoder().decode(
      OperationalEvent.self, from: JSONSerialization.data(withJSONObject: raw)
    )
    var invalid = guardianEvent
    invalid.run = "PRIVATE-boot-id"
    let data = try DiagnosticsExporter.encode(
      snapshot: nil,
      history: .init(
        status: .collected,
        entries: [
          .init(date: now, event: guardianEvent),
          .init(date: now, event: appEvent),
          .init(date: now, event: invalid)
        ]
      ), from: now.addingTimeInterval(-100), through: now, collectedAt: now
    )
    let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
    let entries = document.diagnostics.history.entries
    #expect(entries.count == 2)
    #expect(entries[0].event.run != entries[1].event.run)
    #expect(entries[0].event.session == entries[1].event.session)
    #expect(document.diagnostics.history.rejectedEntries == 1)
    let text = try #require(String(bytes: data, encoding: .utf8))
    for secret in [guardian.uuidString, app.uuidString, session.uuidString, "PRIVATE"] {
      #expect(!text.contains(secret))
    }
  }

  @Test func historyIsBoundedAndKeepsTheNewestEntries() throws {
    let now = Date()
    let run = UUID()
    let history = OperationalHistory(
      status: .collected,
      entries: (1 ... 2200).map {
        .init(
          date: now.addingTimeInterval(Double($0 - 2200)),
          event: .init(code: .started, role: .app, run: run, uptimeMS: Int64($0))
        )
      }
    )
    let data = try DiagnosticsExporter.encode(
      snapshot: nil, history: history,
      from: now.addingTimeInterval(-86400), through: now, collectedAt: now
    )
    let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
    #expect(document.diagnostics.history.entries.count <= 2000)
    #expect(try JSONEncoder().encode(document.diagnostics.history.entries).count <= 500_000)
    #expect(document.diagnostics.history.truncated)
    #expect(document.diagnostics.history.entries.last?.event.uptimeMS == 2200)
  }

  @Test func fileWriteFailuresAreNotSilentlySwallowed() throws {
    let exporter = DiagnosticsExporter(
      reader: HistoryStub(history: .init(status: .unavailable)),
      writer: FailingDiagnosticsWriter()
    )
    let data = try exporter.collect(snapshot: nil)
    #expect(throws: CocoaError.self) {
      try exporter.write(data, to: URL(fileURLWithPath: "/never-written"))
    }
  }

  @Test func actualChildExitIsReportedOnceAndOnlyAfterTermination() throws {
    let sink = CapturedOperationalEvents()
    let logger = OperationalLogger(role: .guardian, sink: sink)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    var reporter = ChildExitDiagnostics()
    let runningReported = reporter.recordIfTerminated(child, using: logger)
    #expect(!runningReported)
    #expect(sink.events.isEmpty)
    logger.emit(.guardianRestoring, reason: .appGone)
    #expect(kill(child.processIdentifier, SIGKILL) == 0)
    child.waitUntilExit()
    let reported = reporter.recordIfTerminated(child, using: logger)
    let reportedAgain = reporter.recordIfTerminated(child, using: logger)
    #expect(reported && reportedAgain)
    #expect(sink.events.map(\.code) == [.guardianRestoring, .childExited])
    #expect(sink.events.last?.reason == .uncaughtSignal)
    #expect(sink.events.last?.exitStatus == SIGKILL)
  }

  @Test func normalChildExitIsNotReportedAsACrash() throws {
    let sink = CapturedOperationalEvents()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try child.run()
    child.waitUntilExit()
    var reporter = ChildExitDiagnostics()
    reporter.recordIfTerminated(child, using: .init(role: .guardian, sink: sink))
    #expect(sink.events.first?.reason == .exited)
    #expect(sink.events.first?.exitStatus == 0)
  }
}
