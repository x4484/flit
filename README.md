# Flit

Flit is an experimental, extremely lightweight native macOS mail client focused on one job: triaging mail quickly across accounts.

> **Status:** pre-alpha. The local-first AppKit interface, SQLite store, local header search, Gmail OAuth, bounded Gmail inbox sync, body-on-open loading, full-fidelity HTML rendering, cached OpenRouter summaries, optimistic remote actions, and Gmail reply/forward sending are working. iCloud remains under development.

## Principles

- Native AppKit shell, with an isolated WebKit view only for sender-authored HTML email
- Show the local inbox before touching the network
- Keep memory proportional to the visible viewport
- Download message bodies only when opened
- Delete cached bodies after archive; retain compact searchable headers
- Apply archive, trash, and read actions optimistically
- Keep the main thread free of SQL, MIME, file, and network work

## Current performance budgets

| Metric | Budget |
| --- | ---: |
| Idle memory | <60 MB |
| Normal triage memory | <90 MB |
| Warm launch to inbox | <100 ms |
| Archive visual response | <16 ms |
| Local search first results | <50 ms |

These are targets, not yet published benchmark results.

## Run

Requirements:

- macOS 13 or newer
- Swift 5.10 or newer through Xcode or Command Line Tools

```bash
swift run Flit
```

The initial build opens the local inbox immediately. Use **Accounts → Add Gmail Account…** after completing the [local Google OAuth setup](docs/google-oauth-setup.md). Flit then authenticates with XOAUTH2 and synchronizes Gmail inbox headers in bounded batches.

To populate local demo data:

```bash
FLIT_SEED_DEMO=1 swift run Flit
```

Build an ad-hoc signed app bundle:

```bash
make app
open dist/Flit.app
```

Run tests:

```bash
swift test
```

## Architecture

```text
AppKit UI
   │ paged value types + optimistic commands
   ▼
MailStore actor ── SQLite WAL + FTS5
   │
   ├── pending operation queue
   └── bounded body-file cache

GmailSyncService
   ├── TLS IMAP + XOAUTH2 metadata sync
   ├── bounded initial and incremental UID batches
   ├── 1 MiB body-on-open fetch + eight-file body cache
   ├── queued read, archive, and trash replication
   └── TLS SMTP + XOAUTH2 reply, reply-all, and forward

OpenRouterSummaryService
   └── one-sentence Ling 3.0 Flash summaries cached in SQLite

SyncCoordinator
   └── cross-account connection budget
```

The unified inbox is a keyset-paginated SQLite query. Archive and trash remove a row immediately, then persist a pending remote operation. Search covers inbox and archived headers through FTS5. Cached body files are deleted when a message leaves the inbox.

See [the interface direction](docs/interface-direction.md) for the native design principles and reference notes guiding the UI.

## Roadmap

- [x] Native AppKit unified-inbox shell
- [x] SQLite metadata store and FTS5 header search
- [x] Optimistic archive/trash queue
- [x] Bounded, paginated inbox reads
- [x] Gmail OAuth/XOAUTH2 account setup
- [x] Streaming IMAP transport and bounded incremental UID sync
- [x] Replicate queued Gmail archive, trash, and read operations
- [x] Reconcile remote Gmail moves, deletions, and read-state changes
- [x] Plain-text MIME body selection and bounded cache
- [x] Gmail SMTP reply, reply-all, and forward
- [x] Cached one-sentence OpenRouter summaries
- [ ] iCloud app-specific-password setup
- [ ] Offline SMTP outbox and retry queue
- [ ] Release-build performance harness with a million-message fixture

## Non-goals

Flit does not plan to support calendars, contacts, rules, rich-text composition, plugins, or general-purpose browsing inside the app.

## License

MIT
