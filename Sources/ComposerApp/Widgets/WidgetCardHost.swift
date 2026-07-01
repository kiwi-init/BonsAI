import SwiftUI

/// Renders a `.widget` card generically: looks the definition up in the registry, derives the
/// render phase from the persisted instance, and calls the widget's erased `card`. Envelope
/// infrastructure — it knows nothing about GitHub or any specific widget, so a new widget adds no
/// code here. v1 widgets are passive (no in-card controls); interactive chrome like manual refresh
/// is a BoardCardView overlay, so the card content can stay hit-disabled like every other element.
struct WidgetCardHost: View {
  let instance: WidgetInstance
  var zoom: CGFloat = 1

  private var phase: WidgetPhase {
    if let error = instance.lastError { return .failed(error) }
    return instance.snapshot == nil ? .loading : .ok
  }

  var body: some View {
    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var content: some View {
    if let def = WidgetRegistry.widget(id: instance.typeID),
       let rendered = try? def.card(instance.config, instance.snapshot, phase) {
      rendered
    } else {
      WidgetUnknownCard(typeID: instance.typeID)
    }
  }
}

/// Shown when a persisted card names a widget type that isn't in the registry (e.g. a board made by
/// a newer build, or a removed widget) — degrade to a labeled placeholder, never a blank tile.
private struct WidgetUnknownCard: View {
  let typeID: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Image(systemName: "puzzlepiece.extension")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.5))
      Text("Unknown widget").font(.callout.weight(.medium)).foregroundStyle(Color.white.opacity(0.85))
      Text(typeID).font(.caption.monospaced()).foregroundStyle(Color.white.opacity(0.5))
    }
    .padding(14)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.black.opacity(0.30))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)))
  }
}
