import Foundation
import Testing

@testable import Flit

struct EmailHTMLDocumentTests {
  @Test
  func addsARestrictivePolicyWithoutRemovingPresentationResources() {
    let document = EmailHTMLDocument.prepare(
      """
      <html><head><style>.hero { color: red }</style></head>
      <body><img src="https://example.com/hero.png"><p class="hero">Hello</p></body></html>
      """)

    #expect(document.contains("Content-Security-Policy"))
    #expect(document.contains("script-src 'none'"))
    #expect(document.contains("connect-src 'none'"))
    #expect(document.contains("img-src https: http: data: cid:"))
    #expect(document.contains("https://example.com/hero.png"))
    #expect(document.contains(".hero { color: red }"))
  }

  @Test
  func removesScriptsEventHandlersAndJavascriptURLs() {
    let document = EmailHTMLDocument.prepare(
      """
      <script>steal()</script>
      <a href="javascript:steal()" onclick="steal()">Open</a>
      <iframe src="https://example.com"></iframe>
      """)

    #expect(!document.localizedCaseInsensitiveContains("<script"))
    #expect(!document.localizedCaseInsensitiveContains("onclick"))
    #expect(!document.localizedCaseInsensitiveContains("javascript:"))
    #expect(!document.localizedCaseInsensitiveContains("<iframe"))
    #expect(document.contains(">Open</a>"))
  }
}
