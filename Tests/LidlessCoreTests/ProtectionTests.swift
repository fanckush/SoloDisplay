import Testing

@testable import LidlessCore

private let protectedPanel = PanelTarget(
  displayID: 7, displayUUID: "panel-uuid", bootID: "boot", loginID: 501)
private let owned = Ownership(target: protectedPanel, operationID: 3)

/// Drives both roles against each other without any transport, so ordering and timing
/// properties are checked deterministically before the real-process tests run them.
private struct Pair {
  var controller: ControllerProtection
  var helper: HelperProtection
  private(set) var established = false
  private(set) var lost = false
  private(set) var recovery: [(Ownership, HelperProtection.Reason)] = []
  private(set) var stoodDown = false

  init(at now: Instant = 0, timing: ProtectionTiming = .init(), witnessed: Bool = true) {
    controller = .init(session: "s", at: now, timing: timing)
    helper = .init(at: now, timing: timing)
    helper.receive(.witness(witnessed ? protectedPanel : nil), at: now)
  }

  /// Delivers messages until neither side has anything to say. `dropHelperReplies` models a
  /// helper that stays connected but stops answering.
  mutating func pump(
    _ seed: [ControllerProtection.Output], at now: Instant, dropHelperReplies: Bool = false
  ) {
    var fromController = seed
    while !fromController.isEmpty {
      var next: [ControllerProtection.Output] = []
      for output in fromController {
        switch output {
        case .protectionEstablished: established = true
        case .protectionLost: lost = true
        case .send(let message):
          for reply in helper.receive(.received(message), at: now) {
            switch reply {
            case .recoveryRequired(let ownership, let reason): recovery.append((ownership, reason))
            case .standDown: stoodDown = true
            case .send(let answer):
              guard !dropHelperReplies else { continue }
              next += controller.receive(.received(answer), at: now)
            }
          }
        }
      }
      fromController = next
    }
  }

  mutating func tick(at now: Instant, dropHelperReplies: Bool = false) {
    pump(controller.receive(.tick, at: now), at: now, dropHelperReplies: dropHelperReplies)
    for output in helper.receive(.tick, at: now) {
      switch output {
      case .recoveryRequired(let ownership, let reason): recovery.append((ownership, reason))
      case .standDown: stoodDown = true
      case .send: break
      }
    }
  }

  mutating func establish(at now: Instant = 0) {
    pump(controller.receive(.start, at: now), at: now)
    pump(controller.receive(.arm(owned), at: now), at: now)
  }
}

struct ProtectionTests {
  @Test func handshakeEstablishesProtectionOnlyAfterAnIndependentWitness() {
    var pair = Pair()
    pair.establish()
    #expect(pair.established)
    #expect(pair.controller.protects(at: 0))
    #expect(pair.helper.phase == .protecting)
    #expect(pair.recovery.isEmpty)
  }

  @Test func armingWithoutAHelperWitnessNeverProtectsAndNeverAuthorizesRecovery() {
    var pair = Pair(witnessed: false)
    pair.establish()
    #expect(!pair.established)
    #expect(!pair.controller.protects(at: 0))
    #expect(pair.stoodDown)
    #expect(pair.recovery.isEmpty)
    // The controller's unacknowledged lease then runs out rather than assuming protection.
    pair.tick(at: 5_000)
    #expect(pair.lost)
    #expect(!pair.controller.protects(at: 5_000))
  }

  @Test func heartbeatsRenewProtectionAndCarryOutstandingOperationState() {
    var pair = Pair()
    pair.establish()
    pair.controller.note(
      progress: .init(id: 3, kind: .disable, phase: .submitted, deadline: 4_000))
    for now in stride(from: Instant(1_000), through: 9_000, by: 1_000) {
      pair.controller.note(
        progress: .init(id: 3, kind: .disable, phase: .submitted, deadline: now + 3_000))
      pair.tick(at: now)
      #expect(pair.controller.protects(at: now))
    }
    #expect(!pair.lost)
    #expect(pair.recovery.isEmpty)
    #expect(pair.helper.phase == .protecting)
  }

  @Test func aSilentButConnectedHelperExpiresTheControllerLease() {
    var pair = Pair()
    pair.establish()
    pair.tick(at: 1_000, dropHelperReplies: true)
    #expect(pair.controller.protects(at: 1_000))
    pair.tick(at: 4_999, dropHelperReplies: true)
    #expect(pair.controller.protects(at: 4_999))
    pair.tick(at: 5_000, dropHelperReplies: true)
    #expect(pair.lost)
    #expect(!pair.controller.protects(at: 5_000))
  }

  @Test func aSilentControllerExpiresTheHelperLeaseWithoutAnImmediateWrite() {
    var pair = Pair()
    pair.establish()
    // The helper only stops hearing from the controller; nothing proves the process died.
    for output in pair.helper.receive(.tick, at: 4_999) {
      if case .recoveryRequired = output { Issue.record("revoked before the lease expired") }
    }
    #expect(pair.helper.phase == .protecting)
    let expired = pair.helper.receive(.tick, at: 5_000)
    #expect(expired == [.recoveryRequired(owned, .heartbeatExpired)])
    #expect(pair.helper.phase == .revoked)
  }

  @Test func aResponsiveLoopDoesNotHideAStalledDisplayCall() {
    var pair = Pair()
    pair.establish()
    pair.controller.note(
      progress: .init(id: 3, kind: .disable, phase: .submitted, deadline: 2_000))
    // Heartbeats keep arriving, so the lease is healthy. The operation deadline is not.
    pair.tick(at: 1_000)
    #expect(pair.recovery.isEmpty)
    pair.tick(at: 3_100)
    #expect(pair.recovery.map(\.1) == [.operationStalled])
    // At most one recovery request, no matter how many more heartbeats arrive.
    pair.tick(at: 4_100)
    pair.tick(at: 5_200)
    #expect(pair.recovery.count == 1)
  }

  @Test func lostContactRequestsRecoveryAsContactLossNotConfirmedTermination() {
    var pair = Pair()
    pair.establish()
    let outputs = pair.helper.receive(.peerFailed(.disconnected), at: 1_000)
    #expect(outputs == [.recoveryRequired(owned, .contactLost)])
    // A confirmed exit afterwards must not produce a second recovery request.
    #expect(pair.helper.receive(.controllerExited, at: 1_100).isEmpty)
  }

  @Test func releaseEndsTheCycleButKeepsThePairing() {
    var pair = Pair()
    pair.establish()
    pair.pump(pair.controller.receive(.release, at: 1_000), at: 1_000)
    #expect(pair.stoodDown)
    #expect(pair.helper.ownership == nil)
    #expect(!pair.controller.protects(at: 1_000))
    #expect(pair.recovery.isEmpty)

    // A second suppression cycle must be possible on the same pair.
    pair.pump(pair.controller.receive(.arm(owned), at: 2_000), at: 2_000)
    #expect(pair.controller.protects(at: 2_000))
    #expect(pair.helper.phase == .protecting)
    // And recovery is available again for the new cycle.
    #expect(
      pair.helper.receive(.controllerExited, at: 2_100) == [
        .recoveryRequired(owned, .controllerExited)
      ])
  }

  @Test func shutdownIsTerminalForTheLink() {
    var pair = Pair()
    pair.establish()
    pair.pump(pair.controller.receive(.shutdown, at: 1_000), at: 1_000)
    #expect(pair.controller.receive(.arm(owned), at: 2_000).isEmpty)
    #expect(!pair.controller.protects(at: 2_000))
  }

  @Test func aControllerThatNeverArmedLeavesNothingForTheHelperToRestore() {
    var pair = Pair()
    pair.pump(pair.controller.receive(.start, at: 0), at: 0)
    #expect(pair.helper.phase == .paired)
    #expect(pair.helper.receive(.controllerExited, at: 100) == [.standDown])
    #expect(pair.recovery.isEmpty)
  }

  @Test func heartbeatsCarryingDifferentOwnershipRevokeProtection() {
    var pair = Pair()
    pair.establish()
    let other = Ownership(
      target: .init(displayID: 8, displayUUID: "other", bootID: "boot", loginID: 501),
      operationID: 4)
    let forged = ProtectionMessage(
      session: "s", sender: .controller, sequence: 99, challenge: 2, kind: .progress,
      ownership: other)
    #expect(
      pair.helper.receive(.received(forged), at: 1_000) == [
        .recoveryRequired(owned, .protocolViolation)
      ])
  }

  @Test func inboxRejectsStaleDuplicateForeignAndMalformedFrames() throws {
    var inbox = ProtectionInbox(session: "s", peer: .controller)
    let hello = ProtectionMessage(session: "s", sender: .controller, sequence: 1, kind: .hello)
    #expect(try inbox.accept(hello) == hello)
    // A replay of an accepted frame latches the inbox closed rather than being ignored.
    #expect(throws: ProtectionRejection.staleSequence) { try inbox.accept(hello) }
    #expect(inbox.isClosed)
    #expect(throws: ProtectionRejection.staleSequence) {
      try inbox.accept(
        ProtectionMessage(session: "s", sender: .controller, sequence: 2, kind: .hello))
    }

    var foreign = ProtectionInbox(session: "s", peer: .controller)
    #expect(throws: ProtectionRejection.wrongSession) {
      try foreign.accept(
        ProtectionMessage(session: "other", sender: .controller, sequence: 1, kind: .hello))
    }

    var reversed = ProtectionInbox(session: "s", peer: .controller)
    #expect(throws: ProtectionRejection.wrongSender) {
      try reversed.accept(
        ProtectionMessage(session: "s", sender: .helper, sequence: 1, kind: .witness))
    }

    var outdated = ProtectionInbox(session: "s", peer: .controller)
    var future = hello
    future.version = ProtectionMessage.currentVersion + 1
    #expect(throws: ProtectionRejection.unsupportedVersion) { try outdated.accept(future) }
  }

  @Test func messageShapeMustMatchItsSenderAndKind() {
    #expect(
      ProtectionMessage(session: "s", sender: .controller, sequence: 1, kind: .hello).wellFormed)
    // A sequence number of zero can never be greater than a fresh inbox's counter.
    #expect(
      !ProtectionMessage(session: "s", sender: .controller, sequence: 0, kind: .hello).wellFormed)
    #expect(
      !ProtectionMessage(session: "", sender: .controller, sequence: 1, kind: .hello).wellFormed)
    // Only the helper witnesses and acknowledges; only the controller arms and reports progress.
    #expect(!ProtectionMessage(session: "s", sender: .helper, sequence: 1, kind: .hello).wellFormed)
    #expect(
      !ProtectionMessage(session: "s", sender: .controller, sequence: 1, kind: .witness).wellFormed)
    // Arming without an ownership claim, or without a challenge, is not an arm request.
    #expect(
      !ProtectionMessage(session: "s", sender: .controller, sequence: 1, challenge: 1, kind: .arm)
        .wellFormed)
    #expect(
      !ProtectionMessage(
        session: "s", sender: .controller, sequence: 1, kind: .arm, ownership: owned
      ).wellFormed)
    #expect(
      ProtectionMessage(
        session: "s", sender: .controller, sequence: 1, challenge: 1, kind: .arm, ownership: owned
      ).wellFormed)
    #expect(
      !ProtectionMessage(
        session: "s", sender: .controller, sequence: 1, kind: .hello,
        detail: String(repeating: "x", count: ProtectionMessage.maximumDetailLength + 1)
      ).wellFormed)
  }

  @Test func aFaultFromEitherRoleEndsProtection() {
    var pair = Pair()
    pair.establish()
    let fault = ProtectionMessage(session: "s", sender: .helper, sequence: 99, kind: .fault)
    #expect(pair.controller.receive(.received(fault), at: 1_000) == [.protectionLost])
    #expect(!pair.controller.protects(at: 1_000))
  }

  @Test func theHelperAdoptsTheSessionFromTheOpeningFrame() {
    // Both sides generate their own identity in production, so the helper cannot be told the
    // session up front. It comes from the first frame on the private inherited pipe.
    var controller = ControllerProtection(session: "controller-chosen", at: 0)
    var helper = HelperProtection(at: 0)
    #expect(helper.session == nil)
    guard case .send(let hello)? = controller.receive(.start, at: 0).first else {
      Issue.record("expected an opening frame")
      return
    }
    let reply = helper.receive(.received(hello), at: 0)
    #expect(helper.session == "controller-chosen")
    #expect(helper.phase == .paired)
    guard case .send(let witness)? = reply.first else {
      Issue.record("expected a witness reply")
      return
    }
    #expect(witness.session == "controller-chosen")
    #expect(controller.receive(.received(witness), at: 0).isEmpty)
    #expect(controller.phase == .paired)
  }

  @Test func aSecondSessionOnTheSamePipeIsRejected() {
    var helper = HelperProtection(at: 0)
    let hello = ProtectionMessage(
      session: "first", sender: .controller, sequence: 1, kind: .hello)
    #expect(!helper.receive(.received(hello), at: 0).isEmpty)
    let intruder = ProtectionMessage(
      session: "second", sender: .controller, sequence: 2, challenge: 1, kind: .arm,
      ownership: owned)
    // Nothing was armed, so there is nothing to recover; it stands down rather than writing.
    #expect(helper.receive(.received(intruder), at: 1) == [.standDown])
  }

  @Test func anOpeningFrameThatIsNotAHelloEstablishesNothing() {
    var helper = HelperProtection(at: 0)
    let premature = ProtectionMessage(
      session: "x", sender: .controller, sequence: 1, challenge: 1, kind: .arm, ownership: owned)
    #expect(helper.receive(.received(premature), at: 0) == [.standDown])
    #expect(helper.session == nil)
    #expect(helper.ownership == nil)
  }

  @Test func aLateAcknowledgementAfterReleaseDoesNotBreakThePairing() throws {
    var pair = Pair()
    pair.establish()
    // Ask for a renewal but hold the helper's reply, the way one can still be in flight.
    var held: ProtectionMessage?
    for output in pair.controller.receive(.tick, at: 1_000) {
      guard case .send(let message) = output else { continue }
      for reply in pair.helper.receive(.received(message), at: 1_000) {
        if case .send(let answer) = reply { held = answer }
      }
    }
    let stale = try #require(held)

    pair.pump(pair.controller.receive(.release, at: 1_100), at: 1_100)
    #expect(pair.controller.receive(.received(stale), at: 1_200).isEmpty)
    #expect(pair.controller.phase == .paired)
    #expect(!pair.lost)
    // It grants nothing either: protection still requires a fresh arm.
    #expect(!pair.controller.protects(at: 1_200))
    pair.pump(pair.controller.receive(.arm(owned), at: 2_000), at: 2_000)
    #expect(pair.controller.protects(at: 2_000))
  }
}
