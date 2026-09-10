import Testing
@testable import SoloDisplayCore

struct ProtectionDiagnosticsTests {
  private let owned = Ownership(
    target: .init(
      displayID: 1, displayUUID: "private-panel",
      bootID: "private-boot", loginID: 42
    ), operationID: 1
  )

  private func armed() -> ControllerProtection {
    var controller = ControllerProtection(session: "test", at: 0)
    controller.receive(.start, at: 0)
    controller.receive(
      .received(
        .init(
          session: "test", sender: .helper,
          sequence: 1, kind: .witness
        )
      ), at: 1
    )
    controller.receive(.arm(owned), at: 2)
    return controller
  }

  @Test func disconnectReasonIsLatchedWithoutChangingLossOutputs() {
    var controller = armed()
    #expect(controller.receive(.peerFailed(.disconnected), at: 3) == [.protectionLost])
    #expect(controller.lossReason == .disconnected)
    #expect(controller.receive(.peerFailed(.malformed), at: 4).isEmpty)
    #expect(controller.lossReason == .disconnected)
    #expect(!controller.protects(at: 4))
  }

  @Test func rejectedFrameAndWrongOwnershipHaveDifferentReasons() {
    var stale = armed()
    stale.receive(
      .received(
        .init(
          session: "test", sender: .helper,
          sequence: 1, challenge: 1, kind: .armed, ownership: owned
        )
      ), at: 3
    )
    #expect(stale.lossReason == .rejectedMessage)
    #expect(stale.rejection == .staleSequence)
    var wrong = armed()
    var other = owned
    other.operationID = 2
    wrong.receive(
      .received(
        .init(
          session: "test", sender: .helper,
          sequence: 2, challenge: 1, kind: .armed, ownership: other
        )
      ), at: 3
    )
    #expect(wrong.lossReason == .ownershipMismatch)
  }

  @Test func leaseExpiryRetainsChallengeAndDeadlineEvidence() {
    var controller = armed()
    #expect(controller.receive(.tick, at: 5002) == [.protectionLost])
    #expect(controller.lossReason == .leaseExpired)
    #expect(controller.diagnosticChallenge == 1)
    #expect(controller.diagnosticLeaseDeadline == 5002)
  }

  @Test func helperRetainsStalledOperationAndLastValidProgressTime() {
    var helper = HelperProtection(at: 0)
    helper.receive(.witness(owned.target), at: 0)
    helper.receive(
      .received(
        .init(
          session: "test", sender: .controller,
          sequence: 1, kind: .hello
        )
      ), at: 1
    )
    helper.receive(
      .received(
        .init(
          session: "test", sender: .controller,
          sequence: 2, challenge: 1, kind: .arm, ownership: owned
        )
      ), at: 2
    )
    let progress = OperationProgress(id: 1, kind: .disable, phase: .submitted, deadline: 100)
    let outputs = helper.receive(
      .received(
        .init(
          session: "test", sender: .controller,
          sequence: 3, challenge: 2, kind: .progress, ownership: owned, progress: progress
        )
      ),
      at: 1101
    )
    #expect(outputs == [.recoveryRequired(owned, .operationStalled)])
    #expect(helper.progress == progress)
    #expect(helper.lastProgressAt == 2)
  }
}
