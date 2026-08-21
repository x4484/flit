import Foundation
import Network

struct SMTPResponse: Sendable, Equatable {
  let code: Int
  let lines: [String]
}

enum SMTPTransportError: Error, LocalizedError {
  case invalidPort
  case connectionFailed(String)
  case connectionClosed
  case malformedResponse
  case lineTooLong
  case commandRejected(String)

  var errorDescription: String? {
    switch self {
    case .invalidPort:
      return "The Gmail SMTP port is invalid."
    case .connectionFailed:
      return "Unable to connect to Gmail to send this message."
    case .connectionClosed:
      return "Gmail closed the sending connection."
    case .malformedResponse, .lineTooLong:
      return "Gmail returned an invalid SMTP response."
    case .commandRejected:
      return "Gmail rejected the message."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .connectionFailed(let details), .commandRejected(let details): return details
    default: return nil
    }
  }
}

private final class SMTPConnectionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  func resume(
    _ continuation: CheckedContinuation<Void, Error>,
    with result: Result<Void, Error>
  ) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    lock.unlock()
    continuation.resume(with: result)
  }
}

final class SMTPTransport: @unchecked Sendable {
  private static let maximumLineBytes = 65_536
  private static let maximumResponseLines = 100

  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "com.ranihaddad.flit.smtp")
  private var connection: NWConnection?
  private var readBuffer = Data()

  init(host: String, port: UInt16) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw SMTPTransportError.invalidPort
    }
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    self.host = NWEndpoint.Host(normalizedHost)
    self.port = endpointPort
  }

  func connect() async throws {
    let connection = NWConnection(host: host, port: port, using: .tls)
    self.connection = connection

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let gate = SMTPConnectionGate()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume(continuation, with: .success(()))
        case .failed(let error):
          gate.resume(
            continuation,
            with: .failure(SMTPTransportError.connectionFailed(error.localizedDescription))
          )
        case .cancelled:
          gate.resume(continuation, with: .failure(SMTPTransportError.connectionClosed))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }

    _ = try await readResponse(expecting: 220)
  }

  @discardableResult
  func execute(_ command: String, expecting code: Int) async throws -> SMTPResponse {
    guard !command.contains("\r"), !command.contains("\n") else {
      throw SMTPTransportError.malformedResponse
    }
    try await send(Data("\(command)\r\n".utf8))
    return try await readResponse(expecting: code)
  }

  func sendMessage(_ message: Data) async throws {
    _ = try await execute("DATA", expecting: 354)
    let normalized = Self.normalizedForData(message)
    try await send(normalized + Data("\r\n.\r\n".utf8))
    _ = try await readResponse(expecting: 250)
  }

  func close() {
    connection?.cancel()
    connection = nil
    readBuffer.removeAll(keepingCapacity: false)
  }

  private func readResponse(expecting expectedCode: Int) async throws -> SMTPResponse {
    var lines: [String] = []
    while lines.count < Self.maximumResponseLines {
      let line = try await readLine()
      lines.append(line)
      guard line.count >= 4, let code = Int(line.prefix(3)) else {
        throw SMTPTransportError.malformedResponse
      }
      let marker = line[line.index(line.startIndex, offsetBy: 3)]
      if marker == " " {
        guard code == expectedCode else {
          throw SMTPTransportError.commandRejected(lines.joined(separator: "\n"))
        }
        return SMTPResponse(code: code, lines: lines)
      }
      guard marker == "-" else { throw SMTPTransportError.malformedResponse }
    }
    throw SMTPTransportError.malformedResponse
  }

  private func send(_ data: Data) async throws {
    guard let connection else { throw SMTPTransportError.connectionClosed }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(
              throwing: SMTPTransportError.connectionFailed(error.localizedDescription))
          } else {
            continuation.resume()
          }
        })
    }
  }

  private func readLine() async throws -> String {
    let delimiter = Data([13, 10])
    while true {
      if let range = readBuffer.range(of: delimiter) {
        let lineData = readBuffer[..<range.lowerBound]
        readBuffer.removeSubrange(..<range.upperBound)
        guard let line = String(data: lineData, encoding: .utf8) else {
          throw SMTPTransportError.malformedResponse
        }
        return line
      }
      guard readBuffer.count <= Self.maximumLineBytes else {
        throw SMTPTransportError.lineTooLong
      }
      readBuffer.append(try await receiveChunk())
    }
  }

  private func receiveChunk() async throws -> Data {
    guard let connection else { throw SMTPTransportError.connectionClosed }
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
        data, _, isComplete, error in
        if let error {
          continuation.resume(
            throwing: SMTPTransportError.connectionFailed(error.localizedDescription))
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(throwing: SMTPTransportError.connectionClosed)
        } else {
          continuation.resume(throwing: SMTPTransportError.connectionClosed)
        }
      }
    }
  }

  static func normalizedForData(_ message: Data) -> Data {
    var text = String(decoding: message, as: UTF8.self)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    var lines = text.components(separatedBy: "\n")
    while lines.last?.isEmpty == true {
      lines.removeLast()
    }
    text = lines
      .map { $0.hasPrefix(".") ? "." + $0 : $0 }
      .joined(separator: "\r\n")
    return Data(text.utf8)
  }
}
