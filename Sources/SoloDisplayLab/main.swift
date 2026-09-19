import CoreGraphics
import Foundation
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

do {
  let args = Array(CommandLine.arguments.dropFirst())
  switch args.first ?? "observe" {
  case "observe":
    guard args.count <= 1 else { throw LabError.message("observe takes no options.") }
    try emit(DisplayObserver.read())
  case "ddc":
    try runDDC(Array(args.dropFirst()))
  case "help", "--help", "-h":
    print(usage)
  default:
    throw LabError.message(usage)
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
