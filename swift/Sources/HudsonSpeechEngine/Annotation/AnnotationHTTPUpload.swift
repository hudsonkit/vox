import Foundation

/// One request owns one ephemeral session/delegate: no cross-account cookies, cache,
/// automatic redirects/retries, or unbounded response buffering.
final class AnnotationHTTPUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maxResponseBytes = 4 * 1024 * 1024
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var session: URLSession?
    private var task: URLSessionUploadTask?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var finished = false

    func perform(_ request: URLRequest, file: URL, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    guard !finished else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                    self.session = session
                    let task = session.uploadTask(with: request, fromFile: file)
                    self.task = task; task.resume()
                }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<(Data, HTTPURLResponse), any Error>?, URLSession?)? in
            guard !finished else { return nil }; finished = true
            let state = (continuation, session)
            continuation = nil; session = nil; task = nil; bytes.removeAll()
            return state
        }
        guard let state else { return }
        state.0?.resume(with: result)
        state.1?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(RemoteAnnotationError.invalidResponse)); completionHandler(.cancel); return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(.failure(RemoteAnnotationError.httpStatus(http.statusCode))); completionHandler(.cancel); return
        }
        guard response.expectedContentLength <= Self.maxResponseBytes else {
            finish(.failure(RemoteAnnotationError.responseTooLarge)); completionHandler(.cancel); return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard bytes.count + data.count <= Self.maxResponseBytes else { return true }
            bytes.append(data); return false
        }
        if overflow { finish(.failure(RemoteAnnotationError.responseTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(RemoteTTSSupport.isCancellation(error) ? CancellationError() : RemoteAnnotationError.transport))
            return
        }
        let result = lock.withLock { () -> (Data, HTTPURLResponse)? in
            guard !finished, let response else { return nil }; return (bytes, response)
        }
        if let result { finish(.success(result)) }
        else { finish(.failure(RemoteAnnotationError.invalidResponse)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Do not forward credentials or replay an upload to another endpoint.
        completionHandler(nil)
    }
}
