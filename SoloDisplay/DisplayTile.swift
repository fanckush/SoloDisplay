import SwiftUI

/// An arrangement drawn as two panels rather than named with a device icon. Windows draws its
/// own display switcher with abstract rectangles for the same reason: a laptop glyph says which
/// machine you own, not which of its screens is lit.
struct DisplayTileArt: View {
  let internalLit: Bool
  let externalLit: Bool

  var body: some View {
    HStack(alignment: .bottom, spacing: 9) {
      panel(width: 26, height: 17, standWidth: 32, lit: internalLit)
      panel(width: 34, height: 22, standWidth: 13, lit: externalLit)
    }
  }

  /// A dark screen keeps its outline rather than fading out. Structure carries the difference,
  /// so a screen that is off still reads as a screen even when the whole tile is dimmed.
  private func panel(width: CGFloat, height: CGFloat, standWidth: CGFloat, lit: Bool) -> some View {
    VStack(spacing: 1.5) {
      ZStack {
        if lit {
          RoundedRectangle(cornerRadius: 2.5)
        } else {
          RoundedRectangle(cornerRadius: 2.5)
            .strokeBorder(lineWidth: 1.3)
            .opacity(0.55)
        }
      }
      .frame(width: width, height: height)
      Capsule()
        .frame(width: standWidth, height: 2)
        .opacity(0.5)
    }
  }
}

/// One of the two arrangements. A pair of buttons rather than a Picker, because a Picker cannot
/// disable a single option, and the whole point here is explaining why one is out of reach.
struct DisplayTile: View {
  let choice: MenuPanel.Choice
  let action: (MenuAction) -> Void

  /// Chosen, but not what is on screen yet. External Only sits here whenever no monitor is
  /// plugged in: the setting is held and will apply on its own, so it is drawn as an outline
  /// rather than filled. Filled means this is what you are looking at right now.
  private var waiting: Bool {
    choice.isSelected && !choice.isActive
  }

  private var fill: AnyShapeStyle {
    if choice.isSelected, choice.isActive {
      return AnyShapeStyle(Color.accentColor)
    }
    if waiting {
      return AnyShapeStyle(Color.accentColor.opacity(0.16))
    }
    return AnyShapeStyle(.quaternary)
  }

  private var foreground: AnyShapeStyle {
    if choice.isSelected, choice.isActive {
      return AnyShapeStyle(.white)
    }
    return AnyShapeStyle(.primary)
  }

  var body: some View {
    Button {
      action(choice.action)
    } label: {
      VStack(spacing: 9) {
        DisplayTileArt(internalLit: choice.internalLit, externalLit: choice.externalLit)
          .frame(height: 26, alignment: .bottom)
        Text(choice.title).font(.system(size: 12, weight: .semibold))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The tile is focusable from MenuPanelView, not here, so the ring belongs to that level. This
    // only stops the button drawing a second one inside it.
    .focusEffectDisabled()
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(fill)
        .overlay(
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, lineWidth: waiting ? 1.5 : 0)
        )
    )
    .foregroundStyle(foreground)
    .overlay {
      if choice.isPending {
        ProgressView().controlSize(.small)
      }
    }
    // A chosen arrangement never fades, even while something blocks it. Dimming the state a
    // person is already in reads as breakage rather than as waiting.
    .opacity(choice.isEnabled || choice.isSelected ? 1 : 0.55)
    .disabled(!choice.isEnabled)
    .accessibilityLabel(choice.title)
    .accessibilityAddTraits(choice.isSelected ? [.isSelected] : [])
    .accessibilityValue(waiting ? "chosen, waiting to take effect" : "")
  }
}
