import Carbon

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility or
/// Input Monitoring permission and never sees other keystrokes.
@MainActor
final class HotKeys {
  static let shared = HotKeys()
  private var handlers: [UInt32: () -> Void] = [:]
  private var refs: [EventHotKeyRef] = []
  private var installed = false

  /// `keyCode` is a virtual key code (kVK_*), `modifiers` Carbon modifier flags (optionKey, cmdKey…).
  func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) {
    installHandlerOnce()
    let id = UInt32(handlers.count + 1)
    handlers[id] = handler
    var ref: EventHotKeyRef?
    let hotKeyID = EventHotKeyID(signature: OSType(0x474C_4E43), id: id) // 'GLNC'
    if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
      let ref {
      refs.append(ref)
    } else {
      NSLog("Glance: shortcut \(keyCode)/\(modifiers) is taken by another app")
    }
  }

  /// Gives every shortcut back (the overlay was switched off).
  func unregisterAll() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs.removeAll()
    handlers.removeAll()
  }

  private func installHandlerOnce() {
    guard !installed else { return }
    installed = true
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var hotKeyID = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
      guard hotKeyID.signature == OSType(0x474C_4E43) else { return OSStatus(eventNotHandledErr) }
      let id = hotKeyID.id
      MainActor.assumeIsolated { HotKeys.shared.handlers[id]?() }
      return noErr
    }, 1, &spec, nil, nil)
  }
}
