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
