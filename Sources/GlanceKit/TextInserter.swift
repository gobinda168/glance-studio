import AppKit
import Carbon
import GlanceCore

/// Types text into whichever app has keyboard focus. Never presses Return. Needs Accessibility.
public enum TextInserter {
  public enum Outcome { case inserted, notAllowed, secureInput, failed }

  /// macOS drops synthetic keystrokes without a word when Accessibility isn't granted to this exact build.
  static var canType: Bool { CGPreflightPostEventAccess() }

  static let accessibilityHint = "Allow Glance in Privacy & Security → Accessibility"

  @MainActor
  static func insert(_ text: String) -> Outcome {
    guard canType else { return .notAllowed }
    // Password fields (and apps with Secure Keyboard Entry) block synthetic input; say so instead of failing silently.
    if IsSecureEventInputEnabled() { return .secureInput }
    return Prefs.insertMode == "paste" ? paste(text) : type(text)
  }

  /// Unicode keystrokes in small chunks: nothing touches the clipboard.
  private static func type(_ text: String) -> Outcome {
    let source = CGEventSource(stateID: .combinedSessionState)
    for chunk in DictationText.chunks(text) {
      let units = Array(chunk.utf16)
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return .failed }
      // fn was just released; make sure no modifier rides along.
      down.flags = []
      up.flags = []
      units.withUnsafeBufferPointer { pointer in
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: pointer.baseAddress)
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
    return .inserted
  }

  /// Fallback for apps that drop synthetic unicode keystrokes: paste, then put the clipboard back.
  @MainActor
  private static func paste(_ text: String) -> Outcome {
    let pasteboard = NSPasteboard.general
    let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
      return copy
    }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    let source = CGEventSource(stateID: .combinedSessionState)
    let v = CGKeyCode(kVK_ANSI_V)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
    else { return .failed }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      pasteboard.clearContents()
      if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }
    return .inserted
  }
}
