import SwiftUI

// The GitHub Actions widget's two surfaces: the pinned card and the config form. Kept in their own
// file so the widget's logic (fetch/parse) stays readable. Colors are tuned locally rather than via
// Theme.Palette so the widget is self-contained.

private enum GHColor {
  static let green = Color(red: 0.37, green: 0.76, blue: 0.50)
  static let red = Color(red: 0.89, green: 0.34, blue: 0.29)
  static let blue = Color(red: 0.29, green: 0.62, blue: 1.0)
  static let amber = Color(red: 0.79, green: 0.64, blue: 0.29)
  static let neutral = Color.white.opacity(0.28)
}

// MARK: - Card

struct GitHubActionsCard: View {
  let config: GitHubActionsWidget.Config
  let snapshot: GitHubActionsWidget.Snapshot?
  let phase: WidgetPhase
  var zoom: CGFloat = 1

  private var runs: [GitHubActionsWidget.Run] { snapshot?.runs ?? [] }

  /// Failure-priority so a red run is never hidden behind a running one: red > blue > green.
  private var borderTint: Color {
    if case .failed(.unauthorized) = phase { return GHColor.neutral }
    guard !runs.isEmpty else { return GHColor.neutral }
    if runs.contains(where: { $0.conclusion == "failure" }) { return GHColor.red }
    if runs.contains(where: { $0.status == "in_progress" }) { return GHColor.blue }
    if runs.allSatisfy({ $0.conclusion == "success" }) { return GHColor.green }
    return GHColor.neutral
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9 * zoom) {
      header
      body(for: phase)
      Spacer(minLength: 0)
    }
    .padding(14 * zoom)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.black.opacity(0.30))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(borderTint.opacity(0.5), lineWidth: 1.2)))
    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
  }

  private var header: some View {
    HStack(spacing: 7 * zoom) {
      Image(systemName: "chevron.left.forwardslash.chevron.right")
        .font(.system(size: 12 * zoom, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.62))
      Text(config.repo.isEmpty ? "owner/name" : config.repo)
        .font(.system(size: 12 * zoom, weight: .semibold).monospaced())
        .foregroundStyle(Color.white.opacity(config.repo.isEmpty ? 0.4 : 0.92))
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 48 * zoom)   // clear space for the host's refresh/updated chrome
    }
  }

  @ViewBuilder
  private func body(for phase: WidgetPhase) -> some View {
    if case .failed(.unauthorized) = phase {
      authState
    } else if !runs.isEmpty {
      VStack(alignment: .leading, spacing: 8 * zoom) {
        branchRow
        VStack(alignment: .leading, spacing: 7 * zoom) {
          ForEach(Array(runs.enumerated()), id: \.offset) { _, run in runRow(run) }
        }
        if case .failed = phase { stalNotice }
      }
    } else if phase == .loading {
      infoRow(icon: "arrow.triangle.2.circlepath", tint: GHColor.blue, text: "Loading runs\u{2026}")
    } else if case .failed = phase {
      infoRow(icon: "exclamationmark.triangle", tint: GHColor.amber, text: "Couldn't load runs")
    } else {
      infoRow(icon: "tray", tint: GHColor.neutral, text: "No runs yet")
    }
  }

  private var branchRow: some View {
    HStack(spacing: 6 * zoom) {
      Text(config.branch?.isEmpty == false ? config.branch! : "all branches")
        .font(.system(size: 10 * zoom, weight: .medium).monospaced())
        .foregroundStyle(Color.white.opacity(0.62))
        .padding(.horizontal, 7 * zoom).padding(.vertical, 2 * zoom)
        .background(Capsule().fill(Color.white.opacity(0.10)))
      Spacer(minLength: 0)
    }
  }

  private func runRow(_ run: GitHubActionsWidget.Run) -> some View {
    HStack(spacing: 8 * zoom) {
      Image(systemName: symbol(for: run))
        .font(.system(size: 13 * zoom, weight: .semibold))
        .foregroundStyle(tint(for: run))
        .frame(width: 15 * zoom)
      Text(run.workflow)
        .font(.system(size: 12 * zoom))
        .foregroundStyle(Color.white.opacity(0.88))
        .lineLimit(1)
      Spacer(minLength: 6 * zoom)
      Text(detail(for: run))
        .font(.system(size: 10.5 * zoom, weight: .medium).monospaced())
        .foregroundStyle(run.status == "in_progress" ? GHColor.blue : Color.white.opacity(0.46))
        .lineLimit(1)
    }
  }

  private var authState: some View {
    VStack(alignment: .leading, spacing: 6 * zoom) {
      Image(systemName: "lock")
        .font(.system(size: 16 * zoom, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.55))
      Text("GitHub CLI not signed in")
        .font(.system(size: 12 * zoom, weight: .medium))
        .foregroundStyle(Color.white.opacity(0.85))
      Text("Run `gh auth login` in your terminal")
        .font(.system(size: 10.5 * zoom).monospaced())
        .foregroundStyle(Color.white.opacity(0.5))
    }
    .padding(.top, 2 * zoom)
  }

  private var stalNotice: some View {
    HStack(spacing: 6 * zoom) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 10 * zoom, weight: .semibold))
        .foregroundStyle(GHColor.amber)
      Text("Couldn't refresh · showing last known")
        .font(.system(size: 10 * zoom))
        .foregroundStyle(GHColor.amber.opacity(0.85))
    }
    .padding(.top, 1 * zoom)
  }

  private func infoRow(icon: String, tint: Color, text: String) -> some View {
    HStack(spacing: 7 * zoom) {
      Image(systemName: icon)
        .font(.system(size: 12 * zoom, weight: .medium))
        .foregroundStyle(tint == GHColor.neutral ? Color.white.opacity(0.5) : tint)
      Text(text)
        .font(.system(size: 12 * zoom))
        .foregroundStyle(Color.white.opacity(0.7))
    }
    .padding(.top, 2 * zoom)
  }

  // MARK: Per-run visuals

  private func symbol(for run: GitHubActionsWidget.Run) -> String {
    switch (run.status, run.conclusion) {
    case ("completed", "success"): return "checkmark.circle.fill"
    case ("completed", "failure"): return "xmark.circle.fill"
    case ("completed", "cancelled"): return "minus.circle.fill"
    case ("completed", "skipped"), ("completed", "neutral"): return "forward.fill"
    case ("completed", _): return "questionmark.circle.fill"
    case ("in_progress", _): return "arrow.triangle.2.circlepath"
    default: return "clock"
    }
  }

  private func tint(for run: GitHubActionsWidget.Run) -> Color {
    switch (run.status, run.conclusion) {
    case ("completed", "success"): return GHColor.green
    case ("completed", "failure"): return GHColor.red
    case ("in_progress", _): return GHColor.blue
    default: return Color.white.opacity(0.5)
    }
  }

  private func detail(for run: GitHubActionsWidget.Run) -> String {
    if run.status == "in_progress" { return "running" }
    if run.status == "queued" { return "queued" }
    return "#\(run.number) · \(widgetRelativeLabel(run.startedAt))"
  }
}

// MARK: - Config form

struct GitHubActionsConfigForm: View {
  @Binding var config: GitHubActionsWidget.Config
  @State private var branchText: String = ""
  @FocusState private var repoFocused: Bool

  private var issues: [ConfigIssue] { GitHubActionsWidget.validate(config) }
  private func issue(_ field: String) -> String? { issues.first { $0.field == field }?.message }

  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      Text("GITHUB ACTIONS")
        .font(.system(size: 10, weight: .bold)).tracking(0.6)
        .foregroundStyle(Color.white.opacity(0.4))

      field(caption: "REPOSITORY", placeholder: "owner/name",
            text: $config.repo, mono: true, issue: issue("repo"))
        .focused($repoFocused)

      field(caption: "BRANCH · optional", placeholder: "all branches",
            text: $branchText, mono: true, issue: issue("branch"))
        .onChange(of: branchText) { _, new in
          let trimmed = new.trimmingCharacters(in: .whitespaces)
          config.branch = trimmed.isEmpty ? nil : trimmed
        }

      Text("Uses the `gh` CLI's sign-in — no token needed.")
        .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.4))
    }
    .onAppear {
      branchText = config.branch ?? ""
      DispatchQueue.main.async { repoFocused = true }
    }
  }

  private func field(caption: String, placeholder: String,
                     text: Binding<String>, mono: Bool, issue: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(caption.uppercased())
        .font(.system(size: 9, weight: .bold)).tracking(0.4)
        .foregroundStyle(Color.white.opacity(0.38))
      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
      if let issue {
        Text(issue).font(.system(size: 10)).foregroundStyle(GHColor.amber)
      }
    }
  }
}
