import Foundation
import Testing

@testable import Flit

struct MIMETextExtractorTests {
  @Test
  func prefersQuotedPrintablePlainTextFromMultipartAlternative() {
    let headers = Data(
      "Content-Type: multipart/alternative; boundary=flit-boundary\r\n".utf8)
    let body = Data(
      """
      --flit-boundary\r
      Content-Type: text/plain; charset=utf-8\r
      Content-Transfer-Encoding: quoted-printable\r
      \r
      Hello=2C Flit=21\r
      --flit-boundary\r
      Content-Type: text/html; charset=utf-8\r
      \r
      <p>Hello, <strong>Flit!</strong></p>\r
      --flit-boundary--\r
      """.utf8)

    #expect(
      MIMETextExtractor.plainText(headerData: headers, bodyData: body) == "Hello, Flit!")
  }

  @Test
  func preservesRichEmailPresentationWhileRemovingActiveContent() {
    let headers = Data(
      "Content-Type: multipart/alternative; boundary=rich-boundary\r\n".utf8)
    let body = Data(
      """
      --rich-boundary\r
      Content-Type: text/plain; charset=utf-8\r
      \r
      Plain fallback with https://example.com/tracking\r
      --rich-boundary\r
      Content-Type: text/html; charset=utf-8\r
      \r
      <html><head><style>body{color:red}</style><script>alert('no')</script></head><body onload=\"track()\"><h1>Readable heading</h1><p>Useful <strong>content</strong>.</p><img src=\"https://example.com/pixel.gif\"></body></html>\r
      --rich-boundary--\r
      """.utf8)

    let preferred = MIMETextExtractor.preferredBody(headerData: headers, bodyData: body)
    guard case .html(let html) = preferred else {
      Issue.record("Expected HTML to be preferred")
      return
    }
    #expect(html.contains("Readable heading"))
    #expect(html.contains("<strong>content</strong>"))
    #expect(html.localizedCaseInsensitiveContains("<style"))
    #expect(html.localizedCaseInsensitiveContains("<img"))
    #expect(html.contains("pixel.gif"))
    #expect(!html.localizedCaseInsensitiveContains("<script"))
    #expect(!html.localizedCaseInsensitiveContains("onload"))
  }

  @Test
  func preservesSafePresentationStylesAndImageAltText() {
    let html = MIMETextExtractor.sanitizedHTML(
      """
      <img alt="PLAUD &amp; Privacy" width="88" src="https://example.com/logo.png">
      <table style="background-color:#F2EFEB;width:100%;background-image:url(https://bad.example)">
        <tr><td style="padding:28px;color:#413D3B;font-size:16px;position:fixed">Content</td></tr>
      </table>
      """)

    #expect(html.contains("data-flit-image-alt=\"true\">PLAUD &amp; Privacy"))
    #expect(!html.contains("&amp;amp;"))
    #expect(html.contains("background-color:#F2EFEB"))
    #expect(html.contains("padding:28px"))
    #expect(html.contains("color:#413D3B"))
    #expect(html.contains("font-size:16px"))
    #expect(!html.contains("logo.png"))
    #expect(!html.localizedCaseInsensitiveContains("position"))
    #expect(!html.localizedCaseInsensitiveContains("background-image"))
  }

  @Test
  func fallsBackToReadableTextForHTMLOnlyMail() {
    let headers = Data("Content-Type: text/html; charset=utf-8\r\n".utf8)
    let body = Data("<style>p{color:red}</style><p>Hello &amp; welcome.</p>".utf8)

    #expect(
      MIMETextExtractor.plainText(headerData: headers, bodyData: body)
        == "Hello & welcome.")
  }

  @Test
  func removesPlainTextTrackingDestinationsWithoutRemovingLinkLabels() {
    let source = """
      Google Workspace<https://example.com/a-very-long-tracking-destination>

      Try eSignature<https://example.com/another-tracking-destination>
      """

    #expect(
      MIMETextExtractor.readableText(source)
        == "Google Workspace\n\nTry eSignature"
    )
  }

  @Test
  func ignoresAttachmentContent() {
    let headers = Data(
      "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=secret.txt\r\n".utf8)

    #expect(MIMETextExtractor.plainText(headerData: headers, bodyData: Data("secret".utf8)).isEmpty)
  }
}
