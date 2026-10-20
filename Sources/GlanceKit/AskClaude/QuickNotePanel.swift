import AppKit
import Carbon
import GlanceCore
import SwiftUI

/// Quick note: ⌃⌥N in any app (or File › Quick Note) opens a small glass box at the top right of the screen that takes
/// the keyboard without activating Studio, so the app the user was in stays in front. ⌘↩ saves what's typed to Notes
/// (a new note, or added to the end of one picked in the destination menu) and closes; Esc closes, asking first when
/// there's text. It drags by its header and reopens where it was left (double-click the header: back to the top
/// right); its left, right and bottom edges resize it, up to the screen's edges, kept for next time (double-click an
/// edge: back to the usual size).
/// Open note… in the header loads an existing note into the box to edit there (saved as it's typed), in the editor
/// Studio hands over (`noteEditor`: Markdown and checkboxes, as on the Notes page). Designed in the replica's
/// `quicknote` module.
@MainActor
public final class QuickNotePanel {
  public static let shared = QuickNotePanel()

  static let defaultWidth: CGFloat = 460
  static let widths: ClosedRange<CGFloat> = 360...960
  /// Room round the card for its shadow.
  static let margin: CGFloat = 28
  /// The card's top-left corner where the user last dragged it, in screen coordinates.
  private static let originKey = "glance.quicknote.origin"
  private static let hotKeySignature = OSType(0x474C_514E) // 'GLQN'

  /// The editor for a note opened in the box, from the app (its live Markdown editor); a plain text box without one.
  public var noteEditor: (@MainActor (Binding<String>) -> AnyView)? {
    get { model.noteEditor }
    set { model.noteEditor = newValue }
  }

  private let model = QuickNoteModel()
  private var panel: QuickNoteWindow?
  /// The card's top-left corner on screen this showing; the card grows and shrinks downwards from it.
  private var corner: NSPoint?
  /// The card (and the menu under it) as last measured.
  private var size = CGSize(width: QuickNotePanel.defaultWidth, height: 170)
  private var closing = false
  private var hotKey: EventHotKeyRef?

  private init() {}

  /// Whether `window` is the panel: Studio's app-wide key monitor lets the panel's keys through untouched.
  nonisolated public static func owns(_ window: NSWindow?) -> Bool { window is QuickNoteWindow }

  /// ⌃⌥N, system-wide (Carbon: no Accessibility permission, and it never sees other keys).
  public func registerHotKey() {
    guard hotKey == nil else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
      var id = EventHotKeyID()
      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &id)
      guard id.signature == QuickNotePanel.hotKeySignature else { return OSStatus(eventNotHandledErr) }
      MainActor.assumeIsolated { QuickNotePanel.shared.show() }
      return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
    if RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0,
                           &ref) == noErr {
      hotKey = ref
    } else {
      NSLog("Glance: ⌃⌥N (Quick note) is taken by another app")
    }
  }

  /// Opens the box, empty, on New note; already open, it just takes the keyboard again.
  public func show() {
    if let panel, panel.isVisible, !closing {
      panel.makeKeyAndOrderFront(nil)
      model.focusRequest += 1
      return
    }
    let front = NSWorkspace.shared.frontmostApplication
    model.reset(source: front?.bundleIdentifier == Bundle.main.bundleIdentifier ? "Glance Studio" : front?.localizedName)
    let panel = self.panel ?? makePanel()
    self.panel = panel
    closing = false
    corner = Self.savedCorner(size) ?? Self.topRight(size)
    place(panel)
    panel.makeKeyAndOrderFront(nil)
    // The card unfolds on the next frame, once the window is up to draw it.
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.closing else { return }
        withAnimation(QuickReplyPanel.arrival) { self.model.visible = true }
      }
    }
  }

  /// Folds the card away, faster than it came. What's typed is dropped.
  public func close() {
    guard let panel, panel.isVisible, !closing else { return }
    closing = true
    withAnimation(QuickReplyPanel.exit) { model.visible = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.closing else { return }
        self.closing = false
        panel.orderOut(nil)
        self.model.reset(source: nil)
      }
    }
  }

  // MARK: Saving

  func save() {
    // An opened note is saved as it's typed: ⌘↩ is Done.
    if model.editing != nil {
      close()
      return
    }
    let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, model.phase != .saved else { return }
    do {
      if let id = model.destination {
        try CaptureStore.shared.appendToNote(id, text: text, source: model.source)
      } else {
        try CaptureStore.shared.addNote(title: "", text: text, source: model.source)
      }
    } catch {
      model.error = "Couldn't save the note: \(error.localizedDescription)"
      return
    }
    model.error = nil
    model.menuOpen = false
    withAnimation(.easeOut(duration: 0.16)) { model.phase = .saved }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.model.phase == .saved else { return }
        self.close()
      }
    }
  }

  /// Esc: closes the menu; else closes, asking first when there's text (a second Esc discards).
  func cancel() {
    if model.menuOpen {
      model.menuOpen = false
      model.focusRequest += 1
      return
    }
    if model.editing != nil || model.phase == .discard
      || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      close()
      return
    }
    withAnimation(.easeOut(duration: 0.16)) { model.phase = .discard }
  }

  // MARK: Keys

  /// The panel's keys, ahead of the text boxes: Esc, ⌘↩, ⌘W, the menu's ↑ ↓ ↩, and the edit keys (Studio may not be
  /// the active app, so its menu can't be relied on for them).
  private func key(_ event: NSEvent, in window: NSWindow) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    // Mid-composition (an input method's marked text) the keys belong to the text box.
    if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
    if event.keyCode == 53, flags.isEmpty {
      cancel()
      return true
    }
    if model.menuOpen, flags.isEmpty || flags == .shift {
      switch event.keyCode {
      case 125: model.movePick(1)
      case 126: model.movePick(-1)
      case 36, 76: model.choosePick()
      default: return false
      }
      return true
    }
    let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if flags == .command {
      switch (event.keyCode, character) {
      case (36, _), (76, _): save()
      case (_, "w"): cancel()
      case (_, "c"): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: window)
      case (_, "v"): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: window)
      case (_, "x"): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: window)
      case (_, "a"): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: window)
      case (_, "z"): return NSApp.sendAction(Selector(("undo:")), to: nil, from: window)
      default: return false
      }
      return true
    }
    if flags == [.command, .shift], character == "z" {
      return NSApp.sendAction(Selector(("redo:")), to: nil, from: window)
    }
    return false
  }

  // MARK: The window

  private func makePanel() -> QuickNoteWindow {
    let panel = QuickNoteWindow(contentRect: NSRect(x: 0, y: 0, width: model.width + 2 * Self.margin, height: 240),
                                styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                                backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The card draws its own shadow inside the window's margin.
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.onKey = { [weak self, weak panel] event in
      guard let self, let panel else { return false }
      return self.key(event, in: panel)
    }
    let actions = QuickNoteActions(
      save: { [weak self] in self?.save() },
      cancel: { [weak self] in self?.cancel() },
      close: { [weak self] in self?.close() },
      moved: { [weak self] in self?.moved() },
      recentre: { [weak self] in self?.recentre() },
      beginResize: { [weak self] in self?.beginResize(box: $0) },
      resize: { [weak self] in self?.resize($0, by: $1) },
      endResize: { [weak self] in self?.endResize() },
      measured: { [weak self] in self?.measured($0) })
    model.focusEditor = { [weak panel] in
      guard let panel, let editor = Self.textView(in: panel.contentView) else { return }
      panel.makeFirstResponder(editor)
      editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
      editor.scrollRangeToVisible(editor.selectedRange())
    }
    let host = QuickNoteHostingView(rootView: QuickNoteRoot(model: model, actions: actions))
    // The window's size comes from what the card measures, not from the hosting view.
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  /// The first editable text view under `view`: the opened note's editor.
  private static func textView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let text = view as? NSTextView, text.isEditable { return text }
    for child in view.subviews { if let found = textView(in: child) { return found } }
    return nil
  }

  private func measured(_ size: CGSize) {
    guard size.width > 0, size.height > 0,
          abs(size.height - self.size.height) > 0.5 || abs(size.width - self.size.width) > 0.5 else { return }
    self.size = size
    // Not only while visible: the first measure lands while the window is still being ordered in, and a box opening
    // at a remembered size would otherwise keep the default frame (the card clipped and centred in it).
    if let panel { place(panel) }
  }

  /// The card's corner at `corner`, growing downwards; a card that would pass the bottom or the right of the screen
  /// moves up or left.
  private func place(_ panel: NSWindow) {
    guard let corner else { return }
    let screen = NSScreen.screens.first { $0.frame.contains(corner) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let y = max(corner.y - size.height, visible.minY + 8)
    // A card wider than what's left of the screen moves left (the remembered corner stays as it was).
    let x = max(visible.minX + 8, min(corner.x, visible.maxX - size.width - 8))
    let card = NSRect(x: x, y: y, width: size.width, height: size.height)
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  // MARK: Resizing

  /// The card on screen when a resize began, its text box's height, and the screen it's on.
  private struct ResizeStart {
    let card: NSRect
    let box: CGFloat
    let visible: NSRect
  }

  private var resizeStart: ResizeStart?

  private func beginResize(box: CGFloat) {
    guard let panel else { return }
    let card = panel.frame.insetBy(dx: Self.margin, dy: Self.margin)
    let screen = NSScreen.screens.first { $0.frame.intersects(card) } ?? NSScreen.main
    resizeStart = ResizeStart(card: card, box: box, visible: screen?.visibleFrame ?? card)
  }

  /// `delta`: how far the pointer has gone since the press, right and down. The edge being dragged follows it, up to
  /// the screen's edges; the opposite edge stays put (a left-edge drag moves the corner).
  private func resize(_ edge: QuickNoteEdge, by delta: CGSize) {
    guard let start = resizeStart else { return }
    let card = start.card, visible = start.visible.insetBy(dx: 8, dy: 8)
    func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
    var left = card.minX
    var width = card.width
    if edge.isRight {
      width = clamp(card.width + delta.width, Self.widths.lowerBound, min(Self.widths.upperBound, visible.maxX - card.minX))
    }
    if edge.isLeft {
      width = clamp(card.width - delta.width, Self.widths.lowerBound, min(Self.widths.upperBound, card.maxX - visible.minX))
      left = card.maxX - width
    }
    if edge.isBottom {
      let room = card.minY - visible.minY
      model.boxHeight = clamp(start.box + delta.height, QuickNoteCard.minHeight,
                              min(QuickNoteCard.maxDraggedHeight, start.box + room))
    }
    corner = NSPoint(x: left, y: card.maxY)
    model.width = width
  }

  private func endResize() {
    resizeStart = nil
    model.saveSize()
    moved()
  }

  /// A drag by the header, or a resize, ended: remember where the card is, so it opens there again.
  private func moved() {
    guard let panel else { return }
    let frame = panel.frame
    let point = NSPoint(x: frame.minX + Self.margin, y: frame.maxY - Self.margin)
    corner = point
    UserDefaults.standard.set([point.x, point.y], forKey: Self.originKey)
  }

  private func recentre() {
    UserDefaults.standard.removeObject(forKey: Self.originKey)
    corner = Self.topRight(size)
    if let panel { place(panel) }
  }

  /// Where the user left it, moved back on screen if the card is now wider than what's left there; nil when its
  /// screen has gone.
  private static func savedCorner(_ size: CGSize) -> NSPoint? {
    guard let saved = UserDefaults.standard.array(forKey: originKey) as? [Double], saved.count == 2 else { return nil }
    let point = NSPoint(x: saved[0], y: saved[1])
    guard let visible = NSScreen.screens.first(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(point) })?
      .visibleFrame else { return nil }
    return NSPoint(x: max(visible.minX + 8, min(point.x, visible.maxX - size.width - 8)), y: min(point.y, visible.maxY))
  }

  /// Top right of the mouse's screen, just under the menu bar.
  private static func topRight(_ size: CGSize) -> NSPoint {
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 10)
  }
}

// MARK: - Model

@MainActor
final class QuickNoteModel: ObservableObject {
  enum Phase { case edit, discard, saved }

  /// A destination menu row: nil is New note.
  struct Row: Identifiable {
    let id: UUID?
    let title: String
    let detail: String
  }

  @Published var text = ""
  /// The note it's added to; nil: a new note.
  @Published var destination: UUID?
  /// The app in front when it opened ("Safari").
  @Published var source: String?
  @Published var phase = Phase.edit
  @Published var menuOpen = false
  @Published var filter = ""
  /// The menu row ↑/↓ are on.
  @Published var pick = 0
  /// What the menu picks: where a new note goes, or a note to open in the box.
  @Published var menuMode = MenuMode.destination
  /// The note opened in the box (Open note…), edited in place; nil: a new quick note.
  @Published var editing: UUID?
  var noteEditor: (@MainActor (Binding<String>) -> AnyView)?

  enum MenuMode { case destination, open }
  @Published var error: String?
  @Published var visible = false
  /// Bumped to put the keyboard back in the text box.
  @Published var focusRequest = 0
  /// The card's width, and the text box's height when the user has dragged it (nil: it follows the text, 3 to 10
  /// lines). Both kept across showings and launches.
  @Published var width = QuickNoteModel.savedWidth
  @Published var boxHeight = QuickNoteModel.savedBoxHeight

  private static let widthKey = "glance.quicknote.width"
  private static let boxHeightKey = "glance.quicknote.boxHeight"

  private static var savedWidth: CGFloat {
    let saved = UserDefaults.standard.double(forKey: widthKey)
    return saved > 0 ? min(max(saved, QuickNotePanel.widths.lowerBound), QuickNotePanel.widths.upperBound)
                     : QuickNotePanel.defaultWidth
  }

  private static var savedBoxHeight: CGFloat? {
    let saved = UserDefaults.standard.double(forKey: boxHeightKey)
    return saved > 0 ? saved : nil
  }

  func saveSize() {
    UserDefaults.standard.set(Double(width), forKey: Self.widthKey)
    if let boxHeight { UserDefaults.standard.set(Double(boxHeight), forKey: Self.boxHeightKey) }
    else { UserDefaults.standard.removeObject(forKey: Self.boxHeightKey) }
  }

  func resetSize() {
    width = QuickNotePanel.defaultWidth
    boxHeight = nil
    saveSize()
  }

  var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase == .edit }

  var destinationNote: NoteDoc? { destination.flatMap { CaptureStore.shared.note($0) } }
  var editingNote: NoteDoc? { editing.flatMap { CaptureStore.shared.note($0) } }

  /// The opened note's body, written to the store as it's typed.
  var editingBody: Binding<String> {
    Binding(get: { [weak self] in self?.editingNote?.body ?? "" },
            set: { [weak self] value in
              guard let id = self?.editing else { return }
              CaptureStore.shared.update(id) { $0.body = value }
            })
  }

  /// Puts the keyboard in an opened note's editor (an AppKit text view the card can't focus itself).
  var focusEditor: (@MainActor () -> Void)?

  /// Loads a note into the box; nil goes back to a new quick note. A typed quick note is kept (it isn't saved yet).
  func open(_ id: UUID?) {
    editing = id
    menuOpen = false
    phase = .edit
    error = nil
    focusRequest += 1
    guard id != nil else { return }
    // Once the editor is on screen.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      MainActor.assumeIsolated { self?.focusEditor?() }
    }
  }

  func reset(source: String?) {
    text = ""
    destination = nil
    editing = nil
    self.source = source
    phase = .edit
    menuOpen = false
    menuMode = .destination
    filter = ""
    pick = 0
    error = nil
    visible = false
  }

  /// Where to save: New note, then the notes whose title matches the filter, newest first. To open: the notes.
  var rows: [Row] {
    let query = filter.trimmingCharacters(in: .whitespaces)
    let notes = CaptureStore.shared.notes.filter {
      query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)
    }.map { Row(id: $0.id, title: $0.displayTitle, detail: Self.detail($0)) }
    if menuMode == .open { return notes }
    return [Row(id: nil, title: "New note", detail: "First line becomes the title")] + notes
  }

  /// The menu for `mode`: opens it, switches it over, or (already showing that one) closes it.
  func toggleMenu(_ mode: MenuMode = .destination) {
    if menuOpen, menuMode != mode {
      menuMode = mode
      filter = ""
      pick = 0
      return
    }
    menuMode = mode
    menuOpen.toggle()
    filter = ""
    pick = 0
    if !menuOpen { focusRequest += 1 }
  }

  func movePick(_ by: Int) {
    let count = rows.count
    guard count > 0 else { return }
    pick = (pick + by + count) % count
  }

  func choosePick() {
    let rows = rows
    guard rows.indices.contains(pick) else { return }
    choose(rows[pick].id)
  }

  func choose(_ id: UUID?) {
    if menuMode == .open {
      open(id)
      return
    }
    destination = id
    menuOpen = false
    focusRequest += 1
  }

  private static func detail(_ note: NoteDoc) -> String {
    let date = note.updated.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    guard let source = note.source, !source.isEmpty else { return date }
    return "\(date) · from \(source)"
  }
}

struct QuickNoteActions {
  var save: @MainActor () -> Void
  var cancel: @MainActor () -> Void
  var close: @MainActor () -> Void
  var moved: @MainActor () -> Void
  var recentre: @MainActor () -> Void
  /// A resize drag: began (with the text box's height), moved, ended.
  var beginResize: @MainActor (CGFloat) -> Void
  var resize: @MainActor (QuickNoteEdge, CGSize) -> Void
  var endResize: @MainActor () -> Void
  var measured: @MainActor (CGSize) -> Void
}

// MARK: - Views

/// The card and, under it while open, the destination menu; unfolding from the top like the quick-reply panel.
struct QuickNoteRoot: View {
  @ObservedObject var model: QuickNoteModel
  let actions: QuickNoteActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      QuickNoteCard(model: model, actions: actions)
      if model.menuOpen {
        DestinationMenu(model: model)
          .padding(.leading, QuickNoteCard.inset)
          .transition(.blurSwap(reduceMotion))
      }
    }
    .frame(width: model.width, alignment: .leading)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: { $0.size }) { actions.measured($0) }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.menuOpen)
    .modifier(Unfold(on: model.visible, reduceMotion: reduceMotion))
    .padding(QuickNotePanel.margin)
    // Top-leading: the card grows right and down from its corner while the window catches up.
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// Header (drags the window), the text box, and the footer: destination · Cancel · Save; thick warm glass with the rim
/// on top, the text on its own clear layer.
struct QuickNoteCard: View {
  @ObservedObject var model: QuickNoteModel
  let actions: QuickNoteActions
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool
  @State private var textHeight: CGFloat = 0
  /// The width and box height when a resize drag began.
  @State private var resizing = false
  /// The resize edge under the pointer (or being dragged), and whether the pointer is over the card: the edges' marks
  /// show faintly over the card and in coral on the edge itself.
  @State private var resizeHover: QuickNoteEdge?
  @State private var cardHover = false

  static let radius: CGFloat = 18
  static let inset: CGFloat = 8
  static var innerRadius: CGFloat { radius - inset }
  private static let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
  private static let lineHeight: CGFloat = 19
  static let minHeight = lineHeight * 3 + 10
  private static let maxHeight = lineHeight * 10 + 10
  /// How tall a drag can make the text box.
  static let maxDraggedHeight: CGFloat = 720
  /// An opened note's box, until the user drags it.
  private static let noteHeight: CGFloat = 260

  var body: some View {
    VStack(spacing: 0) {
      header
      field
        .padding(.horizontal, Self.inset)
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.circle")
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.criticalInk)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.top, 8)
      }
      footer
        .padding(.horizontal, Self.inset)
        .padding(.top, 8)
    }
    .padding(.bottom, Self.inset)
    .frame(width: model.width)
    .modifier(ThickSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(QuickReplyCard.rim, lineWidth: 1))
    // Resizing: the left, right and bottom edges and the bottom corners, straddling the card's border, each with a
    // mark on the border.
    .overlay(alignment: .leading) {
      ZStack {
        Capsule().fill(markColor(.left)).frame(width: 3, height: 28)
        resizeEdge(.left)
      }
      .frame(width: 8).padding(.vertical, Self.radius).offset(x: -4)
    }
    .overlay(alignment: .trailing) {
      ZStack {
        Capsule().fill(markColor(.right)).frame(width: 3, height: 28)
        resizeEdge(.right)
      }
      .frame(width: 8).padding(.vertical, Self.radius).offset(x: 4)
    }
    .overlay(alignment: .bottom) {
      ZStack {
        Capsule().fill(markColor(.bottom)).frame(width: 28, height: 3)
        resizeEdge(.bottom)
      }
      .frame(height: 8).padding(.horizontal, Self.radius).offset(y: 4)
    }
    .overlay(alignment: .bottomTrailing) {
      CornerMark(radius: Self.radius - 0.5)
        .stroke(markColor(.bottomRight), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .frame(width: Self.radius, height: Self.radius)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .bottomLeading) {
      CornerMark(radius: Self.radius - 0.5)
        .stroke(markColor(.bottomLeft), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .scaleEffect(x: -1) // the bottom-left corner: the arc mirrored
        .frame(width: Self.radius, height: Self.radius)
        .allowsHitTesting(false)
    }
    .overlay(alignment: .bottomTrailing) {
      resizeEdge(.bottomRight).frame(width: 12, height: 12).offset(x: 4, y: 4)
    }
    .overlay(alignment: .bottomLeading) {
      resizeEdge(.bottomLeft).frame(width: 12, height: 12).offset(x: -4, y: 4)
    }
    .onHover { cardHover = $0 }
    .animation(.easeOut(duration: 0.12), value: resizeHover)
    .animation(.easeOut(duration: 0.12), value: cardHover)
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.34), radius: 22, y: 10)
    .onAppear { focused = true }
    .onChange(of: model.focusRequest) { focused = true }
    .onChange(of: model.visible) { if model.visible { focused = true } }
    .onChange(of: model.text) { if model.phase == .discard { model.phase = .edit } }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.editingNote.map { "Note: \($0.displayTitle)" } ?? "Quick note")
  }

  private func markColor(_ edge: QuickNoteEdge) -> Color {
    if resizeHover == edge { return GlanceColor.coral.opacity(0.9) }
    return Color.primary.opacity(cardHover ? 0.16 : 0)
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: model.editing == nil ? "square.and.pencil" : "doc.text")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(GlanceColor.coralInk)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(GlanceColor.coral.opacity(0.16)))
        .accessibilityHidden(true)
      if let note = model.editingNote {
        Text(note.displayTitle)
          .font(GlanceFont.sans(13, .semibold))
          .foregroundStyle(GlanceColor.ink)
          .lineLimit(1)
        Text("Saved as you type")
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(1)
          .layoutPriority(-1)
      } else {
        Text("Quick note")
          .font(GlanceFont.sans(13, .semibold))
          .foregroundStyle(GlanceColor.ink)
        if let source = model.source {
          Text("from \(source)")
            .font(GlanceFont.sans(12))
            .foregroundStyle(GlanceColor.muted)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      OpenNoteChip(model: model)
      KeyCap("⌃⌥N")
        .help("Opens from any app")
      CloseButton(action: actions.close)
    }
    .padding(.leading, 14)
    .padding(.trailing, 10)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .background(HeaderDragArea(moved: actions.moved, recentre: actions.recentre))
    .help("Drag to move · double-click to put it back at the top right")
  }

  /// The text box's height: what the user dragged it to, else the text's (3 to 10 lines), or an opened note's.
  private var boxHeight: CGFloat {
    if let dragged = model.boxHeight { return max(dragged, Self.minHeight) }
    if model.editing != nil { return Self.noteHeight }
    return min(max(textHeight + 10, Self.minHeight), Self.maxHeight)
  }

  private func resizeEdge(_ edge: QuickNoteEdge) -> some View {
    ResizeEdge(edge: edge, hovered: { on in
      if on { resizeHover = edge } else if resizeHover == edge, !resizing { resizeHover = nil }
    }, began: {
      resizing = true
      actions.beginResize(boxHeight)
    }, dragged: { delta in
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { actions.resize(edge, delta) }
    }, ended: {
      resizing = false
      actions.endResize()
    }, reset: {
      model.resetSize()
    })
  }

  @ViewBuilder private var field: some View {
    if model.editing != nil { noteField } else { quickField }
  }

  /// An opened note: Studio's Markdown editor (a plain box without it), scrolling inside the box's height.
  private var noteField: some View {
    let shape = RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous)
    let body = model.editingBody
    return ScrollView(.vertical) {
      if let editor = model.noteEditor {
        editor(body)
      } else {
        TextEditor(text: body)
          .font(GlanceFont.sans(13))
          .foregroundStyle(GlanceColor.ink)
          .scrollContentBackground(.hidden)
          .frame(minHeight: boxHeight)
          .padding(8)
      }
    }
    .scrollIndicators(.automatic)
    .frame(height: boxHeight + 16)
    .background(shape.fill(GlanceColor.solid.opacity(0.86)))
    .clipShape(shape)
    .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    .accessibilityLabel("Note")
  }

  private var quickField: some View {
    let shape = RoundedRectangle(cornerRadius: Self.innerRadius, style: .continuous)
    let height = boxHeight
    return ZStack(alignment: .topLeading) {
      // The text's height, measured the way the box lays it out, sizes the box between 3 and 10 lines.
      Text(model.text.isEmpty ? " " : model.text + " ")
        .font(GlanceFont.sans(13))
        .lineSpacing(3)
        .padding(.horizontal, 5)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { textHeight = $0 }
      if model.text.isEmpty {
        Text("Note something…")
          .font(GlanceFont.sans(13))
          .foregroundStyle(GlanceColor.muted)
          .padding(.horizontal, 5)
          .allowsHitTesting(false)
      }
      TextEditor(text: $model.text)
        .font(GlanceFont.sans(13))
        .foregroundStyle(GlanceColor.ink)
        .lineSpacing(3)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .focused($focused)
        .disabled(model.phase == .saved)
        .accessibilityLabel("Note")
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .frame(height: height + 16, alignment: .topLeading)
    .background(shape.fill(GlanceColor.solid.opacity(0.86)))
    .overlay(shape.strokeBorder(focused ? GlanceColor.coral.opacity(0.85) : Color.primary.opacity(0.12), lineWidth: 1))
    .contentShape(shape)
    .onTapGesture { focused = true }
    .animation(.easeOut(duration: 0.16), value: focused)
  }

  @ViewBuilder private var footer: some View {
    HStack(spacing: 6) {
      if let id = model.editing {
        if let open = CaptureStore.shared.onOpenNote {
          GlanceButton("Open in Studio", style: .quiet, label: "Open the note in Studio's Notes", height: 28,
                       cornerRadius: 6) {
            open(id)
            actions.close()
          }
        }
        Spacer(minLength: 8)
        GlanceButton("New quick note", style: .quiet, height: 28, cornerRadius: 6) { model.open(nil) }
        KeyCap("⌘↩")
        GlanceButton("Done", style: .primary, label: "Done (⌘↩)", height: 28, cornerRadius: 6, action: actions.close)
      } else {
        captureFooter
      }
    }
    .id(model.editing == nil ? AnyHashable(model.phase) : AnyHashable("note"))
    .transition(.blurSwap(reduceMotion))
    .animation(.easeOut(duration: 0.16), value: model.phase)
    .animation(.easeOut(duration: 0.16), value: model.editing)
  }

  @ViewBuilder private var captureFooter: some View {
    HStack(spacing: 6) {
      switch model.phase {
      case .discard:
        Text("Discard this note?")
          .font(GlanceFont.sans(13, .medium))
          .foregroundStyle(GlanceColor.ink)
          .padding(.leading, 6)
        Spacer(minLength: 8)
        GlanceButton("Keep editing", style: .quiet, height: 28, cornerRadius: 6) {
          model.phase = .edit
          model.focusRequest += 1
        }
        KeyCap("Esc")
        GlanceButton("Discard", style: .secondary, label: "Discard the note", height: 28, cornerRadius: 6,
                     action: actions.close)
      case .saved:
        Label {
          Text(model.destinationNote.map { "Added to \($0.displayTitle)" } ?? "Saved to Notes")
            .lineLimit(1)
        } icon: {
          Image(systemName: "checkmark.circle.fill")
        }
        .font(GlanceFont.sans(12, .semibold))
        .foregroundStyle(GlanceColor.okInk)
        .padding(.leading, 6)
        .frame(height: 28)
        Spacer(minLength: 0)
      case .edit:
        DestinationChip(model: model)
        Spacer(minLength: 8)
        GlanceButton("Cancel", style: .quiet, label: "Cancel (Esc)", height: 28, cornerRadius: 6,
                     action: actions.cancel)
        KeyCap("⌘↩")
        GlanceButton("Save", style: .primary, label: "Save the note", height: 28, cornerRadius: 6,
                     action: actions.save)
          .disabled(!model.canSave)
          .help("Save (⌘↩)")
      }
    }
  }
}

/// The header's "Open note ▾": the notes to edit in the box.
private struct OpenNoteChip: View {
  @ObservedObject var model: QuickNoteModel
  @State private var hovering = false

  var body: some View {
    let showing = model.menuOpen && model.menuMode == .open
    Button { model.toggleMenu(.open) } label: {
      HStack(spacing: 5) {
        Text(model.editing == nil ? "Open note" : "Notes")
        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
      }
      .font(GlanceFont.sans(12, .medium))
      .foregroundStyle(showing || hovering ? GlanceColor.ink : GlanceColor.muted)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(hovering || showing ? 0.08 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .help("Open an existing note here to edit it")
    .accessibilityLabel("Open note")
  }
}

/// The card's bottom-right corner, as a short arc on its border: centred on the frame's top-left corner.
private struct CornerMark: Shape {
  let radius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    for (index, degrees) in stride(from: 22.0, through: 68.0, by: 4.0).enumerated() {
      let angle = degrees * .pi / 180
      let point = CGPoint(x: rect.minX + radius * cos(angle), y: rect.minY + radius * sin(angle))
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
  }
}

/// Where the note goes: "+ New note ▾" or "Add to <note> ▾"; opens the menu.
private struct DestinationChip: View {
  @ObservedObject var model: QuickNoteModel
  @State private var hovering = false

  var body: some View {
    let note = model.destinationNote
    Button { model.toggleMenu() } label: {
      HStack(spacing: 6) {
        Image(systemName: note == nil ? "plus" : "doc.text")
          .font(.system(size: 11, weight: .medium))
        if let note {
          Text("Add to").foregroundStyle(GlanceColor.muted)
          Text(note.displayTitle).fontWeight(.semibold).foregroundStyle(GlanceColor.ink).lineLimit(1)
        } else {
          Text("New note").fontWeight(.semibold).foregroundStyle(GlanceColor.ink)
        }
        Image(systemName: "chevron.down")
          .font(.system(size: 9, weight: .semibold))
      }
      .font(GlanceFont.sans(12, .medium))
      .foregroundStyle(GlanceColor.muted)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .frame(maxWidth: 250, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(hovering || model.menuOpen ? 0.08 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .help("Where it's saved")
    .accessibilityLabel(note.map { "Add to \($0.displayTitle)" } ?? "New note")
    .accessibilityHint("Choose where the note is saved")
  }
}

/// The destination menu: a find field, New note, then the notes to add to; ↑/↓ and ↩ work from the find field.
private struct DestinationMenu: View {
  @ObservedObject var model: QuickNoteModel
  @FocusState private var finding: Bool
  private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

  var body: some View {
    let rows = model.rows
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(GlanceColor.muted)
        TextField("Find a note", text: $model.filter)
          .textFieldStyle(.plain)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.ink)
          .focused($finding)
          .onChange(of: model.filter) { model.pick = 0 }
          .accessibilityLabel("Find a note")
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
      .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
      .padding(.bottom, 4)
      ScrollViewReader { scroll in
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
              if index == (model.menuMode == .open ? 0 : 1) {
                Text(model.menuMode == .open ? "OPEN A NOTE" : "ADD TO")
                  .font(GlanceFont.sans(11, .semibold))
                  .kerning(0.66)
                  .foregroundStyle(GlanceColor.muted)
                  .padding(.horizontal, 8)
                  .padding(.top, 6)
                  .padding(.bottom, 2)
              }
              MenuRow(row: row, opening: model.menuMode == .open, picked: index == model.pick,
                      chosen: row.id == (model.menuMode == .open ? model.editing : model.destination)) {
                model.choose(row.id)
              }
              .id(index)
            }
            if rows.count == (model.menuMode == .open ? 0 : 1) {
              Text(model.filter.isEmpty ? "No notes yet" : "No note matches “\(model.filter)”")
                .font(GlanceFont.sans(12))
                .foregroundStyle(GlanceColor.muted)
                .padding(8)
            }
          }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 236)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.pick) { scroll.scrollTo(model.pick) }
      }
    }
    .padding(6)
    .frame(width: 300)
    .background(Self.shape.fill(GlanceColor.solid.opacity(0.94)))
    .modifier(GlassSurface(shape: Self.shape))
    .overlay(Self.shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    .shadow(color: .black.opacity(0.32), radius: 14, y: 10)
    .onAppear { finding = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(model.menuMode == .open ? "Notes to open" : "Where to save the note")
  }
}

private struct MenuRow: View {
  let row: QuickNoteModel.Row
  var opening = false
  let picked: Bool
  let chosen: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: row.id == nil ? "plus" : "doc.text")
          .font(.system(size: 11))
          .foregroundStyle(GlanceColor.muted)
          .frame(width: 14)
        VStack(alignment: .leading, spacing: 1) {
          Text(row.title).font(GlanceFont.sans(12, .medium)).foregroundStyle(GlanceColor.ink)
          Text(row.detail).font(GlanceFont.sans(11)).foregroundStyle(GlanceColor.muted)
        }
        .lineLimit(1)
        Spacer(minLength: 4)
        if chosen {
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(GlanceColor.coralInk)
        }
      }
      .padding(.horizontal, 8)
      .frame(minHeight: 36)
      .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(picked || hovering ? 0.07 : 0)))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .accessibilityLabel(row.id == nil ? "New note" : opening ? "Open \(row.title)" : "Add to \(row.title)")
    .accessibilityAddTraits(chosen ? .isSelected : [])
  }
}

/// The header's background moves the window; a double-click puts it back at the top centre.
private struct HeaderDragArea: NSViewRepresentable {
  let moved: () -> Void
  let recentre: () -> Void

  final class DragView: NSView {
    var moved: () -> Void = {}
    var recentre: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 {
        recentre()
        return
      }
      window?.performDrag(with: event)
      moved()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  }

  func makeNSView(context: Context) -> DragView {
    let view = DragView()
    view.moved = moved
    view.recentre = recentre
    return view
  }

  func updateNSView(_ view: DragView, context: Context) {
    view.moved = moved
    view.recentre = recentre
  }
}

/// Which of the quick note card's edges (or bottom corners) a resize drags.
enum QuickNoteEdge {
  case left, right, bottom, bottomLeft, bottomRight

  var isLeft: Bool { self == .left || self == .bottomLeft }
  var isRight: Bool { self == .right || self == .bottomRight }
  var isBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
}

/// A strip along one of the card's edges (or a bottom corner) that resizes it: `dragged` gets how far the pointer has
/// gone since the press, right and down, in points.
private struct ResizeEdge: NSViewRepresentable {
  typealias Edge = QuickNoteEdge

  let edge: Edge
  let hovered: (Bool) -> Void
  let began: () -> Void
  let dragged: (CGSize) -> Void
  let ended: () -> Void
  let reset: () -> Void

  final class EdgeView: NSView {
    var edge = Edge.bottomRight
    var hovered: (Bool) -> Void = { _ in }
    var began: () -> Void = {}
    var dragged: (CGSize) -> Void = { _ in }
    var ended: () -> Void = {}
    var reset: () -> Void = {}
    /// Where the press was, on screen: the window moves under the pointer as it grows.
    private var start: NSPoint?

    override func mouseDown(with event: NSEvent) {
      if event.clickCount == 2 {
        start = nil
        reset()
        return
      }
      start = NSEvent.mouseLocation
      began()
    }

    override func mouseDragged(with event: NSEvent) {
      guard let start else { return }
      cursor.set()
      let now = NSEvent.mouseLocation
      dragged(CGSize(width: now.x - start.x, height: start.y - now.y))
    }

    override func mouseUp(with event: NSEvent) {
      guard start != nil else { return }
      start = nil
      ended()
      if !bounds.contains(convert(event.locationInWindow, from: nil)) {
        hovered(false)
        NSCursor.arrow.set()
      }
    }

    // The cursor: a tracking area that works while another app is active (the panel doesn't activate Studio, so
    // cursor rects alone never apply).
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited,
                                                            .mouseMoved, .cursorUpdate], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
      cursor.set()
      hovered(true)
    }

    override func mouseMoved(with event: NSEvent) { cursor.set() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }

    override func mouseExited(with event: NSEvent) {
      guard start == nil else { return }
      NSCursor.arrow.set()
      hovered(false)
    }

    private var cursor: NSCursor {
      let position: NSCursor.FrameResizePosition = switch edge {
      case .left: .left
      case .right: .right
      case .bottom: .bottom
      case .bottomLeft: .bottomLeft
      case .bottomRight: .bottomRight
      }
      return .frameResize(position: position, directions: .all)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
  }

  func makeNSView(context: Context) -> EdgeView {
    let view = EdgeView()
    updateNSView(view, context: context)
    return view
  }

  func updateNSView(_ view: EdgeView, context: Context) {
    view.edge = edge
    view.hovered = hovered
    view.began = began
    view.dragged = dragged
    view.ended = ended
    view.reset = reset
  }
}

// MARK: - AppKit

final class QuickNoteWindow: NSPanel {
  var onKey: (@MainActor (NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// ⌘-keys come here first, ahead of the main menu (⌘W and ⌘↩ are Studio menu items too).
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, let onKey, onKey(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  /// Plain keys (Esc, the menu's arrows) reach the window here, before the text boxes see them.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let onKey, onKey(event) { return }
    super.sendEvent(event)
  }

  /// Esc reaching the window (no text box in the way): the panel's own Esc already ran in `sendEvent`.
  override func cancelOperation(_ sender: Any?) {}
}

/// The first click on the card presses what's under it, even while another app is active.
private final class QuickNoteHostingView: NSHostingView<QuickNoteRoot> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The header's ✕, as on the quick-reply panel.
private struct CloseButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .help("Close")
    .accessibilityLabel("Close")
  }
}
