import AppKit
import GlanceKit
import SwiftUI
import WebKit

/// A Mermaid diagram, drawn by Web/notes/diagram.html in the app's diagram colours. It sizes itself to the drawing
/// and reports Mermaid's error when the code doesn't render.
struct MermaidView: View {
    let code: String
    var onError: (String?) -> Void = { _ in }
    @State private var height: CGFloat = 120
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MermaidWeb(code: code, dark: colorScheme == .dark, height: $height, onError: onError)
            .frame(height: max(height, 40))
    }
}

private struct MermaidWeb: NSViewRepresentable {
    let code: String
    let dark: Bool
    @Binding var height: CGFloat
    let onError: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakHandler(context.coordinator), name: "glanceDiagram")
        let view = DiagramWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.loadFileURL(Resources.web.appendingPathComponent("notes/diagram.html"), allowingReadAccessTo: Resources.web)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(code: code, dark: dark)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "glanceDiagram")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MermaidWeb
        weak var view: WKWebView?
        private var ready = false
        private var shown: (code: String, dark: Bool)?

        init(_ parent: MermaidWeb) { self.parent = parent }

        /// Draws `code` once the page is ready, and again only when the code or the theme changes.
        func render(code: String, dark: Bool) {
            guard ready, let view, shown?.code != code || shown?.dark != dark else { return }
            shown = (code, dark)
            guard let json = try? JSONSerialization.data(withJSONObject: [code, dark ? "dark" : "light"]),
                  let args = String(data: json, encoding: .utf8) else { return }
            view.evaluateJavaScript("glanceRender(...\(args))")
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
                switch type {
                case "ready":
                    ready = true
                    render(code: parent.code, dark: parent.dark)
                case "size":
                    if let height = (body["height"] as? NSNumber)?.doubleValue, abs(parent.height - height) > 0.5 {
                        parent.height = height
                    }
                case "rendered":
                    parent.onError(nil)
                case "error":
                    parent.onError(body["message"] as? String ?? "Mermaid couldn't draw this.")
                default:
                    break
                }
            }
        }
    }
}

/// Up-and-down scrolling goes to the page around the diagram; only a wide diagram's sideways scroll stays here.
private final class DiagramWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The content controller keeps its handler alive; this keeps the coordinator from being kept with it.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
