import Foundation
import OSLog
import SoloDisplayCore

/// Deliberately not a free-form logging API. No hardware identity or error description fits here.
public struct OperationalEvent: Codable, Equatable, Sendable {
  public enum Category: String, Codable, CaseIterable, Sendable {
    case lifecycle, recovery, diagnostics
  }

  public enum Role: String, Codable, Sendable { case bootstrap, app, guardian, worker }
  /// Mirrors MenuAction by raw value. The bridge that converts one to the other returns an
  /// optional and drops a mismatch silently, so every menu action needs a case here.
  public enum Action: String, Codable, Sendable {
    case retryRecovery, toggleLaunchAtLogin, toggleBrightnessKeys, toggleInputDetection
    case exportDiagnostics, quit
    case openDisplayMonitor, selectAllMonitors, selectExternalOnly, checkForUpdates
  }

  public enum Code: String, Codable, Sendable {
    case started, startupFailed, action, exitRequested, stateChanged, environmentChanged
    case lifecycleReconciled, suspended, resumed, preferencesSaved, instanceLockUnavailable
    case journalPreparing, journalPrepared, journalClearing, journalCleared
    case workerStarted, workerFinished
    case guardianStarted, guardianReady, guardianGone, guardianReleased, guardianRestoring
    case childExited, exportRequested, exportCompleted, exportFailed
    /// A monitor was recorded as owed, or given back. What a monitor is showing is never in a
    /// record: only that this app turned one off, and how many.
    case monitorSuppressing, monitorRestoring

    public var category: Category {
      switch self {
      case .journalPreparing, .journalPrepared, .journalClearing, .journalCleared,
           .workerStarted, .workerFinished, .guardianStarted, .guardianReady, .guardianGone,
           .guardianReleased, .guardianRestoring, .childExited,
           .monitorSuppressing, .monitorRestoring:
        .recovery
      case .exportRequested, .exportCompleted, .exportFailed: .diagnostics
      default: .lifecycle
      }
    }
  }

  public enum Reason: String, Codable, Sendable {
    case userQuit, missingExecutable, invalidLaunch, journalUnavailable, missingSession
    case alreadyRunning, released, appGone, noUsableExternal, nothingOwed
    case workspaceSleep, workspaceWake, workspaceScreenSleep, workspaceSessionActive
    case workspaceSessionInactive, observationFallback
    case exited, uncaughtSignal, exportEncoding, exportWriting
  }

  public var version = 1
  public var code: Code
  public var role: Role
  public var run: String
  public var session: String?
  public var uptimeMS: Int64
  public var reason: Reason?
  public var workerAction: WriteAction?
  public var workerOutcome: WorkerOutcome?
  public var elapsedMS: Int64?
  public var succeeded: Bool?
  public var exitStatus: Int32?
  public var errorCode: Int?
  public var action: Action?
  public var trouble: Trouble?
  public var unavailability: Unavailability?
  public var mode: Mode?
  public var environment: OperationalEnvironment?
  public var panelOff: Bool?
  public var working: Bool?
  public var failures: Int?
  public var appVersion: String?
  public var build: String?

  public init(code: Code, role: Role, run: UUID, uptimeMS: Int64) {
    self.code = code
    self.role = role
    self.run = run.uuidString
    self.uptimeMS = uptimeMS
  }

  /// Only the format we emit is admitted to exports, never arbitrary unified-log text.
  public var isValid: Bool {
    version == 1 && UUID(uuidString: run) != nil
      && (session == nil || UUID(uuidString: session!) != nil)
      && uptimeMS >= 0 && Self.safeVersion(appVersion) && Self.safeVersion(build)
  }

  public static func safeVersion(_ value: String?) -> Bool {
    guard let value else { return true }
    return !value.isEmpty && value.utf8.count <= 32
      && value.unicodeScalars.allSatisfy { "0123456789.".unicodeScalars.contains($0) }
  }

  public static func numericErrorCode(_ error: any Error) -> Int {
    if let displayError = error as? DisplayAPIError, case let .call(_, code) = displayError {
      return Int(code)
    }
    return (error as NSError).code
  }
}

/// A topology summary, intentionally incapable of containing a panel identity.
public struct OperationalEnvironment: Codable, Equatable, Sendable {
  public var power: Power
  public var lid: Lid
  public var foregroundSession: Fact
  public var nativeExternalAvailable: Fact
  public var supportedTopology: Fact
  public var panelState: PanelState
  /// Monitors that could be turned off, and monitors this app has turned off.
  public var monitors: Int
  public var monitorsOff: Int
  public init(_ environment: Environment) {
    power = environment.power
    lid = environment.lid
    foregroundSession = environment.foregroundSession
    nativeExternalAvailable = environment.nativeExternalAvailable
    supportedTopology = environment.supportedTopology
    panelState = environment.panelState
    monitors = environment.externals.count { $0.suppressible }
    monitorsOff = environment.externals.count { $0.suppressed }
  }
}

public protocol OperationalEventSink: Sendable {
  func record(_ event: OperationalEvent)
}

public struct UnifiedOperationalSink: OperationalEventSink {
  public static let subsystem = "dev.solodisplay.SoloDisplay"
  public init() {}
  public func record(_ event: OperationalEvent) {
    guard event.isValid, let bytes = try? JSONEncoder().encode(event), bytes.count <= 1000,
          let payload = String(data: bytes, encoding: .utf8)
    else { return }
    let logger = Logger(subsystem: Self.subsystem, category: event.code.category.rawValue)
    if event.succeeded == false || event.code == .startupFailed
      || event.code == .guardianRestoring {
      logger.error("\(payload, privacy: .public)")
    } else {
      logger.notice("\(payload, privacy: .public)")
    }
  }
}

public struct OperationalLogger: Sendable {
  public let run: UUID
  public let role: OperationalEvent.Role
  private let sink: any OperationalEventSink
  public init(
    role: OperationalEvent.Role, sink: any OperationalEventSink = UnifiedOperationalSink(),
    run: UUID = UUID()
  ) {
    self.role = role
    self.sink = sink
    self.run = run
  }

  public func emit(
    _ code: OperationalEvent.Code, session: String? = nil,
    reason: OperationalEvent.Reason? = nil, succeeded: Bool? = nil, errorCode: Int? = nil,
    details: (inout OperationalEvent) -> Void = { _ in }
  ) {
    var event = OperationalEvent(
      code: code, role: role, run: run,
      uptimeMS: Int64(ProcessInfo.processInfo.systemUptime * 1000)
    )
    event.session = session.flatMap { UUID(uuidString: $0)?.uuidString }
    event.reason = reason
    event.succeeded = succeeded
    event.errorCode = errorCode
    details(&event)
    if event.isValid {
      sink.record(event)
    }
  }

  public func started(bundle: Bundle = .main) {
    emit(.started) {
      let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      $0.appVersion = OperationalEvent.safeVersion(version) ? version : nil
      $0.build = OperationalEvent.safeVersion(build) ? build : nil
    }
  }
}

/// One instance per actual child. Reporting is not evidence about any display.
public struct ChildExitDiagnostics {
  private var recorded = false
  public init() {}
  @discardableResult public mutating func recordIfTerminated(
    _ child: Process,
    using logger: OperationalLogger, session: String? = nil
  ) -> Bool {
    guard !child.isRunning else { return false }
    guard !recorded else { return true }
    recorded = true
    logger.emit(
      .childExited, session: session,
      reason: child.terminationReason == .exit ? .exited : .uncaughtSignal
    ) {
      $0.exitStatus = child.terminationStatus
    }
    return true
  }
}
