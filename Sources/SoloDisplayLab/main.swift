import CoreGraphics
import Foundation
import SoloDisplayCore
import SoloDisplayPlatform

let usage = """
solodisplay-lab observe
    Read-only display and capability report. This is the default command.
    It never changes a display.
solodisplay-lab ddc list
    Lists external displays with the display controller that carries their DDC service.
solodisplay-lab ddc get [displayID]
    Reads the brightness of an external display over DDC.
solodisplay-lab ddc set <value> [displayID]
    Sets the brightness of an external display over DDC.
solodisplay-lab ddc input
    Reads the input source every connected external display is showing.
solodisplay-lab ddc watch [seconds]
    Polls the input source of every external display and reports each change.
    Switch a monitor to another machine to see whether it still answers.
solodisplay-lab modes
    Read-only. For each external display: its native and current modes, and whether Sharp
    Text could render the current size at 2x.
solodisplay-lab modes try <width> <height> [seconds]
    Switches the one external display to the plain mode at that size, then to its 2x twin,
    then back to how it was. Watch the monitor for a blank between the two. Changes last only
    while this runs: Ctrl-C reverts them too.
"""

enum LabError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case let .message(text): text
    }
  }
}

func emit(_ value: some Encodable) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(value)
  print(String(bytes: data, encoding: .utf8) ?? "")
}

/// External displays that both correlate to a controller and have a DDC service, read fresh each
/// time: a monitor switched to another input may leave the list entirely.
func ddcDisplays() -> [(id: UInt32, controller: String)] {
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
  let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
  let services = Set(IOAVServiceDDC.externalControllers())
  return IOAVServiceDDC.controllers(forDisplays: Array(externals))
    .filter { services.contains($0.value) }
    .map { (id: $0.key, controller: $0.value) }
    .sorted { $0.id < $1.id }
}

/// The input source as text, keeping the failure visible: a monitor showing another machine may
/// answer with that input, stop answering, or disappear. All three are results worth seeing.
func inputReading(_ controller: String) -> String {
  let value = try? IOAVServiceDDC.channel(controller: controller)
    .get(code: DDCPacket.inputSource)
  // The same verdict the app acts on, so the two can never read one reply differently.
  let evidence = InputSourceEvidence(controller: controller, reply: value)
  guard let value else { return "no reading, shown \(evidence.shown.rawValue)" }
  return "input 0x\(String(value.current, radix: 16)), shown \(evidence.shown.rawValue)"
}

func watchInputs(every interval: Double) {
  setvbuf(stdout, nil, _IOLBF, 0) // The run is long, so each line has to leave a redirect at once.
  let clock = DateFormatter()
  clock.dateFormat = "HH:mm:ss"
  var reported: [UInt32: String] = [:]
  print("Watching every \(interval)s. Switch a monitor's input, then press Ctrl-C.")
  while true {
    var seen: Set<UInt32> = []
    for (id, controller) in ddcDisplays() {
      seen.insert(id)
      let reading = inputReading(controller)
      if reported[id] != reading {
        print("\(clock.string(from: Date()))  display \(id) (\(controller)): \(reading)")
        reported[id] = reading
      }
    }
    for id in reported.keys where !seen.contains(id) {
      print("\(clock.string(from: Date()))  display \(id): gone from the display list")
      reported[id] = nil
    }
    Thread.sleep(forTimeInterval: interval)
  }
}

func runDDC(_ args: [String]) throws {
  guard IOAVServiceDDC.available else { throw DDCError.unavailable }
  var ids = [CGDirectDisplayID](repeating: 0, count: 16)
  var count: UInt32 = 0
  CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
  let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
  let controllers = IOAVServiceDDC.controllers(forDisplays: Array(externals))
  let services = Set(IOAVServiceDDC.externalControllers())
  func controller(at position: Int) throws -> String {
    if args.count > position {
      guard let id = UInt32(args[position]), let name = controllers[id] else {
        throw LabError.message("No DDC display with ID \(args[position]).")
      }
      return name
    }
    let usable = controllers.values.filter(services.contains)
    guard usable.count == 1 else {
      throw LabError.message("Name a display ID. \(usable.count) DDC displays are connected.")
    }
    return usable[0]
  }
  switch args.first {
  case "list":
    for id in externals {
      let name = controllers[id] ?? "unmatched"
      let ddc = services.contains(name) ? "DDC service" : "no DDC service"
      print("display \(id): \(name), \(ddc)")
    }
  case "get":
    try emit(IOAVServiceDDC.channel(controller: controller(at: 1)).get(code: DDCPacket.brightness))
  case "input":
    for (id, controller) in ddcDisplays() {
      print("display \(id) (\(controller)): \(inputReading(controller))")
    }
  case "watch":
    let interval = args.count >= 2 ? Double(args[1]) ?? 2 : 2
    watchInputs(every: interval)
  case "set":
    guard args.count >= 2, let value = UInt16(args[1]) else { throw LabError.message(usage) }
    try IOAVServiceDDC.channel(controller: controller(at: 2))
      .set(code: DDCPacket.brightness, value: value)
  default:
    throw LabError.message(usage)
  }
}

func runModes(_ args: [String]) throws {
  let api = PrivateDisplayAPI()
  switch args.first {
  case nil:
    try emit(DisplayModeCatalog.externalDisplays().map { DisplayModeCatalog.report($0, api: api) })
  case "try":
    guard (3 ... 4).contains(args.count), let width = Int(args[1]), let height = Int(args[2])
    else { throw LabError.message(usage) }
    let hold = args.count == 4 ? Double(args[3]) ?? 0 : 10
    guard (3 ... 60).contains(hold) else { throw LabError.message("Hold 3 to 60 seconds.") }
    try tryModes(.init(width: width, height: height), hold: hold, api: api)
  default:
    throw LabError.message(usage)
  }
}

/// Plain, then 2x, then the original, with what macOS reports in between. Every change is
/// app only, so this process ending for any reason puts the display back.
func tryModes(_ size: ModeSize, hold: Double, api: PrivateDisplayAPI) throws {
  setvbuf(stdout, nil, _IOLBF, 0)
  let externals = DisplayModeCatalog.externalDisplays().filter { CGDisplayIsActive($0) != 0 }
  guard externals.count == 1, let display = externals.first else {
    throw LabError.message("Needs exactly one active external display, found \(externals.count).")
  }
  guard CGDisplayIsInMirrorSet(display) == 0 else {
    throw LabError.message("Display \(display) is mirrored. Turn mirroring off first.")
  }
  guard let original = CGDisplayCopyDisplayMode(display),
        let rate = DisplayModeCatalog.current(display)?.refreshRate
  else { throw LabError.message("Display \(display) has no current mode.") }
  guard let catalog = api.modes(displayID: display)?.map(DisplayModeCatalog.summary) else {
    throw LabError.message("The private mode list is unavailable on this Mac.")
  }
  guard let plain = catalog.first(where: {
    $0.usable && $0.scale == 1 && $0.size == size && $0.refreshRate == rate
  }), let sharp = SharpText.twin(of: size, refreshRate: rate, in: catalog) else {
    throw LabError.message(
      "No plain and 2x pair at \(size.width)x\(size.height) and \(rate) Hz. See `modes`."
    )
  }

  let events = DisplayEventMonitor()
  let start = ProcessInfo.processInfo.systemUptime
  func stamp() -> String {
    String(format: "+%6.2fs", ProcessInfo.processInfo.systemUptime - start)
  }
  func wait(_ seconds: Double) {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    for event in events.drain().events {
      let at = Double(event.at) / 1000 - start
      let flags = "0x" + String(event.flags, radix: 16)
      print(String(format: "  %+6.2fs  macOS: display %u, flags %@", at, event.displayID, flags))
    }
  }
  func readback(_ expected: DisplayModeSummary) -> Bool {
    guard let now = DisplayModeCatalog.current(display) else { return false }
    let pass = now.size == expected.size && now.scale == expected.scale
    print(
      "\(stamp())  now \(now.width)x\(now.height) at \(now.scale)x, \(now.refreshRate) Hz: "
        + (pass ? "PASS" : "FAIL")
    )
    return pass
  }
  func step(_ title: String, _ mode: DisplayModeSummary) throws -> Bool {
    print("\(stamp())  \(title): \(mode.width)x\(mode.height) at \(mode.scale)x, \(rate) Hz")
    try api.setMode(mode.number, displayID: display, scope: .forAppOnly)
    wait(2)
    return readback(mode)
  }

  print("Display \(display). Watch the monitor, and if it can show the input signal")
  print("resolution in its own menu, note it in both steps.")
  var passed = try step("Step 1, plain (what System Settings picks)", plain)
  if passed {
    wait(hold - 2)
    passed = try step("Step 2, 2x (what Sharp Text would pick). Did it go black?", sharp)
    if passed {
      wait(hold - 2)
    }
  }
  print("\(stamp())  Restoring the original mode")
  var transaction: CGDisplayConfigRef?
  var result = CGBeginDisplayConfiguration(&transaction)
  if result == .success {
    result = CGConfigureDisplayWithDisplayMode(transaction, display, original, nil)
    if result == .success {
      result = CGCompleteDisplayConfiguration(transaction, .forAppOnly)
    } else {
      CGCancelDisplayConfiguration(transaction)
    }
  }
  wait(2)
  let restored = readback(DisplayModeCatalog.summary(original))
  guard passed, result == .success, restored else {
    throw LabError.message("The trial did not complete. Quitting reverts anything left over.")
  }
}

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first ?? "observe" {
  case "observe":
    guard args.count <= 1 else { throw LabError.message("observe takes no options.") }
    try emit(DisplayObserver.read())
  case "ddc":
    try runDDC(Array(args.dropFirst()))
  case "modes":
    try runModes(Array(args.dropFirst()))
  case "help", "--help", "-h":
    print(usage)
  default:
    throw LabError.message(usage)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
