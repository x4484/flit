import Foundation
import Network

final class BodyPrefetchNetworkMonitor: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var allowsPrefetchStorage = false
  private let onPolicyChange: @Sendable (Bool) -> Void

  init(onPolicyChange: @escaping @Sendable (Bool) -> Void) {
    self.onPolicyChange = onPolicyChange
    monitor.pathUpdateHandler = { [weak self] path in
      self?.updatePolicy(
        path.status == .satisfied && !path.isExpensive && !path.isConstrained
      )
    }
    monitor.start(queue: DispatchQueue(label: "com.ranihaddad.flit.body-prefetch-network"))
  }

  deinit {
    monitor.cancel()
  }

  var allowsPrefetch: Bool {
    lock.lock()
    defer { lock.unlock() }
    return allowsPrefetchStorage
  }

  private func updatePolicy(_ allowsPrefetch: Bool) {
    lock.lock()
    let changed = allowsPrefetchStorage != allowsPrefetch
    allowsPrefetchStorage = allowsPrefetch
    lock.unlock()
    if changed {
      onPolicyChange(allowsPrefetch)
    }
  }
}
