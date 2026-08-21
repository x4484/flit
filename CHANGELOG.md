# Changelog

## 0.1.0 — Unreleased

First public beta candidate.

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
- Public Gmail access is gated on Google OAuth production approval
