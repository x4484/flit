import AppKit
import Foundation

struct GoogleAccessSession: Sendable, Equatable {
  let email: String
  let accessToken: String
  let expiresAt: Date
}

struct StoredGoogleCredential: Codable, Sendable, Equatable {
  let email: String
  let refreshToken: String
}

final class GoogleOAuthService: @unchecked Sendable {
  private let configuration: GoogleOAuthConfiguration
  private let keychain: KeychainStore
  private let session: URLSession

  init(
    configuration: GoogleOAuthConfiguration,
    keychain: KeychainStore = KeychainStore(),
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.keychain = keychain
    self.session = session
  }

  func authorize(email: String) async throws -> GoogleAccessSession {
    let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedEmail.contains("@") else { throw GoogleOAuthError.invalidEmail }

    let pkce = PKCEPair.generate()
    let state = PKCEPair.generate(byteCount: 24).verifier
    let receiver = LoopbackOAuthReceiver()

    let callbackURL = try await receiver.receiveRedirect { [configuration] redirectURL in
      guard
        let authorizationURL = Self.authorizationURL(
          configuration: configuration,
          redirectURL: redirectURL,
          email: normalizedEmail,
          state: state,
          challenge: pkce.challenge
        )
      else {
        receiver.cancel()
        return
      }

      Task { @MainActor in
        if !NSWorkspace.shared.open(authorizationURL) {
          receiver.cancel()
        }
      }
    }

    let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    let values = Dictionary(
      uniqueKeysWithValues: (callback?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    if let message = values["error"] {
      throw GoogleOAuthError.authorizationDenied(message)
    }
    guard values["state"] == state else { throw GoogleOAuthError.stateMismatch }
    guard let code = values["code"], !code.isEmpty else { throw GoogleOAuthError.missingCode }

    var redirectComponents = callback
    redirectComponents?.query = nil
    redirectComponents?.fragment = nil
    guard let redirectURL = redirectComponents?.url else { throw GoogleOAuthError.invalidRedirect }

    let token = try await exchangeAuthorizationCode(
      code,
      redirectURL: redirectURL,
      verifier: pkce.verifier
    )
    guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
      throw GoogleOAuthError.missingRefreshToken
    }

    let credential = StoredGoogleCredential(email: normalizedEmail, refreshToken: refreshToken)
    try keychain.save(
      try JSONEncoder().encode(credential), account: keychainAccount(normalizedEmail))

    return GoogleAccessSession(
      email: normalizedEmail,
      accessToken: token.accessToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
    )
  }

  func refreshAccessToken(email: String) async throws -> GoogleAccessSession {
    let normalizedEmail = email.lowercased()
    guard let data = try keychain.data(account: keychainAccount(normalizedEmail)) else {
      throw GoogleOAuthError.missingStoredCredential
    }
    let credential = try JSONDecoder().decode(StoredGoogleCredential.self, from: data)

    var parameters = [
      "client_id": configuration.clientID,
      "refresh_token": credential.refreshToken,
      "grant_type": "refresh_token",
    ]
    if let secret = configuration.clientSecret {
      parameters["client_secret"] = secret
    }
    let token: GoogleTokenResponse = try await postToken(parameters)
    return GoogleAccessSession(
      email: normalizedEmail,
      accessToken: token.accessToken,
      expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
    )
  }

  func disconnect(email: String) throws {
    try keychain.delete(account: keychainAccount(email.lowercased()))
  }

  private func exchangeAuthorizationCode(
    _ code: String,
    redirectURL: URL,
    verifier: String
  ) async throws -> GoogleTokenResponse {
    var parameters = [
      "client_id": configuration.clientID,
      "code": code,
      "code_verifier": verifier,
      "grant_type": "authorization_code",
      "redirect_uri": redirectURL.absoluteString,
    ]
    if let secret = configuration.clientSecret {
      parameters["client_secret"] = secret
    }
    return try await postToken(parameters)
  }

  private func postToken<T: Decodable>(_ parameters: [String: String]) async throws -> T {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formBody(parameters)

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let details = String(data: data, encoding: .utf8) ?? "Unknown response"
      throw GoogleOAuthError.tokenExchangeFailed(details)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func keychainAccount(_ email: String) -> String {
    "gmail:\(email)"
  }

  private static func authorizationURL(
    configuration: GoogleOAuthConfiguration,
    redirectURL: URL,
    email: String,
    state: String,
    challenge: String
  ) -> URL? {
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
    let scopes = [GoogleOAuthConfiguration.mailScope] + GoogleOAuthConfiguration.identityScopes
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: configuration.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "login_hint", value: email),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    return components?.url
  }

  private static func formBody(_ parameters: [String: String]) -> Data? {
    var components = URLComponents()
    components.queryItems = parameters.sorted { $0.key < $1.key }
      .map { URLQueryItem(name: $0.key, value: $0.value) }
    return components.percentEncodedQuery?.data(using: .utf8)
  }
}

private struct GoogleTokenResponse: Decodable {
  let accessToken: String
  let expiresIn: Int
  let refreshToken: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
  }
}

enum GoogleOAuthError: Error, LocalizedError {
  case invalidEmail
  case authorizationDenied(String)
  case stateMismatch
  case missingCode
  case invalidRedirect
  case missingRefreshToken
  case missingStoredCredential
  case tokenExchangeFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidEmail:
      return "Enter a valid Gmail address."
    case .authorizationDenied:
      return "Google sign-in was cancelled or denied."
    case .stateMismatch:
      return "Google sign-in could not be verified."
    case .missingCode, .invalidRedirect:
      return "Google did not return a valid authorization code."
    case .missingRefreshToken:
      return
        "Google did not return offline access. Remove Flit from your Google Account connections and try again."
    case .missingStoredCredential:
      return "This Gmail account is not connected."
    case .tokenExchangeFailed:
      return "Unable to finish Google sign-in."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .authorizationDenied(let details), .tokenExchangeFailed(let details):
      return details
    default:
      return nil
    }
  }
}
