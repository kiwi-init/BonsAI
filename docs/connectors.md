# Connectors: the registry, and the refactor toward one source of truth

> A **connector** injects genuinely useful context for an idea — current library
> docs (`@context7`), a GitHub issue (`@github`), a local file (`@finder`) —
> resolved into paste-ready text at copy time. This document formalizes the
> connector model as it exists today, names the one structural problem in it (two
> parallel registries joined by a string id), and specifies the refactor to a
> single source of truth that both `@`-mentions **and** [widgets](widgets.md) draw
> from.

**Status:** the "today" sections describe shipped code. The "refactor" sections
are a design spec, revised after an adversarial review that found the first draft
under-stated the coupling. It is a careful internal reorganization — the
serialization *format* and secret keys don't move — but it is **not** the
"changes nothing" refactor the first draft claimed. The load-bearing couplings are
called out below as requirements, not hand-waved.

For *which* connectors earn a place (the capability-vs-bloat bar), see the
connector philosophy in [CONTRIBUTING](../CONTRIBUTING.md#connectors). This doc is
about the *machinery*.

---

## Today: how a connector is built

A connector is a value conforming to `ComposerAppConnector`
([`Support/AppConnectors.swift`](../Sources/ComposerApp/Support/AppConnectors.swift)),
registered in `AppConnectorRegistry.all`:

```swift
protocol ComposerAppConnector {
  var id: String { get }                    // "@github" — also the token prefix AND the secret key
  var minimumQueryLength: Int { get }
  var supportsGitHubKindToggle: Bool { get }
  var auth: ConnectorAuth { get }
  func placeholder(context: AppSearchContext) -> String
  func idleMessage(context: AppSearchContext) -> String
  func noResultsMessage(query: String, context: AppSearchContext) -> String
  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult]
  func render(selection: AppSelection?) async throws -> String
}

enum ConnectorAuth: Equatable {
  case none
  case apiToken(label: String, hint: String, createURL: String?)
}
```

The pieces that work well and the refactor keeps:

- **`search` / `render` are the capability.** `search` feeds the chip picker;
  `render` resolves the chosen reference into the prompt block at copy time.
- **`render` may throw; the graceful layer is the caller.** The individual
  connectors do **not** each return a fallback line — Linear/Notion/Sentry/Figma
  `render` paths *throw* on a missing token
  ([`LinearService.swift:36`](../Sources/ComposerApp/Services/LinearService.swift),
  and siblings). The graceful degradation lives in
  [`SelfContainedRenderer`](../Sources/ComposerApp/Services/SelfContainedRenderer.swift),
  which catches the throw and **names the failed connector** in the output instead
  of dropping it silently. That is the real contract — a connector's job is to
  throw a meaningful error; the renderer's job is to not let one failure sink the
  copy. (An earlier draft of this doc claimed each connector "degrades gracefully
  to a plain reference line"; that was wrong about where the graceful behavior
  lives.)
- **`auth` is declarative.** A connector says *what* secret it needs;
  [`ConnectorSecretStore`](../Sources/ComposerApp/Support/ConnectorSecretStore.swift)
  stores it (0600 JSON), `ConnectorTokenField` renders the field, and services
  read it with `ConnectorSecretStore.token(for: "@linear")`.
- **The `@token` is the source of truth.** `AppToken`
  ([`Support/AppReference.swift`](../Sources/ComposerApp/Support/AppReference.swift))
  serializes a connector id + selection into the plain text that persists.

The nine connectors today: `@context7`, `@github`, `@finder`, `@browser`,
`@linear`, `@notion`, `@sentry`, `@figma`, `@xcode`.

---

## The problem: two registries, joined by a string

A connector's definition is split across **two** lists that must agree, keyed by a
bare string id:

| Where | File | Owns |
| ----- | ---- | ---- |
| `AppConnectorRegistry.all` | `AppConnectors.swift` | behavior: `auth`, `search`, `render` |
| `MentionCatalog` | [`Support/MentionToken.swift`](../Sources/ComposerApp/Support/MentionToken.swift) | identity/UI: `label`, `subtitle`, `symbol`, `kind`, **and** the category |

Adding a connector means editing both files and keeping the `@id` in sync by hand.
Settings re-joins them at render time —
`AppConnectorRegistry.connector(for: app.id)?.auth` — and nothing fails at compile
time if the two lists disagree. The id string is load-bearing in **four** places
at once (mention identity, registry key, secret key, token prefix), and — see the
couplings below — the *set* of valid ids is itself derived from
`MentionCatalog.apps` in the token parser.

This is the drift-prone shape the [widget registry](widgets.md) is designed to
avoid, and it's worth fixing. But the fix touches more than the first draft
admitted.

---

## The refactor: the connector is the source of truth for identity

Promote the connector to own its identity and UI, and **derive** the mention
catalog from the registry. The critical correction from review: the derivation and
the capability split have hard constraints, spelled out as requirements.

### The capability split

```swift
// Identity + auth. This is what Settings and widgets need. Renamed from
// ComposerAppConnector; keep `typealias ComposerAppConnector = Connector`
// during migration so call sites compile unchanged.
protocol Connector {
  var id: String { get }                  // "@github" — unchanged token prefix & secret key
  var label: String { get }               // "GitHub"
  var subtitle: String { get }            // "Issues & PRs"
  var symbol: String { get }              // SF Symbol fallback
  var category: ConnectorCategory { get } // .local | .service
  var displayOrder: Int { get }           // see "Ordering is user-visible" below
  var auth: ConnectorAuth { get }
}

// The @-mention capability: search the chip picker + render context. The nine
// existing connectors are all ContextConnectors — no behavior change.
protocol ContextConnector: Connector {
  var minimumQueryLength: Int { get }
  func search(_ query: String, context: AppSearchContext) async throws -> [AppSearchResult]
  func render(selection: AppSelection?) async throws -> String
}
```

**Requirement — two lookups, not one.** `connector(for:)` today returns
`any ComposerAppConnector` and callers immediately use `search` / `minimumQueryLength`
([`AppSearchPanel.swift:29,71,80`](../Sources/ComposerApp/Views/AppSearchPanel.swift))
and `render` ([`SelfContainedRenderer.swift:72`](../Sources/ComposerApp/Services/SelfContainedRenderer.swift)).
A single split lookup can't serve both — return `any Connector` and those sites
won't compile; return `any ContextConnector` and Settings/widgets can't fetch
auth-only connectors. So the registry exposes **both**:

```swift
enum ConnectorRegistry {
  static let all: [any Connector]                       // auth / Settings / widgets
  static func connector(for id: String) -> (any Connector)?
  static var context: [any ContextConnector]            // mentions / tokens / search / render
  static func contextConnector(for id: String) -> (any ContextConnector)?
}
```

### Deriving the mention catalog — from context connectors only

**Requirement — `MentionCatalog.apps` derives from `ContextConnector`s, never from
all connectors.** The @-menu opens inline app search for any `.app` item
([`FreeWriteEditor.swift:752`](../Sources/ComposerApp/Views/FreeWriteEditor.swift)),
which requires `search` / `minimumQueryLength`. A `Connector`-only `@vercel`
(auth for a widget, no mention search) derived into `apps` would appear as a
mentionable tile that does nothing. So:

```swift
extension MentionCatalog {
  static let apps: [MentionItem] =
    ConnectorRegistry.context                 // context connectors ONLY
      .sorted { $0.displayOrder < $1.displayOrder }
      .map(MentionItem.init)
}
```

Settings ▸ Connectors, by contrast, lists **all** `Connector`s (so an auth-only
connector still gets a token field). Two derivations, two source sets — that's the
whole point of the split.

**Requirement — `MentionCatalog.all` is load-bearing; preserve it and its order.**
`.all` (apps + skills + clipboard) is consumed well beyond the @-menu: skills are
extracted for copy output
([`SelfContainedRenderer.swift:48`](../Sources/ComposerApp/Services/SelfContainedRenderer.swift)),
and chip styling / board-render regexes are built from it
([`MentionStyle.swift:222`](../Sources/ComposerApp/Support/MentionStyle.swift),
[`BoardCardView.swift:522`](../Sources/ComposerApp/Views/BoardCardView.swift)). The
skill and clipboard items are **not** connectors and must survive the refactor:

```swift
static let nonAppMentions: [MentionItem] = [ /* skills…, @clipboard */ ]  // unchanged, explicit order
static let all: [MentionItem] = apps + nonAppMentions
```

### Ordering is user-visible

**Requirement — preserve display order explicitly.** The registry's array order
(`@context7`, `@github`, …) is **not** the current mention/Settings order, which is
local-first (`@finder`, `@browser`, `@xcode`, then services). A naïve
`registry.map` silently reorders the @-menu and Settings rows. Hence the
`displayOrder` field above (or, equivalently, reorder the registry to match the UI
and assert it). Either way it's covered by an order test (below). The first draft's
"no user-visible behavior" claim was false here.

---

## What actually changes, and what genuinely doesn't

Unchanged (and tested to stay so):

- **Token *format*** — `AppToken.string` / `.parse` / `.scan` still emit and read
  the same `@id`-prefixed strings, so every persisted board round-trips.
- **Secret keys** — `ConnectorSecretStore` is still keyed by `@id`; saved tokens
  keep working.

Changed — and these are the parts the first draft under-stated:

- **The token parser's *allowed-id set* is derived, not free.**
  `AppToken.appIDs` / `parse` / `scan` build their valid-id set from
  `MentionCatalog.apps`
  ([`AppReference.swift:120,163,260`](../Sources/ComposerApp/Support/AppReference.swift)).
  Once `apps` is `ContextConnector`-only, that set must be sourced from
  `ConnectorRegistry.context` too — otherwise an auth-only connector would parse as
  a token with no `AppSelection` case and nothing to render. **Requirement:**
  `AppToken` uses context-connector ids only.
- **The secret-key duplication is *not* fully eliminated.** Services still hard-code
  their own id for the secret lookup — `ConnectorSecretStore.token(for: "@linear")`
  lives in `LinearService`, independent of `LinearAppConnector.id`
  ([`LinearService.swift:13`](../Sources/ComposerApp/Services/LinearService.swift),
  and Notion/Sentry/Figma siblings). The refactor collapses the *identity/UI/behavior*
  duplication into one definition; it does **not** by itself remove the
  credential-key duplication. Treat that as a scoped follow-up: pass `connectorID`
  into each service, or hang a shared per-connector id constant off the connector.
  Until then, "single source of truth" means *identity, UI, category, and auth
  declaration* — not the secret-read call site.

---

## Modular capabilities

The split — one connector definition consumed by both mentions and widgets — is the
bridge to widgets.

The split is what lets [widgets](widgets.md) reuse a connector for auth without
inheriting the mention surface. A widget's `requiredConnector` names a
`Connector.id` (e.g. `"@github"`); the connector owns the credential; the widget
owns nothing about auth. An auth-only `Connector` (no `ContextConnector`
conformance) is allowed — it gets a Settings token row but **no** @-mention tile,
exactly because `apps` derives from context connectors only.

**Sequencing:** a widget that needs auth depends on this refactor for the derived
Settings row. If widgets ship first, they must read `ConnectorSecretStore` directly
and accept manual Settings plumbing until the refactor lands. Prefer landing this
refactor first.

---

## Migration plan (incremental, each step green)

1. Rename `ComposerAppConnector` → `Connector` with
   `typealias ComposerAppConnector = Connector` so call sites compile untouched.
2. Add `label` / `subtitle` / `symbol` / `category` / `displayOrder` to `Connector`,
   defaulted, then fill them in on each of the nine (copy from `MentionCatalog`).
3. Introduce `ContextConnector`; make the nine conform; add the `context` /
   `contextConnector(for:)` registry accessors; narrow the mention/search/render
   call sites to `ContextConnector`.
4. Point `AppToken`'s allowed-id set at `ConnectorRegistry.context`.
5. Flip `MentionCatalog.apps` to derive from `context` (sorted by `displayOrder`);
   introduce `nonAppMentions`; define `all = apps + nonAppMentions`. Delete the old
   hand-written `MentionItem` app array, the `appCategory` map, and move
   `ConnectorCategory` next to the protocol.
6. Add the tests below. Keep `ConnectorTokenTests` and the full suite green at every
   step.

---

## Adding a connector (after the refactor)

1. **New file** `Sources/ComposerApp/Connectors/<Name>Connector.swift` conforming
   to `Connector` (identity + auth) and, if it injects mention context,
   `ContextConnector` (`search` + `render`).
2. **Throw a meaningful error from `render`** — `SelfContainedRenderer` will name
   the failure; do not block the main actor.
3. **Register one line** in `ConnectorRegistry.all`.
4. **Add round-trip tests** in `ConnectorTokenTests` for the new token shape.

No second list to update, no category map to edit.

---

## Testing

The first draft's single "unique ids" test misses exactly the regressions this
refactor is most likely to cause. Required tests:

- **Token codecs** — `ConnectorTokenTests` round-trip every context connector's
  `@token` ↔ selection. Note the existing test iterates `MentionCatalog.apps` and
  **silently skips** entries with no registry match
  ([`ConnectorTokenTests.swift:80`](../Tests/ComposerAppTests/ConnectorTokenTests.swift));
  tighten it to assert every app has a connector.
- **Exact app order** — assert `MentionCatalog.apps.map(\.id)` equals the expected
  local-first order (guards the ordering regression).
- **Exact `MentionCatalog.all` order** — assert skills and `@clipboard` are present
  and ordered (guards the load-bearing `.all` consumers).
- **Context-only tokens** — assert `AppToken.scan` accepts context-connector ids and
  **rejects** an auth-only connector id.
- **Auth-only visibility** — assert an auth-only `Connector` appears in Settings but
  **not** in `MentionCatalog.apps`.
- **Registry consistency** — ids unique and `@`-prefixed; `label`/`symbol` non-empty;
  valid `category`; and every widget's `requiredConnector` ([widgets.md](widgets.md))
  names a real connector. This is the *same* test referenced by widgets.md, not a
  second one.

---

## See also

- [widgets.md](widgets.md) — the widget registry that consumes connectors for auth;
  same "one definition, derived everywhere" design.
- [CONTRIBUTING ▸ Connectors](../CONTRIBUTING.md#connectors) — the philosophy bar.
- [canvas-api.md](canvas-api.md) — where resolved connector context ends up.
