import Foundation

enum GmailXOAUTH2 {
  static func initialClientResponse(email: String, accessToken: String) -> String {
    let payload = "user=\(email)\u{1}auth=Bearer \(accessToken)\u{1}\u{1}"
    return Data(payload.utf8).base64EncodedString()
  }
}
