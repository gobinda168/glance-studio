import AppKit
import GlanceCore
import GlanceKit
import WebKit

/// Slack's own notifications become Notifications notices (spec 2026-10-09-notifications-design.md, "Sources →
/// Slack"). A document-start script in every frame of a workspace's page replaces `window.Notification` and
/// `ServiceWorkerRegistration.prototype.showNotification`: each notification Slack fires (only the ones its own
/// preferences allow) is posted to the `glanceNotice` message handler and kept in the page, so Open can later call its
/// `onclick` and Slack jumps to that conversation.
///
/// This replaces the `SlackNotifier` (macOS banners) the Chats spec (2026-10-09-chats-slack-design.md, S2) planned:
/// Slack's notifications land in the inbox and nudge from there instead.
///
/// Each `SlackSession` has its own `WKWebViewConfiguration` (`SlackSessions.configuration()`), so the script and the
/// handler go on that session's user content controller, once. Pop-ups a page opens share the controller; their
/// messages are dropped (only the session's own web view counts).
@MainActor
final class SlackNoticeBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "glanceNotice"
    /// Posted by `NoticeRouter` when a Slack notice is opened: `team`, and `id` (the page's notification id).
    static let clickName = Notification.Name("dev.glance.slackNoticeClick")

    /// Weak, so the user content controller (which keeps its handlers) doesn't keep the session alive.
    private weak var session: SlackSession?
    private static var clickObserver: NSObjectProtocol?

    private init(session: SlackSession) {
        self.session = session
    }

    /// Adds the script and the handler to `webView`'s controller (Chats only: Slack sessions exist only then). A
    /// controller that already has the handler is left as it is.
    static func install(on webView: WKWebView, session: SlackSession) {
        guard StudioFeatures.shared.isOn(.browser) else { return }
        let controller = webView.configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == script }) else { return }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(SlackNoticeBridge(session: session), name: handlerName)
        observeClicks()
    }

    // MARK: Notices

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let session, message.webView === session.webView, Self.isSlack(message.frameInfo) else { return }
        // Notices only while Notifications is on, and only from a workspace (not a sign-in page).
        guard StudioFeatures.shared.isOn(.notifications), let team = session.teamID,
              let payload = SlackNotices.Payload(message.body) else { return }
        NotificationHub.shared.post(SlackNotices.notice(payload, team: team, workspace: session.name, at: Date()))
        // Reply on Slack notices needs the Slack connector; this finds out once (it's kept for the run of the app).
        SlackMCPProbe.shared.check()
    }

    /// Slack's own pages only: another site's frame inside the page can't post notices.
    private static func isSlack(_ frame: WKFrameInfo) -> Bool {
        let origin = frame.securityOrigin
        return origin.protocol == "https" && (origin.host == "slack.com" || origin.host.hasSuffix(".slack.com"))
    }

    // MARK: Open

    /// Open on a Slack notice: `NoticeRouter` has brought the workspace's tab forward; the page's notification gets
    /// its click, so Slack opens that conversation. A notification from before the page last loaded is gone (the
    /// script returns false): the tab just shows where it was.
    private static func observeClicks() {
        guard clickObserver == nil else { return }
        clickObserver = NotificationCenter.default.addObserver(forName: clickName, object: nil, queue: .main) { note in
            let team = note.userInfo?["team"] as? String
            let id = note.userInfo?["id"] as? String
            MainActor.assumeIsolated {
                guard let team, let id, let session = SlackSessions.shared.session(teamID: team) else { return }
                // After the tab is on screen (the router opened it just before posting).
                let call = "void (window.__glanceNoticeClick && window.__glanceNoticeClick(\(jsString(id))))"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { session.webView.evaluateJavaScript(call, completionHandler: nil) }
                }
            }
        }
    }

    /// `text` as a JavaScript string literal.
    private static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let array = String(data: data, encoding: .utf8) else { return "''" }
        return String(array.dropFirst().dropLast())
    }

    // MARK: The page's side

    /// Runs before Slack's code in every frame. `new Notification(title, options)` and
    /// `registration.showNotification(title, options)` post `{id, title, body, tag, icon}`; the Notification objects
    /// are kept (the last 200) so `__glanceNoticeClick(id)` can call their `onclick` and dispatch `click`.
    static let script = #"""
    (() => {
      if (window.__glanceNotices) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.glanceNotice;
      if (!handler) return;
      const live = new Map();
      window.__glanceNotices = live;
      let n = 0;
      function post(title, options) {
        const id = 'g' + Date.now() + '-' + (n++);
        const o = options || {};
        handler.postMessage({ id, title: String(title || ''), body: String(o.body || ''), tag: o.tag ? String(o.tag) : null,
                              icon: o.icon ? String(o.icon) : null });
        return id;
      }
      class GlanceNotification extends EventTarget {
        constructor(title, options) {
          super();
          this.title = title; this.body = (options || {}).body || ''; this.tag = (options || {}).tag || '';
          this.data = (options || {}).data; this.onclick = null; this.onclose = null;
          this.__id = post(title, options); live.set(this.__id, this);
          if (live.size > 200) live.delete(live.keys().next().value);
        }
        close() { live.delete(this.__id); if (typeof this.onclose === 'function') try { this.onclose(); } catch (e) {} }
        static get permission() { return 'granted'; }
        static requestPermission(cb) { if (cb) cb('granted'); return Promise.resolve('granted'); }
      }
      window.Notification = GlanceNotification;
      if (window.ServiceWorkerRegistration) {
        ServiceWorkerRegistration.prototype.showNotification = function (title, options) { post(title, options); return Promise.resolve(); };
      }
      window.__glanceNoticeClick = (id) => {
        const item = live.get(id);
        if (!item) return false;
        const event = new Event('click');
        if (typeof item.onclick === 'function') try { item.onclick(event); } catch (e) {}
        item.dispatchEvent(event);
        return true;
      };
    })();
    """#
}
