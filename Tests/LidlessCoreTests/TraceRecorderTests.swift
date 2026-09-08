import Foundation
import Testing

@testable import LidlessCore

@Test func evictionAdvancesReplayBaseline() throws {
  var recorder = TraceRecorder(maxEvents: 2)
  for time in 0..<10 {
    try recorder.append(
      .init(at: Int64(time), event: .selectMode(time % 2 == 0 ? .automatic : .automaticPaused)))
  }
  #expect(recorder.count == 2)
  #expect(recorder.trace.initial.lastReceipt == 7)
  #expect(try recorder.trace.replay().last?.state == recorder.current)
}

@Test func exportRemovesIdentifiersButPreservesDecisions() throws {
  var initial = ControllerState(mode: .automatic)
  initial.protectionAvailable = true
  var recorder = TraceRecorder(initial: initial)
  var reading = environment()
  reading.panel = .init(
    displayID: 875, displayUUID: "sensitive-uuid", bootID: "sensitive-boot", loginID: 91234)
  try recorder.append(
    .init(at: 0, event: .observed(.init(sequence: 1, sampledAt: 0, environment: reading))))
  try recorder.append(
    .init(at: 2_000, event: .observed(.init(sequence: 2, sampledAt: 2_000, environment: reading))))
  let data = try recorder.exportSanitized()
  let text = String(decoding: data, as: UTF8.self)
  #expect(!text.contains("sensitive"))
  #expect(!text.contains("91234"))
  let sanitized = try JSONDecoder().decode(ReplayTrace.self, from: data)
  let states = try sanitized.replay()
  #expect(states.last?.state.operation?.kind == .disable)
  #expect(states.last?.state.operation?.phase == .journaling)
  #expect(states.last?.state.operation?.target.displayUUID == "panel-1")
}

@Test func recorderEnforcesByteLimit() throws {
  var recorder = TraceRecorder(maxEvents: 10_000, maxBytes: 2_000)
  for time in 0..<1_000 { try recorder.append(.init(at: Int64(time), event: .tick)) }
  #expect(try recorder.exportSanitized().count <= 2_000)
  #expect(recorder.count < 1_000)
  #expect(try recorder.trace.replay().last?.state == recorder.current)
}

@Test func malformedReplayTimeIsRejected() {
  let trace = ReplayTrace(events: [.init(at: 3, event: .tick), .init(at: 2, event: .tick)])
  #expect(throws: (any Error).self) { try trace.replay() }
}
