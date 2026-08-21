import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: Error, CustomStringConvertible {
  case open(String)
  case execute(String)
  case prepare(String)
  case bind(String)
  case step(String)

  var description: String {
    switch self {
    case .open(let message): return "Unable to open database: \(message)"
    case .execute(let message): return "Database execution failed: \(message)"
    case .prepare(let message): return "Unable to prepare statement: \(message)"
    case .bind(let message): return "Unable to bind value: \(message)"
    case .step(let message): return "Database statement failed: \(message)"
    }
  }
}

final class SQLiteDatabase {
  fileprivate let handle: OpaquePointer

  init(path: String) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
      if let database { sqlite3_close(database) }
      throw DatabaseError.open(message)
    }

    handle = database
    sqlite3_busy_timeout(handle, 1_000)
  }

  deinit {
    sqlite3_close(handle)
  }

  func execute(_ sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? lastError
      sqlite3_free(errorMessage)
      throw DatabaseError.execute(message)
    }
  }

  func prepare(_ sql: String) throws -> SQLiteStatement {
    try SQLiteStatement(database: self, sql: sql)
  }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try body()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  var lastInsertedRowID: Int64 {
    sqlite3_last_insert_rowid(handle)
  }

  fileprivate var lastError: String {
    String(cString: sqlite3_errmsg(handle))
  }
}

final class SQLiteStatement {
  private unowned let database: SQLiteDatabase
  private let statement: OpaquePointer

  fileprivate init(database: SQLiteDatabase, sql: String) throws {
    self.database = database
    var prepared: OpaquePointer?
    guard sqlite3_prepare_v2(database.handle, sql, -1, &prepared, nil) == SQLITE_OK,
      let prepared
    else {
      throw DatabaseError.prepare(database.lastError)
    }
    statement = prepared
  }

  deinit {
    sqlite3_finalize(statement)
  }

  func bind(_ value: Int64, at index: Int32) throws {
    guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
      throw DatabaseError.bind(database.lastError)
    }
  }

  func bind(_ value: Int32, at index: Int32) throws {
    guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
      throw DatabaseError.bind(database.lastError)
    }
  }

  func bind(_ value: String, at index: Int32) throws {
    guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
      throw DatabaseError.bind(database.lastError)
    }
  }

  func bind(_ value: String?, at index: Int32) throws {
    if let value {
      try bind(value, at: index)
    } else {
      try bindNull(at: index)
    }
  }

  func bind(_ value: Int64?, at index: Int32) throws {
    if let value {
      try bind(value, at: index)
    } else {
      try bindNull(at: index)
    }
  }

  func bindNull(at index: Int32) throws {
    guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
      throw DatabaseError.bind(database.lastError)
    }
  }

  @discardableResult
  func step() throws -> Bool {
    switch sqlite3_step(statement) {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default: throw DatabaseError.step(database.lastError)
    }
  }

  func integer(at index: Int32) -> Int64 {
    sqlite3_column_int64(statement, index)
  }

  func optionalInteger(at index: Int32) -> Int64? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : integer(at: index)
  }

  func text(at index: Int32) -> String {
    guard let value = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: value)
  }

  func optionalText(at index: Int32) -> String? {
    sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(at: index)
  }
}
