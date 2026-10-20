import Foundation

/// A failure shown to the user in the editor tab.
struct EditorError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs a helper program (tar, the server's extension installer, the login shell) off the main thread.
enum EditorProcess {
    /// Its standard output and error together. Throws with the last of that output when it exits non-zero, and stops it
    /// after `timeout` seconds.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 120) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment { process.environment = environment }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = output.text
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let name = (executable as NSString).lastPathComponent
                    continuation.resume(throwing: EditorError("\(name) failed: \(text.suffix(400))"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// A download with progress, to a temporary file the caller owns.
enum EditorDownload {
    static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<URL, Error>?
        private let progress: @MainActor (Double) -> Void
        init(progress: @escaping @MainActor (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let progress = self.progress
            Task { @MainActor in progress(fraction) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // URLSession deletes `location` when this returns: keep the file first.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw EditorError("The editor download failed (HTTP \(http.statusCode)).")
                }
                try FileManager.default.moveItem(at: location, to: kept)
                continuation?.resume(returning: kept)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: EditorError("The editor couldn't be downloaded: \(error.localizedDescription)"))
        }
    }
}
