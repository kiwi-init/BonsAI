import Foundation

/// Which Claude model each headless surface targets. Two independent choices, each persisted as a
/// `ClaudeModel` rawValue in UserDefaults so the picker in the Agent dock and the one in
/// Settings ▸ Runtime stay mirrored — both `@AppStorage`-bind the same key.
///
/// - `chat` backs the in-canvas agent (`CanvasAgent`); default **Opus**.
/// - `describe` backs the "describe board" copy action (`HeadlessPromptService.describeBoard`);
///   default **Sonnet**.
///
/// Refine and Compile deliberately stay on the CLI's own default model and are not covered here.
enum ModelPreferences {
  static let chatModelKey = "model.chat"
  static let describeModelKey = "model.describe"

  static let defaultChatModel: ClaudeModel = .opus
  static let defaultDescribeModel: ClaudeModel = .sonnet

  static var chatModel: ClaudeModel { stored(chatModelKey) ?? defaultChatModel }
  static var describeModel: ClaudeModel { stored(describeModelKey) ?? defaultDescribeModel }

  private static func stored(_ key: String) -> ClaudeModel? {
    UserDefaults.standard.string(forKey: key).flatMap(ClaudeModel.init(rawValue:))
  }
}
