import Foundation

/// Every setting Settings shows, for the side bar's search (spec 2026-10-08-settings-design.md, "Search"): the row's
/// id, its section, its name, and words people may look for it by.
public enum SettingsCatalog {
  public struct Entry: Equatable, Sendable, Identifiable {
    /// The row's id on its page: "<section>.<name>".
    public let id: String
    public let section: SettingsSection
    public let name: String
    public let keywords: [String]

    public init(id: String, section: SettingsSection, name: String, keywords: [String]) {
      self.id = id
      self.section = section
      self.name = name
      self.keywords = keywords
    }
  }

  public static let entries: [Entry] = [
    Entry(id: "account.signIn", section: .account, name: "Glance account",
          keywords: ["login", "log in", "sign in", "sign out", "apple", "github", "google", "cloud", "profile", "account"]),
    Entry(id: "general.terminal", section: .general, name: "Built-in terminal", keywords: ["windows", "dock", "tabs"]),
    Entry(id: "general.overlay", section: .general, name: "Overlay on other terminals",
          keywords: ["menu bar", "panel", "warp", "iterm", "global shortcuts"]),
    Entry(id: "general.home", section: .general, name: "Show Home at launch", keywords: ["start", "startup", "welcome"]),
    Entry(id: "general.claude", section: .general, name: "Open Claude Code at launch",
          keywords: ["start", "startup", "agent", "first tab"]),
    Entry(id: "general.claudeFolder", section: .general, name: "Claude Code folder",
          keywords: ["directory", "project", "working directory", "start"]),
    Entry(id: "general.summaries", section: .general, name: "Transcript summaries",
          keywords: ["summary", "summarize", "transcript", "tokens", "recap", "session"]),
    Entry(id: "general.responseStyle", section: .general, name: "Response style",
          keywords: ["humanize", "tone", "voice", "explainer", "output style", "plain language"]),
    Entry(id: "general.pullRequestsClaude", section: .general, name: "Claude reads pull requests on its own",
          keywords: ["review", "read", "drafts", "automatic", "pull requests"]),
    Entry(id: "general.updates", section: .general, name: "Updates", keywords: ["update", "check", "upgrade", "new version", "sparkle"]),
    Entry(id: "general.version", section: .general, name: "Version", keywords: ["build", "commit", "about"]),
    Entry(id: "terminal.font", section: .terminal, name: "Font family", keywords: ["typeface", "monospace"]),
    Entry(id: "terminal.size", section: .terminal, name: "Font size", keywords: ["text size", "zoom", "points"]),
    Entry(id: "terminal.theme", section: .terminal, name: "Theme",
          keywords: ["colors", "colours", "palette", "dark", "light"]),
    Entry(id: "terminal.cursor", section: .terminal, name: "Cursor", keywords: ["block", "bar", "underline", "caret"]),
    Entry(id: "terminal.blink", section: .terminal, name: "Blink", keywords: ["cursor", "blinking"]),
    Entry(id: "terminal.config", section: .terminal, name: "Open Config File", keywords: ["config", "preferences", "file"]),
    Entry(id: "suggestions.tab", section: .suggestions, name: "Tab menu",
          keywords: ["autocomplete", "completion", "intellisense", "tab", "zsh"]),
    Entry(id: "suggestions.ghost", section: .suggestions, name: "Ghost text",
          keywords: ["autosuggestions", "suggest", "grey", "inline", "fish"]),
    Entry(id: "suggestions.next", section: .suggestions, name: "Predict the next command",
          keywords: ["next command", "habit", "suggest", "follow-up"]),
    Entry(id: "suggestions.marks", section: .suggestions, name: "Error marks while typing",
          keywords: ["syntax", "highlight", "red", "unknown command", "typo", "quote"]),
    Entry(id: "suggestions.fixes", section: .suggestions, name: "Fixes after a failed command",
          keywords: ["correction", "typo", "thefuck", "did you mean", "error", "fix"]),
    Entry(id: "suggestions.claude", section: .suggestions, name: "Claude in the terminal",
          keywords: ["ai", "ask", "haiku", "natural language", "explain", "#", "command-i"]),
    Entry(id: "suggestions.up", section: .suggestions, name: "↑ history list",
          keywords: ["up arrow", "history", "previous command", "recent"]),
    Entry(id: "suggestions.search", section: .suggestions, name: "⌃R history search",
          keywords: ["ctrl-r", "control r", "reverse search", "find command", "history"]),
    Entry(id: "suggestions.record", section: .suggestions, name: "Record history",
          keywords: ["history", "commands", "privacy", "zsh_history"]),
    Entry(id: "suggestions.import", section: .suggestions, name: "zsh history",
          keywords: ["import", "clear", "forget", "zsh_history", "history"]),
    Entry(id: "voice.voice", section: .voice, name: "Voice",
          keywords: ["speech", "narration", "read aloud", "tts", "elevenlabs", "minimax", "glance voice", "kokoro"]),
    Entry(id: "voice.elevenLabsKey", section: .voice, name: "ElevenLabs key", keywords: ["api key", "keychain"]),
    Entry(id: "voice.miniMaxKey", section: .voice, name: "MiniMax key", keywords: ["api key", "keychain"]),
    Entry(id: "voice.list", section: .voice, name: "Voices", keywords: ["sample", "speaker"]),
    Entry(id: "voice.model", section: .voice, name: "Model", keywords: ["quality", "latency", "usage"]),
    Entry(id: "voice.preview", section: .voice, name: "Preview", keywords: ["sample", "listen"]),
    Entry(id: "voice.fallback", section: .voice, name: "Glance Voice fallback", keywords: ["offline", "on-device", "kokoro"]),
    Entry(id: "voice.macVoice", section: .voice, name: "Mac voice", keywords: ["system voice", "premium"]),
    Entry(id: "dictation.enabled", section: .dictation, name: "Hold fn to dictate",
          keywords: ["mic", "speech to text", "voice typing"]),
    Entry(id: "dictation.microphone", section: .dictation, name: "Microphone", keywords: ["permission", "privacy"]),
    Entry(id: "dictation.accessibility", section: .dictation, name: "Accessibility",
          keywords: ["permission", "privacy", "typing"]),
    Entry(id: "editor.kind", section: .editor, name: "Editor tab", keywords: ["razor code", "gs code", "vs code", "monaco"]),
    Entry(id: "editor.formatOnSave", section: .editor, name: "Format on save", keywords: ["prettier", "formatter"]),
    Entry(id: "overlay.terminals", section: .overlay, name: "Show Glance over terminals", keywords: ["warp", "iterm", "panel"]),
    Entry(id: "overlay.editors", section: .overlay, name: "Show Glance over code editors",
          keywords: ["vs code", "cursor", "zed", "orb"]),
    Entry(id: "meetings.enabled", section: .meetings, name: "Meeting nudges",
          keywords: ["calendar", "meeting", "join", "zoom", "google meet", "teams", "reminder", "call"]),
    Entry(id: "meetings.access", section: .meetings, name: "Calendar access", keywords: ["permission", "privacy", "calendar"]),
    Entry(id: "meetings.calendars", section: .meetings, name: "Calendars",
          keywords: ["google", "workspace", "accounts", "calendar"]),
    Entry(id: "meetings.google", section: .meetings, name: "Google Calendar",
          keywords: ["google", "sign in", "rsvp", "decline", "account", "oauth"]),
    Entry(id: "meetings.speak", section: .meetings, name: "Say it out loud",
          keywords: ["voice", "speak", "announce", "read aloud", "hey"]),
    Entry(id: "meetings.sound", section: .meetings, name: "Play a sound", keywords: ["sound", "chime", "alert"]),
    Entry(id: "meetings.test", section: .meetings, name: "Show a test nudge",
          keywords: ["test", "preview", "try", "demo", "example"]),
    Entry(id: "meetings.notesModel", section: .meetings, name: "Transcription model",
          keywords: ["meeting notes", "transcribe", "transcript", "parakeet", "download", "speech to text"]),
    Entry(id: "meetings.notesOffer", section: .meetings, name: "Join & Record",
          keywords: ["record", "meeting notes", "nudge", "notes"]),
    Entry(id: "meetings.notesCalls", section: .meetings, name: "Offer to record calls",
          keywords: ["call", "zoom", "teams", "slack", "huddle", "facetime", "detect", "meeting notes"]),
    Entry(id: "meetings.notesKeepAudio", section: .meetings, name: "Keep recordings",
          keywords: ["audio", "recording", "delete", "privacy", "meeting notes"]),
    Entry(id: "browser.search", section: .browser, name: "Search engine",
          keywords: ["search", "address bar", "duckduckgo", "google", "bing", "kagi", "browser"]),
    Entry(id: "browser.devServers", section: .browser, name: "Open dev servers in Glance Browser",
          keywords: ["dev server", "localhost", "vite", "npm run dev", "browser env", "external browser", "default browser",
                     "links", "terminal"]),
    Entry(id: "browser.history", section: .browser, name: "History",
          keywords: ["history", "clear", "privacy", "visited", "browser"]),
    Entry(id: "browser.siteData", section: .browser, name: "Site data",
          keywords: ["cookies", "cache", "storage", "sign out", "clear", "privacy", "browser"]),
    Entry(id: "browser.jira", section: .browser, name: "Jira and Confluence sites",
          keywords: ["jira", "confluence", "atlassian"]),
    Entry(id: "connectors.claude", section: .connectors, name: "Atlassian through Claude",
          keywords: ["mcp", "connector", "claude.ai", "jira", "confluence", "atlassian", "rovo"]),
    Entry(id: "connectors.sites", section: .connectors, name: "Jira and Confluence sites",
          keywords: ["jira", "confluence", "atlassian", "cloud", "data center", "sign in", "site", "wiki", "glance"]),
    Entry(id: "connectors.token", section: .connectors, name: "Personal token",
          keywords: ["api token", "personal access token", "pat", "sign in", "keychain", "jira", "confluence"]),
    Entry(id: "connectors.others", section: .connectors, name: "Other connectors",
          keywords: ["mcp", "connector", "claude.ai", "linear", "github", "slack"]),
    Entry(id: "notifications.nudge", section: .notifications, name: "Nudge me for",
          keywords: ["nudge", "alert", "slack", "github", "claude", "dm", "mention", "review"]),
    Entry(id: "notifications.vips", section: .notifications, name: "Always nudge for", keywords: ["vip", "people", "channel"]),
    Entry(id: "notifications.dnd", section: .notifications, name: "Do not disturb", keywords: ["quiet", "focus", "mute"]),
    Entry(id: "notifications.meetings", section: .notifications, name: "Quiet during meetings", keywords: ["quiet", "calendar"]),
    Entry(id: "notifications.sound", section: .notifications, name: "Play a sound", keywords: ["sound", "chime"]),
    Entry(id: "notifications.slack", section: .notifications, name: "Slack replies", keywords: ["slack", "mcp", "connector", "reply"]),
    Entry(id: "notifications.github", section: .notifications, name: "GitHub", keywords: ["github", "gh", "sign in"]),
    Entry(id: "orbChannel.enabled", section: .orbChannel, name: "Claude sessions can reach you",
          keywords: ["mcp", "orb", "channel", "nudge", "ask", "claude code", "setup"]),
    Entry(id: "orbChannel.launchFlag", section: .orbChannel, name: "Start Claude with its channel",
          keywords: ["channel", "launch", "flag", "development", "message sessions"]),
    Entry(id: "orbChannel.speech", section: .orbChannel, name: "Sessions speaking aloud",
          keywords: ["speak", "voice", "read aloud", "questions", "quiet"]),
    Entry(id: "orbChannel.approvals", section: .orbChannel, name: "Approvals from the orb",
          keywords: ["approve", "permission", "allow", "deny", "tools"]),
    Entry(id: "orbChannel.needsYou", section: .orbChannel, name: "When Claude needs you",
          keywords: ["permission", "question", "plan", "glow", "auto open", "card", "orb", "input", "waiting"]),
    Entry(id: "orbChannel.voice", section: .orbChannel, name: "Voice answers",
          keywords: ["fn", "speech to text", "parakeet", "transcription", "model", "download", "microphone"]),
    Entry(id: "orbChannel.assistant", section: .orbChannel, name: "Orb assistant",
          keywords: ["assistant", "talk", "siri", "hotkey", "control", "ask glance"]),
    Entry(id: "orbChannel.sessions", section: .orbChannel, name: "Connected sessions",
          keywords: ["sessions", "connected", "terminals", "status"]),
    Entry(id: "secrets.list", section: .secrets, name: "Secrets",
          keywords: ["token", "api key", "credential", "password", "vault", "keychain", "env", "bearer"]),
    Entry(id: "secrets.recent", section: .secrets, name: "Recent use", keywords: ["activity", "log", "requests"]),
    Entry(id: "tickets.trackers", section: .tickets, name: "Trackers",
          keywords: ["jira", "linear", "github", "issues", "connector", "mcp", "query", "jql"]),
    Entry(id: "tickets.ranking", section: .tickets, name: "Daily order",
          keywords: ["rank", "priority", "severity", "prompt", "order", "sort"]),
    Entry(id: "tickets.status", section: .tickets, name: "Status updates",
          keywords: ["auto", "nudge", "status", "move", "transition", "commit", "pull request", "stale", "comment"]),
    Entry(id: "tickets.daily", section: .tickets, name: "Morning and check-in",
          keywords: ["morning", "top 3", "check-in", "evening", "read aloud", "voice"]),
    Entry(id: "journal.enabled", section: .journal, name: "Journaling",
          keywords: ["journal", "diary", "recap", "log", "accomplishments", "daily", "career", "brag"]),
    Entry(id: "journal.sources", section: .journal, name: "Sources",
          keywords: ["claude", "git", "github", "calendar", "terminal", "privacy", "collect"]),
    Entry(id: "journal.wrapUp", section: .journal, name: "Wrap up my day",
          keywords: ["recap", "time", "evening", "end of day", "schedule"]),
    Entry(id: "journal.export", section: .journal, name: "Export",
          keywords: ["json", "markdown", "backup", "download", "portfolio"]),
    Entry(id: "journal.delete", section: .journal, name: "Delete all journal data",
          keywords: ["erase", "remove", "privacy", "clear", "reset"]),
  ]

  /// What the side bar lists for `text`: names with a word starting with it first, then names containing it, then
  /// keyword matches; each setting once, in catalog order within a tier, at most 12. Blank text finds nothing.
  public static func search(_ text: String) -> [Entry] {
    let query = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return [] }
    func wordStarts(_ entry: Entry) -> Bool {
      let name = entry.name.lowercased()
      return name.hasPrefix(query)
        || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(query) }
    }
    let starts = entries.filter(wordStarts)
    let contains = entries.filter { !wordStarts($0) && $0.name.lowercased().contains(query) }
    let keywords = entries.filter { entry in
      !entry.name.lowercased().contains(query) && entry.keywords.contains { $0.contains(query) }
    }
    return Array((starts + contains + keywords).prefix(12))
  }
}
