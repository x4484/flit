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
    try Self.removeLegacyBodyCache(database)
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

  func accounts(provider: String? = nil) throws -> [MailAccount] {
    let statement: SQLiteStatement
    if let provider {
      statement = try database.prepare(
        """
        SELECT id, name, email, provider, uid_validity, highest_uid, highest_modseq
        FROM accounts
        WHERE provider = ?
        ORDER BY id
        """)
      try statement.bind(provider, at: 1)
    } else {
      statement = try database.prepare(
        """
        SELECT id, name, email, provider, uid_validity, highest_uid, highest_modseq
        FROM accounts
        ORDER BY id
        """)
    }

    var accounts: [MailAccount] = []
    while try statement.step() {
      let uidValidity = statement.optionalInteger(at: 4)
      let highestUID = statement.optionalInteger(at: 5)
      let highestModSequence = statement.optionalText(at: 6)
      let cursor =
        uidValidity == nil && highestUID == nil && highestModSequence == nil
        ? nil
        : SyncCursor(
          uidValidity: uidValidity,
          highestUID: highestUID,
          highestModSequence: highestModSequence
        )
      accounts.append(
        MailAccount(
          id: statement.integer(at: 0),
          name: statement.text(at: 1),
          email: statement.text(at: 2),
          provider: statement.text(at: 3),
          syncCursor: cursor
        ))
    }
    return accounts
  }

  @discardableResult
  func addMessage(_ message: NewMessage) throws -> Int64 {
    try upsertMessage(message)
  }

  func applyInboxSync(_ result: SyncResult, accountID: Int64) throws {
    try database.transaction {
      for message in result.messages where message.accountID == accountID {
        _ = try upsertMessage(message)
      }

      if !result.removedRemoteIDs.isEmpty {
        let removed = try database.prepare(
          """
          UPDATE messages
          SET mailbox_state = ?, body_path = NULL, summary = NULL
          WHERE account_id = ? AND remote_id = ? AND mailbox_state = ?
          """)
        for remoteID in result.removedRemoteIDs {
          try removed.bind(MailboxState.archive.rawValue, at: 1)
          try removed.bind(accountID, at: 2)
          try removed.bind(remoteID, at: 3)
          try removed.bind(MailboxState.inbox.rawValue, at: 4)
          try removed.step()
          try removed.reset()
        }
      }

      let cursor = try database.prepare(
        """
        UPDATE accounts
        SET uid_validity = ?, highest_uid = ?, highest_modseq = ?
        WHERE id = ?
        """)
      try cursor.bind(result.cursor.uidValidity, at: 1)
      try cursor.bind(result.cursor.highestUID, at: 2)
      try cursor.bind(result.cursor.highestModSequence, at: 3)
      try cursor.bind(accountID, at: 4)
      try cursor.step()
    }
  }

  func pendingOperations(
    accountID: Int64,
    limit: Int = 100
  ) throws -> [PendingMailOperation] {
    let statement = try database.prepare(
      """
      SELECT p.id, p.message_id, m.account_id, a.email, m.remote_id,
             m.remote_uid, m.uid_validity, p.operation, p.attempts
      FROM pending_operations p
      JOIN messages m ON m.id = p.message_id
      JOIN accounts a ON a.id = m.account_id
      WHERE m.account_id = ? AND a.provider = 'gmail' AND m.remote_uid IS NOT NULL
      ORDER BY p.id
      LIMIT ?
      """)
    try statement.bind(accountID, at: 1)
    try statement.bind(Int64(limit), at: 2)

    var operations: [PendingMailOperation] = []
    while try statement.step() {
      guard let kind = PendingOperationKind(rawValue: Int32(statement.integer(at: 7))) else {
        continue
      }
      operations.append(
        PendingMailOperation(
          id: statement.integer(at: 0),
          messageID: statement.integer(at: 1),
          accountID: statement.integer(at: 2),
          accountEmail: statement.text(at: 3),
          remoteID: statement.text(at: 4),
          remoteUID: statement.integer(at: 5),
          uidValidity: statement.optionalInteger(at: 6),
          kind: kind,
          attempts: Int(statement.integer(at: 8))
        ))
    }
    return operations
  }

  func completePendingOperation(id: Int64) throws {
    let statement = try database.prepare("DELETE FROM pending_operations WHERE id = ?")
    try statement.bind(id, at: 1)
    try statement.step()
  }

  func recordPendingOperationFailure(id: Int64) throws {
    let statement = try database.prepare(
      "UPDATE pending_operations SET attempts = attempts + 1 WHERE id = ?")
    try statement.bind(id, at: 1)
    try statement.step()
  }

  func cacheBody(at path: String, messageID: Int64) throws -> Bool {
    let current = try database.prepare("SELECT mailbox_state FROM messages WHERE id = ?")
    try current.bind(messageID, at: 1)
    guard try current.step(), current.integer(at: 0) == Int64(MailboxState.inbox.rawValue) else {
      return false
    }

    let update = try database.prepare("UPDATE messages SET body_path = ? WHERE id = ?")
    try update.bind(path, at: 1)
    try update.bind(messageID, at: 2)
    try update.step()
    return true
  }

  func summary(for messageID: Int64) throws -> String? {
    let statement = try database.prepare("SELECT summary FROM messages WHERE id = ?")
    try statement.bind(messageID, at: 1)
    guard try statement.step() else { return nil }
    return statement.optionalText(at: 0)
  }

  @discardableResult
  func saveSummary(_ summary: String, for messageID: Int64) throws -> Bool {
    let statement = try database.prepare(
      "UPDATE messages SET summary = ? WHERE id = ? AND mailbox_state = ?")
    try statement.bind(summary, at: 1)
    try statement.bind(messageID, at: 2)
    try statement.bind(MailboxState.inbox.rawValue, at: 3)
    try statement.step()
    return database.changedRowCount > 0
  }

  func pruneBodyCache(maximumFiles: Int) throws {
    let query = try database.prepare(
      "SELECT id, body_path FROM messages WHERE body_path IS NOT NULL")
    var existing: [(id: Int64, path: String, modifiedAt: Date)] = []
    var stale: [(id: Int64, path: String)] = []

    while try query.step() {
      let id = query.integer(at: 0)
      let path = query.text(at: 1)
      guard FileManager.default.fileExists(atPath: path) else {
        stale.append((id, path))
        continue
      }
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
      existing.append((id, path, modifiedAt))
    }

    existing.sort {
      if $0.modifiedAt == $1.modifiedAt { return $0.id > $1.id }
      return $0.modifiedAt > $1.modifiedAt
    }
    let overflow = existing.dropFirst(max(0, maximumFiles)).map { ($0.id, $0.path) }
    let entriesToRemove = stale + overflow
    guard !entriesToRemove.isEmpty else { return }

    let clear = try database.prepare("UPDATE messages SET body_path = NULL WHERE id = ?")
    for entry in entriesToRemove {
      try? FileManager.default.removeItem(atPath: entry.path)
      try clear.bind(entry.id, at: 1)
      try clear.step()
      try clear.reset()
    }
  }

  func oldestInboxRemoteUID(accountID: Int64) throws -> Int64? {
    let statement = try database.prepare(
      """
      SELECT MIN(remote_uid) FROM messages
      WHERE account_id = ? AND mailbox_state = ? AND remote_uid IS NOT NULL
      """)
    try statement.bind(accountID, at: 1)
    try statement.bind(MailboxState.inbox.rawValue, at: 2)
    guard try statement.step() else { return nil }
    return statement.optionalInteger(at: 0)
  }

  func applyInboxDiscovery(_ messages: [NewMessage], accountID: Int64) throws {
    try database.transaction {
      for message in messages where message.accountID == accountID {
        _ = try upsertMessage(message)
      }
    }
  }

  func inboxMessageStates(
    accountID: Int64,
    afterID: Int64? = nil,
    limit: Int = 100
  ) throws -> [LocalInboxMessageState] {
    let statement = try database.prepare(
      """
      SELECT id, remote_id, remote_uid, uid_validity, flags
      FROM messages
      WHERE account_id = ? AND mailbox_state = ? AND id > ?
      ORDER BY id
      LIMIT ?
      """)
    try statement.bind(accountID, at: 1)
    try statement.bind(MailboxState.inbox.rawValue, at: 2)
    try statement.bind(afterID ?? 0, at: 3)
    try statement.bind(Int64(limit), at: 4)

    var messages: [LocalInboxMessageState] = []
    while try statement.step() {
      messages.append(
        LocalInboxMessageState(
          id: statement.integer(at: 0),
          remoteID: statement.text(at: 1),
          remoteUID: statement.optionalInteger(at: 2),
          uidValidity: statement.optionalInteger(at: 3),
          isRead: statement.integer(at: 4) & 1 == 1
        ))
    }
    return messages
  }

  func applyInboxReconciliation(
    _ result: InboxReconciliationResult,
    accountID: Int64
  ) throws {
    var bodyPaths: [String] = []
    try database.transaction {
      let updateState = try database.prepare(
        """
        UPDATE messages
        SET remote_uid = ?, uid_validity = ?,
            flags = CASE
              WHEN EXISTS (
                SELECT 1 FROM pending_operations
                WHERE message_id = messages.id AND operation = 2
              ) THEN flags
              WHEN ? = 1 THEN flags | 1
              ELSE flags & ~1
            END
        WHERE account_id = ? AND remote_id = ? AND mailbox_state = ?
        """)
      for message in result.messages {
        try updateState.bind(message.remoteUID, at: 1)
        try updateState.bind(message.uidValidity, at: 2)
        try updateState.bind(message.isRead ? Int32(1) : Int32(0), at: 3)
        try updateState.bind(accountID, at: 4)
        try updateState.bind(message.remoteID, at: 5)
        try updateState.bind(MailboxState.inbox.rawValue, at: 6)
        try updateState.step()
        try updateState.reset()
      }

      let current = try database.prepare(
        """
        SELECT id, body_path FROM messages
        WHERE account_id = ? AND remote_id = ? AND mailbox_state = ?
        """)
      let move = try database.prepare(
        """
        UPDATE messages
        SET mailbox_state = ?, body_path = NULL, summary = NULL
        WHERE account_id = ? AND remote_id = ? AND mailbox_state = ?
        """)
      let delete = try database.prepare(
        "DELETE FROM messages WHERE id = ? AND mailbox_state = ?")
      let discardReadOperation = try database.prepare(
        "DELETE FROM pending_operations WHERE message_id = ? AND operation = 2")

      for removal in result.removals {
        try current.bind(accountID, at: 1)
        try current.bind(removal.remoteID, at: 2)
        try current.bind(MailboxState.inbox.rawValue, at: 3)
        var messageID: Int64?
        if try current.step() {
          messageID = current.integer(at: 0)
          if let bodyPath = current.optionalText(at: 1) {
            bodyPaths.append(bodyPath)
          }
        }
        try current.reset()
        guard let messageID else { continue }

        switch removal.destination {
        case .archive, .trash:
          try discardReadOperation.bind(messageID, at: 1)
          try discardReadOperation.step()
          try discardReadOperation.reset()

          let mailboxState: MailboxState =
            removal.destination == .archive ? .archive : .trash
          try move.bind(mailboxState.rawValue, at: 1)
          try move.bind(accountID, at: 2)
          try move.bind(removal.remoteID, at: 3)
          try move.bind(MailboxState.inbox.rawValue, at: 4)
          try move.step()
          try move.reset()
        case .delete:
          try delete.bind(messageID, at: 1)
          try delete.bind(MailboxState.inbox.rawValue, at: 2)
          try delete.step()
          try delete.reset()
        }
      }
    }

    for bodyPath in bodyPaths {
      try? FileManager.default.removeItem(atPath: bodyPath)
    }
  }

  func inboxCount() throws -> Int {
    let statement = try database.prepare(
      "SELECT COUNT(*) FROM messages WHERE mailbox_state = ?")
    try statement.bind(MailboxState.inbox.rawValue, at: 1)
    guard try statement.step() else { return 0 }
    return Int(statement.integer(at: 0))
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
          cc: "",
          internetMessageID: "",
          subject: example.1,
          preview: example.2,
          isRead: offset == 2,
          mailboxState: .inbox,
          bodyPath: nil
        ))
    }
  }

  private func upsertMessage(_ message: NewMessage) throws -> Int64 {
    let statement = try database.prepare(
      """
      INSERT INTO messages (
          account_id, remote_id, remote_uid, uid_validity, received_at,
          sender, recipients, cc, internet_message_id, subject, preview, flags,
          mailbox_state, body_path
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_id, remote_id) DO UPDATE SET
          remote_uid = CASE
            WHEN messages.mailbox_state = 0 AND excluded.mailbox_state = 1
              THEN messages.remote_uid
            ELSE excluded.remote_uid
          END,
          uid_validity = CASE
            WHEN messages.mailbox_state = 0 AND excluded.mailbox_state = 1
              THEN messages.uid_validity
            ELSE excluded.uid_validity
          END,
          received_at = excluded.received_at,
          sender = excluded.sender,
          recipients = excluded.recipients,
          cc = excluded.cc,
          internet_message_id = excluded.internet_message_id,
          subject = excluded.subject,
          preview = excluded.preview,
          flags = CASE
            WHEN EXISTS (
              SELECT 1 FROM pending_operations
              WHERE message_id = messages.id AND operation = 2
            ) THEN messages.flags | excluded.flags
            ELSE excluded.flags
          END,
          mailbox_state = CASE
            WHEN EXISTS (
              SELECT 1 FROM pending_operations
              WHERE message_id = messages.id AND operation IN (0, 1)
            ) THEN messages.mailbox_state
            WHEN messages.mailbox_state = 0 AND excluded.mailbox_state = 1
              THEN messages.mailbox_state
            ELSE excluded.mailbox_state
          END,
          body_path = COALESCE(excluded.body_path, messages.body_path)
      RETURNING id
      """)

    try statement.bind(message.accountID, at: 1)
    try statement.bind(message.remoteID, at: 2)
    try statement.bind(message.remoteUID, at: 3)
    try statement.bind(message.uidValidity, at: 4)
    try statement.bind(message.receivedAt, at: 5)
    try statement.bind(message.sender, at: 6)
    try statement.bind(message.recipients, at: 7)
    try statement.bind(message.cc, at: 8)
    try statement.bind(message.internetMessageID, at: 9)
    try statement.bind(message.subject, at: 10)
    try statement.bind(message.preview, at: 11)
    try statement.bind(message.isRead ? Int32(1) : Int32(0), at: 12)
    try statement.bind(message.mailboxState.rawValue, at: 13)
    try statement.bind(message.bodyPath, at: 14)

    guard try statement.step() else {
      throw DatabaseError.step("Message insert returned no identifier")
    }
    return statement.integer(at: 0)
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
        SET mailbox_state = ?, body_path = NULL, summary = NULL
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
      SELECT ?, ?, ?
      WHERE NOT EXISTS (
        SELECT 1 FROM pending_operations
        WHERE message_id = ? AND operation = ?
      )
      """)
    try statement.bind(messageID, at: 1)
    try statement.bind(operation.rawValue, at: 2)
    try statement.bind(Int64(Date().timeIntervalSince1970), at: 3)
    try statement.bind(messageID, at: 4)
    try statement.bind(operation.rawValue, at: 5)
    try statement.step()
  }

  private func readSummaries(from statement: SQLiteStatement) throws -> [MessageSummary] {
    var messages: [MessageSummary] = []
    messages.reserveCapacity(100)

    while try statement.step() {
      guard let state = MailboxState(rawValue: Int32(statement.integer(at: 16))) else { continue }
      messages.append(
        MessageSummary(
          id: statement.integer(at: 0),
          accountID: statement.integer(at: 1),
          accountName: statement.text(at: 2),
          accountEmail: statement.text(at: 3),
          accountProvider: statement.text(at: 4),
          remoteID: statement.text(at: 5),
          remoteUID: statement.optionalInteger(at: 6),
          receivedAt: statement.integer(at: 7),
          sender: statement.text(at: 8),
          recipients: statement.text(at: 9),
          cc: statement.text(at: 10),
          internetMessageID: statement.text(at: 11),
          subject: statement.text(at: 12),
          preview: statement.text(at: 13),
          isRead: statement.integer(at: 14) & 1 == 1,
          mailboxState: state,
          bodyPath: statement.optionalText(at: 15)
        ))
    }
    return messages
  }

  private static let summaryColumns = """
    m.id, m.account_id, a.name, a.email, a.provider, m.remote_id, m.remote_uid,
    m.received_at, m.sender, m.recipients, m.cc, m.internet_message_id,
    m.subject, m.preview, m.flags, m.body_path, m.mailbox_state
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

  private static func removeLegacyBodyCache(_ database: SQLiteDatabase) throws {
    let legacy = try database.prepare(
      """
      SELECT body_path FROM messages
      WHERE body_path IS NOT NULL AND body_path NOT LIKE '%/Bodies-v4/%'
      """)
    var paths: [String] = []
    while try legacy.step() {
      paths.append(legacy.text(at: 0))
    }
    guard !paths.isEmpty else { return }

    for path in paths {
      try? FileManager.default.removeItem(atPath: path)
    }
    try database.execute(
      """
      UPDATE messages SET body_path = NULL
      WHERE body_path IS NOT NULL AND body_path NOT LIKE '%/Bodies-v4/%'
      """)
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
          cc TEXT NOT NULL DEFAULT '',
          internet_message_id TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          preview TEXT NOT NULL DEFAULT '',
          flags INTEGER NOT NULL DEFAULT 0,
          mailbox_state INTEGER NOT NULL DEFAULT 0,
          body_path TEXT,
          summary TEXT,
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

    let columns = try database.prepare("PRAGMA table_info(messages)")
    var columnNames: Set<String> = []
    while try columns.step() {
      columnNames.insert(columns.text(at: 1))
    }

    var shouldRefreshGmailMetadata = false
    if !columnNames.contains("cc") {
      try database.execute("ALTER TABLE messages ADD COLUMN cc TEXT NOT NULL DEFAULT ''")
      shouldRefreshGmailMetadata = true
    }
    if !columnNames.contains("internet_message_id") {
      try database.execute(
        "ALTER TABLE messages ADD COLUMN internet_message_id TEXT NOT NULL DEFAULT ''")
      shouldRefreshGmailMetadata = true
    }
    if !columnNames.contains("summary") {
      try database.execute("ALTER TABLE messages ADD COLUMN summary TEXT")
    }
    if shouldRefreshGmailMetadata {
      try database.execute(
        """
        UPDATE accounts
        SET uid_validity = NULL, highest_uid = NULL, highest_modseq = NULL
        WHERE provider = 'gmail'
        """)
    }
  }
}
