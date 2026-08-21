import Foundation

actor MailStore {
  private let database: SQLiteDatabase

  init(path: String) throws {
    let parentDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parentDirectory,
      withIntermediateDirectories: true
    )

    database = try SQLiteDatabase(path: path)
    try Self.migrate(database)
  }

  func addAccount(name: String, email: String, provider: String) throws -> Int64 {
    let statement = try database.prepare(
      """
      INSERT INTO accounts (name, email, provider)
      VALUES (?, ?, ?)
      ON CONFLICT(email) DO UPDATE SET name = excluded.name
      RETURNING id
      """)
    try statement.bind(name, at: 1)
    try statement.bind(email, at: 2)
    try statement.bind(provider, at: 3)
    guard try statement.step() else {
      throw DatabaseError.step("Account insert returned no identifier")
    }
    return statement.integer(at: 0)
  }

  @discardableResult
  func addMessage(_ message: NewMessage) throws -> Int64 {
    let statement = try database.prepare(
      """
      INSERT INTO messages (
          account_id, remote_id, remote_uid, uid_validity, received_at,
          sender, recipients, subject, preview, flags, mailbox_state, body_path
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_id, remote_id) DO UPDATE SET
          remote_uid = excluded.remote_uid,
          uid_validity = excluded.uid_validity,
          received_at = excluded.received_at,
          sender = excluded.sender,
          recipients = excluded.recipients,
          subject = excluded.subject,
          preview = excluded.preview,
          flags = excluded.flags,
          mailbox_state = excluded.mailbox_state,
          body_path = excluded.body_path
      RETURNING id
      """)

    try statement.bind(message.accountID, at: 1)
    try statement.bind(message.remoteID, at: 2)
    try statement.bind(message.remoteUID, at: 3)
    try statement.bind(message.uidValidity, at: 4)
    try statement.bind(message.receivedAt, at: 5)
    try statement.bind(message.sender, at: 6)
    try statement.bind(message.recipients, at: 7)
    try statement.bind(message.subject, at: 8)
    try statement.bind(message.preview, at: 9)
    try statement.bind(message.isRead ? Int32(1) : Int32(0), at: 10)
    try statement.bind(message.mailboxState.rawValue, at: 11)
    try statement.bind(message.bodyPath, at: 12)

    guard try statement.step() else {
      throw DatabaseError.step("Message insert returned no identifier")
    }
    return statement.integer(at: 0)
  }

  func fetchInbox(after cursor: PageCursor? = nil, limit: Int = 100) throws -> [MessageSummary] {
    let statement: SQLiteStatement
    if let cursor {
      statement = try database.prepare(
        """
        SELECT \(Self.summaryColumns)
        FROM messages m
        JOIN accounts a ON a.id = m.account_id
        WHERE m.mailbox_state = ?
          AND (m.received_at < ? OR (m.received_at = ? AND m.id < ?))
        ORDER BY m.received_at DESC, m.id DESC
        LIMIT ?
        """)
      try statement.bind(MailboxState.inbox.rawValue, at: 1)
      try statement.bind(cursor.receivedAt, at: 2)
      try statement.bind(cursor.receivedAt, at: 3)
      try statement.bind(cursor.id, at: 4)
      try statement.bind(Int64(limit), at: 5)
    } else {
      statement = try database.prepare(
        """
        SELECT \(Self.summaryColumns)
        FROM messages m
        JOIN accounts a ON a.id = m.account_id
        WHERE m.mailbox_state = ?
        ORDER BY m.received_at DESC, m.id DESC
        LIMIT ?
        """)
      try statement.bind(MailboxState.inbox.rawValue, at: 1)
      try statement.bind(Int64(limit), at: 2)
    }

    return try readSummaries(from: statement)
  }

  func search(_ query: String, limit: Int = 200) throws -> [MessageSummary] {
    let matchQuery = Self.ftsQuery(from: query)
    guard !matchQuery.isEmpty else { return try fetchInbox(limit: limit) }

    let statement = try database.prepare(
      """
      SELECT \(Self.summaryColumns)
      FROM messages_fts
      JOIN messages m ON m.id = messages_fts.rowid
      JOIN accounts a ON a.id = m.account_id
      WHERE messages_fts MATCH ?
        AND m.mailbox_state IN (?, ?)
      ORDER BY bm25(messages_fts), m.received_at DESC
      LIMIT ?
      """)
    try statement.bind(matchQuery, at: 1)
    try statement.bind(MailboxState.inbox.rawValue, at: 2)
    try statement.bind(MailboxState.archive.rawValue, at: 3)
    try statement.bind(Int64(limit), at: 4)
    return try readSummaries(from: statement)
  }

  func archive(messageID: Int64) throws {
    try moveLocally(
      messageID: messageID,
      destination: .archive,
      operation: .archive
    )
  }

  func moveToTrash(messageID: Int64) throws {
    try moveLocally(
      messageID: messageID,
      destination: .trash,
      operation: .trash
    )
  }

  func markRead(messageID: Int64) throws {
    try database.transaction {
      let update = try database.prepare("UPDATE messages SET flags = flags | 1 WHERE id = ?")
      try update.bind(messageID, at: 1)
      try update.step()

      try enqueue(operation: .markRead, messageID: messageID)
    }
  }

  func seedDemoDataIfEmpty() throws {
    let count = try database.prepare("SELECT COUNT(*) FROM accounts")
    guard try count.step(), count.integer(at: 0) == 0 else { return }

    let accountID = try addAccount(name: "Personal", email: "hello@example.com", provider: "demo")
    let now = Int64(Date().timeIntervalSince1970)
    let examples = [
      ("Maya Chen", "A smaller, faster inbox", "The first local-first message is ready to triage."),
      ("Alex Rivera", "Project notes", "Everything visible here was loaded from SQLite."),
      (
        "Flit", "Welcome",
        "Archive a row and it disappears immediately while the operation is queued."
      ),
    ]

    for (offset, example) in examples.enumerated() {
      try addMessage(
        NewMessage(
          accountID: accountID,
          remoteID: "demo-\(offset)",
          remoteUID: Int64(offset + 1),
          uidValidity: 1,
          receivedAt: now - Int64(offset * 300),
          sender: example.0,
          recipients: "hello@example.com",
          subject: example.1,
          preview: example.2,
          isRead: offset == 2,
          mailboxState: .inbox,
          bodyPath: nil
        ))
    }
  }

  private func moveLocally(
    messageID: Int64,
    destination: MailboxState,
    operation: PendingOperationKind
  ) throws {
    var bodyPath: String?
    try database.transaction {
      let current = try database.prepare("SELECT body_path FROM messages WHERE id = ?")
      try current.bind(messageID, at: 1)
      if try current.step() {
        bodyPath = current.optionalText(at: 0)
      }

      let update = try database.prepare(
        """
        UPDATE messages
        SET mailbox_state = ?, body_path = NULL
        WHERE id = ?
        """)
      try update.bind(destination.rawValue, at: 1)
      try update.bind(messageID, at: 2)
      try update.step()

      try enqueue(operation: operation, messageID: messageID)
    }

    if let bodyPath {
      try? FileManager.default.removeItem(atPath: bodyPath)
    }
  }

  private func enqueue(operation: PendingOperationKind, messageID: Int64) throws {
    let statement = try database.prepare(
      """
      INSERT INTO pending_operations (message_id, operation, created_at)
      VALUES (?, ?, ?)
      """)
    try statement.bind(messageID, at: 1)
    try statement.bind(operation.rawValue, at: 2)
    try statement.bind(Int64(Date().timeIntervalSince1970), at: 3)
    try statement.step()
  }

  private func readSummaries(from statement: SQLiteStatement) throws -> [MessageSummary] {
    var messages: [MessageSummary] = []
    messages.reserveCapacity(100)

    while try statement.step() {
      guard let state = MailboxState(rawValue: Int32(statement.integer(at: 13))) else { continue }
      messages.append(
        MessageSummary(
          id: statement.integer(at: 0),
          accountID: statement.integer(at: 1),
          accountName: statement.text(at: 2),
          accountEmail: statement.text(at: 3),
          remoteID: statement.text(at: 4),
          remoteUID: statement.optionalInteger(at: 5),
          receivedAt: statement.integer(at: 6),
          sender: statement.text(at: 7),
          recipients: statement.text(at: 8),
          subject: statement.text(at: 9),
          preview: statement.text(at: 10),
          isRead: statement.integer(at: 11) & 1 == 1,
          mailboxState: state,
          bodyPath: statement.optionalText(at: 12)
        ))
    }
    return messages
  }

  private static let summaryColumns = """
    m.id, m.account_id, a.name, a.email, m.remote_id, m.remote_uid,
    m.received_at, m.sender, m.recipients, m.subject, m.preview,
    m.flags, m.body_path, m.mailbox_state
    """

  private static func ftsQuery(from query: String) -> String {
    query
      .split(whereSeparator: { $0.isWhitespace })
      .map { token in
        let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\"*"
      }
      .joined(separator: " AND ")
  }

  private static func migrate(_ database: SQLiteDatabase) throws {
    try database.execute(
      """
      PRAGMA foreign_keys = ON;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      PRAGMA cache_size = -8192;
      PRAGMA busy_timeout = 1000;
      PRAGMA temp_store = FILE;

      CREATE TABLE IF NOT EXISTS accounts (
          id INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          email TEXT NOT NULL UNIQUE,
          provider TEXT NOT NULL,
          uid_validity INTEGER,
          highest_uid INTEGER,
          highest_modseq TEXT
      );

      CREATE TABLE IF NOT EXISTS messages (
          id INTEGER PRIMARY KEY,
          account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
          remote_id TEXT NOT NULL,
          remote_uid INTEGER,
          uid_validity INTEGER,
          received_at INTEGER NOT NULL,
          sender TEXT NOT NULL DEFAULT '',
          recipients TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          preview TEXT NOT NULL DEFAULT '',
          flags INTEGER NOT NULL DEFAULT 0,
          mailbox_state INTEGER NOT NULL DEFAULT 0,
          body_path TEXT,
          UNIQUE(account_id, remote_id)
      );

      CREATE INDEX IF NOT EXISTS inbox_page
      ON messages(mailbox_state, received_at DESC, id DESC);

      CREATE INDEX IF NOT EXISTS account_sync
      ON messages(account_id, uid_validity, remote_uid);

      CREATE TABLE IF NOT EXISTS pending_operations (
          id INTEGER PRIMARY KEY,
          message_id INTEGER REFERENCES messages(id) ON DELETE CASCADE,
          operation INTEGER NOT NULL,
          payload BLOB,
          attempts INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          sender,
          recipients,
          subject,
          preview,
          content='messages',
          content_rowid='id',
          detail=column
      );

      CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
          INSERT INTO messages_fts(rowid, sender, recipients, subject, preview)
          VALUES (new.id, new.sender, new.recipients, new.subject, new.preview);
      END;

      CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, sender, recipients, subject, preview)
          VALUES ('delete', old.id, old.sender, old.recipients, old.subject, old.preview);
      END;

      CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, sender, recipients, subject, preview)
          VALUES ('delete', old.id, old.sender, old.recipients, old.subject, old.preview);
          INSERT INTO messages_fts(rowid, sender, recipients, subject, preview)
          VALUES (new.id, new.sender, new.recipients, new.subject, new.preview);
      END;
      """)
  }
}
