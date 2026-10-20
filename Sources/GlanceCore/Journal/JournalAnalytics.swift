import Foundation

/// One day's time (spec 2026-10-09-journal-design.md, "Analytics math").
public struct JournalDayActivity: Equatable, Sendable {
  public let day: JournalDay
  /// Everything timed, overlaps counted once: Claude sessions, terminal runs, each commit's last five minutes.
  public let activeMinutes: Int
  /// Active time outside meetings.
  public let focusMinutes: Int
  public let meetingMinutes: Int
  /// Each project's own active time outside meetings ("time touched": projects can overlap).
  public let projectMinutes: [String: Int]
  /// Active minutes in each hour of the day, 0–23.
  public let hourMinutes: [Int]

  public init(day: JournalDay, activeMinutes: Int, focusMinutes: Int, meetingMinutes: Int,
              projectMinutes: [String: Int], hourMinutes: [Int]) {
    self.day = day
    self.activeMinutes = activeMinutes
    self.focusMinutes = focusMinutes
    self.meetingMinutes = meetingMinutes
    self.projectMinutes = projectMinutes
    self.hourMinutes = hourMinutes
  }

  public static func empty(_ day: JournalDay) -> JournalDayActivity {
    JournalDayActivity(day: day, activeMinutes: 0, focusMinutes: 0, meetingMinutes: 0, projectMinutes: [:],
                       hourMinutes: Array(repeating: 0, count: 24))
  }
}

/// A square of the year grid.
public struct JournalGridCell: Equatable, Sendable {
  public let day: JournalDay
  public let minutes: Int
  /// 0 (nothing) to 4 (five hours or more).
  public let level: Int
  public let isFuture: Bool
}

/// A named amount: a project's minutes, a skill's entries.
public struct JournalAmount: Equatable, Sendable {
  public let name: String
  public let value: Int

  public init(name: String, value: Int) {
    self.name = name
    self.value = value
  }
}

public struct JournalWeek: Equatable, Sendable {
  public let start: JournalDay
  /// The range's top projects (keys), then "Other".
  public let projects: [JournalAmount]
  public let focusMinutes: Int
  public let meetingMinutes: Int
}

public struct JournalOutputWeek: Equatable, Sendable {
  public let start: JournalDay
  public let merged: Int
  public let reviews: Int
  public let commits: Int
  public let sessions: Int

  public init(start: JournalDay, merged: Int, reviews: Int, commits: Int, sessions: Int) {
    self.start = start
    self.merged = merged
    self.reviews = reviews
    self.commits = commits
    self.sessions = sessions
  }
}

public struct JournalSkillMonth: Equatable, Sendable {
  /// "2026-10".
  public let month: String
  public let skills: [JournalAmount]
}

/// A mark on the Journey timeline.
public struct JournalMilestone: Equatable, Sendable, Identifiable {
  public enum Kind: String, Sendable {
    case firstSkill, firstProject, streak, highlight, month
  }

  public let kind: Kind
  public let day: JournalDay
  public let title: String
  public let detail: String
  /// What it's about: the skill, the project, the entry id, the month.
  public let key: String

  public var id: String { kind.rawValue + ":" + key }
}

/// Everything the Insights board shows for one range.
public struct JournalInsights: Equatable, Sendable {
  public enum Range: String, CaseIterable, Sendable {
    case days30, quarter, year

    public var title: String {
      switch self {
      case .days30: "30 days"
      case .quarter: "Quarter"
      case .year: "Year"
      }
    }

    public var days: Int {
      switch self {
      case .days30: 30
      case .quarter: 91
      case .year: 365
      }
    }
  }

  public let range: Range
  /// The last 53 weeks, whatever the range.
  public let grid: [[JournalGridCell]]
  public let currentStreak: Int
  public let longestStreak: Int
  /// Calendar weekday (1 is Sunday) with the most active minutes on average, nil when nothing was active.
  public let busiestWeekday: Int?
  public let busiestHour: Int?
  public let weeks: [JournalWeek]
  public let focusMinutes: Int
  public let meetingMinutes: Int
  public let output: [JournalOutputWeek]
  /// Highlighted entries and entries with an impact, newest first.
  public let impact: [JournalEntry]
  public let skillMonths: [JournalSkillMonth]
  public let topSkills: [JournalAmount]
  /// All-time milestones, newest first.
  public let journey: [JournalMilestone]
  /// Days in the range with activity or an entry: the cards draw once there are 3.
  public let activeDays: Int
}

/// Journal's figures (spec "Analytics math"), all from stored data, no Claude call.
public enum JournalAnalytics {
  public static let commitMinutes: TimeInterval = 5 * 60

  public static func activity(day: JournalDay, events: [JournalEvent], terminal: [String: [JournalSpan]],
                              fallback: [String: Int], calendar: Calendar) -> JournalDayActivity {
    let bounds = day.interval(in: calendar)
    var byProject: [String: [JournalSpan]] = [:]
    var meetings: [JournalSpan] = []
    for event in events where event.day == day {
      switch event.source {
      case .claude:
        byProject[event.project ?? "", default: []] += event.detail.spans ?? []
      case .git:
        byProject[event.project ?? "", default: []].append(
          JournalSpan(start: event.start.addingTimeInterval(-commitMinutes), end: event.start))
      case .meeting:
        if let end = event.end { meetings.append(JournalSpan(start: event.start, end: end)) }
      case .pr, .review, .note:
        break
      }
    }
    for (project, spans) in terminal { byProject[project, default: []] += spans }
    byProject = byProject.mapValues { JournalSpans.clip($0, to: bounds) }
    meetings = JournalSpans.clip(meetings, to: bounds)
    let meetingMinutes = JournalSpans.minutes(meetings)
    let active = JournalSpans.union(byProject.values.flatMap { $0 })
    if active.isEmpty && !fallback.isEmpty {
      let total = fallback.values.reduce(0, +)
      return JournalDayActivity(day: day, activeMinutes: total, focusMinutes: max(0, total - meetingMinutes),
                                meetingMinutes: meetingMinutes, projectMinutes: fallback.filter { $0.value > 0 },
                                hourMinutes: Array(repeating: 0, count: 24))
    }
    var projects: [String: Int] = [:]
    for (project, spans) in byProject where !project.isEmpty {
      let minutes = JournalSpans.minutes(JournalSpans.subtract(spans, meetings))
      if minutes > 0 { projects[project] = minutes }
    }
    return JournalDayActivity(day: day, activeMinutes: JournalSpans.minutes(active),
                              focusMinutes: JournalSpans.minutes(JournalSpans.subtract(active, meetings)),
                              meetingMinutes: meetingMinutes, projectMinutes: projects,
                              hourMinutes: hours(active, calendar: calendar))
  }

  static func hours(_ spans: [JournalSpan], calendar: Calendar) -> [Int] {
    var seconds = Array(repeating: 0.0, count: 24)
    for span in spans {
      var start = span.start
      while start < span.end {
        let end = min(calendar.dateInterval(of: .hour, for: start)?.end ?? span.end, span.end)
        seconds[calendar.component(.hour, from: start)] += end.timeIntervalSince(start)
        start = end
      }
    }
    return seconds.map { Int(($0 / 60).rounded()) }
  }

  /// A day counts toward a streak with 15 active minutes or an entry.
  public static func qualifies(_ activity: JournalDayActivity?, entries: Int) -> Bool {
    (activity?.activeMinutes ?? 0) >= 15 || entries > 0
  }

  /// The run ending today (or yesterday, so an empty morning doesn't break it), and the longest run.
  public static func streaks(_ days: Set<JournalDay>, today: JournalDay,
                             calendar: Calendar) -> (current: Int, longest: Int) {
    var current = 0
    var day = days.contains(today) ? today : today.adding(days: -1, calendar: calendar)
    while days.contains(day) {
      current += 1
      day = day.adding(days: -1, calendar: calendar)
    }
    return (current, longestRun(days, calendar: calendar)?.length ?? 0)
  }

  static func longestRun(_ days: Set<JournalDay>,
                         calendar: Calendar) -> (start: JournalDay, end: JournalDay, length: Int)? {
    var best: (start: JournalDay, end: JournalDay, length: Int)?
    var start: JournalDay?
    var previous: JournalDay?
    var length = 0
    for day in days.sorted() {
      if let previous, previous.adding(days: 1, calendar: calendar) == day {
        length += 1
      } else {
        start = day
        length = 1
      }
      if length > best?.length ?? 0, let start { best = (start, day, length) }
      previous = day
    }
    return best
  }

  public static func level(minutes: Int) -> Int {
    switch minutes {
    case ..<1: 0
    case ..<60: 1
    case ..<180: 2
    case ..<300: 3
    default: 4
    }
  }

  /// `weeks` columns of seven days, the last holding today; days after today are future (blank).
  public static func grid(today: JournalDay, weeks: Int = 53, minutes: [JournalDay: Int],
                          calendar: Calendar) -> [[JournalGridCell]] {
    let first = weekStart(today, calendar: calendar).adding(days: -7 * (weeks - 1), calendar: calendar)
    var day = first
    var columns: [[JournalGridCell]] = []
    for _ in 0..<weeks {
      var column: [JournalGridCell] = []
      for _ in 0..<7 {
        let value = minutes[day] ?? 0
        column.append(JournalGridCell(day: day, minutes: value, level: day > today ? 0 : level(minutes: value),
                                      isFuture: day > today))
        day = day.adding(days: 1, calendar: calendar)
      }
      columns.append(column)
    }
    return columns
  }

  public static func weekStart(_ day: JournalDay, calendar: Calendar) -> JournalDay {
    let weekday = calendar.component(.weekday, from: day.start(in: calendar).addingTimeInterval(12 * 3600))
    return day.adding(days: -((weekday - calendar.firstWeekday + 7) % 7), calendar: calendar)
  }

  public static func busiest(_ activities: [JournalDayActivity], calendar: Calendar) -> (weekday: Int?, hour: Int?) {
    var totals: [Int: (minutes: Int, days: Int)] = [:]
    var hours = Array(repeating: 0, count: 24)
    for activity in activities {
      let weekday = calendar.component(.weekday, from: activity.day.start(in: calendar).addingTimeInterval(12 * 3600))
      totals[weekday, default: (0, 0)].minutes += activity.activeMinutes
      totals[weekday, default: (0, 0)].days += 1
      for hour in 0..<24 { hours[hour] += activity.hourMinutes[hour] }
    }
    var weekday: Int?
    var best = 0.0
    for day in 1...7 {
      guard let total = totals[day], total.minutes > 0 else { continue }
      let average = Double(total.minutes) / Double(total.days)
      if average > best {
        best = average
        weekday = day
      }
    }
    let most = hours.max() ?? 0
    return (weekday, most > 0 ? hours.firstIndex(of: most) : nil)
  }

  /// Minutes per project per week: the range's `top` projects by name, the rest as "Other" (last).
  public static func weeks(_ activities: [JournalDayActivity], top: Int = 6, calendar: Calendar) -> [JournalWeek] {
    var totals: [String: Int] = [:]
    for activity in activities {
      for (project, minutes) in activity.projectMinutes { totals[project, default: 0] += minutes }
    }
    let named = Set(totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(top)
      .map(\.key))
    let grouped = Dictionary(grouping: activities) { weekStart($0.day, calendar: calendar) }
    return grouped.keys.sorted().map { start in
      let days = grouped[start] ?? []
      var projects: [String: Int] = [:]
      for activity in days {
        for (project, minutes) in activity.projectMinutes {
          projects[named.contains(project) ? project : "Other", default: 0] += minutes
        }
      }
      let amounts = projects.map { JournalAmount(name: $0.key, value: $0.value) }.sorted { a, b in
        if (a.name == "Other") != (b.name == "Other") { return b.name == "Other" }
        return a.value != b.value ? a.value > b.value : a.name < b.name
      }
      return JournalWeek(start: start, projects: amounts, focusMinutes: days.reduce(0) { $0 + $1.focusMinutes },
                         meetingMinutes: days.reduce(0) { $0 + $1.meetingMinutes })
    }
  }

  /// Pull requests merged, reviews given, commits and Claude sessions for each of `weeks` (their first days).
  public static func output(_ events: [JournalEvent], weeks: [JournalDay], calendar: Calendar) -> [JournalOutputWeek] {
    var counts: [JournalDay: [Int]] = [:]
    for event in events {
      let index: Int? = switch event.source {
      case .pr: event.detail.action == "merged" ? 0 : nil
      case .review: 1
      case .git: 2
      case .claude: 3
      case .meeting, .note: nil
      }
      guard let index else { continue }
      counts[weekStart(event.day, calendar: calendar), default: [0, 0, 0, 0]][index] += 1
    }
    return weeks.map { start in
      let count = counts[start] ?? [0, 0, 0, 0]
      return JournalOutputWeek(start: start, merged: count[0], reviews: count[1], commits: count[2], sessions: count[3])
    }
  }

  /// The `top` skill tags by entries, and per month how many entries carried each of them.
  public static func skills(_ entries: [JournalEntry], top: Int = 8) -> (months: [JournalSkillMonth],
                                                                         top: [JournalAmount]) {
    var totals: [String: Int] = [:]
    for entry in entries { for skill in entry.skills { totals[skill, default: 0] += 1 } }
    let ranked = Array(totals.map { JournalAmount(name: $0.key, value: $0.value) }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name }.prefix(top))
    let names = Set(ranked.map(\.name))
    let byMonth = Dictionary(grouping: entries) { String($0.day.key.prefix(7)) }
    let months = byMonth.keys.sorted().map { month in
      var counts: [String: Int] = [:]
      for entry in byMonth[month] ?? [] {
        for skill in entry.skills where names.contains(skill) { counts[skill, default: 0] += 1 }
      }
      return JournalSkillMonth(month: month, skills: counts.map { JournalAmount(name: $0.key, value: $0.value) }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name })
    }
    return (months, ranked)
  }

  /// All-time milestones, newest first: the first day each skill and project appears, the longest streak (3 days or
  /// more), highlighted and measured entries, and each month's totals.
  public static func journey(entries: [JournalEntry], events: [JournalEvent], activities: [JournalDayActivity],
                             qualifying: Set<JournalDay>, calendar: Calendar,
                             name: (String) -> String) -> [JournalMilestone] {
    var milestones: [JournalMilestone] = []
    var firstSkill: [String: JournalEntry] = [:]
    for entry in entries.sorted(by: { ($0.day, $0.position) < ($1.day, $1.position) }) {
      for skill in entry.skills where firstSkill[skill] == nil { firstSkill[skill] = entry }
    }
    milestones += firstSkill.map { skill, entry in
      JournalMilestone(kind: .firstSkill, day: entry.day, title: "First time: \(skill)", detail: entry.title, key: skill)
    }
    var firstProject: [String: JournalDay] = [:]
    for event in events where [.claude, .git, .pr].contains(event.source) {
      guard let project = event.project else { continue }
      if firstProject[project].map({ event.day < $0 }) ?? true { firstProject[project] = event.day }
    }
    milestones += firstProject.map { project, day in
      JournalMilestone(kind: .firstProject, day: day, title: "New project: \(name(project))", detail: "", key: project)
    }
    if let run = longestRun(qualifying, calendar: calendar), run.length >= 3 {
      milestones.append(JournalMilestone(kind: .streak, day: run.end, title: "Longest streak: \(run.length) days",
                                         detail: "\(run.start.key) – \(run.end.key)", key: "longest"))
    }
    for entry in entries where entry.highlight || !entry.impact.isEmpty {
      milestones.append(JournalMilestone(kind: .highlight, day: entry.day, title: entry.title,
                                         detail: entry.impact.isEmpty ? entry.summary : entry.impact, key: entry.id))
    }
    let activeByMonth = Dictionary(grouping: activities.filter { qualifying.contains($0.day) }) {
      String($0.day.key.prefix(7))
    }
    let entriesByMonth = Dictionary(grouping: entries) { String($0.day.key.prefix(7)) }
    for month in Set(activeByMonth.keys).union(entriesByMonth.keys) {
      let days = activeByMonth[month] ?? []
      let monthEntries = entriesByMonth[month] ?? []
      guard let last = (days.map(\.day) + monthEntries.map(\.day)).max() else { continue }
      let hours = days.reduce(0) { $0 + $1.activeMinutes } / 60
      milestones.append(JournalMilestone(
        kind: .month, day: last, title: monthTitle(month, calendar: calendar),
        detail: "\(plural(days.count, "active day", "active days")) · "
          + "\(plural(monthEntries.count, "entry", "entries")) · \(hours) h",
        key: month))
    }
    let order: [JournalMilestone.Kind: Int] = [.month: 0, .streak: 1, .highlight: 2, .firstProject: 3, .firstSkill: 4]
    return milestones.sorted { a, b in
      a.day != b.day ? a.day > b.day : (order[a.kind] ?? 9, a.key) < (order[b.kind] ?? 9, b.key)
    }
  }

  static func plural(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count) \(count == 1 ? one : many)"
  }

  /// "October 2026" for "2026-10".
  static func monthTitle(_ month: String, calendar: Calendar) -> String {
    guard let day = JournalDay(key: month + "-01") else { return month }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "MMMM yyyy"
    return formatter.string(from: day.start(in: calendar).addingTimeInterval(12 * 3600))
  }

  /// The Insights board for `range` ending `today`, from everything stored. The grid, streaks and journey are
  /// all-time; the rest covers the range.
  public static func insights(range: JournalInsights.Range, today: JournalDay, records: [JournalDayRecord],
                              events: [JournalEvent], entries: [JournalEntry], calendar: Calendar,
                              name: (String) -> String) -> JournalInsights {
    let recordsByDay = Dictionary(records.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
    let eventsByDay = Dictionary(grouping: events, by: \.day)
    let entriesByDay = Dictionary(grouping: entries, by: \.day)
    let allDays = Set(recordsByDay.keys).union(eventsByDay.keys).union(entriesByDay.keys)
    var activities: [JournalDay: JournalDayActivity] = [:]
    for day in allDays {
      activities[day] = activity(day: day, events: eventsByDay[day] ?? [], terminal: recordsByDay[day]?.terminal ?? [:],
                                 fallback: recordsByDay[day]?.minutesByProject ?? [:], calendar: calendar)
    }
    let qualifying = Set(allDays.filter { qualifies(activities[$0], entries: entriesByDay[$0]?.count ?? 0) })
    let streak = streaks(qualifying, today: today, calendar: calendar)
    let rangeDays = JournalDay.range(from: today.adding(days: -(range.days - 1), calendar: calendar), through: today,
                                     calendar: calendar)
    let inRange = Set(rangeDays)
    let rangeActivities = rangeDays.map { activities[$0] ?? .empty($0) }
    let busy = busiest(rangeActivities, calendar: calendar)
    let weekStarts = Array(Set(rangeDays.map { weekStart($0, calendar: calendar) })).sorted()
    let rangeEntries = entries.filter { inRange.contains($0.day) }
    let skillCounts = skills(rangeEntries)
    return JournalInsights(
      range: range, grid: grid(today: today, minutes: activities.mapValues(\.activeMinutes), calendar: calendar),
      currentStreak: streak.current, longestStreak: streak.longest, busiestWeekday: busy.weekday,
      busiestHour: busy.hour, weeks: weeks(rangeActivities, calendar: calendar),
      focusMinutes: rangeActivities.reduce(0) { $0 + $1.focusMinutes },
      meetingMinutes: rangeActivities.reduce(0) { $0 + $1.meetingMinutes },
      output: output(events.filter { inRange.contains($0.day) }, weeks: weekStarts, calendar: calendar),
      impact: rangeEntries.filter { $0.highlight || !$0.impact.isEmpty }
        .sorted { ($0.day, -$0.position) > ($1.day, -$1.position) },
      skillMonths: skillCounts.months, topSkills: skillCounts.top,
      journey: journey(entries: entries, events: events, activities: Array(activities.values), qualifying: qualifying,
                       calendar: calendar, name: name),
      activeDays: rangeDays.filter { qualifying.contains($0) }.count)
  }
}
