import Foundation
import GlanceCore
import WebKit

/// Serves `glance-file://project/<path>` (`PreviewFiles`) to the editor's preview: the images, stylesheets and scripts a
/// Markdown or HTML file refers to. Only files inside the project root, read off the main thread. There is no CORS
/// header, so a previewed page can show and run project files but can't read their bytes with fetch.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
  private let files: FileService
  private let queue = DispatchQueue(label: "dev.glance.editor.preview", qos: .userInitiated)
  /// Tasks WebKit hasn't stopped yet, by identity. Answering a stopped task throws an Objective-C exception. The read's
  /// answer looks its task up here on the main actor, so the task never crosses queues.
  private var live: [ObjectIdentifier: any WKURLSchemeTask] = [:]

  init(files: FileService) {
    self.files = files
  }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url, let path = PreviewFiles.path(from: url) else {
      task.didFailWithError(URLError(.badURL))
      return
    }
    let key = ObjectIdentifier(task)
    live[key] = task
    queue.async { [files] in
      let result = Result { try files.readData(path) }
      DispatchQueue.main.async { [weak self] in
        guard let self, let task = self.live.removeValue(forKey: key) else { return }
        switch result {
        case .success(let data):
          let headers = ["Content-Type": PreviewFiles.mimeType(forPath: path), "Content-Length": String(data.count),
                         "Cache-Control": "no-cache"]
          let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: PreviewFiles.mimeType(forPath: path), expectedContentLength: data.count,
                           textEncodingName: nil)
          task.didReceive(response)
          task.didReceive(data)
          task.didFinish()
        case .failure:
          task.didFailWithError(URLError(.fileDoesNotExist))
        }
      }
    }
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
    live[ObjectIdentifier(task)] = nil
  }
}
