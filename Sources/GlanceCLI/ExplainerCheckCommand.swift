import Foundation
import GlanceCore
import GlanceKit

/// `glance explainer-check <reply.md> [--ask <text>] [--out <folder>]`: the real page writer on one reply you pick. It
/// writes the fragment and a page to open in a browser, and prints how long it took and whether the checks passed. It
/// spends one Sonnet run on your plan and reads nothing but the file you name.
enum ExplainerCheckCommand {
  static func run(_ arguments: [String]) -> Int32 {
    var path: String?, ask: String?, out: String?, rest = arguments[...]
    while let word = rest.popFirst() {
      switch word {
      case "--ask": ask = rest.popFirst()
      case "--out": out = rest.popFirst()
      default: path = word
      }
    }
    guard let path, let reply = try? String(contentsOfFile: path, encoding: .utf8) else {
      print("usage: glance explainer-check <reply.md> [--ask <text>] [--out <folder>]")
      return 2
    }
    let folder = URL(fileURLWithPath: out ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-explainer-check"), isDirectory: true)
    let rows = [TimelineRow(id: "reply", kind: .prose(markdown: reply), time: nil, parent: nil)]
    let turn = ReplyTurn(replyID: "reply", ask: ask, rows: rows)
    let prompt = ExplainerInput.prompt(turn: turn)
    return MainActor.assumeIsolated { () -> Int32 in
      let started = Date()
      var code: Int32?
      let run = ExplainerPageRun()
      run.start(prompt: prompt) { event in
        switch event {
        case .answer(let answer):
          print(String(format: "%.1fs answer: %@", Date().timeIntervalSince(started), answer))
        case .page(let page):
          print(String(format: "%.1fs page: %d beats", Date().timeIntervalSince(started), page.beats.count))
          for beat in page.beats { print("  \(beat.id): \(beat.title)") }
          do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(page.fragment.utf8).write(to: folder.appendingPathComponent("fragment.html"))
            let css = (try? ExplainerPageWeb.css()) ?? ""
            let script = (try? String(contentsOf: Resources.web.appendingPathComponent("explainer/runtime.js"), encoding: .utf8)) ?? ""
            let preview = page.document(css: css, dark: true)
              .replacingOccurrences(of: "default-src 'none'; style-src 'unsafe-inline'", with: "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
              .replacingOccurrences(of: "</body>", with: "<script>\(script)</script></body>")
              .replacingOccurrences(of: "<body>", with: "<body style=\"background:#161513;max-width:660px;margin:24px auto\">")
            try Data(preview.utf8).write(to: folder.appendingPathComponent("preview.html"))
            print("wrote \(folder.path)/preview.html")
            code = 0
          } catch {
            print("couldn't write the preview: \(error.localizedDescription)")
            code = 1
          }
        case .failed(let message):
          print("failed: \(message)")
          code = 1
        }
      }
      while code == nil { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1)) }
      return code ?? 1
    }
  }
}
