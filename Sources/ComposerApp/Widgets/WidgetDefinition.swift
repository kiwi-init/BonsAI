import Foundation
import SwiftUI

// The widget registry contract. See docs/widgets.md for the design rationale. This file is the
// executable spec: the protocol, the type-erased registry box, and the supporting value types.
// It compiles standalone (no concrete widgets, no canvas wiring yet) so the shape can be reviewed
// before the envelope (`.widget` CardState kind) and the GitHub Actions widget land on top of it.

// MARK: - Persistence envelope

/// The opaque per-card payload the canvas persists but never parses. Config/Snapshot are JSON the
/// owning widget decodes against its own typed structs. Lives on `CardState.widget`.
struct WidgetInstance: Codable, Equatable {
  var typeID: String            // registry key, e.g. "github.actions" — persisted, never renamed
  var configVersion: Int        // schema version of `config`, for forward-compat migrations
  var config: Data              // the widget's Config, JSON-encoded
  var snapshot: Data?           // the widget's last Snapshot, cached for instant reload
  var fetchedAt: Date?
  var failureCount: Int         // drives refresh backoff
  var lastError: WidgetError?   // sanitized reason, never a raw string

  init(typeID: String, configVersion: Int, config: Data, snapshot: Data? = nil,
       fetchedAt: Date? = nil, failureCount: Int = 0, lastError: WidgetError? = nil) {
    self.typeID = typeID
    self.configVersion = configVersion
    self.config = config
    self.snapshot = snapshot
    self.fetchedAt = fetchedAt
    self.failureCount = failureCount
    self.lastError = lastError
  }
}

// MARK: - Supporting value types

/// A closed set of sanitized failure reasons. NEVER a raw error string — a raw `URLError`/`gh`
/// stderr can carry a token or Authorization header, and this value is persisted onto the board
/// and projected into the agent graph. See docs/widgets.md "Security requirements".
enum WidgetError: String, Codable, Equatable, Sendable, Error {
  case unauthorized, network, badResponse, badConfig, timeout
}

/// Render-time phase handed to `card`. DERIVED from `WidgetInstance`, never stored — `lastError`
/// on the instance is the single source of truth.
enum WidgetPhase: Equatable, Sendable {
  case loading
  case ok
  case failed(WidgetError)
}

enum WidgetCategory: String, CaseIterable, Sendable {
  case devCI
  case deploys
  case reference
}

/// v1 ships `.manual` only; `.interval` is the seam for opt-in polling in a later phase.
enum RefreshPolicy: Equatable, Sendable {
  case manual
  case interval(seconds: TimeInterval)
}

/// A problem `validate` found in a config, surfaced inline by `configForm` before any fetch.
struct ConfigIssue: Equatable, Sendable {
  var field: String
  var message: String
}

/// The impure I/O a widget's `fetch` needs, injected so tests substitute a stub and `parse` stays
/// pure. The live implementation wraps `Shell` (argv only — never string-interpolated) and
/// `URLSession`; a test transport returns canned fixtures.
protocol WidgetTransport: Sendable {
  func shell(_ argv: [String]) async throws -> String
  func get(_ url: URL, headers: [String: String]) async throws -> Data
}

// MARK: - The contract

/// A widget is a stateless *definition* of a kind of live card. The placed instance is the opaque
/// `WidgetInstance` blob on a `CardState`; this describes how to configure, fetch, render, and
/// project it. Everything specific to a data source lives in one file conforming to this.
protocol BoardWidget {
  static var id: String { get }               // "github.actions" — a WIDGET id (dotted), NOT a connector id
  static var name: String { get }
  static var summary: String { get }
  static var symbol: String { get }
  static var category: WidgetCategory { get }

  /// A `Connector.id` (starts with "@", e.g. "@github"), or nil. NOT a widget id. See docs.
  static var requiredConnector: String? { get }
  static var refresh: RefreshPolicy { get }
  static var configVersion: Int { get }

  associatedtype Config: Codable & Equatable & Sendable
  associatedtype Snapshot: Codable & Equatable & Sendable
  associatedtype Raw: Sendable

  static func defaultConfig() -> Config
  static func validate(_ config: Config) -> [ConfigIssue]

  /// Impure I/O via the injected transport. Keep logic OUT of here.
  static func fetch(_ config: Config, _ transport: WidgetTransport) async throws -> Raw
  /// Pure transform — this is what the fixture test covers.
  static func parse(_ raw: Raw) throws -> Snapshot

  /// Compact text projection threaded into `CanvasGraph` so the chat agent can read live state.
  static func agentSummary(_ config: Config, _ snapshot: Snapshot?) -> String

  associatedtype ConfigForm: View
  associatedtype Card: View
  @ViewBuilder static func configForm(_ config: Binding<Config>) -> ConfigForm
  @ViewBuilder static func card(_ config: Config, _ snapshot: Snapshot?, _ phase: WidgetPhase) -> Card
}

extension BoardWidget {
  static var refresh: RefreshPolicy { .manual }
  static var configVersion: Int { 1 }
  static var requiredConnector: String? { nil }
  static func validate(_ config: Config) -> [ConfigIssue] { [] }
}

// MARK: - Type erasure

/// The heterogeneous registry can't hold `BoardWidget` values directly (associated types), and the
/// card boundary MUST erase to `AnyView` — there's no way to render heterogeneous `Card` types
/// through one boxed call otherwise. "Typed" holds INSIDE each widget; the boundary is `AnyView`.
/// Config/Snapshot cross the boundary as `Data`, encoded/decoded inside the box.
struct AnyBoardWidget {
  let id: String
  let name: String
  let summary: String
  let symbol: String
  let category: WidgetCategory
  let requiredConnector: String?
  let refresh: RefreshPolicy
  let configVersion: Int

  private let _defaultConfig: () throws -> Data
  private let _validate: (Data) -> [ConfigIssue]
  private let _fetchParse: @Sendable (Data, any WidgetTransport) async throws -> Data
  private let _agentSummary: (Data, Data?) -> String
  private let _card: @MainActor (Data, Data?, WidgetPhase) throws -> AnyView
  private let _configForm: @MainActor (Binding<Data>) -> AnyView

  init<W: BoardWidget>(_ type: W.Type) {
    id = W.id
    name = W.name
    summary = W.summary
    symbol = W.symbol
    category = W.category
    requiredConnector = W.requiredConnector
    refresh = W.refresh
    configVersion = W.configVersion

    _defaultConfig = { try JSONEncoder().encode(W.defaultConfig()) }
    _validate = { data in
      guard let config = try? JSONDecoder().decode(W.Config.self, from: data) else {
        return [ConfigIssue(field: "config", message: "couldn't read settings")]
      }
      return W.validate(config)
    }
    _fetchParse = { data, transport in
      let config = try JSONDecoder().decode(W.Config.self, from: data)
      let raw = try await W.fetch(config, transport)
      return try JSONEncoder().encode(W.parse(raw))
    }
    _agentSummary = { configData, snapshotData in
      guard let config = try? JSONDecoder().decode(W.Config.self, from: configData) else { return "" }
      let snapshot = snapshotData.flatMap { try? JSONDecoder().decode(W.Snapshot.self, from: $0) }
      return W.agentSummary(config, snapshot)
    }
    _card = { configData, snapshotData, phase in
      let config = try JSONDecoder().decode(W.Config.self, from: configData)
      let snapshot = try snapshotData.map { try JSONDecoder().decode(W.Snapshot.self, from: $0) }
      return AnyView(W.card(config, snapshot, phase))
    }
    _configForm = { dataBinding in
      // Bridge the opaque Data binding to a typed Config binding: decode on read (falling back to
      // defaults if an old blob can't decode — see docs "Config evolution"), re-encode on write.
      let configBinding = Binding<W.Config>(
        get: { (try? JSONDecoder().decode(W.Config.self, from: dataBinding.wrappedValue)) ?? W.defaultConfig() },
        set: { newValue in if let encoded = try? JSONEncoder().encode(newValue) { dataBinding.wrappedValue = encoded } }
      )
      return AnyView(W.configForm(configBinding))
    }
  }

  func defaultConfig() throws -> Data { try _defaultConfig() }
  func validate(_ config: Data) -> [ConfigIssue] { _validate(config) }
  /// The `@Sendable` fetch+parse closure, exposed so a refresh can run it in a detached task
  /// without capturing the (non-Sendable) box itself.
  var fetchParse: @Sendable (Data, any WidgetTransport) async throws -> Data { _fetchParse }
  func fetchAndParse(_ config: Data, _ transport: any WidgetTransport) async throws -> Data {
    try await _fetchParse(config, transport)
  }
  func agentSummary(_ config: Data, _ snapshot: Data?) -> String { _agentSummary(config, snapshot) }
  @MainActor func card(_ config: Data, _ snapshot: Data?, _ phase: WidgetPhase) throws -> AnyView {
    try _card(config, snapshot, phase)
  }
  @MainActor func configForm(_ config: Binding<Data>) -> AnyView { _configForm(config) }
}

/// A short "4m" / "1h" / "2d" label for how long ago `date` was. Used by widget cards (run times)
/// and the host chrome (last-refreshed). Reads the current clock, so it refreshes on redraw.
func widgetRelativeLabel(_ date: Date, now: Date = Date()) -> String {
  let seconds = max(0, now.timeIntervalSince(date))
  if seconds < 60 { return "\(Int(seconds))s" }
  if seconds < 3600 { return "\(Int(seconds / 60))m" }
  if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
  return "\(Int(seconds / 86_400))d"
}

// MARK: - Registry

/// The single source of truth for what widgets exist. The add-widget picker renders from this, so
/// it can't drift. A new widget is one line here plus its own file.
enum WidgetRegistry {
  static let all: [AnyBoardWidget] = [
    AnyBoardWidget(GitHubActionsWidget.self),
  ]

  static func widget(id: String) -> AnyBoardWidget? { all.first { $0.id == id } }
}
