import Foundation

enum EmailHTMLDocument {
  private static let policy = """
    default-src 'none'; img-src https: http: data: cid:; style-src 'unsafe-inline' https: http:; \
    font-src https: http: data:; script-src 'none'; connect-src 'none'; media-src 'none'; \
    frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'
    """

  static func prepare(_ source: String) -> String {
    let safeHTML = MIMETextExtractor.renderableHTML(source)
    let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"

    if let headRange = safeHTML.range(
      of: #"(?i)<head(?:\s[^>]*)?>"#,
      options: .regularExpression
    ) {
      var document = safeHTML
      document.insert(contentsOf: meta, at: headRange.upperBound)
      return document
    }

    if let htmlRange = safeHTML.range(
      of: #"(?i)<html(?:\s[^>]*)?>"#,
      options: .regularExpression
    ) {
      var document = safeHTML
      document.insert(contentsOf: "<head>\(meta)</head>", at: htmlRange.upperBound)
      return document
    }

    return "<!doctype html><html><head>\(meta)</head><body>\(safeHTML)</body></html>"
  }
}
