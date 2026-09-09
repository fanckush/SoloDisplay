import Testing

@testable import LidlessPlatform

/// Fixtures captured from the tested Mac on 2026-09-08 with the Dell U3223QE connected by
/// USB-C. They are recorded evidence for this hardware family, not a universal contract.
private let capturedExternal = TransportEvidence(
  displayID: 5, builtIn: false, vendor: 4268, model: 17020, serial: 808_923_980, unit: 4,
  match: .vendorModelSerial,
  providerChain: ["IOMobileFramebufferShim", "AppleARMIODevice", "AppleSoCIO"],
  providerNames: ["IOMobileFramebufferShim", "dispext0", "AppleSoCIO"])

private let capturedInternal = TransportEvidence(
  displayID: 1, builtIn: true, vendor: 1552, model: 41052, serial: 4_251_086_178, unit: 0,
  match: .vendor,
  providerChain: ["IOMobileFramebufferShim", "AppleARMIODevice", "AppleSoCIO"],
  providerNames: ["IOMobileFramebufferShim", "disp0", "AppleSoCIO"])

struct DisplayTransportTests {
  @Test func capturedHardwareClassifiesAsNative() {
    #expect(capturedExternal.transport == .native)
    #expect(capturedInternal.transport == .unclassified)
  }

  @Test func anUncorrelatedDisplayIsNeverNative() {
    var orphan = capturedExternal
    orphan.match = .none
    // Without a service correlation there is no provenance to reason from at all.
    #expect(orphan.transport == .unclassified)
  }

  @Test func aDisplayOutsideTheSoCPipelineIsNeverNative() {
    var elsewhere = capturedExternal
    elsewhere.providerChain = ["IOUserFramebuffer", "IOUserService", "IOResources"]
    elsewhere.providerNames = ["IOUserFramebuffer", "provider", "IOResources"]
    #expect(elsewhere.transport == .unclassified)

    var unknownVendor = elsewhere
    unknownVendor.vendor = DisplayTransportClassifier.unknownVendor
    #expect(unknownVendor.transport == .virtual)
    var absentVendor = elsewhere
    absentVendor.vendor = 0
    #expect(absentVendor.transport == .virtual)
  }

  @Test func theControllerNameMustBeADisplayControllerNotAnyARMDevice() {
    var wrongDevice = capturedExternal
    wrongDevice.providerNames = ["IOMobileFramebufferShim", "usbext0", "AppleSoCIO"]
    // The class alone is shared by unrelated SoC devices, so the entry name has to agree.
    #expect(wrongDevice.transport == .unclassified)
  }

  @Test func aMissingDisplayServiceLinkIsNotRescuedByARealVendor() {
    var noService = capturedExternal
    noService.providerChain = ["AppleARMIODevice", "AppleSoCIO"]
    noService.providerNames = ["dispext0", "AppleSoCIO"]
    #expect(noService.transport == .unclassified)
  }
}
