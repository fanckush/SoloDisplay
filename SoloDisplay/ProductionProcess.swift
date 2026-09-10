import Darwin
import Foundation

/// Production process roles. These are separate from the Debug-only `--lab-` commands and are
/// the only entry points a normal launch can reach.
nonisolated enum ProductionRole: Equatable {
  /// The supervising process a normal launch becomes. It never disables and owns recovery UI.
  case helper
  /// The menu-bar process the helper launches, paired to it by inherited private pipes.
  case controller
  /// A paired, one-shot process that can only enable the journaled panel for recovery.
  case recoveryWorker
  /// Explicitly unprotected: the read-only interface with display control unavailable.
  case unprotected
}

nonisolated enum ProductionLaunchError: Error, CustomStringConvertible {
  case unpairedController
  case unpairedRecoveryWorker
  case conflictingRoles
  case unknownArgument(String)
  var description: String {
    switch self {
    case .unpairedController:
      "The controller role requires the private pipes inherited from its recovery helper."
    case .unpairedRecoveryWorker:
      "The recovery-worker role requires the private pipes inherited from its recovery helper."
    case .conflictingRoles: "Only one production process role may be selected."
    case let .unknownArgument(argument): "Unrecognized argument: \(argument)."
    }
  }
}

nonisolated enum ProductionLaunch {
  static let controllerArgument = "--solodisplay-controller"
  static let recoveryWorkerArgument = "--solodisplay-recovery-worker"
  static let unprotectedArgument = "--solodisplay-unprotected"

  /// A command-line claim is never the pairing evidence. Only actual inherited pipes on the
  /// standard descriptors let a process act as the paired controller.
  static func role(arguments: [String], pipedStandardStreams: Bool) throws -> ProductionRole {
    for argument in arguments
      where argument.hasPrefix("--") && argument != controllerArgument
      && argument != recoveryWorkerArgument
      && argument != unprotectedArgument && argument != "--diagnostics" {
      throw ProductionLaunchError.unknownArgument(argument)
    }
    let selectedRoles = arguments.filter {
      $0 == controllerArgument || $0 == recoveryWorkerArgument || $0 == unprotectedArgument
    }
    guard selectedRoles.count <= 1 else { throw ProductionLaunchError.conflictingRoles }
    if arguments.contains(controllerArgument) {
      guard pipedStandardStreams else { throw ProductionLaunchError.unpairedController }
      return .controller
    }
    if arguments.contains(recoveryWorkerArgument) {
      guard pipedStandardStreams else { throw ProductionLaunchError.unpairedRecoveryWorker }
      return .recoveryWorker
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
