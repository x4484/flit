import Foundation

actor SyncCoordinator {
  private let maximumConcurrentSyncs = 2
  private var activeSyncs = 0

  func canBeginSync() -> Bool {
    guard activeSyncs < maximumConcurrentSyncs else { return false }
    activeSyncs += 1
    return true
  }

  func finishSync() {
    activeSyncs = max(0, activeSyncs - 1)
  }
}
