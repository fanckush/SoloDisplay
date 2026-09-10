import Darwin
import Foundation
import LidlessCore
import Synchronization
import Testing
@testable import LidlessPlatform

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
    let logger = OperationalLogger(role: .helper, sink: sink)
    logger.emit(.started) { $0.appVersion = "/Users/sensitive/secret" }
    logger.emit(.paired) { $0.run = "display-serial-number" }
    logger.emit(.paired, session: "boot-or-login-identifier")
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
    let logger = OperationalLogger(role: .controller, sink: sink)
    logger.emit(
      .protectionLost, session: UUID().uuidString,
      reason: .protectionFailure,
      operation: .init(id: 99, kind: .disable, phase: .submitted, deadline: 1_000_000),
      succeeded: false, errorCode: 5
    ) {
      $0.controllerLoss = .invalidAcknowledgement
      $0.rejection = .unsupportedVersion
      $0.challengeAgeMS = 5000
      $0.challenge = 99
      $0.leaseDeadlineMS = 1_000_000
    }
    #expect(try JSONEncoder().encode(sink.events[0]).count <= 1000)
  }

  @Test(arguments: [OperationalHistory.Status.unavailable, .failed, .empty, .collected])
  func historyFailuresStillExportCompatibleReplay(_ status: OperationalHistory.Status) throws {
    let trace = ReplayTrace(events: [.init(at: 1, event: .keepOn)])
    let exporter = DiagnosticsExporter(reader: HistoryStub(history: .init(status: status)))
    let data = try exporter.collect(trace: trace)
    let replay = try JSONDecoder().decode(ReplayTrace.self, from: data)
    #expect(try replay.replay() == trace.replay())
    let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
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

  @Test func exportsFilterRawTextAndPreserveExportLocalPairing() throws {
    let now = Date()
    let helper = UUID()
    let controller = UUID()
    let session = UUID()
    var helperEvent = OperationalEvent(code: .paired, role: .helper, run: helper, uptimeMS: 1)
    var controllerEvent = OperationalEvent(
      code: .paired, role: .controller, run: controller, uptimeMS: 2
    )
    helperEvent.session = session.uuidString
    controllerEvent.session = session.uuidString
    var raw = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(helperEvent)) as? [String: Any]
    )
    raw["secret"] = "PRIVATE-display-serial"
    helperEvent = try JSONDecoder().decode(
      OperationalEvent.self, from: JSONSerialization.data(withJSONObject: raw)
    )
    var invalid = helperEvent
    invalid.run = "PRIVATE-boot-id"
    let data = try DiagnosticsExporter.encode(
      trace: .init(events: []),
      history: .init(
        status: .collected,
        entries: [
          .init(date: now, event: helperEvent),
          .init(date: now, event: controllerEvent),
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
    for secret in [helper.uuidString, controller.uuidString, session.uuidString, "PRIVATE"] {
      #expect(!text.contains(secret))
    }
  }

  @Test func combinedExportEvictsOldestEventsAndAdvancesReplayBaseline() throws {
    let now = Date()
    let trace = ReplayTrace(
      events: (1 ... 10050).map {
        .init(at: Int64($0), event: $0 == 1 ? .keepOn : .tick)
      }
    )
    let run = UUID()
    let history = OperationalHistory(
      status: .collected,
      entries: (1 ... 2200).map {
        .init(
          date: now.addingTimeInterval(Double($0 - 2200)),
          event: .init(code: .started, role: .helper, run: run, uptimeMS: Int64($0))
        )
      }
    )
    let data = try DiagnosticsExporter.encode(
      trace: trace, history: history,
      from: now.addingTimeInterval(-86400), through: now, collectedAt: now
    )
    let document = try JSONDecoder().decode(DiagnosticsDocument.self, from: data)
    let replay = try JSONDecoder().decode(ReplayTrace.self, from: data)
    #expect(data.count <= 5_000_000)
    #expect(document.events.count + document.diagnostics.history.entries.count <= 10000)
    #expect(document.diagnostics.history.entries.count <= 2000)
    #expect(try JSONEncoder().encode(document.diagnostics.history.entries).count <= 500_000)
    #expect(document.diagnostics.traceTruncated)
    #expect(document.diagnostics.history.truncated)
    #expect(replay.initial.lastReceipt > 0)
    #expect(try replay.replay().last?.state == trace.replay().last?.state)
    #expect(document.diagnostics.history.entries.last?.event.uptimeMS == 2200)
  }

  @Test func fileWriteFailuresAreNotSilentlySwallowed() throws {
    let exporter = DiagnosticsExporter(
      reader: HistoryStub(history: .init(status: .unavailable)),
      writer: FailingDiagnosticsWriter()
    )
    let data = try exporter.collect(trace: .init(events: []))
    #expect(throws: CocoaError.self) {
      try exporter.write(data, to: URL(fileURLWithPath: "/never-written"))
    }
  }

  @Test func actualChildExitIsReportedOnceAndOnlyAfterTermination() throws {
    let sink = CapturedOperationalEvents()
    let logger = OperationalLogger(role: .helper, sink: sink)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["10"]
    try child.run()
    var reporter = ChildExitDiagnostics()
    let runningReported = reporter.recordIfTerminated(child, using: logger)
    #expect(!runningReported)
    #expect(sink.events.isEmpty)
    logger.emit(.childTerminationRequested, reason: .protectionFailure)
    #expect(kill(child.processIdentifier, SIGKILL) == 0)
    child.waitUntilExit()
    let reported = reporter.recordIfTerminated(child, using: logger)
    let reportedAgain = reporter.recordIfTerminated(child, using: logger)
    #expect(reported && reportedAgain)
    #expect(sink.events.map(\.code) == [.childTerminationRequested, .childExited])
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
    reporter.recordIfTerminated(child, using: .init(role: .helper, sink: sink))
    #expect(sink.events.first?.reason == .exited)
    #expect(sink.events.first?.exitStatus == 0)
  }
}
