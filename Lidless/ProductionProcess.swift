import Darwin
import Foundation

/// Production process roles. These are separate from the Debug-only `--lab-` commands and are
/// the only entry points a normal launch can reach.
nonisolated enum ProductionRole: Equatable {
  /// The supervising process a normal launch becomes. It owns no UI and never disables.
  case helper
  /// The menu-bar process the helper launches, paired to it by inherited private pipes.
  case controller
  /// Explicitly unprotected: the read-only interface with display control unavailable.
  case unprotected
}

nonisolated enum ProductionLaunchError: Error, CustomStringConvertible {
  case unpairedController
  case unknownArgument(String)
  var description: String {
    switch self {
    case .unpairedController:
      "The controller role requires the private pipes inherited from its recovery helper."
    case .unknownArgument(let argument): "Unrecognized argument: \(argument)."
    }
  }
}

nonisolated enum ProductionLaunch {
  static let controllerArgument = "--lidless-controller"
  static let unprotectedArgument = "--lidless-unprotected"

  /// A command-line claim is never the pairing evidence. Only actual inherited pipes on the
  /// standard descriptors let a process act as the paired controller.
  static func role(arguments: [String], pipedStandardStreams: Bool) throws -> ProductionRole {
    for argument in arguments
    where argument.hasPrefix("--") && argument != controllerArgument
      && argument != unprotectedArgument && argument != "--diagnostics"
    {
      throw ProductionLaunchError.unknownArgument(argument)
    }
    if arguments.contains(controllerArgument) {
      guard pipedStandardStreams else { throw ProductionLaunchError.unpairedController }
      return .controller
    }
    return arguments.contains(unprotectedArgument) ? .unprotected : .helper
  }

  static func standardStreamsArePipes() -> Bool {
    ([0, 1] as [Int32]).allSatisfy { descriptor in
      var status = stat()
      return fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFIFO
    }
  }
}
