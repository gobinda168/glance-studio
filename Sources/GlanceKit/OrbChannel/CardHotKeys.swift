import Carbon

/// ⌥1–4, ⌥Y and ⌥N for the active orb-channel card, system-wide, only while a card waits (spec "Cards and the
/// queue"). Carbon hot keys swallow the key, so the app in front doesn't also type "¡" or "¥"; they're released the
/// moment no card waits.
@MainActor
final class CardHotKeys {
  enum Key: Equatable { case choice(Int), allow, deny }

  static let shared = CardHotKeys()
  private static let signature = OSType(0x474C_4348) // 'GLCH'
  private var refs: [EventHotKeyRef] = []
  private var keys: [UInt32: Key] = [:]
  private var handler: ((Key) -> Void)?
  private var installed = false
  private var current: (choices: Int, permission: Bool)?

  /// Registers the keys a card needs (`choices` 0–4, or Allow/Deny), or none when `active` is false.
  func set(active: Bool, choices: Int, permission: Bool, handler: @escaping (Key) -> Void) {
    self.handler = handler
    let wanted = active ? (choices: permission ? 0 : min(choices, 4), permission: permission) : nil
    guard wanted?.choices != current?.choices || wanted?.permission != current?.permission else { return }
    unregister()
    current = wanted
    guard let wanted else { return }
    installHandlerOnce()
    let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
    for index in 0..<wanted.choices { register(digits[index], .choice(index)) }
    if wanted.permission {
      register(kVK_ANSI_Y, .allow)
      register(kVK_ANSI_N, .deny)
    }
  }

  private func register(_ keyCode: Int, _ key: Key) {
    let id = UInt32(keys.count + 1)
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
    if RegisterEventHotKey(UInt32(keyCode), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
       let ref {
      refs.append(ref)
      keys[id] = key
    } else {
      NSLog("Glance: card shortcut \(keyCode) with ⌥ is taken by another app")
    }
  }

  private func unregister() {
    refs.forEach { UnregisterEventHotKey($0) }
    refs.removeAll()
    keys.removeAll()
  }

  private func installHandlerOnce() {
    guard !installed else { return }
    installed = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      guard hotKeyID.signature == CardHotKeys.signature else { return OSStatus(eventNotHandledErr) }
      let id = hotKeyID.id
      MainActor.assumeIsolated {
        if let key = CardHotKeys.shared.keys[id] { CardHotKeys.shared.handler?(key) }
      }
      return noErr
    }, 1, &spec, nil, nil)
  }
}
