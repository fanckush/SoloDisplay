import Foundation

/// Bounded, replayable history. Eviction advances the initial state, preserving replay semantics.
public struct TraceRecorder {
  private struct Entry {
    var event: RecordedEvent
    var bytes: Int
  }
  private var entries: [Entry] = []
  private var head = 0
  private var eventBytes = 0
  private var initial: ControllerState
  public private(set) var current: ControllerState
  private let maxEvents: Int
  private let maxBytes: Int

  public init(
    initial: ControllerState = .init(), maxEvents: Int = 10_000, maxBytes: Int = 5_000_000
  ) {
    precondition(maxEvents > 0 && maxBytes > 0)
    self.initial = initial
    current = initial
    self.maxEvents = maxEvents
    self.maxBytes = maxBytes
  }

  public var count: Int { entries.count - head }
  public var trace: ReplayTrace {
    .init(initial: initial, events: entries[head...].map(\.event))
  }

  @discardableResult public mutating func append(_ event: RecordedEvent) throws -> Transition {
    guard event.at >= current.lastReceipt else { throw ReplayError.nonMonotonicTime }
    let size = try JSONEncoder().encode(event).count
    let transition = Controller.reduce(current, event.event, at: event.at)
    entries.append(.init(event: event, bytes: size))
    eventBytes += size
    current = transition.state
    while count > 0 {
      let bytes = try estimatedBytes()
      if count <= maxEvents && bytes <= maxBytes { break }
      let entry = entries[head]
      initial = Controller.reduce(initial, entry.event.event, at: entry.event.at).state
      eventBytes -= entry.bytes
      head += 1
    }
    if head > 1_024 && head * 2 > entries.count {
      entries.removeFirst(head)
      head = 0
    }
    return transition
  }

  private func estimatedBytes() throws -> Int {
    // An empty trace already contains the array delimiters. Add records and separating commas.
    try JSONEncoder().encode(ReplayTrace(initial: initial, events: [])).count
      + eventBytes + max(0, count - 1)
  }

  public func exportSanitized() throws -> Data {
    var sanitizer = TraceSanitizer()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(sanitizer.sanitize(trace))
    guard data.count <= maxBytes else { throw TraceError.stateExceedsLimit }
    return data
  }
}

public enum TraceError: Error { case stateExceedsLimit }

private struct TraceSanitizer {
  var displays: [UInt32: UInt32] = [:]
  var sessions: [UInt32: UInt32] = [:]
  var uuids: [String: String] = [:]
  var boots: [String: String] = [:]

  mutating func target(_ original: PanelTarget) -> PanelTarget {
    if displays[original.displayID] == nil {
      displays[original.displayID] = UInt32(displays.count + 1)
    }
    if sessions[original.loginID] == nil { sessions[original.loginID] = UInt32(sessions.count + 1) }
    if uuids[original.displayUUID] == nil {
      uuids[original.displayUUID] = "panel-\(uuids.count + 1)"
    }
    if boots[original.bootID] == nil { boots[original.bootID] = "boot-\(boots.count + 1)" }
    return .init(
      displayID: displays[original.displayID]!, displayUUID: uuids[original.displayUUID]!,
      bootID: boots[original.bootID]!, loginID: sessions[original.loginID]!)
  }

  mutating func observation(_ original: Observation) -> Observation {
    var value = original
    if let panel = value.environment.panel { value.environment.panel = target(panel) }
    return value
  }

  mutating func sanitize(_ original: ReplayTrace) -> ReplayTrace {
    var value = original
    if let sample = value.initial.observation { value.initial.observation = observation(sample) }
    if var op = value.initial.operation {
      op.target = target(op.target)
      value.initial.operation = op
    }
    if var owned = value.initial.ownership {
      owned.target = target(owned.target)
      value.initial.ownership = owned
    }
    value.events = original.events.map { event in
      if case .observed(let sample) = event.event {
        return .init(at: event.at, event: .observed(observation(sample)))
      }
      return event
    }
    return value
  }
}
