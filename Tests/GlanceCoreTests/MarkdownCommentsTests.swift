import Testing
@testable import GlanceCore

@Test func aTemplatesCommentsGo() {
  let template = """
  ## What
  <!-- Say what changed and why. -->
  Builds both apps.

  ## Testing
  <!--
  - unit tests
  - by hand
  -->
  Ran `swift test`.
  """
  #expect(MarkdownComments.strip(template) == """
  ## What
  Builds both apps.

  ## Testing
  Ran `swift test`.
  """)
}

@Test func textAroundACommentStays() {
  #expect(MarkdownComments.strip("a <!-- b --> c <!-- d --> e") == "a  c  e")
  #expect(MarkdownComments.strip("start <!-- open\nstill open\nclosed --> end") == "start \n end")
  #expect(MarkdownComments.strip("no comments\n\nhere") == "no comments\n\nhere")
}

@Test func fencedCodeKeepsItsComments() {
  let markdown = "```html\n<!-- kept -->\n```\n<!-- gone -->\nafter"
  #expect(MarkdownComments.strip(markdown) == "```html\n<!-- kept -->\n```\nafter")
}

@Test func anUnclosedCommentHidesTheRest() {
  #expect(MarkdownComments.strip("shown\n<!-- never closed\nhidden") == "shown")
}
