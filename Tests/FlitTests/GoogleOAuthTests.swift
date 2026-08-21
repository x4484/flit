import Foundation
import Testing

@testable import Flit

struct GoogleOAuthTests {
  @Test
  func pkceMatchesRFC7636Vector() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    #expect(PKCEPair.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test
  func loadsDownloadedDesktopClientConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FlitOAuthTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("client.json")
    try Data(
      """
      {
        "installed": {
          "client_id": "flit.apps.googleusercontent.com",
          "client_secret": "desktop-secret"
        }
      }
      """.utf8
    ).write(to: fileURL)

    let configuration = try GoogleOAuthConfigurationLoader.load(environment: [
      "FLIT_GOOGLE_OAUTH_CONFIG": fileURL.path
    ])
    #expect(configuration.clientID == "flit.apps.googleusercontent.com")
    #expect(configuration.clientSecret == "desktop-secret")
  }

  @Test
  func loopbackCallbackPreservesTheAuthorizedRedirectPort() throws {
    let callbackBaseURL = try #require(
      URL(string: "http://127.0.0.1:49152/oauth2/callback"))
    let request =
      "GET /oauth2/callback?code=authorization-code&state=state HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n"

    let redirectURL = try #require(
      LoopbackOAuthReceiver.redirectURL(from: request, relativeTo: callbackBaseURL))

    #expect(redirectURL.scheme == "http")
    #expect(redirectURL.host == "127.0.0.1")
    #expect(redirectURL.port == 49152)
    #expect(redirectURL.path == "/oauth2/callback")
    #expect(URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)?.queryItems?.count == 2)
  }

  @Test
  func xoauth2ResponseUsesGoogleSASLFormat() throws {
    let encoded = GmailXOAUTH2.initialClientResponse(
      email: "person@example.com",
      accessToken: "access-token"
    )
    let data = try #require(Data(base64Encoded: encoded))
    #expect(
      String(decoding: data, as: UTF8.self)
        == "user=person@example.com\u{1}auth=Bearer access-token\u{1}\u{1}"
    )
  }
}
