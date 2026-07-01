import Foundation

/// The production `WidgetTransport`: shells out via `Shell` (argv only — never a shell string, so
/// config values can't inject) and does plain HTTP GETs. Tests inject a stub transport instead, so
/// a widget's `parse` is covered without touching the network or the CLI.
struct LiveWidgetTransport: WidgetTransport {
  func shell(_ argv: [String]) async throws -> String {
    let result = try await Shell.run(argv, timeout: 20)
    guard result.status == 0 else {
      // Never surface raw stderr to the card — it can carry tokens. The widget maps a nonzero
      // exit to a sanitized WidgetError; this just signals failure with the exit code.
      throw WidgetTransportFailure.exit(result.status)
    }
    return result.stdout
  }

  func get(_ url: URL, headers: [String: String]) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: 20)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw WidgetError.network }
    switch http.statusCode {
    case 200..<300: return data
    case 401, 403: throw WidgetError.unauthorized
    default: throw WidgetError.badResponse
    }
  }
}

/// A shell failure carrying only the exit code — never stderr text (which can leak secrets).
enum WidgetTransportFailure: Error, Equatable {
  case exit(Int32)
}
