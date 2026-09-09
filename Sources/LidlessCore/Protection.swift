/// The production protection protocol between the controller and its recovery helper.
/// Messages are claims. Only the receiving role's validated inbox, its own independent
/// observation, and the durable journal turn a claim into authority to change a display.
public enum ProtectionRole: String, Codable, Sendable { case controller, helper }

public enum ProtectionKind: String, Codable, Sendable {
  /// controller -> helper
  case hello, arm, progress, release
  /// helper -> controller
  case witness, armed, acknowledge
  /// either role
  case fault
}

/// Outstanding-operation state carried with every heartbeat. A responsive communication
/// loop must not conceal a stalled display call, so the deadline travels separately.
public struct OperationProgress: Codable, Equatable, Sendable {
  public var id: UInt64
  public var kind: OperationKind
  public var phase: OperationPhase
  public var deadline: Instant

  public init(id: UInt64, kind: OperationKind, phase: OperationPhase, deadline: Instant) {
    self.id = id
    self.kind = kind
    self.phase = phase
    self.deadline = deadline
  }
}

public struct ProtectionMessage: Codable, Equatable, Sendable {
  public static let currentVersion = 2
  public static let maximumDetailLength = 200
  public static let maximumSessionLength = 64

  public var version = ProtectionMessage.currentVersion
  public var session: String
  public var sender: ProtectionRole
  public var sequence: UInt64
  public var challenge: UInt64
  public var kind: ProtectionKind
  public var ownership: Ownership?
  public var progress: OperationProgress?
  public var detail: String?

  public init(
    session: String, sender: ProtectionRole, sequence: UInt64, challenge: UInt64 = 0,
    kind: ProtectionKind, ownership: Ownership? = nil, progress: OperationProgress? = nil,
    detail: String? = nil
  ) {
    self.session = session
    self.sender = sender
    self.sequence = sequence
    self.challenge = challenge
    self.kind = kind
    self.ownership = ownership
    self.progress = progress
    self.detail = detail
  }

  /// Shape validation only. It establishes nothing about the physical display state.
  public var wellFormed: Bool {
    guard version == Self.currentVersion, !session.isEmpty,
      session.count <= Self.maximumSessionLength, sequence > 0,
      (detail?.count ?? 0) <= Self.maximumDetailLength
    else { return false }
    switch kind {
    case .hello, .release:
      return sender == .controller && challenge == 0 && ownership == nil && progress == nil
    case .witness:
      return sender == .helper && challenge == 0 && ownership == nil && progress == nil
    case .arm:
      return sender == .controller && challenge > 0 && ownership != nil && progress == nil
    case .progress:
      return sender == .controller && challenge > 0 && ownership != nil
    case .armed, .acknowledge:
      return sender == .helper && challenge > 0 && ownership != nil && progress == nil
    case .fault:
      return challenge == 0 && ownership == nil && progress == nil
    }
  }
}

public enum ProtectionRejection: String, Error, Equatable, Sendable {
  case unsupportedVersion, wrongSession, wrongSender, staleSequence, malformed, disconnected
}

/// One peer's message stream. Any rejection latches the inbox closed: on a private inherited
/// pipe a stale, duplicated, or malformed frame is evidence of a broken peer, not noise to skip.
public struct ProtectionInbox: Equatable, Sendable {
  public let session: String
  public let peer: ProtectionRole
  public private(set) var lastSequence: UInt64 = 0
  public private(set) var rejection: ProtectionRejection?

  public init(session: String, peer: ProtectionRole) {
    self.session = session
    self.peer = peer
  }

  public var isClosed: Bool { rejection != nil }

  public mutating func close(_ reason: ProtectionRejection = .disconnected) {
    if rejection == nil { rejection = reason }
  }

  public mutating func accept(_ message: ProtectionMessage) throws -> ProtectionMessage {
    if let rejection { throw rejection }
    func refuse(_ reason: ProtectionRejection) -> ProtectionRejection {
      rejection = reason
      return reason
    }
    guard message.version == ProtectionMessage.currentVersion else {
      throw refuse(.unsupportedVersion)
    }
    guard message.wellFormed else { throw refuse(.malformed) }
    guard message.session == session else { throw refuse(.wrongSession) }
    guard message.sender == peer else { throw refuse(.wrongSender) }
    // A single monotonic counter rejects duplicates, reordering, and replayed frames together.
    guard message.sequence > lastSequence else { throw refuse(.staleSequence) }
    lastSequence = message.sequence
    return message
  }
}

public struct ProtectionTiming: Equatable, Sendable {
  /// Heartbeat interval. Leases are revoked after `leaseDuration` without a valid exchange.
  public var heartbeat: Instant = 1_000
  public var leaseDuration: Instant = 5_000
  /// Allowance for scheduling jitter before a passed operation deadline counts as stalled.
  public var stallGrace: Instant = 1_000
  public init() {}
}

/// Controller side. It sends challenges and may disable only while its lease actually protects.
public struct ControllerProtection: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case pairing, paired, arming, protected, lost, released
  }

  public enum Input: Equatable, Sendable {
    case start
    case received(ProtectionMessage)
    case peerFailed(ProtectionRejection)
    case arm(Ownership)
    /// The machine is going to sleep, and is awake again. Time spent suspended is not evidence
    /// of a peer that stopped answering, so no deadline may run across it.
    case suspended
    case resumed
    /// Ends one suppression cycle. Pairing survives, so the next cycle can arm again.
    case release
    /// Ends the run. No further protection is possible on this link.
    case shutdown
    case tick
  }

  public enum Output: Equatable, Sendable {
    case send(ProtectionMessage)
    case protectionEstablished
    /// The controller must restore its owned panel and stop disabling. Never a helper write.
    case protectionLost
  }

  public let session: String
  public let timing: ProtectionTiming
  public private(set) var phase: Phase = .pairing
  public private(set) var ownership: Ownership?
  public private(set) var progress: OperationProgress?

  private var inbox: ProtectionInbox
  private var lease: RecoveryLease?
  private var nextSequence: UInt64 = 1
  private var lastChallengeAt: Instant = 0
  private var suspended = false
  private var now: Instant

  public init(session: String, at now: Instant, timing: ProtectionTiming = .init()) {
    precondition(!session.isEmpty && now >= 0)
    self.session = session
    self.timing = timing
    self.now = now
    inbox = .init(session: session, peer: .helper)
  }

  /// The single gate the coordinator consults. A lease alone is not permission to disable;
  /// durable ownership and fresh platform prerequisites are checked separately.
  public func protects(at now: Instant) -> Bool {
    !suspended && phase == .protected && lease?.protects(at: now) == true
  }

  /// Report the outstanding operation so heartbeats carry a stall the helper can detect.
  public mutating func note(progress: OperationProgress?) { self.progress = progress }

  @discardableResult public mutating func receive(_ input: Input, at now: Instant) -> [Output] {
    guard now >= self.now else { return [] }
    self.now = now
    guard phase != .released else { return [] }

    switch input {
    case .start:
      guard phase == .pairing else { return [] }
      return [.send(next(.hello, at: now))]

    case .peerFailed(let reason):
      inbox.close(reason)
      return fail(at: now)

    case .received(let raw):
      guard let message = try? inbox.accept(raw) else { return fail(at: now) }
      switch (phase, message.kind) {
      case (.pairing, .witness):
        phase = .paired
        return []
      case (.arming, .armed), (.protected, .acknowledge):
        // Replies belong to a suppression cycle, not merely to this process pairing.
        guard message.ownership == ownership else { return fail(at: now) }
        guard lease != nil else { return fail(at: now) }
        lease?.receive(.acknowledged(session: session, challenge: message.challenge), at: now)
        guard lease?.protects(at: now) == true else { return fail(at: now) }
        if phase == .arming {
          phase = .protected
          return [.protectionEstablished]
        }
        return []
      case (_, .fault):
        return fail(at: now)
      case (_, .armed), (_, .acknowledge):
        // A reply for a cycle that has already ended is stale, not evidence of a broken peer.
        // It cannot grant anything either, because only an armed lease is consulted.
        return []
      default:
        // Any other in-shape message in the wrong phase is still a broken peer.
        return fail(at: now)
      }

    case .arm(let owned):
      guard phase == .paired else { return [] }
      ownership = owned
      phase = .arming
      // The lease opens with challenge 1, unacknowledged. Arming is not yet protection.
      lease = RecoveryLease(session: session, at: now, duration: timing.leaseDuration)
      lastChallengeAt = now
      return [.send(next(.arm, at: now, challenge: 1, ownership: owned))]

    case .release, .shutdown:
      let message = next(.release, at: now)
      // Releasing ends a cycle, not the pairing. Only shutdown makes this link terminal.
      phase = input == .shutdown ? .released : .paired
      ownership = nil
      progress = nil
      lease = nil
      return [.send(message)]

    case .suspended:
      suspended = true
      return []

    case .resumed:
      suspended = false
      let renewal = lease?.receive(.resumed, at: now)
      lastChallengeAt = now
      if case .challenge(_, let number)? = renewal?.first {
        return [.send(next(.progress, at: now, challenge: number,
          ownership: ownership, progress: progress))]
      }
      return []

    case .tick:
      guard !suspended, phase == .arming || phase == .protected else { return [] }
      guard var current = lease else { return fail(at: now) }
      let expiry = current.receive(.tick, at: now)
      lease = current
      // An unacknowledged challenge simply lets the lease run out. There is no grace renewal.
      guard expiry.isEmpty else { return fail(at: now) }
      guard phase == .protected, now - lastChallengeAt >= timing.heartbeat else { return [] }
      let renewal = current.receive(.requestRenewal, at: now)
      lease = current
      guard case .challenge(_, let number)? = renewal.first else { return [] }
      lastChallengeAt = now
      return [
        .send(next(.progress, at: now, challenge: number, ownership: ownership, progress: progress))
      ]
    }
  }

  private mutating func fail(at now: Instant) -> [Output] {
    guard phase != .lost, phase != .released else { return [] }
    phase = .lost
    lease?.receive(.contactLost, at: now)
    return [.protectionLost]
  }

  private mutating func next(
    _ kind: ProtectionKind, at now: Instant, challenge: UInt64 = 0,
    ownership: Ownership? = nil, progress: OperationProgress? = nil
  ) -> ProtectionMessage {
    let sequence = nextSequence
    nextSequence += 1
    return .init(
      session: session, sender: .controller, sequence: sequence, challenge: challenge,
      kind: kind, ownership: ownership, progress: progress)
  }
}

/// Helper side. It never disables and never writes on message content alone: recovery still
/// requires confirmed termination of its actual controller child and the takeover ordering.
public struct HelperProtection: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case pairing, paired, protecting, revoked, standingDown
  }

  public enum Reason: String, Equatable, Sendable {
    case controllerExited, contactLost, heartbeatExpired, operationStalled, protocolViolation
  }

  public enum Input: Equatable, Sendable {
    case received(ProtectionMessage)
    case peerFailed(ProtectionRejection)
    /// The helper's own current view of the internal panel, never taken from the message.
    /// Passing nil means it cannot see one, which is never grounds to grant protection.
    case witness(PanelTarget?)
    /// The machine is going to sleep, and is awake again. A suspended controller is not a
    /// silent one, and a deadline that passed while asleep is not a stalled display call.
    case suspended
    case resumed
    /// The controller child is gone. Loss of the pipe alone is not termination evidence.
    case controllerExited
    case tick
  }

  public enum Output: Equatable, Sendable {
    case send(ProtectionMessage)
    /// Drive `RecoveryTakeover` with this ownership. Emitted at most once. That model, not this
    /// one, enforces stopping the actual controller child and taking the lock before any write.
    case recoveryRequired(Ownership, Reason)
    /// Protection ended with nothing owned. The helper must not touch any display.
    case standDown
  }

  /// Adopted from the controller's first frame. Only the actual child inherits this pipe, so
  /// the pairing's identity comes from the pipe rather than from a name both sides guessed.
  public private(set) var session: String?
  public let timing: ProtectionTiming
  public private(set) var phase: Phase = .pairing
  public private(set) var ownership: Ownership?
  public private(set) var reason: Reason?

  private var inbox: ProtectionInbox?
  private var nextSequence: UInt64 = 1
  private var witnessedTarget: PanelTarget?
  private var witnessedAt: Instant?
  private var lastProgressAt: Instant
  private var suspended = false
  private var justResumed = false
  private var recoveryRequested = false
  private var now: Instant

  public init(at now: Instant, timing: ProtectionTiming = .init()) {
    precondition(now >= 0)
    self.timing = timing
    self.now = now
    lastProgressAt = now
  }

  @discardableResult public mutating func receive(_ input: Input, at now: Instant) -> [Output] {
    guard now >= self.now else { return [] }
    self.now = now
    guard phase != .standingDown else { return [] }

    switch input {
    case .suspended:
      suspended = true
      return []

    case .resumed:
      suspended = false
      lastProgressAt = now
      justResumed = true
      return []

    case .witness(let target):
      witnessedTarget = target
      witnessedAt = target == nil ? nil : now
      return []

    case .controllerExited:
      // Only an armed, still-owned protection authorizes recovery. Otherwise stand down.
      return revoke(.controllerExited, at: now)

    case .peerFailed(let rejection):
      inbox?.close(rejection)
      // A closed pipe is lost contact, not confirmed termination. Takeover still proves that.
      return revoke(rejection == .disconnected ? .contactLost : .protocolViolation, at: now)

    case .received(let raw):
      if inbox == nil {
        // The opening frame establishes this pairing's session. Everything after it is
        // validated against that session as strictly as any other stream.
        guard phase == .pairing, raw.kind == .hello, raw.wellFormed else {
          return revoke(.protocolViolation, at: now)
        }
        var fresh = ProtectionInbox(session: raw.session, peer: .controller)
        guard (try? fresh.accept(raw)) != nil else { return revoke(.protocolViolation, at: now) }
        session = raw.session
        inbox = fresh
        phase = .paired
        return [.send(next(.witness, at: now))]
      }
      guard var open = inbox, let message = try? open.accept(raw) else {
        inbox?.close(.malformed)
        return revoke(.protocolViolation, at: now)
      }
      inbox = open
      switch (phase, message.kind) {
      case (.pairing, .hello):
        phase = .paired
        return [.send(next(.witness, at: now))]
      case (.paired, .arm):
        // The claimed target must agree with this process's own fresh observation. A stale
        // witness is no witness: the panel could have changed since it was taken.
        guard let claimed = message.ownership, let witnessedTarget, let witnessedAt,
          claimed.target == witnessedTarget, now - witnessedAt <= timing.leaseDuration
        else {
          return revoke(.protocolViolation, at: now)
        }
        ownership = claimed
        phase = .protecting
        lastProgressAt = now
        return [.send(next(.armed, at: now, challenge: message.challenge))]
      case (.protecting, .progress):
        guard message.ownership == ownership else {
          return revoke(.protocolViolation, at: now)
        }
        // Heartbeats prove the loop runs. They never prove the display call returned. The
        // first report after a resume carries a deadline set before the machine slept.
        if let progress = message.progress, !justResumed,
          now > progress.deadline + timing.stallGrace
        {
          return revoke(.operationStalled, at: now)
        }
        justResumed = false
        lastProgressAt = now
        return [.send(next(.acknowledge, at: now, challenge: message.challenge))]
      case (_, .release):
        // The controller reports its own panel restored. Nothing remains to recover, but the
        // pairing stands so a later cycle can arm again.
        ownership = nil
        reason = nil
        recoveryRequested = false
        phase = .paired
        return [.standDown]
      case (_, .fault):
        return revoke(.protocolViolation, at: now)
      default:
        return revoke(.protocolViolation, at: now)
      }

    case .tick:
      guard !suspended, phase == .protecting, now - lastProgressAt >= timing.leaseDuration
      else { return [] }
      return revoke(.heartbeatExpired, at: now)
    }
  }

  private mutating func revoke(_ reason: Reason, at now: Instant) -> [Output] {
    if self.reason == nil { self.reason = reason }
    guard phase == .protecting || phase == .revoked, let ownership else {
      // Nothing was ever armed, so there is no owned panel this helper may restore.
      phase = .standingDown
      return [.standDown]
    }
    phase = .revoked
    guard !recoveryRequested else { return [] }
    recoveryRequested = true
    return [.recoveryRequired(ownership, self.reason ?? reason)]
  }

  private mutating func next(
    _ kind: ProtectionKind, at now: Instant, challenge: UInt64 = 0
  ) -> ProtectionMessage {
    let sequence = nextSequence
    nextSequence += 1
    return .init(
      session: session ?? "", sender: .helper, sequence: sequence, challenge: challenge, kind: kind,
      ownership: kind == .armed || kind == .acknowledge ? ownership : nil)
  }
}
