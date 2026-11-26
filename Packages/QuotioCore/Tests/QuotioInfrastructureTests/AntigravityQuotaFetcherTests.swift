import Foundation
import XCTest

@testable import QuotioApplication
@testable import QuotioDomain
@testable import QuotioInfrastructure

final class AntigravityQuotaFetcherTests: XCTestCase {
  func testLocalStorePreservesLegacyAccountKeyAndUnknownFieldsWhenRefreshing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("antigravity-person_gmail_com.json")
    try Data(
      #"{"access_token":"old","refresh_token":"refresh","expired":"2020-01-01T00:00:00Z","disabled":true,"project_id":"kept"}"#
        .utf8
    ).write(to: file)
    let store = LocalAntigravityCredentialStore(authDirectory: directory.path)

    let credentials = await store.credentials()
    var credential = try XCTUnwrap(credentials.first)
    XCTAssertEqual(credential.accountKey, "person@gmail.com")
    credential.accessToken = "new"
    credential.expiresAt = Date(timeIntervalSince1970: 2_000_000_000)
    await store.save(credential, expiresIn: 3600)

    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    XCTAssertEqual(json["access_token"] as? String, "new")
    XCTAssertEqual(json["disabled"] as? Bool, true)
    XCTAssertEqual(json["project_id"] as? String, "kept")
    XCTAssertEqual(json["expires_in"] as? Int, 3600)
  }

  func testProviderAndAccountScopesMapSummaryAndSubscriptionUsingLegacyRequests() async throws {
    let credentials = StubAntigravityCredentials(values: [
      .init(accountKey: "first@example.com", accessToken: "first", origin: .native),
      .init(accountKey: "second@example.com", accessToken: "second", origin: .native),
    ])
    let session = AntigravitySession { request in
      switch request.url?.lastPathComponent {
      case "v1internal:loadCodeAssist":
        return (
          #"{"currentTier":{"id":"pro","name":"Pro","description":"Paid"},"cloudaicompanionProject":"project-1"}"#,
          200
        )
      case "v1internal:retrieveUserQuotaSummary":
        return (
          #"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"five-hour-session","remainingFraction":0.25,"resetTime":"2026-01-01T00:00:00Z"},{"bucketId":"weekly","remaining":{"case":"remainingFraction","value":"0.75"}}]},{"name":"Claude and GPT","buckets":[{"name":"weekly","remaining_fraction":1.2}]}]}"#,
          200
        )
      default: return ("{}", 500)
      }
    }
    let fetcher = AntigravityQuotaFetcher(
      localCredentials: credentials, credentialWriter: NoopAntigravityWriter(), session: session)

    for mode in [QuotaOperatingMode.localProxy, .monitor] {
      let output = try await fetcher.fetch(
        .init(provider: .antigravity, scope: .account("second@example.com"), mode: mode))
      XCTAssertEqual(Set(output.quotas.keys), ["second@example.com"])
      XCTAssertEqual(output.subscriptions["second@example.com"]?.effectiveTier?.id, "pro")
      XCTAssertEqual(
        output.quotas["second@example.com"]?.models.map(\.name),
        [
          "antigravity-gemini-session", "antigravity-gemini-weekly",
          "antigravity-claude-gpt-weekly",
        ])
      XCTAssertEqual(output.quotas["second@example.com"]?.models.map(\.percentage), [25, 75, 100])
    }
    let requests = await session.requests()
    XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "POST" })
    XCTAssertTrue(
      requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer second" })
    XCTAssertTrue(
      requests.allSatisfy { request in
        let expectedUA: String
        switch request.url?.lastPathComponent {
        case "v1internal:retrieveUserQuotaSummary":
          expectedUA = "antigravity/hub/2.23.0 darwin/arm64"
        case "v1internal:loadCodeAssist":
          expectedUA = "agy"
        default:
          expectedUA = "antigravity/1.11.3 Darwin/arm64"
        }
        return request.value(forHTTPHeaderField: "User-Agent") == expectedUA
      })
    XCTAssertTrue(
      requests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" })
    let subscriptionBody = try XCTUnwrap(
      requests.first { $0.url?.lastPathComponent == "v1internal:loadCodeAssist" }?.httpBody)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: subscriptionBody) as? [String: Any])
    XCTAssertEqual((object["metadata"] as? [String: String])?["ideType"], "ANTIGRAVITY")
  }

  func testParseSummarySeparatesGeminiArgonAndThirdPartyBuckets() throws {
    let payload = Data(
      #"{"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","remainingFraction":0.64,"resetTime":"2026-11-25T10:46:34Z"},{"bucketId":"gemini-weekly","remainingFraction":0.91,"resetTime":"2026-12-02T05:46:34Z"}]},{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-wtu-weekly","remainingFraction":0.15}]},{"displayName":"Third-party","buckets":[{"bucketId":"3p-5h","remainingFraction":1.0},{"bucketId":"3p-weekly","remainingFraction":1.0}]}]}"#
        .utf8
    )

    let metrics = try XCTUnwrap(AntigravityQuotaFetcher.parseSummary(payload))
    XCTAssertEqual(
      metrics.map(\.name),
      [
        "antigravity-gemini-session",
        "antigravity-gemini-weekly",
        "antigravity-argon-weekly",
        "antigravity-claude-gpt-session",
        "antigravity-claude-gpt-weekly",
      ]
    )
    XCTAssertEqual(metrics.map(\.percentage), [64, 91, 15, 100, 100])
  }

  func testFallbackMapsForbiddenWithoutRetrying() async throws {
    let credentials = StubAntigravityCredentials(values: [
      .init(accountKey: "account", accessToken: "token", origin: .native)
    ])
    let session = AntigravitySession { request in
      switch request.url?.lastPathComponent {
      case "v1internal:fetchAvailableModels": return ("denied", 403)
      default: return ("{}", 404)
      }
    }
    let fetcher = AntigravityQuotaFetcher(
      localCredentials: credentials,
      credentialWriter: NoopAntigravityWriter(),
      session: session,
      sleep: {}
    )

    let output = try await fetcher.fetch(.init(provider: .antigravity, mode: .localProxy))
    XCTAssertEqual(output.quotas["account"]?.isForbidden, true)
    let modelRequests = await session.requests().filter {
      $0.url?.lastPathComponent == "v1internal:fetchAvailableModels"
    }
    XCTAssertEqual(modelRequests.count, 1)
  }

  func testFallbackRetriesTransientModelFailureThreeTimes() async throws {
    let credentials = StubAntigravityCredentials(values: [
      .init(accountKey: "account", accessToken: "token", origin: .native)
    ])
    let session = AntigravitySession { request in
      request.url?.lastPathComponent == "v1internal:fetchAvailableModels"
        ? ("unavailable", 500) : ("{}", 404)
    }
    let fetcher = AntigravityQuotaFetcher(
      localCredentials: credentials,
      credentialWriter: NoopAntigravityWriter(),
      session: session,
      sleep: {}
    )

    let output = try await fetcher.fetch(.init(provider: .antigravity, mode: .localProxy))
    XCTAssertTrue(output.quotas.isEmpty)
    let modelRequests = await session.requests().filter {
      $0.url?.lastPathComponent == "v1internal:fetchAvailableModels"
    }
    XCTAssertEqual(modelRequests.count, 3)
  }
}

private struct StubAntigravityCredentials: AntigravityCredentialReading {
  let values: [AntigravityCredential]
  func credentials() async -> [AntigravityCredential] { values }
}

private struct NoopAntigravityWriter: AntigravityCredentialWriting {
  func save(_ credential: AntigravityCredential, expiresIn: Int) async {}
}

private actor AntigravitySession: QuotaHTTPSession {
  typealias Response = @Sendable (URLRequest) -> (String, Int)
  private let response: Response
  private var recorded: [URLRequest] = []

  init(response: @escaping Response) { self.response = response }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    recorded.append(request)
    let (body, status) = response(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }

  func requests() -> [URLRequest] { recorded }
}
