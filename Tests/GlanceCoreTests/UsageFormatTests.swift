import Foundation
import Testing
@testable import GlanceCore

private let utc: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  calendar.firstWeekday = 2
  return calendar
}()
private let british = Locale(identifier: "en_GB")

@Test func tokenCountsAreShortAndNeverRoundUpToAThousandK() {
  #expect(UsageFormat.tokens(845) == "845")
  #expect(UsageFormat.tokens(1_000) == "1K")
  #expect(UsageFormat.tokens(1_534) == "1.53K")
  #expect(UsageFormat.tokens(12_345) == "12.3K")
  #expect(UsageFormat.tokens(456_789) == "457K")
  #expect(UsageFormat.tokens(999_950) == "1M")
  #expect(UsageFormat.tokens(4_560_000) == "4.56M")
  #expect(UsageFormat.tokens(2_500_000_000) == "2.5B")
}

@Test func costsShowCentsUnderAThousandAndADashWithoutAPrice() {
  #expect(UsageFormat.cost(nil) == "—")
  #expect(UsageFormat.cost(0) == "$0")
  #expect(UsageFormat.cost(0.004) == "<$0.01")
  #expect(UsageFormat.cost(12.345) == "$12.35")
  #expect(UsageFormat.cost(1234.5) == "$1,235")
  #expect(UsageFormat.cost(1_234_567) == "$1,234,567")
}

@Test func changesAndPercentsAreWholeNumbers() {
  #expect(UsageFormat.change(nil) == nil)
  #expect(UsageFormat.change(0.18) == "▲ 18%")
  #expect(UsageFormat.change(-0.054) == "▼ 5%")
  #expect(UsageFormat.change(0.001) == "0%")
  #expect(UsageFormat.percent(0.123) == "12%")
  #expect(UsageFormat.percent(0.003) == "<1%")
  #expect(UsageFormat.percent(0) == "0%")
}

@Test func periodTitlesNameTheDayWeekOrMonth() {
  let thursday = Date(timeIntervalSince1970: 1_791_468_000) // 2026-10-08 14:00 UTC
  #expect(UsageFormat.title(UsagePeriod(.day, containing: thursday, calendar: utc), calendar: utc, locale: british)
    == "Thu 8 Oct")
  #expect(UsageFormat.title(UsagePeriod(.week, containing: thursday, calendar: utc), calendar: utc, locale: british)
    == "5–11 Oct")
  #expect(UsageFormat.title(UsagePeriod(.month, containing: thursday, calendar: utc), calendar: utc, locale: british)
    == "October 2026")
  let spanning = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01, week of 28 Sep
  #expect(UsageFormat.title(UsagePeriod(.week, containing: spanning, calendar: utc), calendar: utc, locale: british)
    == "28 Sep – 4 Oct")
  #expect(UsageFormat.bucket(thursday, hourly: true, calendar: utc, locale: british) == "14:00")
  #expect(UsageFormat.bucket(thursday, hourly: false, calendar: utc, locale: british) == "Thu 8 Oct")
  #expect(UsageFormat.day(thursday, calendar: utc, locale: british) == "8 Oct 2026")
}
