import Foundation

/// The browser tab a loopback sign-in lands on (Google's and Glance Cloud's), in MASTER's dark surface and coral. The
/// title and line can carry a provider's error text, so both are escaped.
public enum LoopbackPage {
  public static func html(title: String, line: String) -> String {
    let title = escaped(title), line = escaped(line)
    return """
    <!doctype html><meta charset="utf-8"><title>\(title)</title>
    <body style="margin:0;height:100vh;display:grid;place-items:center;background:#121110;color:#F1EDE4;
    font:15px -apple-system,system-ui,sans-serif"><div style="text-align:center">
    <div style="width:14px;height:14px;border-radius:50%;background:#E8643C;margin:0 auto 16px;
    box-shadow:0 0 18px #E8643C"></div><h1 style="font-size:20px;font-weight:600;margin:0 0 6px">\(title)</h1>
    <p style="margin:0;color:#9A948A">\(line)</p></div></body>
    """
  }

  static func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}
