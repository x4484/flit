import AppKit
import Foundation
import Testing

@testable import Flit

struct HTMLMessageRendererTests {
  @Test @MainActor
  func rendersHTMLAsNativeAttributedText() throws {
    let html = Data(
      "<h1>Quarterly update</h1><p>Hello <strong>Rani</strong>.</p><p><a href=\"https://example.com\">View details</a></p>".utf8
    )

    let rendered = try HTMLMessageRenderer.render(html)

    #expect(rendered.string.contains("Quarterly update"))
    #expect(rendered.string.contains("Hello Rani."))
    let linkRange = (rendered.string as NSString).range(of: "View details")
    #expect(rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)
    #expect(rendered.attribute(.font, at: 0, effectiveRange: nil) is NSFont)
  }

  @Test @MainActor
  func rendersEmailTablesAsNativeColumnsWithSafeStyling() throws {
    let html = Data(
      """
      <table style="background-color:#F2EFEB;width:100%"><tr>
        <td style="background-color:#FFFFFF;padding:20px;width:50%"><h1 style="font-size:38px;font-weight:400">4 h</h1><strong>of audio captured</strong></td>
        <td style="background-color:#FFFFFF;padding:20px;width:50%"><h1 style="font-size:38px">6</h1><strong>Recordings</strong></td>
      </tr></table>
      """.utf8)

    let rendered = try HTMLMessageRenderer.render(html)
    let firstRange = (rendered.string as NSString).range(of: "4 h")
    let secondRange = (rendered.string as NSString).range(of: "6")
    let firstParagraph = rendered.attribute(
      .paragraphStyle, at: firstRange.location, effectiveRange: nil) as? NSParagraphStyle
    let secondParagraph = rendered.attribute(
      .paragraphStyle, at: secondRange.location, effectiveRange: nil) as? NSParagraphStyle
    let firstBlock = firstParagraph?.textBlocks.last as? NSTextTableBlock
    let secondBlock = secondParagraph?.textBlocks.last as? NSTextTableBlock
    let headingFont = rendered.attribute(.font, at: firstRange.location, effectiveRange: nil) as? NSFont

    #expect(firstBlock != nil)
    #expect(secondBlock != nil)
    #expect(firstBlock?.startingColumn == 0)
    #expect(secondBlock?.startingColumn == 1)
    #expect(firstBlock?.table === secondBlock?.table)
    #expect(headingFont?.pointSize == 38)
  }

  @Test @MainActor
  func removesHiddenPreheaderPadding() throws {
    let html = Data(
      """
      <div style="display:none;max-height:0;overflow:hidden">
        Unlock ongoing access &zwnj; &shy; &shy; &#8204; ͏
      </div>
      <h1>Visible message</h1><p>Useful content.</p>
      """.utf8
    )

    let rendered = try HTMLMessageRenderer.render(html)

    #expect(!rendered.string.contains("Unlock ongoing access"))
    #expect(!rendered.string.contains("&zwnj;"))
    #expect(!rendered.string.contains("&shy;"))
    #expect(!rendered.string.contains("͏"))
    #expect(rendered.string.contains("Visible message"))
    #expect(rendered.string.contains("Useful content."))
  }
}
