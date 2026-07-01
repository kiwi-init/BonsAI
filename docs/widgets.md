# Board widgets: a typed registry for live cards

> A **widget** is a small, typed, self-refreshing view of an external system,
> pinned to the board. A text card holds a thought; a widget holds *live state* —
> a CI run, a deploy, an open-PR count — that updates itself so you never tab away
> to check it. This document is the design of the widget registry: the contract a
> widget conforms to, how one is added, and where the abstraction boundary honestly
> is.

**Status:** design spec, revised after an adversarial review (two Codex agents +
two reviewers) that stress-tested the first draft. Two claims from that draft were
wrong and are corrected here: "views stay typed, not `AnyView`" (the registry
boundary *must* erase to `AnyView`) and "zero canvas/persistence/MCP changes —
ever" (widget #2 is zero-canvas **only after** widget #1 pays a real, enumerated
one-time tax, and agent-visibility needs a one-time schema addition). The envelope
insight survives; the "changes nothing" framing did not.

---

## Scope: what v1 is, and what it defers

Review flagged that a polling refresh engine plus a monitoring-widget store leans
toward the "heavier, do-it-all app" that [CONTRIBUTING](../CONTRIBUTING.md)
explicitly rejects, and away from "fast and quiet." To stay on-mission, the design
is **phased**. The registry is built to grow into the full vision; v1 ships the
smallest slice that earns it.

| | v1 (build now) | Later (when a third mission-aligned widget exists) |
| --- | --- | --- |
| Envelope (`.widget` kind + `WidgetInstance`) | ✅ | |
| `BoardWidget` protocol + registry | ✅ | |
| Widgets shipped | **GitHub Actions** only (Clock as a test fixture) | Vercel deploys, more |
| Refresh | **manual + on board-open** (`.manual`) | opt-in `.interval` polling |
| Store UI | a simple "add widget" picker | the categorized store grid |
| Monitoring widgets (uptime, SSL, RSS, DB health) | **cut** — these are a dashboard you *watch*, not a thought you *route to an agent*; by CONTRIBUTING's own Obsidian logic they don't belong | reconsider case-by-case |

The bar for a widget is the connector bar: it must inject *live context an agent
will act on*, not turn the board into Datadog. GitHub CI passes (the thought is
"the deploy is red — fix it," and the agent reads the board). An SSL-expiry monitor
does not.

The **connector refactor** ([connectors.md](connectors.md)) is independently good
and should land first regardless of widget phasing — widgets depend on it for auth.

---

## Why a registry (the envelope insight)

Building the CI-status prototype as its own `CanvasElementKind` (`.ciStatus`)
touched **seven files**. That's the tax the envelope removes: the canvas learns
about widgets **once** — a single `.widget` kind carrying an *opaque* payload — and
a new *widget* (not a new kind) adds no canvas code after that. The one-time cost of
teaching the canvas about `.widget` is real and enumerated in
[The one-time canvas tax](#the-one-time-canvas-tax); it is not zero, but it is paid
once.

Two facts to anchor on:

1. **The board holds opaque blobs; the widget holds the types.** `CardState`
   stores a widget's config and last snapshot as JSON it never parses. The widget
   owns the `Codable` `Config` and `Snapshot`. Contributors get type-safety; the
   canvas stays widget-agnostic.
2. **A widget reuses the connector registry for auth — it never rolls its own.**
   A GitHub widget declares `requiredConnector = "@github"` and the existing
   [connector](connectors.md) secret store handles the token.

---

## The envelope: one card kind

`CardState` gains one optional field (nil on every legacy board and non-widget
card):

```swift
struct WidgetInstance: Codable, Equatable {
  var typeID: String          // registry key, e.g. "github.actions" — persisted, never renamed
  var configVersion: Int      // schema version of `config` (see Config evolution)
  var config: Data            // the widget's Config, JSON-encoded (opaque to the canvas)
  var snapshot: Data?         // the widget's last Snapshot, cached so reload is instant
  var fetchedAt: Date?
  var failureCount: Int       // drives backoff
  var lastError: WidgetError? // SANITIZED reason, never a raw string (see Security)
}

// A closed set of reasons — never a raw error string, which can carry a token or
// an Authorization header into the persisted board and the agent graph.
enum WidgetError: String, Codable { case unauthorized, network, badResponse, badConfig, timeout }

// In CardState, added once:
var widget: WidgetInstance?
```

`config` and `snapshot` are `Data`, not `[String: Any]`, so the canvas can't peek.
Only the widget that wrote them decodes them, against its own compile-checked types.

---

## The contract: `BoardWidget`

```swift
protocol BoardWidget {
  // Identity (shown in the picker/store)
  static var id: String { get }               // "github.actions" — a WIDGET id (dotted), NOT a connector id
  static var name: String { get }
  static var summary: String { get }
  static var symbol: String { get }
  static var category: WidgetCategory { get }

  // Auth — nil, or a Connector.id (starts with "@"). See the id-namespace note.
  static var requiredConnector: String? { get }

  static var refresh: RefreshPolicy { get }
  static var configVersion: Int { get }        // bump when Config's shape changes

  associatedtype Config: Codable & Equatable & Sendable
  associatedtype Snapshot: Codable & Equatable & Sendable   // Equatable: skip no-op redraws
  associatedtype Raw: Sendable                               // transport output, before parsing

  static func defaultConfig() -> Config
  static func validate(_ config: Config) -> [ConfigIssue]    // default []; surfaced inline by configForm

  // The data source, split for testability (see Testing):
  //  • transport does the impure I/O (Shell/URLSession) and is INJECTED so tests stub it
  //  • parse is a PURE function — this is what the fixture test actually covers
  static func fetch(_ config: Config, _ transport: WidgetTransport) async throws -> Raw
  static func parse(_ raw: Raw) throws -> Snapshot

  // Agent visibility — a compact text projection threaded into CanvasGraph once.
  static func agentSummary(_ config: Config, _ snapshot: Snapshot?) -> String

  // SwiftUI surfaces. Typed inside the widget; erased to AnyView at the registry boundary.
  associatedtype ConfigForm: View
  associatedtype Card: View
  @ViewBuilder static func configForm(_ config: Binding<Config>) -> ConfigForm
  @ViewBuilder static func card(_ config: Config, _ snapshot: Snapshot?, _ phase: WidgetPhase) -> Card
}

enum WidgetCategory: String, CaseIterable, Sendable { case devCI, deploys, reference }
enum RefreshPolicy: Equatable, Sendable { case manual; case interval(seconds: TimeInterval) }  // v1: .manual only
enum WidgetPhase: Equatable, Sendable { case loading; case ok; case failed(WidgetError) }
```

`WidgetPhase` is **derived, never stored** — the refresh controller computes it from
`WidgetInstance` (`lastError != nil → .failed`, else `snapshot == nil → .loading`,
else `.ok`) and hands it to `card`. `lastError` on the instance is the single source
of truth; `WidgetPhase` is a render-time view of it.

The four things a contributor writes: two `Codable` structs (`Config`, `Snapshot`),
a pure `parse`, and two SwiftUI views. `fetch` is a thin, injected-transport seam;
`parse` is where the bugs (and the tests) live.

---

## The registry (erasure returns `AnyView` — by necessity)

Associated-type protocols can't go in an array, and — corrected from the first
draft — the erased box **must return `AnyView`**: there is no way to render
heterogeneous widget `Card` types through one boxed call without erasing the view.
"Typed" holds *inside* each widget; the boundary is `AnyView`.

```swift
struct AnyBoardWidget {
  let id: String
  let requiredConnector: String?
  let refresh: RefreshPolicy
  private let _defaultConfig: @Sendable () throws -> Data
  private let _fetchParse: @Sendable (Data, WidgetTransport) async throws -> Data   // decode→fetch→parse→encode
  private let _agentSummary: @Sendable (Data, Data?) -> String
  private let _card: @MainActor (Data, Data?, WidgetPhase) throws -> AnyView        // decode→AnyView(card)

  init<W: BoardWidget>(_ t: W.Type) {
    id = W.id; requiredConnector = W.requiredConnector; refresh = W.refresh
    _defaultConfig = { try JSONEncoder().encode(W.defaultConfig()) }
    _fetchParse = { data, transport in
      let cfg = try JSONDecoder().decode(W.Config.self, from: data)
      return try JSONEncoder().encode(W.parse(W.fetch(cfg, transport)))
    }
    _agentSummary = { c, s in
      let cfg = try? JSONDecoder().decode(W.Config.self, from: c)
      let snap = s.flatMap { try? JSONDecoder().decode(W.Snapshot.self, from: $0) }
      return cfg.map { W.agentSummary($0, snap) } ?? ""
    }
    _card = { c, s, phase in
      let cfg = try JSONDecoder().decode(W.Config.self, from: c)
      let snap = try s.map { try JSONDecoder().decode(W.Snapshot.self, from: $0) }
      return AnyView(W.card(cfg, snap, phase))
    }
  }
}

enum WidgetRegistry {
  static let all: [AnyBoardWidget] = [
    AnyBoardWidget(GitHubActionsWidget.self),
    AnyBoardWidget(ClockWidget.self),   // test/reference fixture only — not a shipped store tile
  ]
  static func widget(id: String) -> AnyBoardWidget? { all.first { $0.id == id } }
}
```

---

## The one-time canvas tax

Honest accounting of what teaching the canvas about `.widget` costs — paid **once**,
by the envelope, not per widget:

- **Exhaustive `switch`es** gain a `.widget` case: `CardState.minimumSize`
  ([`CardState.swift:117`](../Sources/ComposerApp/Support/CardState.swift)),
  `BoardViewModel.addElement` size + points
  ([`BoardViewModel.swift:339,347`](../Sources/ComposerApp/Views/BoardViewModel.swift)),
  `BoardViewModel.isLayoutNode`
  ([`:701`](../Sources/ComposerApp/Views/BoardViewModel.swift)), and
  `CanvasElementContent`
  ([`BoardCardView.swift:364`](../Sources/ComposerApp/Views/BoardCardView.swift)).
  The compiler enumerates these for you.
- **Non-exhaustive admission paths need policy.** `add_shape` would happily parse
  `"widget"` as a shape kind
  ([`CanvasBridge.swift:69`](../Sources/ComposerApp/Services/CanvasBridge.swift)) and
  `addDrawnElement`
  ([`BoardViewModel.swift:381`](../Sources/ComposerApp/Views/BoardViewModel.swift))
  would let it through. Restrict both to real shapes; add a dedicated
  `addWidget(typeID:config:)` and a `report`-style API for the refresh controller.
- **Agent visibility is a schema change, not a free pass-through.** `CanvasGraph.Node`
  ([`CanvasGraph.swift:7`](../Sources/ComposerApp/Support/CanvasGraph.swift)) carries
  only kind/text/geometry; `CanvasBridge.snapshot()`
  ([`:18`](../Sources/ComposerApp/Services/CanvasBridge.swift)) emits only those, and
  `CanvasMCP.get_canvas` re-encodes them. For the agent to *see* live widget state,
  thread `typeID` + `agentSummary` into `CanvasGraph.Node` **once** (exactly as the
  `ci` field had to be threaded). The first draft's "no MCP changes ever" was wrong;
  it's "one schema addition, then free."
- **Widget cards are not passive boxes for free.** Non-text double-click opens the
  shape-label editor
  ([`BoardCardView.swift:131,158`](../Sources/ComposerApp/Views/BoardCardView.swift))
  and rendered content disables hit-testing
  ([`:126`](../Sources/ComposerApp/Views/BoardCardView.swift)). v1 rule: **widgets are
  passive** — double-click routes to the config form (not the label editor), and the
  card takes no interactive controls. Interactive widgets are out of scope until the
  routing + selective hit-testing is designed.

After all of that lands once, widget #2 adds **none** of it.

---

## The refresh engine

A single `@MainActor` `WidgetRefreshController`. On board-open (v1) or a coarse tick
(when `.interval` ships), for each due `.widget` card:

- **Runs `fetch` off the main actor for real.** `async` ≠ background — a `@MainActor`
  caller can run pre-suspension work on main. Fetch closures are `@Sendable` and run
  in `Task.detached`; the result is written back via
  `await MainActor.run { board.setWidgetSnapshot(id, …) }`.
- **Writes snapshots without touching undo.** Background refresh must not litter the
  undo stack (which snapshots whole cards,
  [`BoardViewModel.swift:263`](../Sources/ComposerApp/Views/BoardViewModel.swift)) or
  the edit-history titles. `setWidgetSnapshot(…, registersUndo: false)`, and widget
  cards project a generic title/plain-text (from `agentSummary`) wherever `card.text`
  is used for history/compile/copy.
- **Skips unauthenticated widgets.** If `requiredConnector` has no token, the card
  shows a "connect in Settings" state and `fetch` is never called.
- **Backs off concretely.** On failure, `failureCount++` and the next attempt is
  `min(base · 2^failureCount, cap)`; reset to 0 on success. `.manual` widgets are
  skipped by the tick entirely and refresh only on user action.
- **Cached-first paint.** The last `snapshot` renders instantly on board load.

---

## Config evolution (forward-compatible or broken)

A card holds a `config` blob written by a possibly-older app version. If a widget
adds or renames a `Config` field, `JSONDecoder().decode(Config.self)` throws and the
card is bricked. Rules:

- **Every new `Config` field is optional or defaulted** — use `decodeIfPresent`;
  never add a non-optional field without a fallback.
- **Decode failure is recoverable, not fatal.** The registry decodes with `try?` and
  falls back to `defaultConfig()` merged with whatever parsed, surfacing
  `lastError = .badConfig` ("re-check settings") rather than dropping the card.
- **`configVersion`** on both the widget and the instance enables real migrations
  later.
- This is **not** caught by a `Config` round-trip test — the checklist requires an
  explicit "decode an old-shape blob → current `Config`" fixture test.

---

## Auth: borrowed from the connector registry

A widget declares `requiredConnector: String?` and gets the token, the "needs a
token" state, and the Settings field for free — from the
[connector registry](connectors.md). **Id-namespace warning (a day-one trap):**
`requiredConnector` is a **`Connector.id`** — it starts with `@` (e.g. `"@github"`),
**not** a widget id. `"github"` and `"github.actions"` are both wrong and fail
*silently* (no token, never fetches), not at compile time. The
[registry-consistency test](#testing) fails the build if a `requiredConnector`
doesn't name a real connector — that's the guardrail.

Because `MentionCatalog.apps` derives from `ContextConnector`s only, an auth-only
`@vercel` connector can exist purely to hold a widget's token without appearing as a
dead @-mention tile — see [connectors.md](connectors.md#modular-capabilities).

---

## The add-widget picker

A toolbar action — a sibling of *Describe Board* / *Copy Board*, **not** a draw tool
— opens the picker, rendered from `WidgetRegistry.all` so it can't drift from what's
registered. v1 is a simple list; the categorized store grid is a later phase. Flow:
pick → the widget's `configForm` collects `Config` (with `validate` surfacing bad
input inline) → a `.widget` card is placed and refreshes immediately.

This is a pure toolbar/sheet addition and **must not** touch the board + dock +
toolbar composition [CLAUDE.md](../CLAUDE.md) protects.

---

## Security requirements (mandatory before implementation)

The pitch — "submit a PR to add a widget" — means a widget ships arbitrary `fetch`
code that runs on a schedule with network access and the user's tokens. That is a
real attack surface. These are requirements, not suggestions:

1. **Sanitized errors only.** `lastError` is the `WidgetError` enum, never a raw
   string. A raw `URLError`/`gh` stderr can carry a token or `Authorization` header,
   and `lastError` is persisted to the board **and** projected to the agent graph.
   Test: inject a token into a failing fetch; assert it appears in neither the
   persisted JSON nor the `CanvasGraph`.
2. **No shell string-interpolation; validate config.** `GitHubActionsWidget` shells
   `gh` — use argv arrays, never interpolate config into a shell string. Validate
   `repo` against `^[\w.-]+/[\w.-]+$` and `branch` against a ref-safe charset. Test:
   `repo = "a/b; rm -rf ~"` is rejected, not executed.
3. **SSRF allowlist for any user-URL widget.** If a widget ever fetches a
   user-supplied URL, block RFC1918 / loopback / link-local / `169.254.169.254` /
   redirect-to-private *before* the request. (v1 cuts URL-fetch widgets, which
   removes most of this risk — see Scope.)
4. **Community widgets are a code-execution review.** A widget PR grants network +
   `Shell` + token access; document that review audits egress and secret use, and
   that no unreviewed widget auto-loads.
5. **Respect "fast and quiet."** Even when `.interval` ships, polling pauses when the
   board is hidden/backgrounded, caps concurrent fetches, and hard-timeouts each.
   Test: a backgrounded board issues zero network calls.

---

## Adding a widget

Zero **canvas / persistence / MCP** changes (those were paid once by the envelope) —
but honestly it's **one widget file + one registry line + one test file**, not "one
line":

1. **New file** `Sources/ComposerApp/Widgets/<Name>Widget.swift` conforming to
   `BoardWidget`.
2. **Define `Config` and `Snapshot`** (`Codable`; `Config` fields optional/defaulted
   for forward-compat; `Snapshot: Equatable`).
3. **Implement `fetch(_,transport)` + pure `parse(_)`** — I/O in `fetch` via the
   injected transport; data-shape logic in `parse`. Read secrets via
   `ConnectorSecretStore.token(for:)`; validate config; throw sanitized errors.
4. **Implement `agentSummary`, `configForm`, `card`** — match the quiet glass card
   language (status icon + colored badge).
5. **Declare `requiredConnector`** (a `@`-prefixed connector id) if it needs a secret.
6. **Register one line** in `WidgetRegistry.all`.
7. **Add tests** (below).

A widget that needs more than this — a new canvas kind, interactive controls, a
bespoke Settings tab — doesn't fit the envelope. Open an issue first.

---

## The seed widgets

- **`GitHubActionsWidget`** — the shipped v1 widget and the CI-prototype's successor.
  `Config = { repo, branch }`, `Snapshot = { runs: [Run] }`; `fetch` shells
  `gh run list` (argv, validated); the prototype's `CIRunCardView` pattern becomes
  its `card`. The prototype never shipped, so retiring its `.ciStatus` kind /
  `report_ci_run` op carries no migration burden.
- **`GitHubOpenPRsWidget`** *(canonical reference)* — the "copy this first" example,
  because it exercises the parts that matter: `requiredConnector`, one authed HTTP
  GET, a thrown → sanitized error, and cached-first paint. `Config = { repo }`,
  `Snapshot = { count }`.
- **`ClockWidget`** — the *degenerate* example: no auth, no network, `Snapshot` is a
  formatted time. Useful as the smallest mechanical fixture and a refresh-timing test
  case — **not** a shipped tile and **not** the reference to copy (it exercises none
  of the auth/error/async surface real widgets have).

---

## Testing

- **`parse` against a fixture** — the high-value test; `parse` is pure, so a captured
  `Raw` (e.g. `gh` JSON) → expected `Snapshot` needs no app, no network, no shell.
- **Config forward-compat** — decode an old-shape config blob into the current
  `Config`; assert it recovers to defaults rather than throwing.
- **`Config`/`Snapshot` codecs** — round-trip.
- **Security** — token-never-in-error (req. 1) and config-injection-rejected (req. 2)
  are tests, not prose.
- **Registry invariants** — unique stable `id`; non-empty `name`/`symbol`; every
  `requiredConnector` names a real connector (the *same* consistency test in
  [connectors.md](connectors.md#testing), covering both registries).

---

## Open questions

- **Interactive widgets** — v1 widgets are passive (config-form editing only). Live
  controls need selective hit-testing + edit routing; deferred.
- **`.interval` polling** — deferred past v1 to protect "fast and quiet"; the
  `RefreshPolicy` enum is the seam.
- **A typed `ConnectorID`** instead of a bare `String` for `requiredConnector` —
  would turn the id-namespace trap into a compile error; worth it if the connector
  refactor introduces the type.

---

## See also

- [connectors.md](connectors.md) — the connector registry refactor this depends on
  for auth; land it first.
- [canvas-agent.md](canvas-agent.md) — the `CanvasGraph` model `agentSummary`
  projects into.
- [CONTRIBUTING](../CONTRIBUTING.md) — the friction-vs-bloat bar every widget faces.
