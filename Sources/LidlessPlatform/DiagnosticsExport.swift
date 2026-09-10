import Foundation
import LidlessCore
import OSLog

public struct OperationalHistoryEntry: Codable, Equatable, Sendable {
  public var date: Date
  public var event: OperationalEvent
  public init(date: Date, event: OperationalEvent) {
    self.date = date
    self.event = event
  }
}

public struct OperationalHistory: Codable, Sendable {
  public enum Status: String, Codable, Sendable { case collected, empty, unavailable, failed }
  public var status: Status
  public var entries: [OperationalHistoryEntry]
  public var truncated: Bool
  public var rejectedEntries: Int
  public var errorCode: Int?
  public init(
    status: Status, entries: [OperationalHistoryEntry] = [], truncated: Bool = false,
    rejectedEntries: Int = 0, errorCode: Int? = nil
  ) {
    self.status = status
    self.entries = entries
    self.truncated = truncated
    self.rejectedEntries = rejectedEntries
    self.errorCode = errorCode
  }
}

public protocol OperationalHistoryReading: Sendable {
  /// Synchronous by design; callers must use a background task, never the protection loop.
  func read(from: Date, through: Date) -> OperationalHistory
}

public struct SystemOperationalHistoryReader: OperationalHistoryReading {
  public init() {}
  public func read(from: Date, through: Date) -> OperationalHistory {
    let store: OSLogStore
    do { store = try OSLogStore(scope: .system) } catch {
      return .init(status: .unavailable, errorCode: (error as NSError).code)
    }
    let predicate = NSPredicate(
      format: "subsystem == %@ AND category IN %@",
      UnifiedOperationalSink.subsystem, OperationalEvent.Category.allCases.map(\.rawValue)
    )
    do {
      let entries = try store.getEntries(
        with: [.reverse], at: store.position(date: through),
        matching: predicate
      )
      var result = OperationalHistory(status: .empty)
      var bytes = 0
      let deadline = Date().addingTimeInterval(5)
      for raw in entries {
        if raw.date < from {
          break
        }
        if Task.isCancelled || Date() >= deadline {
          result.truncated = true
          break
        }
        guard raw.date <= through, let log = raw as? OSLogEntryLog,
              log.subsystem == UnifiedOperationalSink.subsystem,
              let category = OperationalEvent.Category(rawValue: log.category)
        else { continue }
        let data = Data(log.composedMessage.utf8)
        guard data.count <= 1000,
              let event = try? JSONDecoder().decode(OperationalEvent.self, from: data),
              event.isValid, event.code.category == category
        else {
          result.rejectedEntries += 1
          continue
        }
        let entry = OperationalHistoryEntry(date: log.date, event: event)
        let size = try JSONEncoder().encode(entry).count + 1
        if result.entries.count >= 2000 || bytes + size > 500_000 {
          result.truncated = true
          break
        }
        result.entries.append(entry)
        bytes += size
      }
      result.entries.reverse()
      result.status = result.entries.isEmpty ? .empty : .collected
      return result
    } catch { return .init(status: .failed, errorCode: (error as NSError).code) }
  }
}

public struct DiagnosticsMetadata: Codable, Sendable {
  public var schemaVersion = 1
  public var collectedAt: Date
  public var requestedFrom: Date
  public var requestedThrough: Date
  public var traceTruncated: Bool
  public var history: OperationalHistory
  public var explanation: String
  public static let consoleInstructions =
    "In Console, select this Mac and search for subsystem:dev.lidless.Lidless. "
      + "Check the incident time and the lifecycle, protection, and recovery categories. "
      + "macOS controls access and retention; Console may require administrator access. "
      + "If historical entries are unavailable, start streaming before reproducing the issue."
}

/// Replay fields stay at the top level so existing ReplayTrace decoders continue to work.
public struct DiagnosticsDocument: Codable, Sendable {
  public var schemaVersion: Int
  public var initial: ControllerState
  public var events: [RecordedEvent]
  public var diagnostics: DiagnosticsMetadata
}

public protocol DiagnosticsFileWriting: Sendable {
  func write(_ data: Data, to url: URL) throws
}

public struct AtomicDiagnosticsFileWriter: DiagnosticsFileWriting {
  public init() {}
  public func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }
}

public struct DiagnosticsExporter: Sendable {
  private let reader: any OperationalHistoryReading
  private let writer: any DiagnosticsFileWriting
  public init(
    reader: any OperationalHistoryReading = SystemOperationalHistoryReader(),
    writer: any DiagnosticsFileWriting = AtomicDiagnosticsFileWriter()
  ) {
    self.reader = reader
    self.writer = writer
  }

  public func collect(trace: ReplayTrace, at date: Date = Date()) throws -> Data {
    let from = date.addingTimeInterval(-24 * 60 * 60)
    return try Self.encode(
      trace: trace, history: reader.read(from: from, through: date),
      from: from, through: date, collectedAt: Date()
    )
  }

  public func write(_ data: Data, to url: URL) throws {
    try writer.write(data, to: url)
  }

  public static func encode(
    trace: ReplayTrace, history: OperationalHistory,
    from: Date, through: Date, collectedAt: Date
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var history = history
    let valid = history.entries.filter {
      $0.event.isValid && $0.date >= from && $0.date <= through
    }.sorted { $0.date < $1.date }
    history.rejectedEntries += history.entries.count - valid.count
    history.entries = []
    var bytes = 0
    for entry in valid.reversed() {
      let size = try encoder.encode(entry).count + 1
      guard history.entries.count < 2000, bytes + size <= 500_000 else {
        history.truncated = true
        break
      }
      history.entries.append(entry)
      bytes += size
    }
    history.entries.reverse()
    if history.status == .collected || history.status == .empty {
      history.status = history.entries.isEmpty ? .empty : .collected
    }
    // A single namespace preserves pairing relationships without retaining original run IDs.
    var aliases: [String: String] = [:]
    func alias(_ id: String) -> String {
      if let existing = aliases[id] {
        return existing
      }
      let name = "run-\(aliases.count + 1)"
      aliases[id] = name
      return name
    }
    for index in history.entries.indices {
      history.entries[index].event.run = alias(history.entries[index].event.run)
      if let session = history.entries[index].event.session {
        history.entries[index].event.session = alias(session)
      }
    }
    // Leave room for metadata and JSON framing inside the existing overall 5 MB ceiling.
    var recorder = TraceRecorder(initial: trace.initial, maxEvents: 8000, maxBytes: 4_450_000)
    for entry in trace.events {
      try recorder.append(entry)
    }
    let replay = try JSONDecoder().decode(ReplayTrace.self, from: recorder.exportSanitized())
    let explanation = switch history.status {
    case .collected:
      "Available Lidless history only, not a complete record of every exit."
    case .empty:
      "No readable Lidless history was returned. This does not prove nothing happened."
    case .unavailable:
      "macOS did not grant system-log access. The current replay trace is still included."
    case .failed:
      "System-log collection failed. The current replay trace is still included."
    }
    let document = DiagnosticsDocument(
      schemaVersion: replay.schemaVersion, initial: replay.initial,
      events: replay.events,
      diagnostics: .init(
        collectedAt: collectedAt, requestedFrom: from,
        requestedThrough: through, traceTruncated: replay.events.count < trace.events.count,
        history: history, explanation: explanation + " " + DiagnosticsMetadata.consoleInstructions
      )
    )
    let data = try encoder.encode(document)
    guard data.count <= 5_000_000 else { throw TraceError.stateExceedsLimit }
    return data
  }
}
