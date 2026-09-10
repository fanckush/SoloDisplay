import Testing
@testable import SoloDisplayCore

@Test func oldArmReplyCannotAuthorizeAnotherOperation() {
  let target = PanelTarget(displayID: 1, displayUUID: "panel", bootID: "boot", loginID: 1)
  let old = Ownership(target: target, operationID: 1)
  var controller = ControllerProtection(session: "run", at: 0)
  controller.receive(.start, at: 0)
  controller.receive(.received(.init(session: "run", sender: .helper,
                                     sequence: 1, kind: .witness)), at: 1)
  controller.receive(.arm(old), at: 2)
  controller.receive(.release, at: 3)
  controller.receive(.arm(.init(target: target, operationID: 2)), at: 4)
  let output = controller.receive(.received(.init(
    session: "run",
    sender: .helper,
    sequence: 2,
    challenge: 1,
    kind: .armed,
    ownership: old
  )), at: 5)
  #expect(!output.contains(.protectionEstablished))
  #expect(!controller.protects(at: 5))
}

@Test func wakingRequiresANewLeaseAcknowledgement() {
  var lease = RecoveryLease(session: "run", at: 0)
  lease.receive(.acknowledged(session: "run", challenge: 1), at: 1)
  #expect(lease.protects(at: 1))
  #expect(lease.receive(.resumed, at: 120_000) == [.challenge(session: "run", number: 2)])
  #expect(!lease.protects(at: 120_000))
  lease.receive(.acknowledged(session: "run", challenge: 1), at: 120_001)
  #expect(!lease.protects(at: 120_001))
  lease.receive(.acknowledged(session: "run", challenge: 2), at: 120_002)
  #expect(lease.protects(at: 120_002))
}
