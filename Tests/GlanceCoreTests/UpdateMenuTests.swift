import Testing
@testable import GlanceCore

@Test func idleOffersACheckWhenSparkleIsReady() {
  let item = UpdateMenu.item(for: .idle, canCheck: true)
  #expect(item == UpdateMenuItem(title: "Check for Updates…", isEnabled: true, showsBadge: false))
}

@Test func idleIsDisabledWhileSparkleIsBusy() {
  #expect(UpdateMenu.item(for: .idle, canCheck: false).isEnabled == false)
}

@Test func anAvailableUpdateNamesTheVersionAndBadgesTheIcon() {
  let item = UpdateMenu.item(for: .available(version: "0.1.1 (152)"), canCheck: false)
  #expect(item.title == "Update Available: 0.1.1 (152)…")
  #expect(item.isEnabled) // reopens the dialog even while Sparkle says it can't start a new check
  #expect(item.showsBadge)
}

@Test func anUpdateWithNoVersionStringStillReadsSensibly() {
  #expect(UpdateMenu.item(for: .available(version: ""), canCheck: true).title == "Update Available…")
  #expect(UpdateMenu.item(for: .available(version: "  "), canCheck: true).title == "Update Available…")
}

@Test func installingIsShownAndDisabled() {
  let item = UpdateMenu.item(for: .installing, canCheck: true)
  #expect(item.title == "Installing Update…")
  #expect(item.isEnabled == false)
  #expect(item.showsBadge == false)
}

@Test func aFeedOverrideComesFromTheEnvironment() {
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": "http://localhost:8000/feed-glance/appcast.xml"])
    == "http://localhost:8000/feed-glance/appcast.xml")
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": "https://example.com/a.xml"]) == "https://example.com/a.xml")
}

@Test func anUnsetOrBadFeedOverrideIsIgnored() {
  #expect(UpdateFeed.override(environment: [:]) == nil)
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": ""]) == nil)
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": "file:///etc/passwd"]) == nil)
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": "not a url"]) == nil)
  #expect(UpdateFeed.override(environment: ["GLANCE_FEED_URL": "ftp://example.com/a.xml"]) == nil)
}
