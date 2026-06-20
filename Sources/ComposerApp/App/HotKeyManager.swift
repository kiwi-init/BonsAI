import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  func register() {
    installHandler()
    registerHotKey()
    NotificationCenter.default.addObserver(
      self, selector: #selector(reregister),
      name: .composerShortcutChanged, object: nil)
  }

  /// Re-bind the global hotkey after the user picks a new shortcut in Settings.
  @objc private func reregister() { registerHotKey() }

  private func installHandler() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )

    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ in
        var hotKeyID = EventHotKeyID()
        GetEventParameter(
          event,
          EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil,
          MemoryLayout<EventHotKeyID>.size,
          nil,
          &hotKeyID
        )

        if hotKeyID.id == 1 {
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: .composerToggleWindow, object: nil)
          }
        }
        return noErr
      },
      1,
      &eventType,
      nil,
      &eventHandler
    )
  }

  private func registerHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
    let shortcut = ShortcutStore.shared.shortcut
    let hotKeyID = EventHotKeyID(signature: "CMPR".fourCharCode, id: 1)
    RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &hotKeyRef
    )
  }

  deinit {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
    }
  }
}
