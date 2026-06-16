import AppKit
import Carbon.HIToolbox

final class HotKeyManager {
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandler: EventHandlerRef?

  func register() {
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

    let hotKeyID = EventHotKeyID(signature: "CMPR".fourCharCode, id: 1)
    RegisterEventHotKey(
      UInt32(kVK_Space),
      UInt32(controlKey | optionKey),
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
