# Changelog

## 0.1.0-beta.2 — 2026-08-21

### Fixed

- Message bodies no longer remain indefinitely on “Loading message…” when Gmail stalls or a cached IMAP connection goes stale
- Opening a message now cancels unrelated speculative prefetches, retries one transient IMAP failure, and enforces bounded connection, command, and body-fetch deadlines
- Cancelled Gmail session waiters now leave the queue immediately instead of delaying selected-message work

## 0.1.0-beta.1 — 2026-08-21

First public beta.

### Included

- Native AppKit unified inbox with local SQLite WAL and FTS5 search
- Gmail OAuth, bounded IMAP synchronization, remote reconciliation, and SMTP sending
- Inbox pagination and server-backed search for unsynchronized headers
- Rolling ten-message body prefetch with demand-prioritized loading and a bounded disk cache
- Lazy Gmail thread navigation with one active full-fidelity HTML reader
- Optimistic archive, trash, and read operations with retry tracking
- Reply, reply all, and forward with thread-aware headers
- Optional cached one-sentence OpenRouter summaries
- Universal Apple silicon and Intel packaging
- Developer ID signing, Apple notarization, DMG/ZIP packaging, and checksums through the protected release workflow

### Known limitations

- Gmail is the only connected provider
- New-message composition and attachments are not complete
- There is no offline SMTP outbox or automatic updater
- Google OAuth verification is incomplete; new users see Google's unverified-app warning, and the client is subject to the 100-new-user cap
