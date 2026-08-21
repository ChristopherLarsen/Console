import XCTest
@testable import Console

final class GitHubReleaseClientTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRelease(tag: String, draft: Bool = false, prerelease: Bool = false, name: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "html_url": "https://github.com/ChristopherLarsen/Console/releases/tag/\(tag)",
        ]
        if let name { payload["name"] = name }
        return payload
    }

    private func jsonData(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    // MARK: - Decoding documented fields

    func testDecodesDocumentedFieldsAndIgnoresUnknownOnes() throws {
        let payload = """
        [
          {
            "id": 1,
            "tag_name": "v1.3.0",
            "name": "Console 1.3.0",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/ChristopherLarsen/Console/releases/tag/v1.3.0",
            "assets": [{"browser_download_url": "https://example.com/Console.dmg"}],
            "author": {"login": "ChristopherLarsen"}
          }
        ]
        """.data(using: .utf8)!

        let releases = try JSONDecoder().decode([GitHubRelease].self, from: payload)

        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].tagName, "v1.3.0")
        XCTAssertEqual(releases[0].name, "Console 1.3.0")
        XCTAssertFalse(releases[0].draft)
        XCTAssertFalse(releases[0].prerelease)
        XCTAssertEqual(releases[0].semanticVersion, SemanticVersion(major: 1, minor: 3, patch: 0))
    }

    // MARK: - Qualification

    func testQualifyingCandidatesIgnoreDraftsPrereleasesAndMalformedTags() {
        let releases = [
            GitHubRelease(tagName: "2.0.0", name: nil, draft: true, prerelease: false, htmlURL: nil),
            GitHubRelease(tagName: "1.9.0-rc.1", name: nil, draft: false, prerelease: true, htmlURL: nil),
            GitHubRelease(tagName: "not-a-version", name: nil, draft: false, prerelease: false, htmlURL: nil),
            GitHubRelease(tagName: "1.4", name: nil, draft: false, prerelease: false, htmlURL: nil),
        ]
        XCTAssertTrue(GitHubRelease.qualifyingCandidates(in: releases).isEmpty)
    }

    func testHighestQualifyingVersionWins() throws {
        let payload = jsonData([
            makeRelease(tag: "v1.3.0"),
            makeRelease(tag: "v1.4.0"),
            makeRelease(tag: "v2.0.0"),
            makeRelease(tag: "v0.9.9"),
        ])
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: payload)
        let current = SemanticVersion(major: 1, minor: 2, patch: 3)

        let update = GitHubRelease.qualifyingUpdate(from: current, in: releases)

        XCTAssertEqual(update?.tagName, "v2.0.0")
    }

    func testQualifyingUpdateIgnoresPatchOnlyAndEmptyLists() {
        let current = SemanticVersion(major: 1, minor: 2, patch: 3)
        XCTAssertNil(GitHubRelease.qualifyingUpdate(from: current, in: []))

        let patchOnly = [
            GitHubRelease(tagName: "v1.2.4", name: nil, draft: false, prerelease: false, htmlURL: nil),
            GitHubRelease(tagName: "v1.2.10", name: nil, draft: false, prerelease: false, htmlURL: nil),
        ]
        XCTAssertNil(GitHubRelease.qualifyingUpdate(from: current, in: patchOnly))
    }

    // MARK: - Client against a stubbed transport

    private func makeClient(statusCode: Int, data: Data, error: Error? = nil) -> GitHubReleaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.statusCode = statusCode
        StubURLProtocol.respondedData = data
        StubURLProtocol.error = error
        return GitHubReleaseClient(session: URLSession(configuration: configuration))
    }

    func testClientReturnsDecodedReleases() async throws {
        let client = makeClient(statusCode: 200, data: jsonData([makeRelease(tag: "v1.4.0")]))

        let releases = try await client.fetchReleases()

        XCTAssertEqual(releases.map(\.tagName), ["v1.4.0"])
    }

    func testClientSurfacesHTTPStatusAsActionableError() async {
        let client = makeClient(statusCode: 503, data: Data("unavailable".utf8))

        do {
            _ = try await client.fetchReleases()
            XCTFail("Expected an error")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .httpStatus(503))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testClientSurfacesDecodingFailures() async {
        let client = makeClient(statusCode: 200, data: Data("<html>gateway</html>".utf8))

        do {
            _ = try await client.fetchReleases()
            XCTFail("Expected an error")
        } catch let error as UpdateError {
            guard case .decoding = error else {
                return XCTFail("Expected decoding error, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testClientMaps404ToRepositoryUnavailable() async {
        let client = makeClient(statusCode: 404, data: Data("not found".utf8))

        do {
            _ = try await client.fetchReleases()
            XCTFail("Expected an error")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .repositoryUnavailable)
            XCTAssertEqual(error.errorDescription, "The Console releases repository is not publicly readable.")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testClientMaps403And429ToRateLimited() async {
        for status in [403, 429] {
            let client = makeClient(statusCode: status, data: Data())
            do {
                _ = try await client.fetchReleases()
                XCTFail("Expected an error for HTTP \(status)")
            } catch let error as UpdateError {
                XCTAssertEqual(error, .rateLimited, "HTTP \(status)")
            } catch {
                XCTFail("Unexpected error type for HTTP \(status): \(error)")
            }
        }
    }

    func testClientMapsOfflineURLError() async {
        let client = makeClient(statusCode: 200, data: Data(), error: URLError(.notConnectedToInternet))

        do {
            _ = try await client.fetchReleases()
            XCTFail("Expected an error")
        } catch let error as UpdateError {
            XCTAssertEqual(error, .offline)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

/// Minimal URLProtocol stand-in so tests never touch the network.
final class StubURLProtocol: URLProtocol {

    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var respondedData: Data = Data()
    nonisolated(unsafe) static var error: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.github.com")!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.respondedData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
