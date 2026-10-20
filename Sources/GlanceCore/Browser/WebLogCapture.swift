import Foundation

/// Turns what the injected script (`WebLogScript`) posts, and what the web view's delegate sees of the page's own
/// document, into log entries. Requests arrive in two messages (start, end) and are written as two states of one
/// entry.
public struct WebLogAssembler {
  public var masksSecrets: Bool
  private var nextID = 0
  /// Requests that started and have not ended, by `<frame>:<request>`.
  private var pending: [String: WebLogEntry] = [:]
  private var pendingFrame: [String: String] = [:]

  public init(masksSecrets: Bool = true) { self.masksSecrets = masksSecrets }

  /// The entries to write for one message from the script.
  public mutating func receive(_ body: [String: Any], now: Double = Date().timeIntervalSince1970) -> [WebLogEntry] {
    let time = (Self.number(body["at"]).map { $0 / 1000 }) ?? now
    switch body["t"] as? String {
    case "console":
      var entry = start(.console, time)
      entry.level = (body["level"] as? String) ?? "log"
      entry.text = Self.text(body["text"])
      return [output(entry)]
    case "nav":
      var written: [WebLogEntry] = []
      let frame = body["fid"] as? String ?? ""
      // A new document in the main frame ends what the old one still waited for.
      if body["top"] as? Bool == true, body["spa"] as? Bool != true {
        for (key, old) in pending where pendingFrame[key] != frame {
          var entry = old
          entry.status = 0
          entry.failed = true
          entry.error = "cancelled: the page moved on"
          entry.durationMs = Int(max(0, time - old.time) * 1000)
          written.append(output(entry))
          pending[key] = nil
          pendingFrame[key] = nil
        }
      }
      var entry = start(.navigation, time)
      entry.text = Self.text(body["url"])
      written.append(output(entry))
      return written
    case "net":
      let key = "\(body["fid"] as? String ?? ""):\(Self.number(body["rid"]).map { String(Int($0)) } ?? "")"
      if body["phase"] as? String == "start" {
        var entry = start(.network, time)
        entry.method = body["method"] as? String
        entry.url = Self.text(body["url"])
        entry.via = body["via"] as? String
        entry.requestHeaders = body["requestHeaders"] as? [String: String]
        entry.requestBody = body["requestBody"] as? String
        pending[key] = entry
        pendingFrame[key] = body["fid"] as? String
        return [output(entry)]
      }
      guard var entry = pending.removeValue(forKey: key) else { return [] }
      pendingFrame[key] = nil
      let status = Self.number(body["status"]).map { Int($0) } ?? 0
      entry.status = status
      entry.statusText = body["statusText"] as? String
      entry.durationMs = Self.number(body["durationMs"]).map { Int($0) }
      entry.responseHeaders = body["responseHeaders"] as? [String: String]
      entry.responseBody = body["responseBody"] as? String
      entry.contentType = body["responseType"] as? String
      if let error = body["error"] as? String {
        entry.error = error
        entry.failed = true
      } else if status == 0 {
        entry.error = "no response"
        entry.failed = true
      }
      return [output(entry)]
    default:
      return []
    }
  }

  /// The page's own document answered (the delegate's navigation response): the one request the script can't see.
  public mutating func document(url: String, status: Int, headers: [String: String], contentType: String?,
                                now: Double = Date().timeIntervalSince1970) -> [WebLogEntry] {
    var entry = start(.network, now)
    entry.method = "GET"
    entry.url = url
    entry.via = "document"
    entry.status = status
    entry.responseHeaders = headers
    entry.contentType = contentType
    return [output(entry)]
  }

  /// The page's document never arrived (connection refused, a bad certificate, offline).
  public mutating func documentFailed(url: String?, message: String,
                                      now: Double = Date().timeIntervalSince1970) -> [WebLogEntry] {
    var entry = start(.network, now)
    entry.method = "GET"
    entry.url = url
    entry.via = "document"
    entry.status = 0
    entry.failed = true
    entry.error = message
    return [output(entry)]
  }

  private mutating func start(_ kind: WebLogEntry.Kind, _ time: Double) -> WebLogEntry {
    nextID += 1
    return WebLogEntry(id: nextID, kind: kind, time: time)
  }

  private func output(_ entry: WebLogEntry) -> WebLogEntry {
    masksSecrets ? WebLogRedactor.entry(entry) : entry
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue ?? (value as? Double)
  }

  private static func text(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    return string.count > 20_000 ? String(string.prefix(20_000)) + "…" : string
  }
}

/// The script every Browser tab's pages run first (all frames, the page's own world): it wraps `console`, `fetch`
/// and `XMLHttpRequest`, and listens for errors, and posts each event to the `glanceLog` message handler. It changes
/// nothing a page sees: wrapped calls pass straight through, and nothing here throws into the page.
public enum WebLogScript {
  public static let handlerName = "glanceLog"

  public static let source = #"""
    (function () {
      if (window.__glanceLog) return;
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.glanceLog;
      if (!handler) return;
      try { Object.defineProperty(window, "__glanceLog", { value: true }); } catch (e) { return; }
      var top = window.top === window;
      var fid = Math.random().toString(36).slice(2, 8);
      var seq = 0;
      var MESSAGE = 4000, BODY = 16000;
      function post(m) {
        try {
          m.fid = fid;
          for (var k in m) if (m[k] === undefined) delete m[k];
          handler.postMessage(m);
        } catch (e) {}
      }
      function cut(s, n) { s = String(s); return s.length > n ? s.slice(0, n) + "… [" + (s.length - n) + " more characters]" : s; }
      function show(v) {
        if (typeof v === "string") return v;
        if (v instanceof Error) return v.stack || (v.name + ": " + v.message);
        if (typeof v === "undefined") return "undefined";
        if (typeof v === "function") return "[Function " + (v.name || "anonymous") + "]";
        if (typeof Node !== "undefined" && v instanceof Node) return "<" + (v.nodeName || "node").toLowerCase() + ">";
        try {
          var seen = [];
          var s = JSON.stringify(v, function (k, x) {
            if (typeof x === "bigint") return x.toString() + "n";
            if (x && typeof x === "object") { if (seen.indexOf(x) >= 0) return "[Circular]"; seen.push(x); }
            return x;
          });
          return s === undefined ? String(v) : s;
        } catch (e) { return String(v); }
      }
      function isText(type) {
        return /^(text\/|application\/(json|xml|javascript|x-www-form-urlencoded|graphql)|[^;]*\+(json|xml))/i.test(type || "");
      }

      // Console. A page that logs faster than 200 a second gets the rest counted, not written.
      var windowStart = 0, windowCount = 0, dropped = 0;
      function room() {
        var now = Date.now();
        if (now - windowStart > 1000) {
          if (dropped) {
            post({ t: "console", level: "warn", at: now, text: dropped + " console messages were not logged (too many too fast)" });
          }
          windowStart = now; windowCount = 0; dropped = 0;
        }
        if (++windowCount > 200) { dropped++; return false; }
        return true;
      }
      ["log", "info", "warn", "error", "debug"].forEach(function (level) {
        var original = console[level];
        if (typeof original !== "function") return;
        console[level] = function () {
          try {
            if (room()) {
              post({ t: "console", level: level, at: Date.now(),
                     text: cut(Array.prototype.map.call(arguments, show).join(" "), MESSAGE) });
            }
          } catch (e) {}
          return original.apply(this, arguments);
        };
      });
      window.addEventListener("error", function (e) {
        var target = e.target;
        if (target && target !== window && (target.src || target.href)) {
          post({ t: "console", level: "error", at: Date.now(),
                 text: "Failed to load " + String(target.tagName || "").toLowerCase() + " " + (target.src || target.href) });
          return;
        }
        var where = e.filename ? " (" + e.filename + ":" + e.lineno + ":" + e.colno + ")" : "";
        post({ t: "console", level: "error", at: Date.now(),
               text: cut("Uncaught " + (e.error && e.error.stack ? e.error.stack : e.message + where), MESSAGE) });
      }, true);
      window.addEventListener("unhandledrejection", function (e) {
        post({ t: "console", level: "error", at: Date.now(),
               text: cut("Unhandled promise rejection: " + show(e.reason), MESSAGE) });
      }, true);

      // Page changes.
      post({ t: "nav", url: location.href, top: top, spa: false, at: Date.now() });
      ["pushState", "replaceState"].forEach(function (name) {
        var original = history[name];
        if (typeof original !== "function") return;
        history[name] = function () {
          var result = original.apply(this, arguments);
          post({ t: "nav", url: location.href, top: top, spa: true, at: Date.now() });
          return result;
        };
      });

      // Requests.
      function headersOf(h) {
        var o = {};
        try {
          if (h && !(typeof h.forEach === "function" && !Array.isArray(h))) h = new Headers(h);
          if (h) h.forEach(function (v, k) { o[k] = v; });
        } catch (e) {}
        return o;
      }
      function bodyText(b) {
        if (b == null) return undefined;
        if (typeof b === "string") return cut(b, BODY);
        if (typeof URLSearchParams !== "undefined" && b instanceof URLSearchParams) return cut(b.toString(), BODY);
        if (typeof FormData !== "undefined" && b instanceof FormData) {
          var parts = [];
          b.forEach(function (v, k) { parts.push(k + "=" + (typeof v === "string" ? v : "[file " + (v.name || "") + "]")); });
          return cut(parts.join("&"), BODY);
        }
        if (typeof Blob !== "undefined" && b instanceof Blob) return "[Blob " + b.size + " bytes " + b.type + "]";
        if (b instanceof ArrayBuffer || ArrayBuffer.isView(b)) return "[binary " + b.byteLength + " bytes]";
        return "[" + Object.prototype.toString.call(b) + "]";
      }
      function absolute(u) { try { return new URL(String(u), location.href).href; } catch (e) { return String(u); } }
      function readCapped(res) {
        if (!res.body || !res.body.getReader) return res.text().then(function (t) { return cut(t, BODY); });
        var reader = res.body.getReader(), decoder = new TextDecoder(), text = "", bytes = 0;
        function pump() {
          return reader.read().then(function (r) {
            if (r.done) return cut(text, BODY);
            bytes += r.value.byteLength;
            if (text.length < BODY) text += decoder.decode(r.value, { stream: true });
            if (bytes > 4000000) { reader.cancel(); return cut(text, BODY) + " [stopped reading at 4 MB]"; }
            return pump();
          });
        }
        return pump();
      }

      var realFetch = window.fetch;
      if (typeof realFetch === "function") {
        window.fetch = function (input, init) {
          var rid = ++seq, started = performance.now();
          try {
            var isRequest = typeof Request !== "undefined" && input instanceof Request;
            post({ t: "net", phase: "start", rid: rid, via: "fetch", at: Date.now(),
                   method: String((init && init.method) || (isRequest && input.method) || "GET").toUpperCase(),
                   url: absolute(isRequest ? input.url : input),
                   requestHeaders: headersOf((init && init.headers) || (isRequest ? input.headers : null)),
                   requestBody: init && init.body != null ? bodyText(init.body) : undefined });
          } catch (e) {}
          var promise = realFetch.apply(this, arguments);
          promise.then(function (res) {
            var done = { t: "net", phase: "end", rid: rid, status: res.status, statusText: res.statusText,
                         responseHeaders: headersOf(res.headers), at: Date.now(),
                         responseType: res.headers.get("content-type") || "" };
            var length = parseInt(res.headers.get("content-length") || "", 10);
            if (isText(done.responseType) && !/event-stream/i.test(done.responseType) && !(length > 4000000)) {
              try {
                readCapped(res.clone()).then(function (text) {
                  done.responseBody = text;
                  done.durationMs = Math.round(performance.now() - started);
                  post(done);
                }, function () { done.durationMs = Math.round(performance.now() - started); post(done); });
                return;
              } catch (e) {}
            }
            done.durationMs = Math.round(performance.now() - started);
            post(done);
          }, function (err) {
            post({ t: "net", phase: "end", rid: rid, status: 0, at: Date.now(),
                   durationMs: Math.round(performance.now() - started),
                   error: err && err.name === "AbortError" ? "aborted" : String((err && err.message) || err) });
          });
          return promise;
        };
      }

      var X = window.XMLHttpRequest;
      if (X && X.prototype) {
        var open = X.prototype.open, setHeader = X.prototype.setRequestHeader, sendX = X.prototype.send;
        X.prototype.open = function (method, url) {
          this.__gl = { method: String(method).toUpperCase(), url: absolute(url), headers: {} };
          return open.apply(this, arguments);
        };
        X.prototype.setRequestHeader = function (name, value) {
          if (this.__gl) this.__gl.headers[String(name).toLowerCase()] = String(value);
          return setHeader.apply(this, arguments);
        };
        X.prototype.send = function (body) {
          var xhr = this, meta = xhr.__gl;
          if (meta) {
            var rid = ++seq, started = performance.now();
            post({ t: "net", phase: "start", rid: rid, via: "xhr", at: Date.now(), method: meta.method, url: meta.url,
                   requestHeaders: meta.headers, requestBody: bodyText(body) });
            xhr.addEventListener("abort", function () { meta.why = "aborted"; });
            xhr.addEventListener("timeout", function () { meta.why = "timed out"; });
            xhr.addEventListener("loadend", function () {
              var done = { t: "net", phase: "end", rid: rid, status: xhr.status, statusText: xhr.statusText, at: Date.now(),
                           durationMs: Math.round(performance.now() - started), responseHeaders: {},
                           responseType: xhr.getResponseHeader("content-type") || "" };
              try {
                (xhr.getAllResponseHeaders() || "").trim().split(/[\r\n]+/).forEach(function (line) {
                  var i = line.indexOf(":");
                  if (i > 0) done.responseHeaders[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
                });
              } catch (e) {}
              if (xhr.status === 0) done.error = meta.why || "network error";
              try {
                if ((xhr.responseType === "" || xhr.responseType === "text") && isText(done.responseType)) {
                  done.responseBody = cut(xhr.responseText, BODY);
                }
              } catch (e) {}
              post(done);
            });
          }
          return sendX.apply(this, arguments);
        };
      }
    })();
    """#
}
