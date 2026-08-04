import Foundation

/// A stand-in for the model endpoint. Every notes test runs against this, so
/// the default suite never opens a network connection.
final class StubEndpoint: URLProtocol {

    struct Exchange: @unchecked Sendable {
        var status: Int = 200
        var body: Data = Data()
        var failure: URLError?
        /// Filled in by the protocol so a test can assert what was sent.
        var recordedRequest: URLRequest?
        var recordedBody: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var exchange = Exchange()

    static func expect(status: Int = 200, json: String) {
        lock.lock()
        defer { lock.unlock() }
        exchange = Exchange(status: status, body: Data(json.utf8))
    }

    static func expectFailure(_ error: URLError) {
        lock.lock()
        defer { lock.unlock() }
        exchange = Exchange(failure: error)
    }

    static func lastRequest() -> (URLRequest?, Data?) {
        lock.lock()
        defer { lock.unlock() }
        return (exchange.recordedRequest, exchange.recordedBody)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubEndpoint.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubEndpoint.lock.lock()
        var current = StubEndpoint.exchange
        current.recordedRequest = request
        current.recordedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4_096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        StubEndpoint.exchange = current
        StubEndpoint.lock.unlock()

        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: current.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
