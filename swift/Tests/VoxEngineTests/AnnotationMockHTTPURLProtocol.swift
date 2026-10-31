import Foundation

final class AnnotationMockHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int
        var headers: [String: String]
        var body: Data

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) static var defaultStub = Stub()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var failure: Error?

    static func session(
        body: Data = Data(),
        statusCode: Int = 200,
        contentType: String = "audio/wav",
        stubs: [String: Stub] = [:],
        error: Error? = nil
    ) -> URLSession {
        lock.lock()
        self.stubs = stubs
        self.defaultStub = Stub(
            statusCode: statusCode,
            headers: ["content-type": contentType],
            body: body
        )
        lastRequest = nil
        lastBody = nil
        requests = []
        bodies = []
        failure = error
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AnnotationMockHTTPURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.lock()
        Self.lastRequest = request
        Self.lastBody = body
        Self.requests.append(request)
        Self.bodies.append(body)
        let failure = Self.failure
        let stub = request.url.flatMap { Self.stubs[$0.path] } ?? Self.defaultStub
        Self.lock.unlock()
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
