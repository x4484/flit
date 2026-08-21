import Foundation
import Network

final class LoopbackOAuthReceiver: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.ranihaddad.flit.oauth-loopback")
  private var listener: NWListener?
  private var continuation: CheckedContinuation<URL, Error>?
  private var completed = false

  func receiveRedirect(onReady: @escaping @Sendable (URL) -> Void) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        self.continuation = continuation
        do {
          let listener = try NWListener(using: .tcp, on: .any)
          self.listener = listener

          listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
              switch state {
              case .ready:
                guard let port = listener.port else {
                  self.finish(.failure(LoopbackOAuthError.missingPort))
                  return
                }
                let redirectURL = URL(
                  string: "http://127.0.0.1:\(port.rawValue)/oauth2/callback")!
                onReady(redirectURL)
              case .failed(let error):
                self.finish(.failure(error))
              case .cancelled:
                if !self.completed {
                  self.finish(.failure(CancellationError()))
                }
              default:
                break
              }
            }
          }

          listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
          }
          listener.start(queue: self.queue)
        } catch {
          self.finish(.failure(error))
        }
      }
    }
  }

  func cancel() {
    queue.async { [self] in
      finish(.failure(CancellationError()))
    }
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, _, error in
      guard let self else { return }
      self.queue.async {
        if let error {
          connection.cancel()
          self.finish(.failure(error))
          return
        }
        guard let data, let request = String(data: data, encoding: .utf8),
          let redirectURL = Self.redirectURL(from: request)
        else {
          self.respond(
            to: connection, status: "400 Bad Request", message: "Unable to complete sign-in.")
          self.finish(.failure(LoopbackOAuthError.invalidRequest))
          return
        }

        self.respond(
          to: connection,
          status: "200 OK",
          message: "Flit is connected. You can close this window."
        )
        self.finish(.success(redirectURL))
      }
    }
  }

  private func respond(to connection: NWConnection, status: String, message: String) {
    let body = """
      <!doctype html><meta charset="utf-8"><title>Flit</title>
      <style>body{font:16px system-ui;margin:64px;max-width:560px;line-height:1.5}</style>
      <h1>\(message)</h1>
      """
    let response = """
      HTTP/1.1 \(status)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(body.utf8.count)\r
      Connection: close\r
      \r
      \(body)
      """
    connection.send(
      content: Data(response.utf8),
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private func finish(_ result: Result<URL, Error>) {
    guard !completed else { return }
    completed = true
    listener?.cancel()
    listener = nil
    let continuation = continuation
    self.continuation = nil
    continuation?.resume(with: result)
  }

  private static func redirectURL(from request: String) -> URL? {
    guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else { return nil }
    return URL(string: "http://127.0.0.1\(parts[1])")
  }
}

enum LoopbackOAuthError: Error, LocalizedError {
  case missingPort
  case invalidRequest

  var errorDescription: String? {
    switch self {
    case .missingPort:
      return "Unable to reserve a local sign-in callback port."
    case .invalidRequest:
      return "The Google sign-in callback was invalid."
    }
  }
}
