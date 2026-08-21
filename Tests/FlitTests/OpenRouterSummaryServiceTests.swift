import Foundation
import Testing

@testable import Flit

@Suite(.serialized)
struct OpenRouterSummaryServiceTests {
  @Test
  func requestsTheConfiguredModelAndReturnsOneNormalizedLine() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
    let session = URLSession(configuration: configuration)

    OpenRouterMockURLProtocol.handler = { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
      let body = try #require(requestBody(request))
      let payload = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      #expect(payload["model"] as? String == OpenRouterSummaryService.model)
      let messages = try #require(payload["messages"] as? [[String: Any]])
      #expect(messages.count == 2)
      #expect((messages.last?["content"] as? String)?.contains("Subject: Project update") == true)

      let response = try #require(
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        ))
      let data = Data(
        #"{"choices":[{"message":{"role":"assistant","content":"The project is on track. A second sentence must be removed.\n"}}]}"#.utf8
      )
      return (response, data)
    }
    defer { OpenRouterMockURLProtocol.handler = nil }

    let summary = try await OpenRouterSummaryService(session: session).summarize(
      sender: "Maya <maya@example.com>",
      subject: "Project update",
      readableBody: "The implementation is on track for Friday.",
      apiKey: "test-key"
    )

    #expect(summary == "The project is on track.")
  }

  @Test
  func boundsEmailBodySentToOpenRouter() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
    let session = URLSession(configuration: configuration)

    OpenRouterMockURLProtocol.handler = { request in
      let body = try #require(requestBody(request))
      let payload = try #require(
        try JSONSerialization.jsonObject(with: body) as? [String: Any]
      )
      let messages = try #require(payload["messages"] as? [[String: Any]])
      let content = try #require(messages.last?["content"] as? String)
      #expect(!content.contains("END-MARKER"))

      let response = try #require(
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      return (
        response,
        Data(#"{"choices":[{"message":{"role":"assistant","content":"Bounded."}}]}"#.utf8)
      )
    }
    defer { OpenRouterMockURLProtocol.handler = nil }

    _ = try await OpenRouterSummaryService(session: session).summarize(
      sender: "Sender",
      subject: "Long email",
      readableBody: String(repeating: "a", count: 24_001) + "END-MARKER",
      apiKey: "test-key"
    )
  }
}

private func requestBody(_ request: URLRequest) -> Data? {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return nil }
  stream.open()
  defer { stream.close() }
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count <= 0 { break }
    data.append(buffer, count: count)
  }
  return data
}

private final class OpenRouterMockURLProtocol: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let handler = try #require(Self.handler)
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
