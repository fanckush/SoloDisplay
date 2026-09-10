import SoloDisplayCore
import SoloDisplayPlatform
import SwiftUI

struct ContentView: View {
  let model: DiagnosticsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Display Diagnostics").font(.title).accessibilityIdentifier("diagnosticsTitle")
        Text(
          "Read-only development build. SoloDisplay will not change displays, brightness, or mirroring."
        )
        .accessibilityIdentifier("readOnlyNotice")
        // Kept near the top so it is on screen without scrolling, for UI automation.
        Text("Manual refreshes: \(model.manualRefreshes)")
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("manualRefreshCount")
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
          if let error = reading.enumerationError {
            Text("Enumeration error: \(error)")
          }
          ForEach(reading.displays, id: \.id) { display in
            VStack(alignment: .leading, spacing: 4) {
              Text("\(display.builtIn ? "Built-in" : "External") display \(display.id)").font(
                .headline
              )
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
              "Mirroring is supported when the internal panel follows one present external source. This window changes nothing either way."
            )
          }
        }
        Divider()
        Text("Controller safety gate").font(.headline)
        Text(
          "Shadow mode: live observations reach the state machine, but no display effects execute."
        )
        Text(
          "Observations: \(model.controller.observationCount) · Rejected effects: \(model.controller.rejectedEffectCount)"
        )
        .font(.caption).foregroundStyle(.secondary)
        Text(
          "This window is a read-only observer. The menu bar controls are what change displays."
        )
        .font(.caption).foregroundStyle(.secondary)
        Divider()
        Text("Event timeline").font(.headline)
        Text(
          model.callbackRegistrationError.map { "Callback registration failed: \($0)" }
            ?? "Callback subscription: \(model.reading == nil ? "not started" : "registered")"
        )
        Text(
          "This timeline stays in memory. Sparse operational events use macOS system logging. No uploads. Discarded entries: \(model.history.discarded). Dropped callbacks: \(model.droppedCallbacks)."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(model.history.entries.reversed()) { entry in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.milliseconds) ms · \(entry.reason)").font(
              .system(.caption, design: .monospaced)
            )
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
