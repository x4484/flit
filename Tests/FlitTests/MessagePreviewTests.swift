import Testing

@testable import Flit

struct MessagePreviewTests {
  @Test
  func normalizesReadableBodiesIntoBoundedSingleLinePreviews() {
    let preview = MessagePreview.make(
      from: "  First line\n\nSecond\tline with more words.  ",
      limit: 24
    )

    #expect(preview == "First line Second line…")
    #expect(preview.count <= 24)
    #expect(!preview.contains("\n"))
  }

  @Test
  func preservesShortReadableBodies() {
    #expect(MessagePreview.make(from: "  A short message. \n") == "A short message.")
    #expect(MessagePreview.make(from: "   ").isEmpty)
  }
}
