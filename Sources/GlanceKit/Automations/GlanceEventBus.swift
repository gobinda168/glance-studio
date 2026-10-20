import Foundation
import GlanceCore

/// Glance's in-process events (spec "Trigger sources", *event*): Meetings, Notifications, Tickets, the PR pages and
/// Journal publish; the automation engine subscribes for its event triggers. Handlers run on the main thread on the
/// next turn of the run loop, never inside the publisher's own call.
@MainActor
public final class GlanceEventBus {
  public static let shared = GlanceEventBus()

  public struct Token: Hashable, Sendable {
    let id: Int
  }

  private var next = 0
  private var handlers: [Int: (name: String, handler: @MainActor (GlanceEvent) -> Void)] = [:]

  public init() {}

  @discardableResult
  public func subscribe(_ name: String, _ handler: @escaping @MainActor (GlanceEvent) -> Void) -> Token {
    next += 1
    handlers[next] = (name, handler)
    return Token(id: next)
  }

  public func unsubscribe(_ token: Token) {
    handlers[token.id] = nil
  }

  public func publish(_ event: GlanceEvent) {
    let matching = handlers.sorted { $0.key < $1.key }.filter { $0.value.name == event.name }.map(\.value.handler)
    guard !matching.isEmpty else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { matching.forEach { $0(event) } }
    }
  }
}
