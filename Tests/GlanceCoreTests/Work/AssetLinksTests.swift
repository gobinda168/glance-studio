import Foundation
import Testing
@testable import GlanceCore

/// A PR body is hostile input: these rules are what the download trusts.
@Suite struct AssetLinksTests {
  func found(_ body: String) -> [String] { AssetLinks.find(in: body).map(\.absoluteString) }

  @Test func aMarkdownImage() {
    #expect(found("Before\n\n![login page](https://example.com/shots/login.png)\n\nAfter") == ["https://example.com/shots/login.png"])
  }

  @Test func aMarkdownImageWithATitleAndAnAngleBracketURL() {
    #expect(found(#"![a](https://example.com/a.png "The login") ![b](<https://example.com/b.png>)"#)
      == ["https://example.com/a.png", "https://example.com/b.png"])
  }

  @Test func htmlImageAndVideoTags() {
    let body = """
    <img width="400" alt="x" src="https://example.com/a.png">
    <video src='https://example.com/demo.mp4' controls></video>
    <video controls><source src="https://example.com/b.webm" type="video/webm"></video>
    """
    #expect(found(body) == ["https://example.com/a.png", "https://example.com/demo.mp4", "https://example.com/b.webm"])
  }

  @Test func anHTMLAttributeNamedLikeSrcIsNotASource() {
    #expect(found(#"<img data-src="https://example.com/lazy.png" alt="x">"#).isEmpty)
  }

  @Test func htmlEntitiesInAnAttributeAreDecoded() {
    #expect(found(#"<img src="https://example.com/a.png?x=1&amp;y=2">"#) == ["https://example.com/a.png?x=1&y=2"])
  }

  @Test func aBareAttachmentURLOnItsOwnLineIsGitHubsVideoForm() {
    let id = "5f1b7c36-1c4e-4e0a-9d0c-0e8a3f1c2b9d"
    let body = "Demo:\n\nhttps://github.com/user-attachments/assets/\(id)\n\nThanks"
    #expect(found(body) == ["https://github.com/user-attachments/assets/\(id)"])
  }

  @Test func aBareURLInsideASentenceIsNotMedia() {
    let id = "5f1b7c36-1c4e-4e0a-9d0c-0e8a3f1c2b9d"
    #expect(found("see https://github.com/user-attachments/assets/\(id) for the demo").isEmpty)
    #expect(found("https://example.com/demo.mp4").isEmpty) // only GitHub's own attachment form stands alone
  }

  @Test func aQueryStringIsKept() {
    #expect(found("![a](https://example.com/a.png?v=4&s=200)") == ["https://example.com/a.png?v=4&s=200"])
  }

  @Test func plainHTTPIsRefused() {
    #expect(found("![a](http://example.com/a.png)\n<img src=\"http://example.com/b.png\">").isEmpty)
  }

  @Test func otherSchemesAreRefused() {
    let body = """
    ![a](data:image/png;base64,iVBORw0KGgo=)
    ![b](file:///etc/passwd)
    ![c](javascript:alert(1))
    ![d](//example.com/d.png)
    ![e](relative/e.png)
    <img src="ftp://example.com/f.png">
    """
    #expect(found(body).isEmpty)
  }

  @Test func privateHostsAreRefused() {
    let body = """
    ![a](https://localhost/a.png)
    ![b](https://127.0.0.1/b.png)
    ![c](https://10.0.0.5/c.png)
    ![d](https://[::1]/d.png)
    ![e](https://printer.local/e.png)
    ![f](https://intranet/f.png)
    ![g](https://app.localhost/g.png)
    ![h](https://169.254.169.254/latest/meta-data.png)
    """
    #expect(found(body).isEmpty)
  }

  @Test func credentialsInTheURLAreRefused() {
    #expect(found("![a](https://user:pass@example.com/a.png)\n![b](https://token@example.com/b.png)").isEmpty)
  }

  @Test func aFencedBlockIsSkipped() {
    let body = """
    ```md
    ![in a fence](https://example.com/fenced.png)
    ```

    ~~~
    <img src="https://example.com/tilde.png">
    ~~~

    ![out](https://example.com/out.png)
    """
    #expect(found(body) == ["https://example.com/out.png"])
  }

  // GitHub PR bodies are often CRLF; Swift reads CR-LF as one Character, so a split on "\n" alone misses every line end.
  @Test func crlfBodiesKeepTheirFences() {
    let body = "```md\r\n![in a fence](https://example.com/fenced.png)\r\n```\r\n\r\n![out](https://example.com/out.png)\r\n"
    #expect(found(body) == ["https://example.com/out.png"])
  }

  @Test func aCRLFBodyStartingWithAFenceStillFindsTheMediaAfterIt() {
    let body = "```\r\n<img src=\"https://example.com/a.png\">\r\n```\r\nDone:\r\n![b](https://example.com/b.png)"
    #expect(found(body) == ["https://example.com/b.png"])
  }

  @Test func aCRLFTildeFenceIsSkippedAndAnUnclosedOneRunsToTheEnd() {
    #expect(found("~~~\r\n![in](https://example.com/in.png)\r\n~~~\r\n![out](https://example.com/out.png)") == ["https://example.com/out.png"])
    #expect(found("![a](https://example.com/a.png)\r\n~~~\r\n![b](https://example.com/b.png)\r\n") == ["https://example.com/a.png"])
  }

  @Test func aLoneCRBodyIsSplitIntoLinesToo() {
    let body = "~~~\r![in](https://example.com/in.png)\r~~~\r![out](https://example.com/out.png)\r"
    #expect(found(body) == ["https://example.com/out.png"])
  }

  @Test func crlfBodiesStillFindEverythingElse() {
    let id = "5f1b7c36-1c4e-4e0a-9d0c-0e8a3f1c2b9d"
    let body = "Demo:\r\n\r\nhttps://github.com/user-attachments/assets/\(id)\r\n\r\n<img src=\"https://example.com/a.png\">\r\n`![c](https://example.com/c.png)`\r\n"
    #expect(found(body) == ["https://github.com/user-attachments/assets/\(id)", "https://example.com/a.png"])
  }

  @Test func anUnclosedFenceRunsToTheEnd() {
    #expect(found("![a](https://example.com/a.png)\n```\n![b](https://example.com/b.png)\n") == ["https://example.com/a.png"])
  }

  @Test func aLongerFenceIsNotClosedByAShorterOne() {
    let body = "````\n```\n![a](https://example.com/a.png)\n```\n````\n![b](https://example.com/b.png)"
    #expect(found(body) == ["https://example.com/b.png"])
  }

  @Test func inlineCodeIsSkipped() {
    #expect(found("use `![a](https://example.com/a.png)` like this, or ``<img src=\"https://example.com/b.png\">`` and ![c](https://example.com/c.png)")
      == ["https://example.com/c.png"])
  }

  @Test func anHTMLCommentIsSkipped() {
    #expect(found("<!-- ![a](https://example.com/a.png) -->\n![b](https://example.com/b.png)") == ["https://example.com/b.png"])
  }

  @Test func duplicatesAppearOnceInOrderOfMention() {
    let body = "![a](https://example.com/a.png) ![b](https://example.com/b.png) <img src=\"https://example.com/a.png\">"
    #expect(found(body) == ["https://example.com/a.png", "https://example.com/b.png"])
  }

  @Test func aLinkToAPDFIsNotMedia() {
    #expect(found("[the report](https://example.com/report.pdf)").isEmpty)
    #expect(found("![the report](https://example.com/report.pdf)").isEmpty) // an image tag doesn't make a PDF media
    #expect(found("<img src=\"https://example.com/installer.zip\">").isEmpty)
  }

  @Test func aPlainLinkToAnImageIsNotMedia() {
    #expect(found("see [the shot](https://example.com/a.png)").isEmpty)
  }

  @Test func anImageInsideALinkIsFoundButTheLinkIsNot() {
    #expect(found("[![a](https://example.com/a.png)](https://example.com/page)") == ["https://example.com/a.png"])
  }

  @Test func aUserAttachmentsFileIsNotMedia() {
    #expect(found("![a](https://github.com/user-attachments/files/123456/log)").isEmpty)
    #expect(found("![a](https://github.com/user-attachments/files/123456/a.png)").isEmpty)
  }

  @Test func extensionlessImagesAreKept() {
    #expect(found("![a](https://avatars.githubusercontent.com/u/123?v=4)") == ["https://avatars.githubusercontent.com/u/123?v=4"])
  }

  @Test func emptyAndMediaFreeBodies() {
    #expect(found("").isEmpty)
    #expect(found("Just words, no media.").isEmpty)
  }

  // MARK: isGitHubAttachment

  func attachment(_ text: String) -> Bool { URL(string: text).map(AssetLinks.isGitHubAttachment) ?? false }

  @Test func anAttachmentAssetOnGitHub() {
    #expect(attachment("https://github.com/user-attachments/assets/5f1b7c36-1c4e-4e0a-9d0c-0e8a3f1c2b9d"))
    #expect(attachment("https://GitHub.com/user-attachments/assets/5f1b7c36"))
  }

  @Test func lookalikeHostsAreRefused() {
    for host in ["github.com.evil.com", "evil-github.com", "notgithub.com", "github.com@evil.com", "githubusercontent.com",
                 "gist.github.com", "api.github.com"] {
      #expect(!attachment("https://\(host)/user-attachments/assets/5f1b7c36"), "\(host)")
    }
    #expect(!attachment("https://github.com@evil.com/user-attachments/assets/5f1b7c36"))
    #expect(!attachment("https://github.com:8443/user-attachments/assets/5f1b7c36"))
    #expect(!attachment("http://github.com/user-attachments/assets/5f1b7c36"))
  }

  @Test func dotDotAndEncodedDotDotAreRefused() {
    #expect(!attachment("https://github.com/user-attachments/assets/../files/123/a.zip"))
    #expect(!attachment("https://github.com/user-attachments/assets/%2e%2e/files/123"))
    #expect(!attachment("https://github.com/user-attachments/assets/..%2Ffiles%2F123"))
    #expect(!attachment("https://github.com/other/user-attachments/assets/5f1b7c36"))
    #expect(!attachment("https://github.com//user-attachments/assets/5f1b7c36"))
  }

  @Test func filesAreNotMedia() {
    #expect(!attachment("https://github.com/user-attachments/files/123456/report.pdf"))
    #expect(!attachment("https://github.com/user-attachments/assets/"))
    #expect(!attachment("https://github.com/user-attachments/assets"))
    #expect(!attachment("https://github.com/user-attachments/assets/a/b"))
  }
}
