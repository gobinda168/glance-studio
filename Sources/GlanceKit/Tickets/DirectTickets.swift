import Combine
import Foundation
import GlanceCore

/// Tickets' second kind of source (spec 2026-10-12-connectors-design.md): Jira sites Glance itself is signed in to,
/// read and moved over REST. Studio sets `TicketService.direct`; GlanceKit can't see its Atlassian sessions.
@MainActor public protocol DirectTickets: AnyObject {
  /// One tracker per signed-in site with a Jira address.
  var trackers: [Tracker] { get }
  /// Fires after the sites or their sign-ins change.
  var changed: AnyPublisher<Void, Never> { get }
  func fetch(_ tracker: Tracker, query: String?) async -> Result<[Ticket], TicketFailure>
  /// The status the ticket is in now.
  func move(_ ticket: Ticket, to transition: Ticket.Transition, assignToMe: Bool, comment: String?) async
    -> Result<String?, TicketFailure>
  /// The Jira host a tracker covers, lowercased.
  func host(_ tracker: Tracker) -> String?
  /// The projects tickets can be created in (Ask Claude's "Create ticket").
  func projects(_ tracker: Tracker) async -> Result<[JiraREST.Project], TicketFailure>
  /// Creates a ticket; its key and its page.
  func create(_ tracker: Tracker, project: String, summary: String, description: String) async
    -> Result<CreatedTicket, TicketFailure>
}

public struct CreatedTicket: Equatable, Sendable {
  public let key: String
  public let url: URL?

  public init(key: String, url: URL?) {
    self.key = key
    self.url = url
  }
}

public extension DirectTickets {
  func projects(_ tracker: Tracker) async -> Result<[JiraREST.Project], TicketFailure> {
    .failure(TicketFailure(message: "This source can't create tickets."))
  }

  func create(_ tracker: Tracker, project: String, summary: String, description: String) async
    -> Result<CreatedTicket, TicketFailure> {
    .failure(TicketFailure(message: "This source can't create tickets."))
  }
}
