import Foundation
import Network

struct IMAPResponse: Sendable, Equatable {
  let line: String
  let literal: Data?
}

struct IMAPCommandResult: Sendable, Equatable {
  let responses: [IMAPResponse]
}

private final class IMAPConnectionGate: @unchecked Sendable {
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

enum IMAPTransportError: Error, LocalizedError {
  case invalidPort
  case connectionFailed(String)
  case connectionClosed
  case lineTooLong
  case literalTooLarge(Int)
  case malformedResponse
  case concurrentCommand
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidPort:
      return "The mail server port is invalid."
    case .connectionFailed:
      return "Unable to connect to Gmail."
    case .connectionClosed:
      return "Gmail closed the connection."
    case .lineTooLong, .literalTooLarge, .malformedResponse:
      return "Gmail returned an invalid IMAP response."
    case .concurrentCommand:
      return "Another Gmail operation is already in progress."
    case .commandFailed:
      return "Gmail rejected an IMAP command."
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .connectionFailed(let details), .commandFailed(let details):
      return details
    default:
      return nil
    }
  }
}

final class IMAPTransport: @unchecked Sendable {
  private static let maximumLineBytes = 1_048_576
  private static let maximumLiteralBytes = 1_048_576
  private static let maximumResponsesPerCommand = 2_048

  private let host: NWEndpoint.Host
  private let port: NWEndpoint.Port
  private let queue = DispatchQueue(label: "com.ranihaddad.flit.imap")
  private let executionLock = NSLock()
  private var commandInProgress = false
  private var connection: NWConnection?
  private var readBuffer = Data()
  private var nextTag = 1

  init(host: String, port: UInt16) throws {
    guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
      throw IMAPTransportError.invalidPort
    }
    self.host = NWEndpoint.Host(host)
    self.port = endpointPort
  }

  func connect() async throws -> String {
    let connection = NWConnection(host: host, port: port, using: .tls)
    self.connection = connection

    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let gate = IMAPConnectionGate()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.resume(continuation, with: .success(()))
        case .failed(let error):
          gate.resume(
            continuation,
            with: .failure(IMAPTransportError.connectionFailed(error.localizedDescription))
          )
        case .cancelled:
          gate.resume(continuation, with: .failure(IMAPTransportError.connectionClosed))
        default:
          break
        }
      }
      connection.start(queue: queue)
    }

    let greeting = try await readLine()
    guard greeting.hasPrefix("* OK") else {
      throw IMAPTransportError.connectionFailed(greeting)
    }
    return greeting
  }

  func execute(_ command: String, answerContinuationWithEmptyLine: Bool = false) async throws
    -> IMAPCommandResult
  {
    guard beginCommand() else { throw IMAPTransportError.concurrentCommand }
    defer { endCommand() }

    guard !command.contains("\r"), !command.contains("\n") else {
      throw IMAPTransportError.malformedResponse
    }

    let tag = String(format: "A%04d", nextTag)
    nextTag += 1
    try await send("\(tag) \(command)\r\n")

    var responses: [IMAPResponse] = []
    responses.reserveCapacity(64)

    while responses.count < Self.maximumResponsesPerCommand {
      let line = try await readLine()
      if line.hasPrefix("+") && answerContinuationWithEmptyLine {
        try await send("\r\n")
        responses.append(IMAPResponse(line: line, literal: nil))
        continue
      }

      var responseLine = line
      var literal: Data?
      if let literalByteCount = Self.trailingLiteralByteCount(in: line) {
        guard literalByteCount <= Self.maximumLiteralBytes else {
          throw IMAPTransportError.literalTooLarge(literalByteCount)
        }
        literal = try await readExactly(literalByteCount)
        responseLine += " " + (try await readLine())
      }
      responses.append(IMAPResponse(line: responseLine, literal: literal))

      if line.hasPrefix("\(tag) ") {
        guard line.uppercased().hasPrefix("\(tag) OK") else {
          throw IMAPTransportError.commandFailed(line)
        }
        return IMAPCommandResult(responses: responses)
      }
    }

    throw IMAPTransportError.malformedResponse
  }

  func close() {
    connection?.cancel()
    connection = nil
    readBuffer.removeAll(keepingCapacity: false)
  }

  private func beginCommand() -> Bool {
    executionLock.lock()
    defer { executionLock.unlock() }
    guard !commandInProgress else { return false }
    commandInProgress = true
    return true
  }

  private func endCommand() {
    executionLock.lock()
    commandInProgress = false
    executionLock.unlock()
  }

  private func send(_ string: String) async throws {
    guard let connection else { throw IMAPTransportError.connectionClosed }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: Data(string.utf8),
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(
              throwing: IMAPTransportError.connectionFailed(error.localizedDescription))
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
          throw IMAPTransportError.malformedResponse
        }
        return line
      }
      guard readBuffer.count <= Self.maximumLineBytes else {
        throw IMAPTransportError.lineTooLong
      }
      readBuffer.append(try await receiveChunk())
    }
  }

  private func readExactly(_ byteCount: Int) async throws -> Data {
    while readBuffer.count < byteCount {
      readBuffer.append(try await receiveChunk())
    }
    let data = Data(readBuffer.prefix(byteCount))
    readBuffer.removeFirst(byteCount)
    return data
  }

  private func receiveChunk() async throws -> Data {
    guard let connection else { throw IMAPTransportError.connectionClosed }
    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, Error>) in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
        data, _, isComplete, error in
        if let error {
          continuation.resume(
            throwing: IMAPTransportError.connectionFailed(error.localizedDescription))
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(throwing: IMAPTransportError.connectionClosed)
        } else {
          continuation.resume(throwing: IMAPTransportError.connectionClosed)
        }
      }
    }
  }

  private static func trailingLiteralByteCount(in line: String) -> Int? {
    guard line.last == "}", let openingBrace = line.lastIndex(of: "{") else { return nil }
    let digits = line[line.index(after: openingBrace)..<line.index(before: line.endIndex)]
    return Int(digits)
  }
}
