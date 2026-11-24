import Foundation

/// Command Center (spec 2026-11-01-command-center-design.md §4.2): when a browser clip starts and stops. One `ClipRules`
/// per Claude session's wrapper (client). A clip records a page while Claude is working in the browser, and ends 5 s after
/// its last tool call, on navigating away, when the page closes, or at 180 s. Pure: time and pages come in as inputs, the
/// recorder (screencast, files) is somewhere else.
///
/// - Pages the user opened (`adopted`) are never recorded; popups Claude opened are.
/// - A clip cut at 180 s stays cut on that page until the next tool start; other pages keep recording.
/// - A clip is kept when it has at least `minFrames` frame and lasted at least `minVisitSeconds`. A static page sends one
///   frame per visit, so it becomes a short still clip; a redirect flash is dropped by its length, a page that never
///   painted by its frames.
public struct ClipRules: Sendable, Equatable {
  public static let idleSeconds: TimeInterval = 5
  public static let maxSeconds: TimeInterval = 180
  public static let minFrames = 1
  public static let minVisitSeconds: TimeInterval = 1

  public enum Input: Sendable {
    case tool(phase: BrowserSessionTable.Phase, at: Date)
    case navigated(target: String, url: String, at: Date)
    case pageOpened(target: String, url: String, adopted: Bool, at: Date)
    case pageClosed(target: String, at: Date)
    case frame(target: String, at: Date)
    case tick(at: Date)
    /// The connection dropped or came back: every clip ends, and the client is forgotten (a reconnect announces its pages
    /// and calls in flight again).
    case reset(at: Date)
  }

  public enum Output: Sendable, Equatable {
    case start(target: String, url: String)
    case finish(target: String, keep: Bool, endedAt: Date)
  }

  private struct Page: Equatable {
    let target: String
    var url: String
    var adopted: Bool
    /// Cut at the time limit: no new clip until the next tool start.
    var cut = false
    var clipStart: Date?
    var frames = 0
  }

  private struct Navigation: Equatable {
    let url: String
    let at: Date
  }

  /// Pages in the order they were opened (so outputs come in a stable order).
  private var pages: [Page] = []
  /// Navigations seen for a page `pageOpened` hasn't announced yet (the two arrive in either order).
  private var pendingNavigation: [String: Navigation] = [:]
  private var inFlight = 0
  private var lastToolEnd: Date?
  private var lastToolEvent: Date?
  /// Claude is working in the browser: a tool is in flight, or one ended less than `idleSeconds` ago.
  private var working = false

  public init() {}

  public mutating func step(_ input: Input) -> [Output] {
    var out: [Output] = []
    expire(at: Self.time(of: input), into: &out)
    switch input {
    case .tool(let phase, let at):
      switch phase {
      case .start:
        inFlight += 1
        lastToolEvent = at
        working = true
        for index in pages.indices { pages[index].cut = false }
        for index in pages.indices { startIfAllowed(index, at: at, into: &out) }
      case .end:
        inFlight = max(0, inFlight - 1)
        lastToolEnd = at
        lastToolEvent = at
      }
    case .navigated(let target, let url, let at):
      // A page we weren't told about yet keeps its latest URL until `pageOpened` arrives. That event says whether the
      // user opened the page, which a navigation can't.
      if let index = indexOf(target) {
        navigate(index, to: url, at: at, into: &out)
      } else {
        pendingNavigation[target] = Navigation(url: url, at: at)
      }
    case .pageOpened(let target, let url, let adopted, let at):
      if let index = indexOf(target) {
        pages[index].adopted = adopted
        navigate(index, to: url, at: at, into: &out)
      } else {
        var current = url
        if let pending = pendingNavigation.removeValue(forKey: target),
           pending.at > at || (!Self.recordable(url) && Self.recordable(pending.url)) {
          current = pending.url
        }
        pages.append(Page(target: target, url: current, adopted: adopted))
        startIfAllowed(pages.count - 1, at: at, into: &out)
      }
    case .pageClosed(let target, let at):
      pendingNavigation[target] = nil
      if let index = indexOf(target) {
        finish(index, at: at, into: &out)
        pages.remove(at: index)
      }
    case .frame(let target, _):
      if let index = indexOf(target), pages[index].clipStart != nil { pages[index].frames += 1 }
    case .tick:
      break
    case .reset(let at):
      for index in pages.indices { finish(index, at: at, into: &out) }
      pages = []
      pendingNavigation = [:]
      inFlight = 0
      lastToolEnd = nil
      lastToolEvent = nil
      working = false
    }
    return out
  }

  // MARK: Rules

  private mutating func expire(at now: Date, into out: inout [Output]) {
    // A tool call with no word for as long as a clip may last lost its end: it counts as finished then.
    if inFlight > 0, let last = lastToolEvent, now.timeIntervalSince(last) >= Self.maxSeconds {
      inFlight = 0
      lastToolEnd = last
    }
    if working, inFlight == 0, let end = lastToolEnd, now.timeIntervalSince(end) >= Self.idleSeconds {
      working = false
      let ended = end.addingTimeInterval(Self.idleSeconds)
      for index in pages.indices { finish(index, at: ended, into: &out) }
    }
    for index in pages.indices {
      if let start = pages[index].clipStart, now.timeIntervalSince(start) >= Self.maxSeconds {
        finish(index, at: now, into: &out)
        pages[index].cut = true
      }
    }
  }

  private mutating func navigate(_ index: Int, to url: String, at: Date, into out: inout [Output]) {
    let before = pages[index].url
    pages[index].url = url
    if pages[index].clipStart != nil, !Self.sameVisit(before, url) { finish(index, at: at, into: &out) }
    startIfAllowed(index, at: at, into: &out)
  }

  private mutating func startIfAllowed(_ index: Int, at: Date, into out: inout [Output]) {
    let page = pages[index]
    guard working, page.clipStart == nil, !page.adopted, !page.cut, Self.recordable(page.url) else {
      // A page that became the user's (or stopped being recordable) mid-clip ends there.
      if page.clipStart != nil, page.adopted || !Self.recordable(page.url) { finish(index, at: at, into: &out) }
      return
    }
    pages[index].clipStart = at
    pages[index].frames = 0
    out.append(.start(target: page.target, url: page.url))
  }

  private mutating func finish(_ index: Int, at ended: Date, into out: inout [Output]) {
    guard let start = pages[index].clipStart else { return }
    let endedAt = max(ended, start)
    let keep = pages[index].frames >= Self.minFrames && endedAt.timeIntervalSince(start) >= Self.minVisitSeconds
    out.append(.finish(target: pages[index].target, keep: keep, endedAt: endedAt))
    pages[index].clipStart = nil
    pages[index].frames = 0
  }

  private func indexOf(_ target: String) -> Int? { pages.firstIndex { $0.target == target } }

  private static func time(of input: Input) -> Date {
    switch input {
    case .tool(_, let at), .navigated(_, _, let at), .pageOpened(_, _, _, let at),
         .pageClosed(_, let at), .frame(_, let at), .tick(let at), .reset(let at):
      return at
    }
  }

  // MARK: URLs

  /// Only pages with content worth watching: `http`, `https` and `file`. Not `about:blank`, `chrome://`, `data:`.
  public static func recordable(_ url: String) -> Bool {
    let lower = url.lowercased()
    return ["http://", "https://", "file://"].contains { lower.hasPrefix($0) && lower.count > $0.count }
  }

  /// The same page: the URLs differ at most in the fragment (`#section`), which is a scroll, not a visit.
  public static func sameVisit(_ a: String, _ b: String) -> Bool {
    func withoutFragment(_ url: String) -> Substring { url.prefix { $0 != "#" } }
    return withoutFragment(a) == withoutFragment(b)
  }
}
