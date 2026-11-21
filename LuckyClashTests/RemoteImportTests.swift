import Foundation
import Testing
@testable import LuckyClash

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
        #expect(RemoteImport.url(from: "example.com/config.yaml")?.absoluteString
            == "https://example.com/config.yaml")
    }

    @Test func streamingDownloadReturnsBodyAndHeaders() async throws {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Subscription-Userinfo": "upload=7; download=8"]
                )!,
                Data("proxies:\n".utf8)
            )
        }
        let response = try await RemoteImport.download(
            URL(string: "https://example.com/config.yaml")!, configuration: streamingConfiguration()
        )
        #expect(String(decoding: response.data, as: UTF8.self) == "proxies:\n")
        #expect(response.header("subscription-userinfo") == "upload=7; download=8")
    }

    @Test func streamingDownloadRejectsDeclaredOversizeContent() async {
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
            _ = try await RemoteImport.download(
                URL(string: "https://example.com/config.yaml")!, configuration: streamingConfiguration()
            )
            Issue.record("Expected a size failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .tooLarge)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func streamingDownloadRefusesHTTPRedirect() async {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: nil,
                    headerFields: ["Location": "http://example.com/config.yaml"]
                )!,
                Data()
            )
        }
        do {
            _ = try await RemoteImport.download(
                URL(string: "https://example.com/config.yaml")!, configuration: streamingConfiguration()
            )
            Issue.record("Expected an insecure-scheme failure")
        } catch let failure as RemoteImport.Failure {
            #expect(failure == .insecureScheme || failure == .status(302))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func downloadReturnsLowercasedHeaders() async throws {
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: [
                        "Subscription-Userinfo": "upload=1; download=2; total=3",
                        "Profile-Update-Interval": "6"
                    ]
                )!,
                Data("proxies: []".utf8)
            )
        }
        let response = try await RemoteImport.download(
            URL(string: "https://example.com/config.yaml")!, session: session()
        )
        #expect(response.header("subscription-userinfo") == "upload=1; download=2; total=3")
        #expect(response.header("profile-update-interval") == "6")
    }

    @Test func downloadsAdvertiseMetaCapableUserAgent() async throws {
        for useSession in [true, false] {
            var userAgent: String?
            StubURLProtocol.handler = { request in
                userAgent = request.value(forHTTPHeaderField: "User-Agent")
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!,
                    Data("proxies: []".utf8)
                )
            }
            let url = URL(string: "https://example.com/config.yaml")!
            if useSession {
                _ = try await RemoteImport.fetch(url, session: session())
            } else {
                _ = try await RemoteImport.download(url, configuration: streamingConfiguration())
            }
            #expect(userAgent == RemoteImport.userAgent)
        }
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
        URLSession(configuration: streamingConfiguration())
    }

    private func streamingConfiguration() -> URLSessionConfiguration {
        let configuration = RemoteImport.configuration
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
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
