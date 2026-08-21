import Foundation
import Security

struct KeychainStore: Sendable {
  let service: String

  init(service: String = "com.ranihaddad.flit.oauth") {
    self.service = service
  }

  func save(_ data: Data, account: String) throws {
    let query = baseQuery(account: account)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]

    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError(status: updateStatus)
    }

    var insert = query
    for (key, value) in attributes {
      insert[key] = value
    }
    let insertStatus = SecItemAdd(insert as CFDictionary, nil)
    guard insertStatus == errSecSuccess else {
      throw KeychainError(status: insertStatus)
    }
  }

  func data(account: String) throws -> Data? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw KeychainError(status: status)
    }
    return data
  }

  func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

struct KeychainError: Error, LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    if let message = SecCopyErrorMessageString(status, nil) as String? {
      return "Unable to access Keychain: \(message)"
    }
    return "Unable to access Keychain (\(status))."
  }
}
