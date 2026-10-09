import Testing
@testable import SoloDisplayPlatform

/// Fixtures captured from the tested Mac on 2026-09-08 with the Dell U3223QE connected by
/// USB-C. They are recorded evidence for this hardware family, not a universal contract.
private let capturedExternal = TransportEvidence(
  displayID: 5, builtIn: false, vendor: 4268, model: 17020, serial: 808_923_980, unit: 4,
  match: .vendorModelSerial,
  providerChain: ["IOMobileFramebufferShim", "AppleARMIODevice", "AppleSoCIO"],
  providerNames: ["IOMobileFramebufferShim", "dispext0", "AppleSoCIO"]
)

private let capturedInternal = TransportEvidence(
  displayID: 1, builtIn: true, vendor: 1552, model: 41052, serial: 4_251_086_178, unit: 0,
  match: .vendor,
  providerChain: ["IOMobileFramebufferShim", "AppleARMIODevice", "AppleSoCIO"],
  providerNames: ["IOMobileFramebufferShim", "disp0", "AppleSoCIO"]
)

/// Captured from the same Mac on 2026-10-09 with a 1440p monitor on its HDMI port, whose EDID
/// macOS failed to read: zeros on the display and on the `dispext0` service alike.
private let blankMonitor = DisplayTransportClassifier.Identity(vendor: 0, model: 0, serial: 0)
/// The built-in panel's service. Its ProductID is wider than 32 bits, so it reads as 0.
private let internalService = DisplayTransportClassifier.Identity(vendor: 1552, model: 0, serial: 0)
private let internalDisplay = DisplayTransportClassifier.Identity(
  vendor: 1552, model: 41052, serial: 4_251_086_178
)
private let dell = DisplayTransportClassifier.Identity(
  vendor: 4268, model: 17020, serial: 808_923_980
)

private func links(
  _ displays: [(DisplayTransportClassifier.Identity, Bool)],
  _ services: [DisplayTransportClassifier.Identity]
) -> [Int: TransportMatch] {
  DisplayTransportClassifier.links(
    displays: displays.map { (identity: $0.0, builtIn: $0.1) }, services: services
  ).mapValues(\.match)
}

struct DisplayTransportTests {
  @Test func capturedHardwareClassifiesAsNative() {
    #expect(capturedExternal.transport == .native)
    #expect(capturedInternal.transport == .unclassified)
  }

  /// Reported in issue #8 by a Mac whose display services are named `AppleCLCD2`. The chip
  /// decides the class name, so the earlier one classifies exactly like the later one.
  @Test func theEarlierDisplayServiceClassIsAlsoNative() {
    var earlier = capturedExternal
    earlier.providerChain = ["AppleCLCD2", "AppleARMIODevice", "AppleSoCIO"]
    earlier.providerNames = ["AppleCLCD2", "dispext0", "AppleSoCIO"]
    #expect(earlier.transport == .native)

    var wrongDevice = earlier
    wrongDevice.providerNames = ["AppleCLCD2", "usbext0", "AppleSoCIO"]
    #expect(wrongDevice.transport == .unclassified)
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

  @Test func aMonitorMacOSCouldNotIdentifyIsLinkedToTheOnlyPortLeft() {
    let found = DisplayTransportClassifier.links(
      displays: [(internalDisplay, true), (blankMonitor, false)],
      services: [internalService, blankMonitor]
    )
    #expect(found[1]?.service == 1)
    #expect(found[1]?.match == .vendorModel)
    #expect(found[0] == nil)

    var hdmi = capturedExternal
    hdmi.vendor = 0
    hdmi.model = 0
    hdmi.serial = 0
    hdmi.match = .vendorModel
    #expect(hdmi.transport == .native)
  }

  @Test func aVirtualDisplayNextToABlankMonitorLeavesBothUnlinked() {
    // Two displays read as zeros and only one port does: either could be the software one.
    #expect(links([(internalDisplay, true), (blankMonitor, false), (blankMonitor, false)],
                  [internalService, blankMonitor]).isEmpty)
  }

  @Test func aMonitorWithoutASerialIsLinkedUnlessTheSerialsDisagree() {
    var serialless = dell
    serialless.serial = 0
    #expect(links([(serialless, false)], [serialless]) == [0: .vendorModel])
    #expect(links([(serialless, false)], [dell]) == [0: .vendorModel])

    var other = dell
    other.serial = 1
    #expect(links([(other, false)], [dell]).isEmpty)
  }

  @Test func twoIdenticalMonitorsWithoutSerialsStayUnlinked() {
    var serialless = dell
    serialless.serial = 0
    #expect(links([(serialless, false), (serialless, false)], [serialless, serialless]).isEmpty)
  }

  @Test func anExactMatchKeepsItsPortFromTheSecondPass() {
    var serialless = dell
    serialless.serial = 0
    // The Dell owns its port, so the serial-less twin has nothing left to pair with.
    #expect(links([(dell, false), (serialless, false)], [dell]) == [0: .vendorModelSerial])
  }

  @Test func theBuiltInPanelIsNeverLinkedByTheSecondPass() {
    #expect(links([(internalService, true)], [internalService]).isEmpty)
  }

  @Test func aSecondPassLinkStillHasToBeOnTheDisplayPipeline() {
    var linked = capturedExternal
    linked.match = .vendorModel
    #expect(linked.transport == .native)
    linked.providerNames = ["IOMobileFramebufferShim", "usbext0", "AppleSoCIO"]
    #expect(linked.transport == .unclassified)
  }
}
