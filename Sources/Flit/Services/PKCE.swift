import CryptoKit
import Foundation
import Security

struct PKCEPair: Sendable, Equatable {
  let verifier: String
  let challenge: String

  static func generate(byteCount: Int = 32) -> PKCEPair {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    precondition(status == errSecSuccess, "Unable to generate secure random bytes")

    let verifier = Data(bytes).base64URLEncodedString()
    return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
  }

  static func challenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLEncodedString()
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
