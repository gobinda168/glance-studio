import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Settings → Secrets (spec 2026-10-10-secrets-broker-design.md; built from the signed-off replica,
/// design-system/glance/prototype/secrets.js): the secrets, or the locked or failed vault, and Recent use. Rows carry
/// no values; the only value this page ever holds is one the editor reveals, in a panel of its own.
struct SecretsSettings: View {
    @StateObject private var model = SecretsModel()
    @State private var editing: SecretEditTarget?
    /// The row whose Edit is loading its draft.
    @State private var opening: UUID?
    @State private var unlocking = false
    @State private var resetting = false
    @State private var hostWindow: NSWindow?
    /// The page's window height, so the editor sheet's form fits under it with Save showing.
    @State private var windowHeight: CGFloat = 900

    static let recentShown = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Your secrets") { yours }
            SettingsGroup(title: "Recent use") {
                SecretsRecentUse(activity: Array(model.recent.prefix(Self.recentShown)))
            }
        }
        .background(WindowAccessor { window in
            DispatchQueue.main.async {
                hostWindow = window
                if let window { windowHeight = window.frame.height }
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            windowHeight = window.frame.height
        }
        .onAppear { model.reload() }
        // A Claude call may have unlocked the vault (or a sleep locked it) while another window was in front.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard hostWindow == nil || (note.object as? NSWindow) === hostWindow else { return }
            model.reload()
        }
        .sheet(item: $editing) { target in
            SecretEditorSheet(target: target, model: model, formHeight: SecretEditorSheet.formHeight(in: windowHeight)) {
                editing = nil
            }
        }
    }

    // MARK: Your secrets

    @ViewBuilder private var yours: some View {
        if model.locked {
            if let problem = model.problem { failedRow(problem) } else { lockedRow }
        } else {
            SettingsRow(id: "secrets.list", name: "Unlocked until your Mac sleeps",
                        detail: model.rows.isEmpty ? Self.emptyLine : Self.introLine, light: true) {
                StudioButton(title: "Add a secret", icon: .plus, style: .primary) { editing = .new }
            }
            ForEach(model.rows) { row in
                SecretRowView(row: row, opening: opening == row.id) { edit(row.id) }
            }
        }
    }

    static let introLine = "Claude can use these through Glance, but never sees them. Each is sent only to its hosts, "
        + "in its one header."
    static let emptyLine = "No secrets yet. Add a token, like a GitHub or Stripe key, and Claude can call that API "
        + "through Glance: Glance puts the token in the request on its way out, so Claude never sees it, and sends it "
        + "only to the hosts you list."

    private var lockedRow: some View {
        SecretsRowShell(id: "secrets.list") {
            HStack(alignment: .center, spacing: 14) {
                SecretsLockTile(failed: false)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your secrets are locked.")
                        .font(.studio(13, .medium))
                        .foregroundStyle(StudioColors.ink)
                    Text("Touch ID opens them until your Mac sleeps, its screen locks or Studio quits. If Claude needs "
                        + "one first, Studio asks then.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SecretsButton(title: "Unlock with Touch ID", symbol: "touchid", style: .primary, busy: unlocking) {
                    unlock()
                }
                .fixedSize()
            }
        }
    }

    private func failedRow(_ problem: String) -> some View {
        SecretsRowShell(id: "secrets.list") {
            HStack(alignment: .center, spacing: 14) {
                SecretsLockTile(failed: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(problem)
                        .font(.studio(13, .medium))
                        .foregroundStyle(StudioColors.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    // The model's problem covers a cancelled Touch ID too, so this doesn't claim they're lost.
                    Text("If they can't be opened any more, for example after your fingerprints changed, Reset "
                        + "deletes them and you add your tokens again.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    SecretsButton(title: "Try Again", symbol: "touchid", busy: unlocking, enabled: !resetting) {
                        unlock()
                    }
                    SecretsButton(title: "Reset secrets…", style: .danger, busy: resetting, enabled: !unlocking) {
                        confirmReset()
                    }
                }
                .fixedSize()
            }
        }
    }

    // MARK: Actions

    private func unlock() {
        guard !unlocking else { return }
        unlocking = true
        Task { @MainActor in
            await model.unlock()
            unlocking = false
        }
    }

    /// The draft holds no value, so opening asks nothing; a save that changes the value or a rule asks then.
    private func edit(_ id: UUID) {
        guard opening == nil, editing == nil else { return }
        opening = id
        Task { @MainActor in
            defer { opening = nil }
            if let draft = await model.draft(for: id) {
                editing = .existing(id, draft)
            } else {
                model.reload()
            }
        }
    }

    private func confirmReset() {
        guard !resetting else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete every saved secret?"
        alert.informativeText = "Use this only when your secrets can't be unlocked, for example after your "
            + "fingerprints changed. You'll add your tokens again."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        resetting = true
        Task { @MainActor in
            await model.reset()
            resetting = false
        }
    }
}

/// What the editor sheet opens on.
enum SecretEditTarget: Identifiable {
    case new
    /// The secret's id and its fields (the value left empty).
    case existing(UUID, SecretDraft)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let id, _): id.uuidString
        }
    }
}

/// The page's words for the three approvals.
enum SecretsCopy {
    /// The editor's radio labels (the `always` one is the spec's copy, verbatim).
    static func choice(_ approval: SecretApproval) -> String {
        switch approval {
        case .everyTime: "Ask every time"
        case .oncePerSession: "Ask once per Claude session"
        case .always: "Always: any Claude session in these folders, without asking."
        }
    }

    /// A row's badge.
    static func badge(_ approval: SecretApproval) -> String {
        switch approval {
        case .everyTime: "Every time"
        case .oncePerSession: "Once per session"
        case .always: "Always"
        }
    }

    /// "~/Code/acme" for a folder in the home folder.
    static func folder(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// The header a slot fills, the value masked: a row's "sent as" and the editor's live preview. Basic shows the
    /// formula, not base64 of a mask (that would be meaningless).
    static func header(_ slot: SecretSlot) -> (name: String, value: String) {
        switch slot {
        case .bearer:
            return ("Authorization", "Bearer ••••")
        case .header(let name, let prefix):
            return (name.isEmpty ? "X-API-Key" : name, prefix + "••••")
        case .basic(let username):
            return ("Authorization", "Basic base64(\(username.isEmpty ? "username" : username):••••)")
        }
    }
}

// MARK: - Rows

/// A Settings row that isn't name-and-control: the same padding, hairline and search flash as `SettingsRow`.
struct SecretsRowShell<Content: View>: View {
    let id: String
    var verticalPadding: CGFloat = 12
    @ViewBuilder let content: Content
    @Environment(\.settingsFlash) private var flash

    var body: some View {
        content
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StudioColors.selection)
                .padding(.horizontal, -8)
                .opacity(flash == id ? 1 : 0))
            .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
            .id(id)
    }
}

/// The locked vault's 36pt tile; red when it failed to open.
private struct SecretsLockTile: View {
    let failed: Bool

    var body: some View {
        StudioIcon(.lock, size: 16)
            .foregroundStyle(failed ? StudioColors.danger : StudioColors.body)
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(failed ? StudioColors.dangerFill : StudioColors.field))
            .accessibilityHidden(true)
    }
}

/// One secret: name and note; its hosts and the header it fills; where and how much it's used; its approval and Edit.
private struct SecretRowView: View {
    let row: SecretsModel.Row
    let opening: Bool
    let edit: () -> Void

    var body: some View {
        SecretsRowShell(id: "secrets.item.\(row.name)", verticalPadding: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(row.name)
                            .font(.studioMono(13, .semibold))
                            .foregroundStyle(StudioColors.ink)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if !row.note.isEmpty {
                            Text(row.note)
                                .font(.studio(12.5))
                                .foregroundStyle(StudioColors.muted)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    FlowRow(spacing: 6) {
                        ForEach(row.hosts, id: \.self) { host in
                            Text(host)
                                .font(.studioMono(11.5))
                                .foregroundStyle(StudioColors.body)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                        }
                        sentAs.padding(.leading, 4)
                    }
                    HStack(spacing: 6) {
                        StudioIcon(.folder, size: 12).foregroundStyle(StudioColors.muted)
                        Text(meta)
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SecretsApprovalBadge(approval: row.approval)
                StudioButton(title: "Edit", busy: opening, height: 28, action: edit)
                    .fixedSize()
                    .help("Saving a change to the value or a rule asks for Touch ID")
                    .accessibilityLabel("Edit \(row.name)")
            }
        }
    }

    private var sentAs: some View {
        let header = SecretsCopy.header(row.slot)
        return HStack(spacing: 6) {
            Text("sent as").font(.studio(12)).foregroundStyle(StudioColors.muted)
            Text("\(header.name): \(header.value)")
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.body)
                .lineLimit(1)
        }
        .frame(height: 22)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        let place = row.folders.isEmpty ? "Any folder" : row.folders.map(SecretsCopy.folder).joined(separator: ", ")
        guard row.uses > 0 else { return "\(place) · Not used yet" }
        let when = row.lastUsed.map { " \(StudioTime.ago($0))" } ?? ""
        return "\(place) · Last used\(when) · \(row.uses) request\(row.uses == 1 ? "" : "s")"
    }
}

/// The approval as a 22pt capsule: outlined for the two that ask, amber for Always (it never asks).
private struct SecretsApprovalBadge: View {
    let approval: SecretApproval

    var body: some View {
        let always = approval == .always
        Text(SecretsCopy.badge(approval))
            .font(.studio(11.5, .medium))
            .foregroundStyle(always ? StudioColors.amber : StudioColors.body)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(always ? StudioColors.amberFill : .clear))
            .overlay { if !always { Capsule().strokeBorder(StudioColors.line3, lineWidth: 1) } }
            .fixedSize()
            .help(SecretsCopy.choice(approval))
            .accessibilityLabel("Approval: \(SecretsCopy.choice(approval))")
    }
}

// MARK: - Recent use

/// Every request Claude made with a secret, newest first, in a bordered list: time, session, secret, request, outcome.
private struct SecretsRecentUse: View {
    let activity: [SecretActivity]

    var body: some View {
        SecretsRowShell(id: "secrets.recent") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Every request Claude made with a secret, newest first. A value is never written down.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if activity.isEmpty {
                    Text("Nothing yet.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(activity.enumerated()), id: \.offset) { index, entry in
                            line(entry)
                                .overlay(alignment: .top) {
                                    if index > 0 { Rectangle().fill(StudioColors.line2).frame(height: 1) }
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StudioColors.line, lineWidth: 1))
                }
            }
        }
    }

    private func line(_ entry: SecretActivity) -> some View {
        HStack(spacing: 12) {
            Text(Self.time(entry.date))
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.muted)
                .frame(width: 44, alignment: .leading)
            Text(entry.session)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .frame(width: 84, alignment: .leading)
            Text(entry.secret)
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.body)
                .frame(width: 128, alignment: .leading)
            (Text(entry.method).fontWeight(.semibold).foregroundColor(StudioColors.ink)
                + Text(" \(entry.host)").foregroundColor(StudioColors.body)
                + Text(entry.path).foregroundColor(StudioColors.muted))
                .font(.studioMono(11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.outcome)
                .font(.studioMono(11.5, .semibold))
                .foregroundStyle(Self.tone(entry.outcome))
                .frame(maxWidth: 160, alignment: .trailing)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .accessibilityElement(children: .combine)
    }

    /// Green for a 2xx answer, red for one Glance didn't send (denied, refused, failed).
    static func tone(_ outcome: String) -> Color {
        if let code = Int(outcome) { return (200..<300).contains(code) ? StudioColors.ok : StudioColors.body }
        if outcome.hasPrefix("denied") || outcome.hasPrefix("refused") || outcome.hasPrefix("failed") {
            return StudioColors.danger
        }
        return StudioColors.muted
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jjmm")
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    /// "14:32" today, else "12 Oct".
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clock.string(from: date) : day.string(from: date)
    }
}

// MARK: - Buttons

/// `StudioButton`'s look plus what Secrets needs: an SF Symbol (`touchid` marks every control that asks for Touch ID)
/// and a danger style (Reset, Delete): danger text, a 45% danger edge, the danger tint on hover.
struct SecretsButton: View {
    enum Style { case primary, secondary, danger }

    let title: String
    var symbol: String?
    var style: Style = .secondary
    var busy = false
    var enabled = true
    var height: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .regular)).accessibilityHidden(true)
                }
                Text(title)
                    .font(.studio(12, style == .primary ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay {
                switch style {
                case .primary: EmptyView()
                case .secondary:
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1)
                case .danger:
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(StudioColors.danger.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch style {
        case .primary: StudioColors.onCoral
        case .secondary: StudioColors.ink
        case .danger: StudioColors.danger
        }
    }

    private var fill: Color {
        let lit = hovering && enabled && !busy
        switch style {
        case .primary: return lit ? StudioColors.coralHover : StudioColors.coral
        case .secondary: return lit ? StudioColors.hover : .clear
        case .danger: return lit ? StudioColors.dangerFill : .clear
        }
    }
}
