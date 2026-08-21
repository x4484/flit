import Foundation

struct GoogleOAuthConfiguration: Sendable, Equatable {
  let clientID: String
  let clientSecret: String?

  static let mailScope = "https://mail.google.com/"
  static let identityScopes = ["openid", "email"]
}

enum GoogleOAuthConfigurationError: Error, LocalizedError {
  case missing(searchedPaths: [String])
  case malformed(path: String)
  case placeholder(path: String)

  var errorDescription: String? {
    switch self {
    case .missing:
      return "Google OAuth setup is required."
    case .malformed:
      return "The Google OAuth configuration is invalid."
    case .placeholder:
      return "Replace the example Google OAuth values before connecting an account."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .missing(let paths):
      return
        "Download a Desktop app OAuth client from Google Cloud and save it as GoogleOAuth.json at \(paths.first ?? "the Flit application support folder")."
    case .malformed(let path):
      return "Download the OAuth client again and replace \(path)."
    case .placeholder(let path):
      return "Replace \(path) with the Desktop app credentials downloaded from Google Cloud."
    }
  }
}

enum GoogleOAuthConfigurationLoader {
  static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws
    -> GoogleOAuthConfiguration
  {
    let candidateURLs = candidateURLs(environment: environment)
    guard let url = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    else {
      throw GoogleOAuthConfigurationError.missing(searchedPaths: candidateURLs.map(\.path))
    }

    let data = try Data(contentsOf: url)
    let file: GoogleClientConfigurationFile
    do {
      file = try JSONDecoder().decode(GoogleClientConfigurationFile.self, from: data)
    } catch {
      throw GoogleOAuthConfigurationError.malformed(path: url.path)
    }

    guard let installed = file.installed, !installed.clientID.isEmpty else {
      throw GoogleOAuthConfigurationError.malformed(path: url.path)
    }
    guard !installed.clientID.contains("YOUR_GOOGLE") else {
      throw GoogleOAuthConfigurationError.placeholder(path: url.path)
    }

    return GoogleOAuthConfiguration(
      clientID: installed.clientID,
      clientSecret: installed.clientSecret?.isEmpty == false ? installed.clientSecret : nil
    )
  }

  static func applicationSupportURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
      .appendingPathComponent("Flit", isDirectory: true)
      .appendingPathComponent("GoogleOAuth.json")
  }

  private static func candidateURLs(environment: [String: String]) -> [URL] {
    var urls: [URL] = []
    if let override = environment["FLIT_GOOGLE_OAUTH_CONFIG"], !override.isEmpty {
      urls.append(URL(fileURLWithPath: override))
    }
    if let bundled = Bundle.main.url(forResource: "GoogleOAuth", withExtension: "json") {
      urls.append(bundled)
    }
    urls.append(applicationSupportURL())
    urls.append(
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Support/GoogleOAuth.local.json")
    )
    return urls
  }
}

private struct GoogleClientConfigurationFile: Decodable {
  let installed: InstalledClient?
}

private struct InstalledClient: Decodable {
  let clientID: String
  let clientSecret: String?

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case clientSecret = "client_secret"
  }
}
