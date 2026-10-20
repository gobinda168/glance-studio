import Combine
import Foundation
import GlanceCore
import GlanceKit

/// Tickets' Glance source (spec 2026-10-12-connectors-design.md, "Studio's side"): each signed-in Atlassian site
/// with Jira, read and moved over Jira's REST API with the tabs' session or the site's token.
@MainActor
final class JiraDirectTickets: DirectTickets {
    static let shared = JiraDirectTickets()

    private let sessions = AtlassianSessions.shared
    /// Site id → its Sprint field (nil: looked up, there's none). Asked once per site per run of Studio.
    private var sprintFields: [String: String?] = [:]

    var trackers: [Tracker] {
        sessions.store.sites.filter { site in
            guard site.has(.jira), case .signedIn = sessions.signIn(site.id) else { return false }
            return true
        }.map { Tracker.glance(site: $0.id, name: $0.name) }
    }

    var changed: AnyPublisher<Void, Never> {
        sessions.$store.map { _ in () }.merge(with: sessions.$signIns.map { _ in () }).dropFirst(2).eraseToAnyPublisher()
    }

    func host(_ tracker: Tracker) -> String? {
        site(tracker.server)?.jiraURL?.host?.lowercased()
    }

    private func site(_ server: String) -> AtlassianSite? {
        Tracker.siteID(fromServer: server).flatMap { sessions.store.site(id: $0) }
    }

    func fetch(_ tracker: Tracker, query: String?) async -> Result<[Ticket], TicketFailure> {
        guard let site = site(tracker.server) else { return .failure(TicketFailure(message: "That Jira site was removed.")) }
        let credential = sessions.credential(for: site)
        let send = sessions.send
        let field = await sprintField(site, credential: credential, send: send)
        let searches: [(String, Ticket.Group)] = query.map { [($0, .query)] }
            ?? [(JiraREST.assignedJQL, .assigned), (JiraREST.upNextJQL, .upNext)]
        var lists: [[Ticket]] = []
        for (jql, group) in searches {
            guard let request = JiraREST.searchRequest(site, jql: jql, sprintField: field, credential: credential) else {
                return .failure(TicketFailure(message: "\(site.name) has no Jira address."))
            }
            let answer: (Data, Int)
            do { answer = try await send(request) } catch { return .failure(unreachable(site)) }
            // A Jira without sprints (no Jira Software) rejects openSprints(): Up next is just empty.
            if answer.1 == 400 && group == .upNext { continue }
            guard answer.1 == 200,
                  let tickets = JiraREST.tickets(answer.0, site: site, tracker: tracker.server, group: group,
                                                 sprintField: field) else {
                if answer.1 == 401 { sessions.signedOut(site.id) }
                return .failure(JiraREST.failure(status: answer.1, data: answer.0, site: site, key: nil))
            }
            lists.append(tickets)
        }
        return .success(JiraREST.merged(lists))
    }

    func move(_ ticket: Ticket, to transition: Ticket.Transition, assignToMe: Bool, comment: String?) async
        -> Result<String?, TicketFailure> {
        guard let site = site(ticket.tracker) else { return .failure(TicketFailure(message: "That Jira site was removed.")) }
        let credential = sessions.credential(for: site)
        let send = sessions.send
        if assignToMe {
            guard let user = site.user,
                  let request = JiraREST.assignRequest(site, key: ticket.key, user: user, credential: credential) else {
                return .failure(TicketFailure(message: "Glance doesn't know who you are on \(site.name) yet. Sign in again."))
            }
            if let failure = await call(request, site: site, key: ticket.key, send: send) { return .failure(failure) }
        }
        guard let request = JiraREST.transitionRequest(site, key: ticket.key, transitionID: transition.id,
                                                       credential: credential) else {
            return .failure(TicketFailure(message: "\(site.name) has no Jira address."))
        }
        if let failure = await call(request, site: site, key: ticket.key, send: send) { return .failure(failure) }
        // The move stands even if its comment doesn't land.
        if let comment, let request = JiraREST.commentRequest(site, key: ticket.key, body: comment, credential: credential) {
            _ = await call(request, site: site, key: ticket.key, send: send)
        }
        return .success(transition.name)
    }

    func projects(_ tracker: Tracker) async -> Result<[JiraREST.Project], TicketFailure> {
        guard let site = site(tracker.server) else { return .failure(TicketFailure(message: "That Jira site was removed.")) }
        guard let request = JiraREST.projectsRequest(site, credential: sessions.credential(for: site)) else {
            return .failure(TicketFailure(message: "\(site.name) has no Jira address."))
        }
        do {
            let (data, status) = try await sessions.send(request)
            guard status == 200, let projects = JiraREST.projects(data) else {
                if status == 401 { sessions.signedOut(site.id) }
                return .failure(JiraREST.failure(status: status, data: data, site: site, key: nil))
            }
            return .success(projects)
        } catch {
            return .failure(unreachable(site))
        }
    }

    func create(_ tracker: Tracker, project: String, summary: String, description: String) async
        -> Result<CreatedTicket, TicketFailure> {
        guard let site = site(tracker.server) else { return .failure(TicketFailure(message: "That Jira site was removed.")) }
        let credential = sessions.credential(for: site)
        let send = sessions.send
        guard let lookup = JiraREST.projectRequest(site, key: project, credential: credential) else {
            return .failure(TicketFailure(message: "\(site.name) has no Jira address."))
        }
        do {
            let (found, status) = try await send(lookup)
            guard status == 200 else {
                if status == 401 { sessions.signedOut(site.id) }
                return .failure(JiraREST.failure(status: status, data: found, site: site, key: nil))
            }
            let type = JiraREST.issueType(inProject: found) ?? "Task"
            guard let request = JiraREST.createRequest(site, project: project, issueType: type, summary: summary,
                                                       description: description, credential: credential) else {
                return .failure(TicketFailure(message: "\(site.name) has no Jira address."))
            }
            let (data, createStatus) = try await send(request)
            guard (200..<300).contains(createStatus), let key = JiraREST.createdKey(data) else {
                if createStatus == 401 { sessions.signedOut(site.id) }
                return .failure(JiraREST.failure(status: createStatus, data: data, site: site, key: nil))
            }
            return .success(CreatedTicket(key: key, url: JiraREST.browseURL(site, key: key)))
        } catch {
            return .failure(unreachable(site))
        }
    }

    /// A write: nil when Jira took it (2xx), else what went wrong.
    private func call(_ request: URLRequest, site: AtlassianSite, key: String, send: AtlassianAPI.Send) async
        -> TicketFailure? {
        do {
            let (data, status) = try await send(request)
            if (200..<300).contains(status) { return nil }
            if status == 401 { sessions.signedOut(site.id) }
            return JiraREST.failure(status: status, data: data, site: site, key: key)
        } catch {
            return unreachable(site)
        }
    }

    private func sprintField(_ site: AtlassianSite, credential: AtlassianAPI.Credential,
                             send: AtlassianAPI.Send) async -> String? {
        if let known = sprintFields[site.id] { return known }
        guard let request = JiraREST.fieldsRequest(site, credential: credential),
              let (data, status) = try? await send(request), status == 200 else { return nil }
        let field = JiraREST.sprintField(data)
        sprintFields[site.id] = .some(field)
        return field
    }

    private func unreachable(_ site: AtlassianSite) -> TicketFailure {
        TicketFailure(message: "Couldn't reach \(site.jiraURL?.host ?? site.name).")
    }
}
