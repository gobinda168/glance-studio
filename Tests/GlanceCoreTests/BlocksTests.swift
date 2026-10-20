import Testing
@testable import GlanceCore

@Test func splitsTheCommonBlockKinds() {
  let md = """
  # Login flow

  Okay, so login is a **three-hop** dance.
  It spans two lines.

  ```mermaid
  sequenceDiagram
    User->>API: POST /login
  ```

  - first item
  - second item
    continued

  ```ts
  const a = 1

  const b = 2
  ```

  | a | b |
  |---|---|
  | 1 | 2 |

  > a quote

  ---
  Last words.
  """
  let blocks = Blocks.split(md)
  #expect(blocks.map(\.kind) == [.heading, .paragraph, .mermaid, .list, .code, .table, .quote, .rule, .paragraph])
  #expect(blocks[1].markdown == "Okay, so login is a **three-hop** dance.\nIt spans two lines.")
  #expect(blocks[2].markdown == "sequenceDiagram\n  User->>API: POST /login")
  #expect(blocks[3].markdown == "- first item\n- second item\n  continued")
  #expect(blocks[4].lang == "ts")
  #expect(blocks[4].markdown == "const a = 1\n\nconst b = 2")
  #expect(blocks[8].markdown == "Last words.")
}

@Test func unclosedFenceRunsToTheEnd() {
  let blocks = Blocks.split("Intro\n```mermaid\ngraph TD\n  A-->B")
  #expect(blocks.map(\.kind) == [.paragraph, .mermaid])
  #expect(blocks[1].markdown == "graph TD\n  A-->B")
}

@Test func listsSurviveBlankLinesBetweenItems() {
  let blocks = Blocks.split("1. one\n\n2. two\n\nAfter.")
  #expect(blocks.map(\.kind) == [.list, .paragraph])
  #expect(blocks[0].markdown == "1. one\n\n2. two")
}

@Test func emptyInputHasNoBlocks() {
  #expect(Blocks.split("\n\n  \n").isEmpty)
}
