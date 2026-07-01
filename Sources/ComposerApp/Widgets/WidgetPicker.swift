import SwiftUI

/// The "add widget" list, shown in a popover from the toolbar. Rendered straight from
/// `WidgetRegistry.all`, so it can never drift from what's actually registered — a new widget
/// appears here automatically. v1 is a flat list; a categorized grid is a later phase.
struct WidgetPickerList: View {
  var onPick: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Add widget")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 5)

      ForEach(WidgetRegistry.all, id: \.id) { widget in
        Button { onPick(widget.id) } label: {
          HStack(spacing: 10) {
            Image(systemName: widget.symbol)
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(.primary)
              .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
              Text(widget.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
              Text(widget.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 12).padding(.vertical, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .frame(width: 264)
    .padding(.bottom, 8)
  }
}
