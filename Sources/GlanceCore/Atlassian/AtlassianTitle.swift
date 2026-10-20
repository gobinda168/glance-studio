import Foundation

/// A Jira or Confluence tab's title from its page's (spec 2026-10-09-jira-confluence-design.md, "Tabs"): the endings
/// that name the product or the site go (" - Jira", " - Confluence", " | <site title>"), an issue's "[GL-142] …"
/// becomes "GL-142 …", and a page still loading is the product's name. A Confluence page keeps its space.
public enum AtlassianTitle {
  public static func clean(_ title: String, product: AtlassianProduct, site: AtlassianSite) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == "Loading..." || text == "Loading…" { return product.title }
    let separator = text.contains(" | ") ? " | " : " - "
    let endings = Set((["Jira", "Confluence", site.name] + site.titles).map { $0.lowercased() })
    while let range = text.range(of: separator, options: .backwards),
          endings.contains(text[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()) {
      text = String(text[..<range.lowerBound])
    }
    if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
      let key = text[text.index(after: text.startIndex)..<close]
      if isIssueKey(key) {
        text = String(key) + " " + text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
      }
    }
    text = text.trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? product.title : text
  }

  /// "GL-142": a project key (a capital letter, then capitals, digits or underscores), a dash and a number.
  public static func isIssueKey<S: StringProtocol>(_ text: S) -> Bool {
    guard let dash = text.lastIndex(of: "-") else { return false }
    let project = text[..<dash]
    let number = text[text.index(after: dash)...]
    guard let first = project.first, first.isASCII, first.isUppercase, !number.isEmpty else { return false }
    return project.allSatisfy { ($0.isASCII && ($0.isUppercase || $0.isNumber)) || $0 == "_" }
      && number.allSatisfy { $0.isASCII && $0.isNumber }
  }
}
