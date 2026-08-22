import Foundation
import Testing
@testable import Flit

@Suite
struct GmailSyncServiceTests {
  @Test
  func bodyFetchDeadlineReturnsCompletedWork() async throws {
    let expected = URL(fileURLWithPath: "/tmp/flit-body")

    let result = try await GmailSyncService.withBodyFetchDeadline(
      nanoseconds: 100_000_000
    ) {
      expected
    }

    #expect(result == expected)
  }

  @Test
  func bodyFetchDeadlineStopsHungWork() async {
    await #expect(throws: GmailSyncServiceError.self) {
      try await GmailSyncService.withBodyFetchDeadline(nanoseconds: 5_000_000) {
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return URL(fileURLWithPath: "/tmp/never-created")
      }
    }
  }
}
