import Foundation

public struct RecordedEvent: Codable, Equatable, Sendable {
  public var at: Instant
  public var event: Event
  public init(at: Instant, event: Event) {
    self.at = at
    self.event = event
  }
}

public struct ReplayTrace: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var initial: ControllerState
  public var events: [RecordedEvent]
  public init(initial: ControllerState = .init(), events: [RecordedEvent]) {
    self.initial = initial
    self.events = events
  }

  public func replay() throws -> [Transition] {
    guard schemaVersion == 1 else { throw ReplayError.unsupportedSchema }
    var state = initial
    var transitions: [Transition] = []
    for record in events {
      guard record.at >= state.lastReceipt else { throw ReplayError.nonMonotonicTime }
      let transition = Controller.reduce(state, record.event, at: record.at)
      transitions.append(transition)
      state = transition.state
    }
    return transitions
  }
}

public enum ReplayError: Error { case unsupportedSchema, nonMonotonicTime }
