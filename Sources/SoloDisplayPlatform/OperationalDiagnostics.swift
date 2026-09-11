import Foundation
import OSLog
import SoloDisplayCore

/// Deliberately not a free-form logging API. No hardware identity or error description fits here.
public struct OperationalEvent: Codable, Equatable, Sendable {
  public enum Category: String, Codable, CaseIterable, Sendable {
    case lifecycle, protection, recovery, diagnostics
  }

  public enum Role: String, Codable, Sendable { case bootstrap, controller, helper, probe }
  /// Mirrors MenuAction by raw value. The bridge that converts one to the other returns an
  /// optional and drops a mismatch silently, so a case removed here would quietly empty the
  /// action field of an exported record. Retired interface actions therefore stay, because
  /// this type is persisted and older journals still decode through it.
  public enum Action: String, Codable, Sendable {
    case selectManual, selectAutomatic, turnInternalOff, turnInternalOn, keepInternalOn
    case resumeAutomatic, retryRecovery, toggleLaunchAtLogin, exportDiagnostics, quit
    case openDisplayMonitor, selectAllMonitors, selectExternalOnly
  }

  public enum Code: String, Codable, Sendable {
    case started, startupFailed, paired, action, exitRequested, childTerminationRequested
    case protectionEnded
    case childExited, childExitUnconfirmed, protectionLost, protectionReady, suspended, resumed
    case lifecycleReconciled, operationQueued, operationStarted, operationReturned
    case operationRefused, restoreDeferred, operationVerified, stateChanged, writerUnresponsive
    case journalPreparing, journalPrepared, journalClearing, journalCleared, preferencesSaved
    case environmentChanged
    case recoveryRequested, recoveryWaiting, recoveryBlocked, recoveryVerified
    case writerLockAcquired, writerLockUnavailable, exportRequested, exportCompleted, exportFailed

    public var category: Category {
      switch self {
      case .paired, .protectionLost, .protectionReady, .protectionEnded: .protection
      case .operationQueued, .operationStarted, .operationReturned, .operationRefused,
           .restoreDeferred, .operationVerified, .writerUnresponsive, .journalPreparing,
           .journalPrepared, .journalClearing, .journalCleared, .recoveryRequested,
           .recoveryWaiting, .recoveryBlocked, .recoveryVerified, .writerLockAcquired,
           .writerLockUnavailable:
        .recovery
      case .exportRequested, .exportCompleted, .exportFailed: .diagnostics
      default: .lifecycle
      }
    }
  }

  public enum Reason: String, Codable, Sendable {
    case userQuit, helperLost, nothingOwed, recoveryComplete, controllerLaunchFailed
    case missingExecutable, invalidLaunch, journalUnavailable, missingSession, alreadyRunning
    case unresolvedOwnership, priorSession, recordRetained, recordMismatch, recordUnreadable
    case writerBusy, orderingRefused, evidenceUnavailable, verificationFailed
    case workspaceSleep, workspaceWake, workspaceScreenSleep, workspaceScreenWake
    case workspaceSessionActive, workspaceSessionInactive, activityFallback, observationFallback
    case exited, uncaughtSignal, protectionFailure, exportEncoding, exportWriting
  }

  public var version = 1
  public var code: Code
  public var role: Role
  public var run: String
  public var session: String?
  public var uptimeMS: Int64
  public var reason: Reason?
  public var controllerLoss: ControllerProtection.LossReason?
  public var rejection: ProtectionRejection?
  public var helperLoss: HelperProtection.Reason?
  public var operation: OperationProgress?
  public var operationID: UInt64?
  public var elapsedMS: Int64?
  public var progressAgeMS: Int64?
  public var challengeAgeMS: Int64?
  public var challenge: UInt64?
  public var leaseDeadlineMS: Int64?
  public var deadlineOverdueMS: Int64?
  public var succeeded: Bool?
  public var exitStatus: Int32?
  public var errorCode: Int?
  public var action: Action?
  public var fault: Fault?
  public var unavailability: Unavailability?
  public var mode: Mode?
  public var environment: OperationalEnvironment?
  public var panelOwned: Bool?
  public var pendingRecovery: Bool?
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
  public var restorationMatches: Fact
  public init(_ environment: Environment) {
    power = environment.power
    lid = environment.lid
    foregroundSession = environment.foregroundSession
    nativeExternalAvailable = environment.nativeExternalAvailable
    supportedTopology = environment.supportedTopology
    panelState = environment.panelState
    restorationMatches = environment.restorationMatches
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
    if event.succeeded == false || event.code == .protectionLost || event.code == .startupFailed
      || event.code == .recoveryBlocked || event.code == .writerUnresponsive {
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
    reason: OperationalEvent.Reason? = nil, operation: OperationProgress? = nil,
    succeeded: Bool? = nil, errorCode: Int? = nil,
    details: (inout OperationalEvent) -> Void = { _ in }
  ) {
    var event = OperationalEvent(
      code: code, role: role, run: run,
      uptimeMS: Int64(ProcessInfo.processInfo.systemUptime * 1000)
    )
    event.session = session.flatMap { UUID(uuidString: $0)?.uuidString }
    event.reason = reason
    event.operation = operation
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

/// One instance per actual child. Reporting is not evidence that authorizes display writes.
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
