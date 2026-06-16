import Foundation

/// Persists the single scratchpad note to Application Support, debounced.
enum NotePersistence {
  private static var url: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Composer/note.txt")
  }
  private static var saveWork: DispatchWorkItem?

  static func load() -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }

  static func scheduleSave(_ text: String) {
    saveWork?.cancel()
    let work = DispatchWorkItem { write(text) }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  static func write(_ text: String) {
    let directory = url.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
  }
}
