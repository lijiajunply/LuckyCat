import Foundation
import Testing
@testable import LuckyCat

@MainActor
@Suite(.serialized)
struct RemoteImportTests {
    @Test func validatesSchemeAndCredentialFreeURLs() {
        #expect(RemoteImport.url(from: "https://example.com/config.yaml") != nil)
        #expect(RemoteImport.url(from: "  https://example.com/config.yaml  ") != nil)
        #expect(RemoteImport.url(from: "http://example.com/config.yaml") == nil)
        #expect(RemoteImport.url(from: "file:///tmp/config.yaml") == nil)
        #expect(RemoteImport.url(from: "https://user:secret@example.com/config.yaml") == nil)
        #expect(RemoteImport.url(from: "https://") == nil)
    }

    @Test func fetchRejectsNonHTTPSWithoutARequest() async {
        let url = URL(string: "http://example.com/config.yaml")!
        do {
            _ = try await RemoteImport.fetch(url)
            Issue.record("Expected an insecure-scheme failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .insecureScheme)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func fetchReturnsBody() async throws {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("proxies:\n".utf8)
            )
        }
        let data = try await RemoteImport.fetch(
            URL(string: "https://example.com/config.yaml")!, session: session()
        )
        #expect(String(decoding: data, as: UTF8.self) == "proxies:\n")
    }

    @Test func fetchRejectsHTTPStatus() async {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        do {
            _ = try await RemoteImport.fetch(
                URL(string: "https://example.com/config.yaml")!, session: session()
            )
            Issue.record("Expected a status failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .status(404))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func fetchRejectsDeclaredOversizeContent() async {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Length": "\(RemoteImport.maximumBytes + 1)"]
                )!,
                Data()
            )
        }
        do {
            _ = try await RemoteImport.fetch(
                URL(string: "https://example.com/config.yaml")!, session: session()
            )
            Issue.record("Expected a size failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .tooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func fetchStopsWhenStreamedBodyExceedsLimit() async {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(repeating: 32, count: RemoteImport.maximumBytes + 1)
            )
        }
        do {
            _ = try await RemoteImport.fetch(
                URL(string: "https://example.com/config.yaml")!, session: session()
            )
            Issue.record("Expected a size failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .tooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func fetchRejectsRedirectToHTTP() async {
        StubURLProtocol.handler = { _ in
            (
                HTTPURLResponse(
                    url: URL(string: "http://example.com/config.yaml")!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                Data("proxies:\n".utf8)
            )
        }
        do {
            _ = try await RemoteImport.fetch(
                URL(string: "https://example.com/config.yaml")!, session: session()
            )
            Issue.record("Expected an insecure-scheme failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .insecureScheme)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: RemoteImport.Failure.network)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
