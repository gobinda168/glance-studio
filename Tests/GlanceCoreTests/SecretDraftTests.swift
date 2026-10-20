import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretDraftTests {
  let now = Date(timeIntervalSince1970: 100)

  @Test func aNewDraftBecomesARecord() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.note = "GitHub"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com, uploads.github.com"
    draft.slotKind = .bearer
    draft.approval = .oncePerSession
    let id = UUID()
    let record = try draft.record(id: id, created: now, now: now, otherNames: [], keeping: nil).get()
    #expect(record.hosts == ["api.github.com", "uploads.github.com"])
    #expect(record.slot == .bearer)
    #expect(record.folders == [])
  }

  @Test func editingWithAnEmptyValueKeepsTheOldOne() throws {
    let old = SecretRecordTests.record()
    var draft = SecretDraft(record: old)
    #expect(draft.value == "")
    draft.note = "changed"
    let record = try draft.record(id: old.id, created: old.created, now: now, otherNames: [], keeping: old.value).get()
    #expect(record.value == old.value)
    #expect(record.note == "changed")
    #expect(record.updated == now)
  }

  @Test func slotFieldsBuildTheSlot() throws {
    var draft = SecretDraft(record: SecretRecordTests.record())
    draft.slotKind = .header
    draft.headerName = "X-API-Key"
    draft.headerPrefix = ""
    #expect(try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: "abcdefghij").get().slot
      == .header(name: "X-API-Key", prefix: ""))
    draft.slotKind = .basic
    draft.username = "me"
    #expect(try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: "abcdefghij").get().slot
      == .basic(username: "me"))
  }

  @Test func problemsComeBackForTheSheet() {
    var draft = SecretDraft()
    draft.name = "x"
    draft.value = "short"
    draft.hosts = "localhost"
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems.count == 3)
  }

  // MARK: - Beyond the brief

  @Test func hostsSplitOnCommasSpacesAndEveryKindOfLineBreak() {
    var draft = SecretDraft()
    draft.hosts = " a.example.com,b.example.com  c.example.com\r\nd.example.com\ne.example.com\u{2028}f.example.com\u{A0}g.example.com,, "
    #expect(draft.hostList == ["a.example.com", "b.example.com", "c.example.com", "d.example.com", "e.example.com",
                               "f.example.com", "g.example.com"])
  }

  @Test func repeatedHostsAreKeptOnce() {
    var draft = SecretDraft()
    draft.hosts = "api.github.com, API.GitHub.com, api.github.com."
    #expect(draft.hostList == ["api.github.com"])
  }

  @Test func noHostsIsAProblem() {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = " , "
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems == ["Add at least one host it may be sent to."])
  }

  @Test func theSlotFieldsOfTheOtherKindsAreIgnored() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.slotKind = .bearer
    draft.headerName = "not a header\r\n"
    draft.username = "a:b"
    #expect(try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil).get().slot == .bearer)
  }

  @Test func theHeaderNameIsTrimmedButThePrefixIsNot() throws {
    var draft = SecretDraft()
    draft.name = "ACME_KEY"
    draft.value = "abcdefghijkl"
    draft.hosts = "api.acme.com"
    draft.slotKind = .header
    draft.headerName = "  X-Token \t"
    draft.headerPrefix = "Token "
    #expect(try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil).get().slot
      == .header(name: "X-Token", prefix: "Token "))
  }

  @Test func aCrLfInTheNameOrValueIsNotHidden() {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghij\r\nklmnop"
    draft.hosts = "api.github.com"
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems == ["The value can't contain line breaks."])
  }

  @Test func aTakenNameIsAProblemButTheSecretsOwnNameIsNot() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now,
                                                      otherNames: ["GITHUB_TOKEN"], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems == ["Another secret is already called GITHUB_TOKEN."])
    _ = try draft.record(id: UUID(), created: now, now: now, otherNames: ["OTHER"], keeping: nil).get()
  }

  @Test func aRelativeFolderIsAProblem() {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.folders = ["Code/acme"]
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems.count == 1)
  }

  @Test func alwaysNeedsAtLeastOneFolder() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.approval = .always
    guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems.count == 1)
    draft.folders = ["/Users/me/Code/acme"]
    #expect(try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil).get().approval == .always)
  }

  @Test func theRecordKeepsItsIdCreatedAndTrimsTheNote() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.note = "\n  GitHub, repo scope \n"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    let id = UUID()
    let created = Date(timeIntervalSince1970: 5)
    let record = try draft.record(id: id, created: created, now: now, otherNames: [], keeping: nil).get()
    #expect(record.id == id)
    #expect(record.created == created)
    #expect(record.updated == now)
    #expect(record.note == "GitHub, repo scope")
  }

  @Test func editingWithoutAKeptValueAndNoNewOneIsAProblem() {
    let old = SecretRecordTests.record()
    let draft = SecretDraft(record: old)
    guard case .failure(let problems) = draft.record(id: old.id, created: old.created, now: now, otherNames: [],
                                                      keeping: nil)
    else { Issue.record("expected problems"); return }
    #expect(problems == ["The value must be at least 8 characters."])
  }

  @Test func theDraftOfARecordRoundTrips() throws {
    let old = SecretRecordTests.record(hosts: ["api.acme.com", "*.acme.com"], slot: .header(name: "X-Key", prefix: "K "),
                                       folders: ["/Users/me/Code/acme"], approval: .always)
    let draft = SecretDraft(record: old)
    #expect(draft.value == "")
    let record = try draft.record(id: old.id, created: old.created, now: old.updated, otherNames: [], keeping: old.value).get()
    #expect(record == old)
  }

  // MARK: - Fix round 1

  private func changes(_ edit: (inout SecretRecord) -> Void) -> [String] {
    let old = SecretRecordTests.record(folders: ["/Users/me/Code/acme"], approval: .oncePerSession)
    var new = old
    edit(&new)
    return SecretDraft.ruleChanges(from: old, to: new)
  }

  @Test func aNameOrNoteChangeIsNotARuleChange() {
    #expect(changes { _ in } == [])
    #expect(changes { $0.name = "OTHER_TOKEN"; $0.note = "other"; $0.updated = Date(timeIntervalSince1970: 9) } == [])
    #expect(changes { $0.hosts = ["api.github.com"] } == [])
  }

  @Test func reorderedHostsAndFoldersAreNotChanges() {
    let old = SecretRecordTests.record(hosts: ["a.example.com", "b.example.com"], folders: ["/x/a", "/x/b"])
    var new = old
    new.hosts = ["b.example.com", "a.example.com"]
    new.folders = ["/x/b", "/x/a"]
    #expect(SecretDraft.ruleChanges(from: old, to: new) == [])
  }

  @Test func eachRuleFieldNamesItsChange() {
    #expect(changes { $0.value = "a-brand-new-value" } == ["a new value"])
    #expect(changes { $0.hosts = ["api.github.com", "attacker.example"] } == ["adds 1 host “attacker.example”"])
    #expect(changes { $0.hosts = [] } == ["removes 1 host “api.github.com”"])
    #expect(changes { $0.slot = .header(name: "X-Key", prefix: "") } == ["sent as header “X-Key”"])
    #expect(changes { $0.slot = .header(name: "X-Key", prefix: "K ") } == ["sent as header “X-Key” with prefix"])
    #expect(changes { $0.slot = .basic(username: "me") } == ["sent as basic for “me”"])
    #expect(changes { $0.folders = [] } == ["any folder"])
    #expect(changes { $0.folders = ["/Users/me/Code/acme", "/tmp/x"] } == ["adds 1 folder “/tmp/x”"])
    #expect(changes { $0.folders = ["/tmp/x"] }
      == ["adds 1 folder “/tmp/x”", "removes 1 folder “/Users/me/Code/acme”"])
    #expect(changes { $0.approval = .always } == ["Always"])
    #expect(changes { $0.approval = .everyTime } == ["ask every time"])
    #expect(changes { $0.approval = .oncePerSession } == [])
  }

  @Test func severalChangesAreAllNamedInTheReason() {
    let old = SecretRecordTests.record(folders: ["/Users/me/Code/acme"], approval: .oncePerSession)
    var new = old
    new.hosts = ["evil.example"]; new.approval = .always; new.value = "another-value-1"
    #expect(SecretDraft.ruleChanges(from: old, to: new)
      == ["Always", "adds 1 host “evil.example”", "removes 1 host “api.github.com”", "a new value"])
    #expect(SecretDraft.changeReason(from: old, to: new)
      == "change GITHUB_TOKEN: Always · adds 1 host “evil.example” · removes 1 host “api.github.com” · a new value")
  }

  @Test func alwaysRefusesSlashAndTheHomeFolderButNotAProjectInIt() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.approval = .always
    let sentence = "Always needs a project folder, not / or your home folder."
    for folder in ["/", "//", "/.", "/Users/me", "/Users/me/", "/users/ME", "/Users/me/Code/.."] {
      draft.folders = [folder]
      guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [],
                                                        keeping: nil, home: "/Users/me")
      else { Issue.record("expected problems for \(folder)"); continue }
      #expect(problems == [sentence], "\(folder)")
    }
    draft.folders = ["/Users/me/Code/acme"]
    _ = try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: "/Users/me").get()
    // Another folder next to the home folder doesn't excuse it.
    draft.folders = ["/Users/me/Code/acme", "/Users/me"]
    #expect(throws: SecretDraft.Problems.self) {
      try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: "/Users/me").get()
    }
    // Only `always` is limited this way.
    draft.approval = .oncePerSession
    draft.folders = ["/Users/me"]
    _ = try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: "/Users/me").get()
  }

  @Test func aDraftRemembersWhichVersionItCameFrom() {
    let old = SecretRecordTests.record()
    #expect(SecretDraft(record: old).baseUpdated == old.updated)
    #expect(SecretDraft().baseUpdated == nil)
  }

  // MARK: - Fix rounds 2 and 3

  private func reason(old: SecretRecord = SecretRecordTests.record(folders: ["/Users/me/Code/acme"],
                                                                 approval: .oncePerSession),
                      _ edit: (inout SecretRecord) -> Void) -> String {
    var new = old
    edit(&new)
    return SecretDraft.changeReason(from: old, to: new) ?? "<no prompt>"
  }

  @Test func noRuleChangeMeansNoReason() {
    #expect(reason { $0.note = "x"; $0.name = "NEW_TOKEN" } == "<no prompt>")
  }

  @Test func theMostDangerousChangesComeFirst() {
    let list = changes {
      $0.value = "another-value-1"; $0.slot = .basic(username: "me"); $0.hosts = ["evil.example"]
      $0.folders = []; $0.approval = .always
    }
    #expect(list == ["Always", "any folder", "adds 1 host “evil.example”", "removes 1 host “api.github.com”",
                     "sent as basic for “me”", "a new value"])
  }

  @Test func lineBreaksBidiMarksAndFillersInANameCantReshapeTheSheet() {
    let text = reason { $0.folders = ["/tmp/a\nApprove: yes\u{202E}gnp.exe\u{200B}\u{3164}\u{2800}\u{FE0F}", "/tmp/b\u{2028}x\r\ny\u{7}z"] }
    #expect(text == "change GITHUB_TOKEN: adds 2 folders “/tmp/a Approve: yesgnp.exe” +1"
      + " · removes 1 folder “/Users/me/Code/acme”")
    for scalar in text.unicodeScalars {
      #expect(scalar.value >= 0x20 && scalar.value != 0x7F && !(0x200B...0x200F).contains(scalar.value)
        && !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
        && ![0x3164, 0x2800, 0xFE0F, 0x115F, 0x1160, 0xFFA0, 0x034F].contains(scalar.value))
    }
  }

  @Test func aFolderCalledLikeAPhraseIsQuotedAndDefused() {
    let text = reason { $0.folders = ["/tmp/x · Always", "/Users/me/Code/acme"] }
    #expect(text == "change GITHUB_TOKEN: adds 1 folder “/tmp/x _ Always”")
    let quotes = reason { $0.hosts = ["a\"b”c“d,e.example"] }
    #expect(quotes == "change GITHUB_TOKEN: adds 1 host “a'b'c'd_e.example” · removes 1 host “api.github.com”")
  }

  @Test func aHugePrefixAddsOnlyTheWordPrefix() {
    let text = reason { $0.slot = .header(name: "X-Key", prefix: String(repeating: "P", count: 500)) }
    #expect(text == "change GITHUB_TOKEN: sent as header “X-Key” with prefix")
  }

  @Test func aHugeHeaderNameIsOneCappedItem() {
    let text = reason { $0.slot = .header(name: String(repeating: "H", count: 500), prefix: "") }
    #expect(text == "change GITHUB_TOKEN: sent as header “" + String(repeating: "H", count: 31) + "…”")
  }

  @Test func manyAddedHostsShowOneAndACount() {
    let hosts = (1...10).map { "h\($0).example.com" }
    let text = reason { $0.hosts = ["api.github.com"] + hosts }
    #expect(text == "change GITHUB_TOKEN: adds 10 hosts “h1.example.com” +9")
  }

  @Test func aRenameShowsBothNamesCappedAndTheHostPhraseSurvives() {
    let old = SecretRecordTests.record(name: String(repeating: "A", count: 64), folders: ["/Users/me/Code/acme"])
    let text = reason(old: old) { $0.name = String(repeating: "B", count: 64); $0.hosts = ["evil.example"] }
    #expect(text == "change " + String(repeating: "A", count: 23) + "… (now " + String(repeating: "B", count: 23)
      + "…): adds 1 host “evil.example” · removes 1 host “api.github.com”")
    #expect(text.contains("adds 1 host"))
  }

  @Test func threeLongFoldersAndAHostAdditionKeepTheHostPhrase() {
    let folders = ["a", "b", "c"].map { "/" + String(repeating: $0, count: 47) }
    let old = SecretRecordTests.record(folders: ["/Users/me/Code/acme"] + folders, approval: .always)
    let text = reason(old: old) { $0.folders = []; $0.hosts = ["api.github.com", "evil.example"] }
    #expect(text.contains("adds 1 host “evil.example”"))
    #expect(text.count <= 200)
    let more = reason(old: SecretRecordTests.record(folders: ["/x"]), { $0.folders = folders; $0.hosts = ["evil.example"] })
    #expect(more.contains("adds 1 host “evil.example”"))
    #expect(more.count <= 200)
  }

  @Test func theWorstCaseNeverExceedsTheLimitAndNeverCutsATail() {
    let long = { (c: String) in "/" + String(repeating: c, count: 200) }
    let old = SecretRecordTests.record(name: String(repeating: "A", count: 64),
                                       hosts: (1...50).map { "old\($0).example.com" }, slot: .bearer,
                                       folders: (1...50).map { "/old\($0)" }, approval: .everyTime)
    var new = old
    new.name = String(repeating: "B", count: 64)
    new.approval = .always
    new.folders = (1...150).map { _ in long("f") } + ["/z"]
    new.hosts = (1...150).map { "new\($0)." + String(repeating: "h", count: 100) + ".com" }
    new.slot = .header(name: String(repeating: "H", count: 300), prefix: "P")
    new.value = "another-value-1"
    let text = SecretDraft.changeReason(from: old, to: new)
    // Items don't fit at any cap, so the reason falls to counts: still every kind, nothing cut off the end.
    #expect(text == "change " + String(repeating: "A", count: 23) + "… (now " + String(repeating: "B", count: 23)
      + "…): Always · adds 99+ folders · removes 50 folders · adds 99+ hosts · removes 50 hosts"
      + " · sent as header with prefix · a new value")
    #expect((text ?? "").count <= SecretDraft.reasonLimit)
  }

  // MARK: - Fix round 4

  @Test func theLongestCountsDropWithPrefixButKeepEveryKindAndTheApprovalWord() {
    // Counts only, with "with prefix", this is 201 Characters: the last form drops "with prefix" and nothing else.
    let old = SecretRecordTests.record(name: String(repeating: "A", count: 24),
                                       hosts: (1...10).map { "old\($0).example.com" }, slot: .bearer,
                                       folders: (1...10).map { "/old\($0)" }, approval: .everyTime)
    var new = old
    new.name = String(repeating: "B", count: 24)
    new.approval = .oncePerSession
    new.folders = (1...10).map { "/Users/me/Code/" + String(repeating: "f", count: 40) + "\($0)" }
    new.hosts = (1...10).map { "new\($0)." + String(repeating: "h", count: 40) + ".com" }
    new.slot = .header(name: "X-Key", prefix: "P")
    new.value = "another-value-1"
    let text = SecretDraft.changeReason(from: old, to: new) ?? ""
    #expect(text == "change " + String(repeating: "A", count: 24) + " (now " + String(repeating: "B", count: 24)
      + "): ask once per session · adds 10 folders · removes 10 folders · adds 10 hosts · removes 10 hosts"
      + " · sent as header · a new value")
    #expect(text.count <= SecretDraft.reasonLimit)
  }

  /// Every mix of changed kinds, with and without a rename of two 64-character names, with small lists and with lists of
  /// 20 long items added and 20 removed (besides one kept): the reason fits and names each changed kind, and only those.
  @Test func everyMixOfChangesFitsAndNamesEachChangedKind() {
    enum Folders: CaseIterable { case same, anyToOnly, onlyToAny, adds, removes, addsAndRemoves }
    enum Hosts: CaseIterable { case same, adds, removes, addsAndRemoves }
    let approvals: [SecretApproval?] = [nil] + SecretApproval.allCases
    let word: [SecretApproval: String] = [.always: "Always", .oncePerSession: "ask once per session",
                                          .everyTime: "ask every time"]
    // No item text contains a phrase's word ("host", "folder", "value", "sent as", "ask", "Always", "only in", "any").
    let header = String(repeating: "X", count: 64), user = String(repeating: "u", count: 64)
    let slots: [(SecretSlot, String)?] = [nil, (.header(name: header, prefix: "P"), "sent as header"),
                                          (.basic(username: user), "sent as basic"), (.bearer, "sent as bearer")]
    var checked = 0
    for big in [false, true] {
      let size = big ? 20 : 2
      let folder = { (tag: Character, i: Int) in
        big ? "/Users/me/Code/" + String(repeating: tag, count: 80) + "/\(i)" : "/p/\(tag)\(i)"
      }
      let host = { (tag: Character, i: Int) in
        big ? "\(tag)\(i)." + String(repeating: tag, count: 60) + ".example.com" : "\(tag)\(i).example.com"
      }
      let addedFolders = (1...size).map { folder("n", $0) }, removedFolders = (1...size).map { folder("r", $0) }
      let addedHosts = (1...size).map { host("n", $0) }, removedHosts = (1...size).map { host("r", $0) }
      for renamed in [false, true] {
        for approval in approvals {
          for folders in Folders.allCases {
            for hosts in Hosts.allCases {
              for slot in slots {
                for newValue in [false, true] {
                  var old = SecretRecordTests.record(name: String(repeating: renamed ? "A" : "C", count: 64))
                  var new = old
                  if renamed { new.name = String(repeating: "B", count: 64) }
                  if let approval {
                    new.approval = approval
                    old.approval = SecretApproval.allCases.first { $0 != approval }!
                  }
                  let kept = [folder("k", 0)]
                  switch folders {
                  case .same: old.folders = kept; new.folders = kept
                  case .anyToOnly: old.folders = []; new.folders = addedFolders
                  case .onlyToAny: old.folders = kept + removedFolders; new.folders = []
                  case .adds: old.folders = kept; new.folders = kept + addedFolders
                  case .removes: old.folders = kept + removedFolders; new.folders = kept
                  case .addsAndRemoves: old.folders = kept + removedFolders; new.folders = kept + addedFolders
                  }
                  let keptHost = [host("k", 0)]
                  old.hosts = keptHost + ([.removes, .addsAndRemoves].contains(hosts) ? removedHosts : [])
                  new.hosts = keptHost + ([.adds, .addsAndRemoves].contains(hosts) ? addedHosts : [])
                  if let target = slot?.0 {
                    old.slot = target == .bearer ? .basic(username: "me") : .bearer
                    new.slot = target
                  }
                  if newValue { new.value = "another-value-1" }

                  let anyChange = approval != nil || folders != .same || hosts != .same || slot != nil || newValue
                  guard let text = SecretDraft.changeReason(from: old, to: new) else {
                    #expect(!anyChange); continue
                  }
                  let label = "\(big) \(renamed) \(String(describing: approval)) \(folders) \(hosts) \(slot?.1 ?? "-") \(newValue)"
                  checked += 1
                  #expect(anyChange, "\(label)")
                  #expect(text.count <= SecretDraft.reasonLimit, "\(label): \(text)")
                  #expect(text.unicodeScalars.count <= SecretDraft.reasonLimit * 2, "\(label)")
                  #expect(!text.hasSuffix("…"), "\(label): \(text)")
                  let who = renamed
                    ? String(repeating: "A", count: 23) + "… (now " + String(repeating: "B", count: 23) + "…)"
                    : String(repeating: "C", count: 23) + "…"
                  #expect(text.hasPrefix("change \(who): "), "\(label): \(text)")
                  for (value, phrase) in word {
                    #expect(text.contains(phrase) == (approval == value), "\(label): \(text)")
                  }
                  let n = size
                  switch folders {
                  case .same: #expect(!text.contains("folder"), "\(label): \(text)")
                  case .anyToOnly: #expect(text.contains("only in \(n) folders"), "\(label): \(text)")
                  case .onlyToAny: #expect(text.contains("any folder"), "\(label): \(text)")
                  case .adds:
                    #expect(text.contains("adds \(n) folders") && !text.contains("removes \(n) folders"), "\(label)")
                  case .removes:
                    #expect(text.contains("removes \(n) folders") && !text.contains("adds \(n) folders"), "\(label)")
                  case .addsAndRemoves:
                    #expect(text.contains("adds \(n) folders") && text.contains("removes \(n) folders"), "\(label)")
                  }
                  #expect(text.contains("adds \(n) hosts") == [.adds, .addsAndRemoves].contains(hosts), "\(label): \(text)")
                  #expect(text.contains("removes \(n) hosts") == [.removes, .addsAndRemoves].contains(hosts),
                          "\(label): \(text)")
                  if hosts == .same { #expect(!text.contains("host"), "\(label): \(text)") }
                  if let phrase = slot?.1 {
                    #expect(text.contains(phrase), "\(label): \(text)")
                  } else {
                    #expect(!text.contains("sent as"), "\(label): \(text)")
                  }
                  #expect(text.contains("a new value") == newValue, "\(label): \(text)")
                }
              }
            }
          }
        }
      }
    }
    #expect(checked == 2 * 2 * (4 * 6 * 4 * 4 * 2 - 1))
  }

  @Test func blankLookingAndWideSpacesBecomeOnePlainSpace() {
    #expect(SecretDraft.clean("a\u{17B4}\u{17B5}b\u{180B}\u{180C}\u{180D}\u{180F}c") == "abc")
    #expect(SecretDraft.clean("a\u{00A0}\u{2000}\u{2003}\u{200A}\u{3000}\u{202F}\u{205F}b") == "a b")
    #expect(SecretDraft.clean("a  \n\t\u{2028} b\u{3000}") == "a b")
    #expect(SecretDraft.clean("a\u{200B} \u{200B} b") == "a b")
  }

  @Test func lookAlikeSeparatorsAndQuotesInAnItemAreDefused() {
    let text = reason { $0.folders = ["/x ∙•・･\u{0387}⋅‧ ‟＂‘’‚„", "/Users/me/Code/acme"] }
    #expect(text == "change GITHUB_TOKEN: adds 1 folder “/x _______ ''''''”")
  }

  @Test func zalgoCantMakeTheReasonLong() {
    let mark = String(repeating: "\u{0301}", count: 5_000)
    let text = reason { $0.hosts = ["evil.example"]; $0.folders = ["/tmp/a" + mark] }
    #expect(text.unicodeScalars.count <= SecretDraft.reasonLimit * 2)
  }

  @Test func aRenameAloneNeverAsks() {
    #expect(changes { $0.name = "NEW_TOKEN" } == [])
  }

  @Test func theDataVolumeSpellingOfTheHomeFolderIsTooWide() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.approval = .always
    for folder in ["/System/Volumes/Data", "/System/Volumes/Data/Users", "/System/Volumes/Data/Users/me",
                   "/system/volumes/data/users/ME/"] {
      for home in ["/Users/me", "/System/Volumes/Data/Users/me"] {
        draft.folders = [folder]
        guard case .failure = draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: home)
        else { Issue.record("expected problems for \(folder) with home \(home)"); continue }
      }
    }
    draft.folders = ["/System/Volumes/Data/Users/me/Code"]
    _ = try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: "/Users/me").get()
  }

  @Test func alwaysRefusesFoldersAboveTheHomeFolderToo() throws {
    var draft = SecretDraft()
    draft.name = "GITHUB_TOKEN"
    draft.value = "ghp_abcdefghijklmnop"
    draft.hosts = "api.github.com"
    draft.approval = .always
    for folder in ["/Users", "/Users/", "/Users/../Users", "/"] {
      draft.folders = [folder]
      guard case .failure(let problems) = draft.record(id: UUID(), created: now, now: now, otherNames: [],
                                                        keeping: nil, home: "/Users/me")
      else { Issue.record("expected problems for \(folder)"); continue }
      #expect(problems == ["Always needs a project folder, not / or your home folder."], "\(folder)")
    }
    // A sibling whose name only starts like the home folder, and a folder inside it, are fine.
    for folder in ["/Users/me2", "/Users/me/Code"] {
      draft.folders = [folder]
      _ = try draft.record(id: UUID(), created: now, now: now, otherNames: [], keeping: nil, home: "/Users/me").get()
    }
  }
}
