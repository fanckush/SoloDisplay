import LidlessCore
import LidlessPlatform
import SwiftUI

struct ContentView: View {
  let model: DiagnosticsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Display Diagnostics").font(.title).accessibilityIdentifier("diagnosticsTitle")
        Text(
          "Read-only development build. Lidless will not change displays, brightness, or mirroring."
        )
        .accessibilityIdentifier("readOnlyNotice")
        HStack {
          Label(model.headline, systemImage: "display")
          Spacer()
          Button("Refresh", action: model.refresh).accessibilityIdentifier("refreshDiagnostics")
        }
        if let reading = model.reading {
          Text(
            "Lid: \(reading.lid.rawValue) · Foreground session: \(reading.foregroundSession.rawValue)"
          )
          Text(
            "Process \(ProcessInfo.processInfo.processIdentifier) · Sample uptime \(reading.monotonicMilliseconds) ms"
          )
          .font(.caption).foregroundStyle(.secondary)
          if let error = reading.enumerationError { Text("Enumeration error: \(error)") }
          ForEach(reading.displays, id: \.id) { display in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(display.builtIn ? "Built-in" : "External") display \(display.id)").font(
                .headline)
              Text(DiagnosticPresentation.activity(active: display.active, asleep: display.asleep))
              Text(
                "\(display.width) × \(display.height) at (\(display.originX), \(display.originY)) · Mirrored: \(display.mirrored ? "yes" : "no")"
              )
              Text("Transport: \(display.transport)").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
          }
          if reading.mirroringDetected {
            Text(
              "Mirroring plus a dimmed built-in screen is a supported starting scenario for our investigation. This build preserves it untouched; off/on restoration is not yet validated."
            )
          }
        }
        Divider()
        Text("Controller safety gate").font(.headline)
        Text(
          "Shadow mode: live observations reach the state machine, but no display effects execute.")
        Text(
          "Observations: \(model.controller.observationCount) · Rejected effects: \(model.controller.rejectedEffectCount)"
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          "Control remains unavailable until recovery integration, native transport classification, and lifecycle validation are complete."
        )
        .font(.caption).foregroundStyle(.secondary)
        Divider()
        Text("Event timeline").font(.headline)
        Text(
          model.callbackRegistrationError.map { "Callback registration failed: \($0)" }
            ?? "Callback subscription: \(model.reading == nil ? "not started" : "registered")")
        Text(
          "Recent events stay in memory only. No diagnostics are saved or uploaded. Discarded entries: \(model.history.discarded). Dropped callbacks: \(model.droppedCallbacks)."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(model.history.entries.reversed()) { entry in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.milliseconds) ms · \(entry.reason)").font(
              .system(.caption, design: .monospaced))
            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 620, minHeight: 420)
  }
}
